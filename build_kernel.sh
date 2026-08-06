#!/bin/bash
set -e

# build_kernel.sh - Configure and build QNAP's GPL kernel tree for arm64.
#
# Why this step exists at all:
#   QNAP's GPL bundle ships src/linux-5.10 ALREADY BUILT, but only for x86_64 -
#   vmlinux, System.map, Module.symvers and even scripts/mod/modpost are x86-64
#   ELF, and the tree's Model file says TS-X55U. arch/arm64 contains sources only.
#   So the arm64 target cannot reuse the pre-built tree the way the x86_64 build
#   did; the tree has to be configured with the target model's GPL config and
#   built here.
#
#   This runs at Docker image build time so the result lands in a cached layer and
#   is paid for once, not on every driver compile.
#
# Cross-compilation, not emulation:
#   The build host is x86_64 and the module is cross-compiled with the aarch64
#   toolchain. This is how QNAP produced the kernel too - their config records
#   CONFIG_CC_VERSION_TEXT="gcc (Debian 4.9.2-10) 4.9.2", a Debian x86 host with a
#   cross toolchain.

KERNEL_SRC="${KERNEL_SRC:-/build/kernel/linux-source}"
KERNEL_CONFIG="${KERNEL_CONFIG:-/build/kernel/target.config}"
: "${ARCH:?ARCH must be set (e.g. arm64)}"
: "${CROSS_COMPILE:?CROSS_COMPILE must be set (e.g. aarch64-linux-gnu-)}"
: "${KERNEL_VERSION:?KERNEL_VERSION must be set (e.g. 5.10.60)}"

# CONFIG_LOCALVERSION="-qnap" in every QNAP config, and CONFIG_LOCALVERSION_AUTO
# is off, so the release string is fully determined. A module whose vermagic does
# not match the running kernel exactly will be refused by insmod, so this is
# checked rather than assumed.
EXPECTED_RELEASE="${KERNEL_VERSION}-qnap"

JOBS="$(nproc)"

# QNAP's model defines, from the CFLAGS_KERNEL_QNAP line in cflag_kernel_qnap.mk.
#
# These are NOT optional decoration. QNAP's tree is patched to switch on them, and
# the GPL drop is only self-consistent with them set. The clearest case is
# net/ipv4/ip_input.c:
#
#     #if defined(CONFIG_MACH_QNAPTS) && !defined(QNAP_HAL)
#     #include <qnap/pic.h>          <- NOT shipped in the GPL bundle
#     #endif
#     #if defined(CONFIG_MACH_QNAPTS) && defined(QNAP_HAL)
#     #include <qnap/hal_event.h>    <- shipped
#     #endif
#
# so without -DQNAP_HAL the kernel does not compile at all. They also gate real
# struct fields (e.g. a trailing `int pid` in struct mm_struct), so the module has
# to be compiled with the same set - see build_driver.sh.
#
# The model-specific defines from the shipped file (-DTSX55U -DX86_PARKER
# -DQNAP_I2C_MV9235) are dropped: that file is a build record left behind by
# QNAP's x86 TS-X55U build, and none of those three are referenced by any
# defined() test in this tree.
QNAP_DEFINES="-DQNAP -DNAS_VIRTUAL -DNAS_VIRTUAL_EX -DQNAP_FNOTIFY \
-DQNAP_SEARCH_FILENAME_CASE_INSENSITIVE -DQNAP_HAL -DSUPPORT_VAAI \
-DSUPPORT_FAST_BLOCK_CLONE -DSUPPORT_LOGICAL_BLOCK_4KB_FROM_NAS_GUI \
-DSUPPORT_CONCURRENT_TASKS -DSUPPORT_SINGLE_INIT_LOGIN -DVIRTUAL_JBOD \
-DSUPPORT_VOLUME_BASED -DQTS_HA -DSUPPORT_TP -DNFS_VAAI -DNFS_VAAI_V3 -DNFS_QLOG \
-DQNAP_NFS_FORCE_UMASK -DQNAP_SNAPSHOT -DISCSI_MULTI_INIT_ACL \
-DUSE_BLKDEV_READPAGES -DUSE_BLKDEV_WRITEPAGES -DKSWAPD_FIX \
-DQNAP_KERNEL_STORAGE_V2"

