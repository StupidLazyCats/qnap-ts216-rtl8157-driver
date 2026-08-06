#!/bin/bash
set -e

# Configuration
KERNEL_VERSION="${KERNEL_VERSION:-5.10.60}"
KERNEL_SRC="${KERNEL_SRC:-/build/kernel/linux-source}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
# DRIVER_VERSION is NOT an input. It is read out of the Realtek source that was
# actually downloaded (see download_driver_source) and written to
# output/driver/driver_version for build.sh to package with, so the version stamped
# on the QPKG can never disagree with the code inside it.
#
# DRIVER_URL is optional. When set it wins, so a Realtek direct link or a local
# mirror can be used instead of the default tag archive - see versions.yml. Only
# one of the two is needed, hence the tag is required only as the fallback.
if [ -n "${DRIVER_URL}" ]; then
    REALTEK_DRIVER_URL="${DRIVER_URL}"
else
    : "${DRIVER_SOURCE_TAG:?set driver_source_tag or driver_url in versions.yml}"
    REALTEK_DRIVER_URL="https://github.com/awesometic/realtek-r8125-dkms/archive/refs/tags/${DRIVER_SOURCE_TAG}.tar.gz"
fi
# RTL8125/8125B are PCIe 2.5GbE controllers, driven by r8125.ko
DRIVER_NAME="r8125"
# Composed per include/linux/vermagic.h from the TS-X33 GPL config:
#   UTS_RELEASE "5.10.60-qnap" + CONFIG_SMP -> "SMP " + CONFIG_PREEMPT unset
#   (PREEMPT_VOLUNTARY contributes nothing) + CONFIG_MODULE_UNLOAD -> "mod_unload "
#   + CONFIG_MODVERSIONS unset + arm64's MODULE_ARCH_VERMAGIC "aarch64".
# CONFIG_GCC_PLUGINS is off, so no RANDSTRUCT hash is appended.
EXPECTED_VERMAGIC="${KERNEL_VERSION}-qnap SMP mod_unload aarch64"

echo "==================================="
echo "RTL8125 Driver Build for QNAP arm64"
echo "==================================="
echo "Kernel Version: ${KERNEL_VERSION}"
echo "Driver source:  ${REALTEK_DRIVER_URL}"
echo "Target arch:    ${ARCH} (cross: ${CROSS_COMPILE})"
echo "==================================="

# Function to verify kernel source
verify_kernel_source() {
    echo "[1/6] Verifying kernel source..."

    if [ ! -d "${KERNEL_SRC}" ]; then
        echo "ERROR: Kernel source not found at ${KERNEL_SRC}!"
        echo "The Docker image should have built the arm64 kernel tree."
        echo "Please rebuild the Docker image: ./build.sh image"
        exit 1
    fi

    # build_kernel.sh produces these; without them modpost cannot resolve the
    # kernel's exported symbols and breakage would only show up at insmod time.
    for f in Module.symvers scripts/mod/modpost include/generated/utsrelease.h; do
        if [ ! -e "${KERNEL_SRC}/${f}" ]; then
            echo "ERROR: ${KERNEL_SRC}/${f} missing - kernel tree was not built for ${ARCH}"
            echo "Please rebuild the Docker image: ./build.sh image"
            exit 1
        fi
    done

    echo "✓ Kernel source found and built for ${ARCH}"
    echo "  Location: ${KERNEL_SRC}"
    echo "  Release:  $(cat "${KERNEL_SRC}/include/config/kernel.release" 2>/dev/null || echo unknown)"
}

# Function to verify the cross toolchain
verify_toolchain() {
    echo "[2/6] Verifying cross toolchain..."

    if ! command -v "${CROSS_COMPILE}gcc" > /dev/null 2>&1; then
        echo "ERROR: ${CROSS_COMPILE}gcc not found in PATH"
        exit 1
    fi

    echo "✓ $(${CROSS_COMPILE}gcc --version | head -1)"
}

