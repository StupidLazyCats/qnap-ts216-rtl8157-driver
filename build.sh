#!/bin/bash
set -e

# Main build orchestration script for RTL8152 driver QPKG

echo "=========================================="
echo "RTL8152 Driver QPKG Build System"
echo "=========================================="

# Configuration
DOCKER_IMAGE="rtl8152-builder"
DOCKER_TAG="${DOCKER_TAG:-latest}"  # Allow override from environment
CONTAINER_NAME="rtl8152-build"

# Load versions from versions.yml (the single source of truth for all versions).
# There are intentionally NO hardcoded version fallbacks here: a missing or garbled
# versions.yml must fail loudly instead of silently building a stale version.
if [ ! -f "versions.yml" ]; then
    echo "ERROR: versions.yml not found - it is the single source of truth for versions."
    echo "Run this script from the repository root."
    exit 1
fi

# Parse YAML using grep and sed (simple approach, no external dependencies)
DEFAULT_KERNEL_VERSION=$(grep '[[:space:]]*kernel_version:' versions.yml | head -1 | sed 's/.*kernel_version:[[:space:]]*"\(.*\)".*/\1/' | tr -d '"' | tr -d "'")

# Target platform, also from versions.yml. These drive both the kernel build
# inside the image and the QDK architecture directory used for packaging.
read_key() {
    grep "^$1:" versions.yml | sed "s/^$1:[[:space:]]*\"\(.*\)\".*/\1/" | tr -d '"' | tr -d "'"
}
TARGET_MODEL=$(read_key target_model)
KERNEL_CONFIG_FILE=$(read_key kernel_config)
KERNEL_ARCH=$(read_key kernel_arch)
CROSS_COMPILE_PREFIX=$(read_key cross_compile)
QPKG_ARCH=$(read_key qpkg_arch)
DEFAULT_DRIVER_SOURCE_REF=$(read_key driver_source_ref)
DEFAULT_DRIVER_URL=$(read_key driver_url)

for _k in TARGET_MODEL KERNEL_CONFIG_FILE KERNEL_ARCH CROSS_COMPILE_PREFIX QPKG_ARCH; do
    eval "_v=\$$_k"
    if [ -z "${_v}" ]; then
        echo "ERROR: could not read the target platform keys from versions.yml (${_k} is empty)"
        echo "Expected target_model, kernel_config, kernel_arch, cross_compile and qpkg_arch."
        exit 1
    fi
done

# Kernel series (5.10.60 -> 5.10), used for the GPL source path
KERNEL_SERIES=$(echo "${DEFAULT_KERNEL_VERSION}" | cut -d. -f1-2)

# Use environment variables if set, otherwise use values from versions.yml
KERNEL_VERSION="${KERNEL_VERSION:-${DEFAULT_KERNEL_VERSION}}"
DRIVER_SOURCE_REF="${DRIVER_SOURCE_REF:-${DEFAULT_DRIVER_SOURCE_REF}}"
DRIVER_URL="${DRIVER_URL:-${DEFAULT_DRIVER_URL}}"

if [ -z "${DRIVER_SOURCE_REF}" ] && [ -z "${DRIVER_URL}" ]; then
    echo "ERROR: versions.yml must set driver_source_ref (or driver_url)"
    exit 1
fi

# The Realtek version is not configured anywhere - build_driver.sh reads it out of
# the source it downloaded and leaves it in output/driver/driver_version, which
# create_qpkg() picks up. There is no version to print until the driver is built.
DRIVER_VERSION_FILE="output/driver/driver_version"

echo "Target: QNAP ${TARGET_MODEL} (${KERNEL_ARCH}, kernel ${KERNEL_VERSION}-qnap)"
echo "Driver: Realtek r8152 from ${DRIVER_URL:-ref ${DRIVER_SOURCE_REF}}"
echo "=========================================="

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not in PATH"
    exit 1
fi

# Parse command line arguments
COMMAND="${1:-all}"