# Written out so build_driver.sh compiles the module with the identical set.
echo "${QNAP_DEFINES}" > /build/kernel/qnap_defines

# QNAP's build wrapper also sets plain make variables that the GPL drop does not
# default. These two are the complete set in this tree (grep for
# 'ifeq ($(QNAP' across all Makefiles), and both pair with defines above.
#
# They are not cosmetic: fs/nfsd/Makefile builds qnap/nfsd_qtransport.o
# unconditionally into nfsd-y, but only builds qnap/nfsd_qlog.o - which defines
# and exports qnap_nfsd_get_nl_func, the symbol qtransport calls - when
# QNAP_NFS_QLOG=yes. Without it vmlinux fails to link on an undefined reference.
QNAP_MAKE_VARS="QNAP_NFS_QLOG=yes QNAP_NFS_VAAI=yes"

echo "===================================="
echo "Building QNAP GPL kernel tree for ${ARCH}"
echo "===================================="
echo "Source:        ${KERNEL_SRC}"
echo "Config:        ${KERNEL_CONFIG}"
echo "Cross compile: ${CROSS_COMPILE}"
echo "Expected release: ${EXPECTED_RELEASE}"
echo "Parallel jobs: ${JOBS}"
echo "===================================="

cd "${KERNEL_SRC}"

if [ ! -f "${KERNEL_CONFIG}" ]; then
    echo "ERROR: kernel config not found: ${KERNEL_CONFIG}"
    exit 1
fi

echo ""
echo "[1/5] Clearing QNAP's pre-built x86_64 artifacts..."
# The tree arrives configured and built for x86_64. Leaving include/config,
# include/generated and the host tools in place would poison the arm64 build.
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" mrproper > /dev/null
echo "  Tree cleaned"

echo ""
echo "[2/5] Applying ${ARCH} kernel config..."
cp "${KERNEL_CONFIG}" .config
cp "${KERNEL_CONFIG}" /build/kernel/config.as-shipped

make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig > /dev/null

# QNAP configured this kernel with gcc 4.9 and a matching binutils. Our toolchain
# is much newer, so olddefconfig happily turns ON arm64 features that were only
# ever off because the old compiler could not do them. Three of those change the
# kernel/module ABI; the two below can be pinned off here and must be, to match
# the running kernel:
#
#   ARM64_PTR_AUTH         adds fields to thread_struct (processor.h:151), which
#                          is embedded in task_struct, and changes function
#                          prologue codegen (paciasp/autiasp).
#   ARM64_MTE              adds gcr_user_incl et al to thread_struct
#                          (processor.h:155) and selects ARCH_USES_HIGH_VMA_FLAGS,
#                          which shifts the VM_* flag allocation.
#
# The shipped config does not mention either of them, which is consistent with
# gcc 4.9 lacking PAC/MTE support.
#
# CONFIG_STACKPROTECTOR_PER_TASK is a third case and is deliberately NOT handled
# here: it is `def_bool y` with no prompt, derived from CC_HAVE_STACKPROTECTOR_SYSREG,
# so olddefconfig recomputes it from the compiler no matter what is written into
# .config. It is dealt with where it actually matters - build_driver.sh compiles
# the module with -fno-stack-protector.
echo ""
echo "  Pinning off toolchain-gated features absent from the GPL config..."
for sym in ARM64_PTR_AUTH ARM64_MTE; do
    ./scripts/config --file .config -d "${sym}"
    echo "    disabled CONFIG_${sym}"
done
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig > /dev/null