# Function to download driver source
download_driver_source() {
    echo "[3/6] Downloading Realtek r8125 driver source..."
    echo "  URL: ${REALTEK_DRIVER_URL}"

    rm -rf /build/driver/src-tree
    mkdir -p /build/driver/src-tree
    cd /build/driver

    TARBALL="r8125-${DRIVER_SOURCE_TAG:-source}.tar.gz"

    if [ ! -f "${TARBALL}" ]; then
        if ! wget -O "${TARBALL}" "${REALTEK_DRIVER_URL}"; then
            rm -f "${TARBALL}"
            echo "ERROR: could not download the driver source from:"
            echo "  ${REALTEK_DRIVER_URL}"
            echo "Set driver_url in versions.yml to a reachable archive."
            exit 1
        fi
    fi

    # Strip the archive's top-level directory so the layout is the same whatever
    # the source is named - a Realtek tarball unpacks to r8125-9.0xx.yy/, a tag
    # archive to <repo>-<tag>/.
    tar -xzf "${TARBALL}" -C /build/driver/src-tree --strip-components=1

    cd /build/driver/src-tree

    if [ ! -f "src/Makefile" ]; then
        echo "ERROR: src/Makefile not found - unexpected source layout"
        ls -la
        exit 1
    fi

    # The version is whatever this source says it is. r8125.h:598 reads
    #   #define RTL8125_VERSION "9.018.00" NAPI_SUFFIX DASH_SUFFIX ... RSS_SUFFIX
    # so the leading quoted literal is the Realtek release; the suffixes are macros
    # resolved from the feature flags and are appended to what modinfo reports.
    DRIVER_VERSION=$(sed -n 's/^#define[[:space:]]\+RTL8125_VERSION[[:space:]]\+"\([0-9][0-9.]*\)".*/\1/p' src/r8125.h | head -1)
    if [ -z "${DRIVER_VERSION}" ]; then
        echo "ERROR: could not read RTL8125_VERSION from src/r8125.h"
        grep -n 'RTL8125_VERSION' src/r8125.h || true
        exit 1
    fi

    echo "✓ Driver source: $(pwd)"
    echo "  Upstream version: ${DRIVER_VERSION}"
}

# Function to configure driver build options
patch_driver() {
    echo "[4/6] Configuring driver build options..."

    # S5 Wake-on-LAN is on by default in Realtek's Makefile. Assert rather than
    # patch, so a future release that flips the default is caught here instead of
    # silently shipping a driver that cannot wake the NAS.
    if grep -qE '^[[:space:]]*ENABLE_S5WOL[[:space:]]*=[[:space:]]*y' src/Makefile; then
        echo "✓ S5_WOL enabled (Realtek default)"
    else
        echo "S5_WOL not enabled by default - enabling..."
        sed -i 's/^\([[:space:]]*ENABLE_S5WOL[[:space:]]*=[[:space:]]*\)n/\1y/' src/Makefile
        grep -E '^[[:space:]]*ENABLE_S5WOL' src/Makefile
    fi

    # Receive Side Scaling. Realtek ships this off; turn it on so RX work can be
    # spread over the NAS's cores instead of landing on one. The RTL8125 supports
    # 8 RX queues against only 2 TX, so this is the side worth scaling.
    #
    # The driver still decides at runtime whether to actually use it
    # (r8125_n.c:15769): it needs a chip revision with HwSuppRssVer > 0 (NOT the
    # case for CFG_METHOD_2/3/6, i.e. early RTL8125A), MSI-X up (HwCurrIsrVer > 1),
    # and at least as many IRQ vectors as rings, where the ring count is
    # min(8, netif_get_num_default_rss_queues()) - the latter being
    # min(8, num_online_cpus()), so 4 on a TS-433. If any of that fails it falls
    # back to a single ring rather than misbehaving.
    sed -i 's/^\([[:space:]]*ENABLE_RSS_SUPPORT[[:space:]]*=[[:space:]]*\)n/\1y/' src/Makefile
    if grep -qE '^[[:space:]]*ENABLE_RSS_SUPPORT[[:space:]]*=[[:space:]]*y' src/Makefile; then
        echo "✓ RSS enabled"
    else
        echo "ERROR: failed to enable ENABLE_RSS_SUPPORT in src/Makefile"
        grep -nE 'ENABLE_RSS_SUPPORT' src/Makefile || true
        exit 1
    fi

    # PCIe ASPM off. Measured on a TS-433 (RTL8125B, mcfg 5): with Realtek's
    # CONFIG_ASPM = y default, a 60s single-stream iperf3 into the NAS collapsed
    # from 2.35Gb/s to 1.2-1.6Gb/s with rx_missed climbing into the thousands -
    # L1 exit latency stalls the DMA engine, the RX FIFO overruns, and every
    # dropped frame becomes a TCP retransmit. With aspm=0 the same test held
    # 2.35Gb/s for the full 60s and rx_missed fell to 223, matching the sender's
    # 223 retransmits exactly.
    #
    # CONFIG_ASPM is tested in exactly one place (r8125_n.c:277) and only sets the
    # default of the `aspm` module parameter, so this is identical to passing
    # aspm=0 and gates no other code. Override at load time with `insmod ... aspm=1`.
    # Costs a little idle power in exchange for not dropping frames under load.
    sed -i 's/^\([[:space:]]*CONFIG_ASPM[[:space:]]*=[[:space:]]*\)y/\1n/' src/Makefile
    if grep -qE '^[[:space:]]*CONFIG_ASPM[[:space:]]*=[[:space:]]*n' src/Makefile; then
        echo "✓ PCIe ASPM disabled"
    else
        echo "ERROR: failed to disable CONFIG_ASPM in src/Makefile"
        grep -nE 'CONFIG_ASPM' src/Makefile || true
        exit 1
    fi

    # Second TX ring. The RTL8125 caps at 2 (R8125_MAX_TX_QUEUES, r8125.h:729), and
    # the driver only takes it if irq_nvecs >= 19 (r8125_n.c:15744). Measured on a
    # TS-433: 32 MSI-X vectors (eth0-0..eth0-31), so the threshold is met with room
    # to spare. Worth having because TX all lands on one interrupt - on that box
    # eth0-16 (tx_ring[0]) had ~1.0M interrupts pinned to CPU0, more than any
    # single RX ring, while vectors 17/18 sat idle.
    sed -i 's/^\([[:space:]]*ENABLE_MULTIPLE_TX_QUEUE[[:space:]]*=[[:space:]]*\)n/\1y/' src/Makefile
    if grep -qE '^[[:space:]]*ENABLE_MULTIPLE_TX_QUEUE[[:space:]]*=[[:space:]]*y' src/Makefile; then
        echo "✓ Multiple TX queues enabled"
    else
        echo "ERROR: failed to enable ENABLE_MULTIPLE_TX_QUEUE in src/Makefile"
        grep -nE 'ENABLE_MULTIPLE_TX_QUEUE' src/Makefile || true
        exit 1
    fi

    echo "Driver configuration complete."
}