# Function to check and prepare GPL source
check_gpl_source() {
    if [ ! -d "GPL_QTS/src/linux-${KERNEL_SERIES}" ]; then
        echo ""
        echo "=========================================="
        echo "QNAP GPL Kernel Source Required"
        echo "=========================================="
        echo ""
        echo "GPL source not found. Checking for archives..."
        echo ""

        # Check if prepare script exists
        if [ ! -f "prepare_gpl_source.sh" ]; then
            echo "✗ Error: prepare_gpl_source.sh not found"
            exit 1
        fi

        # Run preparation script
        ./prepare_gpl_source.sh

        # Verify it worked
        if [ ! -d "GPL_QTS/src/linux-${KERNEL_SERIES}" ]; then
            echo ""
            echo "✗ Error: GPL source preparation failed"
            echo ""
            echo "Please download GPL archives manually:"
            echo "  1. Visit: https://sourceforge.net/projects/qosgpl/files/QNAP%20NAS%20GPL%20Source/QTS%205.2.0/"
            echo "  2. Download both parts: QTS_Kernel_*.0.tar.gz and QTS_Kernel_*.1.tar.gz"
            echo "  3. Place them in: gpl_source/"
            echo "  4. Run: ./prepare_gpl_source.sh"
            echo ""
            exit 1
        fi
    fi
}

show_usage() {
    cat << EOF
Usage: $0 [command]

Commands:
  all              - Build Docker image, compile driver, and create QPKG (default)
  image            - Build Docker image only
  driver           - Compile driver only (requires existing image)
  qpkg             - Create QPKG package only (requires compiled driver)
  clean            - Remove Docker image and build artifacts
  shell            - Start interactive shell in build container
  help             - Show this help message

Environment Variables:
  DRIVER_SOURCE_REF - Commit, tag, or branch to fetch (default: from versions.yml)
  DRIVER_URL        - Fetch the driver source from this URL instead of the tag
  KERNEL_VERSION    - Target kernel version (default: from versions.yml)
  QPKG_VERSION      - QPKG package version (default: the Realtek version that was
                      compiled, read out of the source by build_driver.sh)

Configuration:
  Defaults live in versions.yml:
    - driver_source_ref / driver_url: where the r8152 source comes from
    - kernel_version:  Target kernel version
    - target_model, kernel_config, kernel_arch, cross_compile, qpkg_arch:
      the target platform
  Environment variables override these defaults.

  The Realtek version itself is NOT configured. It is parsed from DRIVER_VERSION
  in the downloaded r8152.c and written to output/driver/driver_version.

Note:
  The aarch64 module is CROSS-compiled from an x86_64 image. QNAP's GPL bundle
  ships the kernel tree pre-built for x86_64 only, so ./build.sh image configures
  and builds that tree for arm64 - slow the first time, then cached as a layer.

Examples:
  $0 all                                    # Full build (uses versions.yml)
  QPKG_VERSION=5.55.1b1 $0 all              # Override QPKG version only
  DRIVER_SOURCE_REF=main $0 all             # Build a different upstream ref
  $0 driver                                  # Compile driver only
  $0 shell                                   # Interactive debugging

Icons:
  Icons are located in qpkg/RTL8152_Driver/icons/ directory.
  Required files (64x64 GIF for standard, 80x80 for dialog):
    - RTL8152_Driver.gif (enabled state)
    - RTL8152_Driver_gray.gif (disabled state)
    - RTL8152_Driver_80.gif (80x80, dialog popup)
  These files are included in the qpkg source template.

EOF
}