for sym in ARM64_PTR_AUTH ARM64_MTE; do
    if grep -q "^CONFIG_${sym}=y" .config; then
        echo "ERROR: CONFIG_${sym} came back enabled after olddefconfig"
        exit 1
    fi
done

# Report whatever else moved instead of letting it drift silently.
echo ""
echo "  Config delta vs the GPL config as shipped:"
if [ -x scripts/diffconfig ]; then
    scripts/diffconfig /build/kernel/config.as-shipped .config | sed 's/^/    /' || true
else
    diff /build/kernel/config.as-shipped .config | sed 's/^/    /' || true
fi

echo ""
echo "[3/5] Verifying kernel release string..."
ACTUAL_RELEASE="$(make -s ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" kernelrelease)"
if [ "${ACTUAL_RELEASE}" != "${EXPECTED_RELEASE}" ]; then
    echo "ERROR: kernel release mismatch"
    echo "  Expected: ${EXPECTED_RELEASE}"
    echo "  Actual:   ${ACTUAL_RELEASE}"
    echo ""
    echo "A module built here would be rejected by insmod on the NAS."
    exit 1
fi
echo "  Kernel release: ${ACTUAL_RELEASE}"

echo ""
echo "[4/5] Building vmlinux and preparing for external modules..."
# An external module build needs a symbol dump to resolve the kernel's exported
# symbols; without one, undefined symbols only surface at insmod time on the NAS.
#
# In 5.10 that dump is split in two:
#   vmlinux.symvers       exports from built-in code. Written by modpost, which
#                         scripts/link-vmlinux.sh runs at line 282 as part of the
#                         vmlinux link (MODPOST_VMLINUX=1).
#   modules-only.symvers  exports from loadable modules, written by `make modules`.
#   Module.symvers        simply cat of the two (scripts/Makefile.modpost).
#
# r8125 is a self-contained PCIe NIC driver that imports only built-in kernel
# exports, so vmlinux.symvers is the complete answer for it and `make modules` is
# not needed. That matters here beyond build time: QNAP's tree does not survive a
# full `make modules` under a modern gcc - several of their patched subsystems
# (dm-cache, the iSCSI target) hit warnings that -Werror turns into errors, which
# would mean patching QNAP's source to satisfy a compiler they never used.
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}" \
     ${QNAP_MAKE_VARS} KCFLAGS="${QNAP_DEFINES}" vmlinux
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}" \
     ${QNAP_MAKE_VARS} KCFLAGS="${QNAP_DEFINES}" modules_prepare

if [ ! -f vmlinux.symvers ]; then
    echo "ERROR: vmlinux.symvers not produced by the vmlinux link"
    exit 1
fi
cp vmlinux.symvers Module.symvers
echo "  Module.symvers written from vmlinux.symvers (built-in exports)"

echo ""
echo "[5/5] Verifying build products..."
FAILED=0
for f in Module.symvers scripts/mod/modpost include/generated/utsrelease.h include/config/auto.conf; do
    if [ -e "$f" ]; then
        echo "  Found: $f"
    else
        echo "  MISSING: $f"
        FAILED=1
    fi
done

if [ "${FAILED}" -ne 0 ]; then
    echo "ERROR: kernel tree is not usable for external module builds"
    exit 1
fi

SYMS="$(wc -l < Module.symvers)"
echo "  Module.symvers: ${SYMS} exported symbols"
if [ "${SYMS}" -lt 1000 ]; then
    echo "ERROR: Module.symvers looks truncated (${SYMS} symbols)"
    exit 1
fi

# Freed only after Module.symvers exists. External module builds (make M=...) read
# the generated headers, scripts/ and Module.symvers, never these or the built
# module objects.
rm -f vmlinux vmlinux.o .tmp_vmlinux* .tmp_System.map
rm -rf arch/"${ARCH}"/boot/Image arch/"${ARCH}"/boot/Image.gz


echo ""
echo "===================================="
echo "Kernel tree ready for ${ARCH} module builds"
echo "  Release: ${ACTUAL_RELEASE}"
echo "===================================="