# Function to compile driver
compile_driver() {
    echo "[5/6] Compiling driver..."

    # CONFIG_MODVERSIONS is not set in QNAP's config, so the module carries no
    # symbol CRCs and the kernel resolves its imports by name at load time. That
    # makes matching struct layouts entirely a matter of compiling against the
    # same headers with the same defines.
    #
    # QNAP's defines gate real struct fields - a trailing `int pid` in
    # struct mm_struct under CONFIG_MACH_QNAPTS && QNAP_HAL, plus fields in the
    # iSCSI/NFS target headers and genhd.h/writeback.h. r8125 touches none of
    # those, but the kernel tree was built with them (build_kernel.sh) and
    # compiling the module with a different set is a difference with no upside.
    QNAP_DEFINES="$(cat /build/kernel/qnap_defines 2>/dev/null || true)"
    if [ -z "${QNAP_DEFINES}" ]; then
        echo "ERROR: /build/kernel/qnap_defines missing - rebuild the image"
        exit 1
    fi
    echo "  QNAP defines: ${QNAP_DEFINES}"

    # -fno-stack-protector: our toolchain is new enough that the kernel config
    # turns on CONFIG_STACKPROTECTOR_PER_TASK, which QNAP's gcc 4.9 could not do.
    # That makes arch/arm64/Makefile compile with
    #   -mstack-protector-guard=sysreg -mstack-protector-guard-reg=sp_el0
    #   -mstack-protector-guard-offset=<offsetof(task_struct, stack_canary)>
    # so the module would read its canary from an offset off sp_el0 computed from
    # OUR task_struct, while the running kernel uses the global __stack_chk_guard.
    # The symbol is def_bool with no prompt, so it cannot be turned off in the
    # config (see build_kernel.sh). Dropping the canary from the module sidesteps
    # the mismatch entirely and changes no struct layout or exported symbol.
    # EXTRA_CFLAGS is deliberately NOT set here. Realtek's src/Makefile builds its
    # entire feature set with `EXTRA_CFLAGS += -DENABLE_...` (S5WOL, DASH, ASPM,
    # NAPI, EEE, ...), and a command-line `EXTRA_CFLAGS=` overrides makefile
    # assignments, silently discarding all of them - which breaks the build
    # outright, since r8125_dash.c then compiles against a struct
    # rtl8125_private whose DASH members are #ifdef'd out. Extra flags go through
    # KCFLAGS, which kbuild appends rather than replaces. -O2 needs no help; the
    # kernel build already sets it.
    make ARCH="${ARCH}" \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         -C "${KERNEL_SRC}" \
         M="$(pwd)/src" \
         modules \
         KCFLAGS="${QNAP_DEFINES} -fno-stack-protector"

    if [ ! -f "src/${DRIVER_NAME}.ko" ]; then
        echo "ERROR: Driver compilation failed - ${DRIVER_NAME}.ko not found!"
        exit 1
    fi

    # Confirm the feature flags actually reached gcc. Setting them in src/Makefile
    # is not sufficient on its own: a command-line EXTRA_CFLAGS= silently overrides
    # every `EXTRA_CFLAGS +=` in that file, which is how all of these got discarded
    # once already. kbuild records the real command line in the .cmd file, so check
    # there rather than trusting the Makefile edit.
    CMD_FILE="src/.${DRIVER_NAME}_n.o.cmd"
    if [ ! -f "${CMD_FILE}" ]; then
        echo "ERROR: ${CMD_FILE} not found - cannot verify the compile flags"
        exit 1
    fi
    for d in ENABLE_S5WOL ENABLE_RSS_SUPPORT ENABLE_MULTIPLE_TX_QUEUE; do
        if grep -q -- "-D${d}" "${CMD_FILE}"; then
            echo "  ✓ -D${d} reached the compiler"
        else
            echo "ERROR: -D${d} was NOT passed to the compiler"
            echo "Defines actually used:"
            grep -oE '\-D(ENABLE|CONFIG|DISABLE)_[A-Z0-9_]+' "${CMD_FILE}" | sort -u | sed 's/^/    /'
            exit 1
        fi
    done

    # ASPM is the inverse case: the define must be ABSENT, since its only effect
    # is to default the aspm module parameter to 1.
    if grep -q -- "-DCONFIG_ASPM" "${CMD_FILE}"; then
        echo "ERROR: -DCONFIG_ASPM reached the compiler; ASPM would default to on"
        exit 1
    fi
    echo "  ✓ -DCONFIG_ASPM absent (aspm defaults to 0)"

    echo "Driver compiled successfully!"
    ls -lh "src/${DRIVER_NAME}.ko"
}