# Function to build Docker image
build_image() {
    echo ""
    echo "[Step 1/3] Building Docker image..."
    echo "=========================================="

    # Verify GPL source before building image
    if [ ! -d "GPL_QTS/src/linux-${KERNEL_SERIES}" ]; then
        echo "✗ ERROR: GPL source not found!"
        echo ""
        echo "The Dockerfile requires GPL_QTS/src/linux-${KERNEL_SERIES}/ to exist."
        echo "Docker build will fail at COPY instruction."
        echo ""
        echo "Please run: ./prepare_gpl_source.sh"
        echo ""
        exit 1
    fi

    echo "✓ GPL source verified: GPL_QTS/src/linux-${KERNEL_SERIES}/"

    # The kernel config for the target model is a COPY source in the Dockerfile,
    # so a missing one fails the build with an opaque message. Catch it here.
    MODEL_CONFIG="GPL_QTS/kernel_cfg/${TARGET_MODEL}/${KERNEL_CONFIG_FILE}"
    if [ ! -f "${MODEL_CONFIG}" ]; then
        echo "✗ ERROR: kernel config not found: ${MODEL_CONFIG}"
        echo ""
        echo "Available models with a ${KERNEL_CONFIG_FILE}:"
        for d in GPL_QTS/kernel_cfg/*/; do
            [ -f "${d}${KERNEL_CONFIG_FILE}" ] && echo "  - $(basename "${d}")"
        done
        echo ""
        echo "Set target_model in versions.yml to one of the above."
        exit 1
    fi
    echo "✓ Kernel config verified: ${MODEL_CONFIG}"
    echo ""
    echo "NOTE: this builds QNAP's kernel tree for ${KERNEL_ARCH} from source and"
    echo "      takes a while. The result is cached as a Docker layer."
    echo ""

    docker build -t "${DOCKER_IMAGE}:${DOCKER_TAG}" \
        --build-arg TARGET_MODEL="${TARGET_MODEL}" \
        --build-arg KERNEL_SERIES="${KERNEL_SERIES}" \
        --build-arg KERNEL_CONFIG_FILE="${KERNEL_CONFIG_FILE}" \
        --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
        --build-arg KERNEL_ARCH="${KERNEL_ARCH}" \
        --build-arg CROSS_COMPILE_PREFIX="${CROSS_COMPILE_PREFIX}" \
        .

    echo "Docker image built successfully: ${DOCKER_IMAGE}:${DOCKER_TAG}"
}

# Function to compile driver
compile_driver() {
    echo ""
    echo "[Step 2/3] Compiling RTL8152 driver..."
    echo "=========================================="
    echo "Using QNAP GPL kernel source from Docker image"
    echo "  (built for ${KERNEL_ARCH} during image build)"

    # Prepare volume mounts
    VOLUME_MOUNTS="-v $(pwd)/output:/build/output"

    # Remove old container if exists
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

    # Run build
    docker run --name "${CONTAINER_NAME}" \
        ${VOLUME_MOUNTS} \
        -e DRIVER_SOURCE_REF="${DRIVER_SOURCE_REF}" \
        -e DRIVER_URL="${DRIVER_URL}" \
        -e KERNEL_VERSION="${KERNEL_VERSION}" \
        "${DOCKER_IMAGE}:${DOCKER_TAG}" \
        /bin/bash -c "/build/build_driver.sh"

    # Check if driver was built
    if [ -f "output/driver/r8152.ko" ]; then
        echo ""
        echo "Driver compiled successfully!"
        echo "Location: $(pwd)/output/driver/r8152.ko"
        echo "Version:  $(cat "${DRIVER_VERSION_FILE}")"
        ls -lh output/driver/r8152.ko
    else
        echo "ERROR: Driver compilation failed!"
        exit 1
    fi

    # Cleanup container
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
}

# Function to create QPKG
create_qpkg() {
    echo ""
    echo "[Step 3/3] Creating QPKG package..."
    echo "=========================================="

    # Check if driver exists
    if [ ! -f "output/driver/r8152.ko" ]; then
        echo "ERROR: Driver not found! Please compile the driver first."
        echo "Run: $0 driver"
        exit 1
    fi

    if [ ! -f "${DRIVER_VERSION_FILE}" ]; then
        echo "ERROR: ${DRIVER_VERSION_FILE} not found - it is written by build_driver.sh"
        echo "from the Realtek source it compiled. Rebuild the driver: $0 driver"
        exit 1
    fi
    DRIVER_VERSION=$(cat "${DRIVER_VERSION_FILE}")

    # QPKG_VERSION is overridable for a one-off package revision of the same driver;
    # left alone it is the upstream Realtek version that was actually compiled.
    QPKG_VERSION="${QPKG_VERSION:-${DRIVER_VERSION}}"
    echo "Packaging Realtek r8152 ${DRIVER_VERSION} as QPKG version ${QPKG_VERSION}"

    # Validate qpkg source directory exists
    if [ ! -d "qpkg/RTL8152_Driver" ]; then
        echo "ERROR: QPKG source template not found at qpkg/RTL8152_Driver"
        echo "Current directory: $(pwd)"
        echo "Directory contents:"
        ls -la qpkg/ || echo "qpkg directory does not exist"
        exit 1
    fi

    # Validate required template files
    if [ ! -f "qpkg/RTL8152_Driver/qpkg.cfg" ]; then
        echo "ERROR: qpkg.cfg not found in template"
        exit 1
    fi

    if [ ! -f "qpkg/RTL8152_Driver/package_routines" ]; then
        echo "ERROR: package_routines not found in template"
        exit 1
    fi

    if [ ! -f "qpkg/RTL8152_Driver/shared/RTL8152_Driver.sh" ]; then
        echo "ERROR: RTL8152_Driver.sh not found in template"
        exit 1
    fi

    echo "QPKG template validation passed"

    # Remove old container if exists
    docker rm -f "${CONTAINER_NAME}-qpkg" 2>/dev/null || true

    # Prepare volume mounts for QPKG creation
    # Mount output directory for driver files and final QPKG
    # Mount qpkg directory which contains the source template with icons
    QPKG_VOLUME_MOUNTS="-v $(pwd)/output:/build/output"
    QPKG_VOLUME_MOUNTS="${QPKG_VOLUME_MOUNTS} -v $(pwd)/qpkg:/qpkg_source"

    # Run QPKG creation with template-based approach
    # Icons are now part of the qpkg/RTL8152_Driver/icons/ directory
    docker run --name "${CONTAINER_NAME}-qpkg" \
        ${QPKG_VOLUME_MOUNTS} \
        -e DRIVER_VERSION="${DRIVER_VERSION}" \
        -e QPKG_VERSION="${QPKG_VERSION}" \
        -e QPKG_ARCH="${QPKG_ARCH}" \
        "${DOCKER_IMAGE}:${DOCKER_TAG}" \
        /bin/bash -c "/build/build_qpkg.sh"

    # Find the generated QPKG file
    QPKG_FILE="output/RTL8152_Driver_${QPKG_VERSION}_${QPKG_ARCH}.qpkg"

    if [ -f "${QPKG_FILE}" ]; then
        echo ""
        echo "QPKG package created successfully!"
        echo "Location: ${QPKG_FILE}"
        ls -lh "${QPKG_FILE}"
        echo ""
        echo "=========================================="
        echo "Installation Instructions:"
        echo "=========================================="
        echo "1. Copy ${QPKG_FILE} to your QNAP NAS"
        echo "2. Install via App Center > Install Manually"
        echo "   OR"
        echo "3. Install via SSH: sh $(basename ${QPKG_FILE})"
        echo "=========================================="
    else
        echo "ERROR: QPKG creation failed!"
        echo "Expected package file not found: ${QPKG_FILE}"
        exit 1
    fi

    # Cleanup container
    docker rm "${CONTAINER_NAME}-qpkg" 2>/dev/null || true
}

# Function to clean build artifacts
clean() {
    echo "Cleaning build artifacts..."

    # Remove output directory
    rm -rf output

    # Remove Docker image
    docker rmi "${DOCKER_IMAGE}:${DOCKER_TAG}" 2>/dev/null || true

    # Remove any leftover containers
    docker rm -f "${CONTAINER_NAME}" "${CONTAINER_NAME}-qpkg" 2>/dev/null || true

    echo "Cleanup complete!"
}

# Function to start interactive shell
interactive_shell() {
    echo "Starting interactive build shell..."
    echo "Available scripts:"
    echo "  /build/build_driver.sh  - Compile driver"
    echo "  /build/create_qpkg.sh   - Create QPKG package"
    echo ""

    docker run -it --rm \
        -v $(pwd)/output:/build/output \
        "${DOCKER_IMAGE}:${DOCKER_TAG}" \
        /bin/bash
}

# Main execution
case "${COMMAND}" in
    all)
        check_gpl_source
        build_image
        compile_driver
        create_qpkg
        echo ""
        echo "=========================================="
        echo "Build process completed successfully!"
        echo "=========================================="
        ;;
    image)
        check_gpl_source
        build_image
        ;;
    driver)
        check_gpl_source
        compile_driver
        ;;
    qpkg)
        create_qpkg
        ;;
    clean)
        clean
        ;;
    shell)
        check_gpl_source
        interactive_shell
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo "ERROR: Unknown command: ${COMMAND}"
        echo ""
        show_usage
        exit 1
        ;;
esac
