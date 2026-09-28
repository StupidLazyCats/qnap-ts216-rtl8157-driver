#!/bin/bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-5.10.60}"
KERNEL_SRC="${KERNEL_SRC:-/build/kernel/linux-source}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DRIVER_NAME="r8152"
EXPECTED_VERMAGIC="${KERNEL_VERSION}-qnap SMP mod_unload aarch64"

if [ -n "${DRIVER_URL:-}" ]; then
    REALTEK_DRIVER_URL="${DRIVER_URL}"
else
    : "${DRIVER_SOURCE_REF:?set driver_source_ref or driver_url in versions.yml}"
    REALTEK_DRIVER_URL="https://github.com/RikshaDriver/realtek-r8152-linux/archive/${DRIVER_SOURCE_REF}.tar.gz"
fi

echo "=========================================="
echo "Realtek RTL8157 driver build for QNAP ARM64"
echo "=========================================="
echo "Kernel: ${KERNEL_VERSION}-qnap"
echo "Source: ${REALTEK_DRIVER_URL}"
echo "Target: ${ARCH} (${CROSS_COMPILE})"

verify_kernel_source() {
    echo "[1/6] Verifying prepared QNAP kernel tree"
    for file in Module.symvers scripts/mod/modpost include/generated/utsrelease.h; do
        if [ ! -e "${KERNEL_SRC}/${file}" ]; then
            echo "ERROR: ${KERNEL_SRC}/${file} is missing"
            exit 1
        fi
    done

    actual_release=$(cat "${KERNEL_SRC}/include/config/kernel.release")
    if [ "${actual_release}" != "${KERNEL_VERSION}-qnap" ]; then
        echo "ERROR: prepared kernel release is '${actual_release}'"
        exit 1
    fi
}

verify_toolchain() {
    echo "[2/6] Verifying cross compiler"
    command -v "${CROSS_COMPILE}gcc" >/dev/null
    "${CROSS_COMPILE}gcc" --version | head -1
}

download_driver_source() {
    echo "[3/6] Downloading pinned r8152 source"
    rm -rf /build/driver/src-tree
    mkdir -p /build/driver/src-tree

    wget -q --show-progress -O /build/driver/r8152.tar.gz "${REALTEK_DRIVER_URL}"
    tar -xzf /build/driver/r8152.tar.gz \
        -C /build/driver/src-tree --strip-components=1
    cd /build/driver/src-tree

    for file in Makefile r8152.c compatibility.h; do
        if [ ! -f "${file}" ]; then
            echo "ERROR: expected driver file '${file}' is missing"
            exit 1
        fi
    done

    DRIVER_VERSION=$(sed -n \
        's/^#define[[:space:]]\+DRIVER_VERSION[[:space:]]\+"v\([0-9][0-9.]*\)".*/\1/p' \
        r8152.c | head -1)
    if [ -z "${DRIVER_VERSION}" ]; then
        echo "ERROR: could not read DRIVER_VERSION from r8152.c"
        exit 1
    fi
    echo "Driver version: ${DRIVER_VERSION}"
}

verify_rtl8157_support() {
    echo "[4/6] Verifying RTL8157 support"
    if ! grep -q 'REALTEK_USB_DEVICE(VENDOR_ID_REALTEK, 0x8157)' r8152.c; then
        echo "ERROR: this source does not register USB device 0bda:8157"
        exit 1
    fi
    echo "Found Realtek USB ID 0bda:8157"
}

compile_driver() {
    echo "[5/6] Compiling r8152.ko"
    QNAP_DEFINES=$(cat /build/kernel/qnap_defines)

    make ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        -C "${KERNEL_SRC}" \
        M="$(pwd)" \
        modules \
        KCFLAGS="${QNAP_DEFINES} -fno-stack-protector"

    if [ ! -f "${DRIVER_NAME}.ko" ]; then
        echo "ERROR: ${DRIVER_NAME}.ko was not produced"
        exit 1
    fi
}

verify_and_export() {
    echo "[6/6] Verifying module and exporting artifacts"
    module_arch=$(file "${DRIVER_NAME}.ko")
    module_vermagic=$(modinfo -F vermagic "${DRIVER_NAME}.ko")
    module_version=$(modinfo -F version "${DRIVER_NAME}.ko")

    echo "${module_arch}"
    echo "version:  ${module_version}"
    echo "vermagic: ${module_vermagic}"

    case "${module_arch}" in
        *ARM\ aarch64*) ;;
        *) echo "ERROR: module is not AArch64"; exit 1 ;;
    esac

    if [ "${module_vermagic}" != "${EXPECTED_VERMAGIC}" ]; then
        echo "ERROR: expected vermagic '${EXPECTED_VERMAGIC}'"
        exit 1
    fi

    if ! modinfo -F alias "${DRIVER_NAME}.ko" | \
        grep -qi 'usb:v00000BDAp00008157'; then
        echo "ERROR: compiled module does not advertise USB ID 0bda:8157"
        exit 1
    fi

    mkdir -p /build/output/driver
    cp "${DRIVER_NAME}.ko" /build/output/driver/
    modinfo "${DRIVER_NAME}.ko" > /build/output/driver/module_info.txt
    printf '%s\n' "${DRIVER_VERSION}" > /build/output/driver/driver_version
    sha256sum "${DRIVER_NAME}.ko" > /build/output/driver/r8152.ko.sha256
}

main() {
    verify_kernel_source
    verify_toolchain
    download_driver_source
    verify_rtl8157_support
    compile_driver
    verify_and_export
    echo "Build complete: /build/output/driver/r8152.ko"
}

main "$@"