# Function to verify the built module targets the right kernel
verify_module() {
    echo "[6/6] Verifying built module..."

    KO="src/${DRIVER_NAME}.ko"

    # A module built for the wrong arch or kernel is the single most common way
    # this project has broken, and it is invisible until insmod on the NAS.
    FILE_TYPE=$(file -b "${KO}")
    echo "  ELF: ${FILE_TYPE}"
    case "${FILE_TYPE}" in
        *aarch64*) ;;
        *)
            echo "ERROR: module is not an aarch64 object!"
            exit 1
            ;;
    esac

    ACTUAL_VERMAGIC=$(modinfo -F vermagic "${KO}")
    echo "  vermagic: ${ACTUAL_VERMAGIC}"
    if [ "${ACTUAL_VERMAGIC}" != "${EXPECTED_VERMAGIC}" ]; then
        echo "ERROR: vermagic mismatch - insmod on the NAS would reject this module"
        echo "  Expected: ${EXPECTED_VERMAGIC}"
        echo "  Actual:   ${ACTUAL_VERMAGIC}"
        exit 1
    fi

    # The QPKG is stamped with DRIVER_VERSION as parsed out of r8125.h, so confirm
    # the compiled object agrees. modinfo reports the version with the feature
    # suffixes appended (e.g. 9.018.00-NAPI-DASH-RSS), hence comparing the head.
    MODULE_VERSION=$(modinfo -F version "${KO}")
    echo "  version:  ${MODULE_VERSION}"
    if [ "${MODULE_VERSION%%-*}" != "${DRIVER_VERSION}" ]; then
        echo "ERROR: built module reports ${MODULE_VERSION%%-*}, but the source parsed as ${DRIVER_VERSION}"
        exit 1
    fi

    echo "  srcversion: $(modinfo -F srcversion "${KO}")"
    echo "✓ Module verified"
}

# Function to prepare output
prepare_output() {
    echo "Preparing output..."

    mkdir -p /build/output/driver
    cp "src/${DRIVER_NAME}.ko" /build/output/driver/

    # Get driver info
    modinfo "src/${DRIVER_NAME}.ko" > /build/output/driver/module_info.txt || true

    # How the version reaches packaging: build_qpkg.sh runs in a separate container
    # and cannot see the source tree, so hand it across on the shared output volume.
    echo "${DRIVER_VERSION}" > /build/output/driver/driver_version

    echo "Driver build complete!"
    echo "Output location: /build/output/driver/${DRIVER_NAME}.ko"
    echo "Version:         ${DRIVER_VERSION}"
}

# Main build process
main() {
    verify_kernel_source
    verify_toolchain
    download_driver_source
    patch_driver
    compile_driver
    verify_module
    prepare_output

    echo ""
    echo "==================================="
    echo "Build completed successfully!"
    echo "==================================="
    echo "Driver: /build/output/driver/${DRIVER_NAME}.ko"
    echo ""
    echo "Next step: Run build_qpkg.sh to package the driver"
}

# Run main function
main
