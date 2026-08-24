# Claude Development Guide - RTL8125 QNAP Driver (arm64)

## Project Status: LOADS AND RUNS ON A TS-433

**Target**: QNAP TS-433 (and other TS-x33 family), QTS 5.2.x, kernel `5.10.60-qnap`, aarch64
**Driver**: Realtek r8125 9.018.00 (RTL8125/8125B, 2.5GbE PCIe)
**Build host**: x86_64, cross-compiling with `aarch64-linux-gnu-`

The build runs end to end, and the resulting module has been loaded on a real
TS-433 where it drives the onboard 2.5GbE port with RSS active. Reboot persistence
and sustained throughput are still unconfirmed - see Verification.

---

## Quick Start

```bash
# 1. GPL source auto-managed via versions.yml
./prepare_gpl_source.sh

# 2. Build everything
./build.sh all

# 3. Output
ls output/RTL8125_Driver_*_arm_64.qpkg
ls output/driver/r8125.ko
```

---

## Critical Success Factors

### 1. The GPL tree is pre-built for x86_64 ONLY - arm64 must be built from source

x86_64 builds work by reusing QNAP's GPL tree exactly as shipped, because the
bundle ships it already built. That is not true for arm64. In
`GPL_QTS/src/linux-5.10`:

- `vmlinux`, `System.map`, `arch/x86/boot/bzImage` are x86-64
- `scripts/mod/modpost` and the other host tools are x86-64 ELF
- `include/config/auto.conf` has `CONFIG_X86_64=y`
- the `Model` file says `TS-X55U`
- `arch/arm64/` contains **sources only** - no build products

So `build_kernel.sh` runs at Docker image build time and does:

```
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- mrproper     # drop x86 artifacts
cp GPL_QTS/kernel_cfg/TS-X33/linux-5.10-arm64.config .config
make ... olddefconfig
make ... QNAP_NFS_QLOG=yes QNAP_NFS_VAAI=yes KCFLAGS="<QNAP defines>" vmlinux
make ... QNAP_NFS_QLOG=yes QNAP_NFS_VAAI=yes KCFLAGS="<QNAP defines>" modules_prepare
cp vmlinux.symvers Module.symvers
```

**Do NOT try to fix this with `make modules`.** An external module build needs a
symbol dump to resolve the kernel's exported symbols, or undefined symbols only
surface at `insmod` time on the NAS. In 5.10 that dump is split:

| File | Contents | Written by |
|---|---|---|
| `vmlinux.symvers` | exports from built-in code | modpost, run by `scripts/link-vmlinux.sh:282` (`MODPOST_VMLINUX=1`) during the **vmlinux link** |
| `modules-only.symvers` | exports from loadable modules | `make modules` |
| `Module.symvers` | `cat` of the two | `scripts/Makefile.modpost` |

So `make vmlinux` already gives us `vmlinux.symvers`; only the concatenation step
is missing, hence the `cp`. r8125 is a self-contained PCIe NIC driver that imports
nothing from other modules, so the built-in exports are the complete answer for it.

This matters beyond build time: **QNAP's tree does not survive a full
`make modules` under a modern gcc.** Several of their patched subsystems
(`drivers/md/dm-cache-metadata.c`, `drivers/target/iscsi`,
`drivers/target/qnap/target_core_qtransport.c`) hit warnings that `-Werror`
escalates to errors, because they were only ever built with gcc 4.9. Making that
target pass would mean patching QNAP's source to satisfy a compiler they never
used, for symbols r8125 does not import.

### 2. Cross-compile, do not use buildx/qemu

The image is x86_64 and the module is cross-compiled. Do not "fix" this by
switching to a multi-arch/emulated arm64 image:

- QNAP cross-compiled this kernel themselves - their arm64 config records
  `CONFIG_CC_VERSION_TEXT="gcc (Debian 4.9.2-10) 4.9.2"`, a Debian x86 host.
- QDK's `qbuild` is arch-agnostic shell and runs natively.
- A full kernel build under qemu is roughly an order of magnitude slower.

### 3. vermagic must match exactly

Derived from `include/linux/vermagic.h` plus the TS-X33 config, NOT guessed:

| Component | Source | Contributes |
|---|---|---|
| `UTS_RELEASE` | `5.10.60` + `CONFIG_LOCALVERSION="-qnap"` | `5.10.60-qnap ` |
| `CONFIG_SMP=y` | config | `SMP ` |
| `CONFIG_PREEMPT` unset (`PREEMPT_VOLUNTARY`) | config | *(nothing)* |
| `CONFIG_MODULE_UNLOAD=y` | config | `mod_unload ` |
| `CONFIG_MODVERSIONS` unset | config | *(nothing)* |
| `MODULE_ARCH_VERMAGIC` | `arch/arm64/include/asm/vermagic.h` | `aarch64` |

Result: **`5.10.60-qnap SMP mod_unload aarch64`**

`CONFIG_LOCALVERSION_AUTO` is off and `CONFIG_GCC_PLUGINS` is off, so no `+`,
git hash, or RANDSTRUCT seed is appended. `build_kernel.sh` asserts the kernel
release string and `build_driver.sh` asserts the full vermagic; both fail the
build on mismatch rather than shipping a module `insmod` will reject.

### 3b. Toolchain drift: features gcc 4.9 could not enable

`olddefconfig` under a modern gcc turns ON arm64 features that were only ever off
because QNAP's gcc 4.9 could not do them. Three change the kernel/module ABI:

| Symbol | Effect | Handled by |
|---|---|---|
| `ARM64_PTR_AUTH` | adds fields to `thread_struct` (`processor.h:151`), embedded in `task_struct`; changes prologue codegen | pinned off in `build_kernel.sh` |
| `ARM64_MTE` | adds `gcr_user_incl` etc (`processor.h:155`); selects `ARCH_USES_HIGH_VMA_FLAGS`, shifting `VM_*` allocation | pinned off in `build_kernel.sh` |
| `STACKPROTECTOR_PER_TASK` | canary read from `sp_el0 + offsetof(task_struct, stack_canary)` instead of the global `__stack_chk_guard` | `-fno-stack-protector` on the module |

`STACKPROTECTOR_PER_TASK` cannot be turned off in the config: it is `def_bool y`
with no prompt, derived from `CC_HAVE_STACKPROTECTOR_SYSREG`, so `olddefconfig`
recomputes it from the compiler whatever `.config` says. Do not waste time trying
- it is handled at the module instead, which costs only the canary and changes no
struct layout or exported symbol.

`build_kernel.sh` re-asserts the two pinned symbols after `olddefconfig` and fails
if they come back.

### 4. QNAP's defines and make variables are MANDATORY

The tree contains `cflag_kernel_qnap.mk` defining `CFLAGS_KERNEL_QNAP` /
`CFLAGS_MODULE_QNAP` with defines (`-DQNAP_HAL`, `-DSUPPORT_TP`,
`-DQNAP_KERNEL_STORAGE_V2`, ...). Nothing in the kernel Makefile reads that file -
it is a build record left by QNAP's out-of-tree build wrapper - but the defines
themselves are load-bearing and the GPL drop does not compile without them:

```c
// net/ipv4/ip_input.c:148
#if defined(CONFIG_MACH_QNAPTS) && !defined(QNAP_HAL)
#include <qnap/pic.h>          // NOT shipped in the GPL bundle
#endif
#if defined(CONFIG_MACH_QNAPTS) && defined(QNAP_HAL)
#include <qnap/hal_event.h>    // shipped
#endif
```

Without `-DQNAP_HAL` the build takes the branch needing an unshipped header.
`build_kernel.sh` passes them via `KCFLAGS` and writes them to
`/build/kernel/qnap_defines`; `build_driver.sh` reads that file so the module is
compiled with the identical set. This matters beyond compilation because the
defines gate real struct fields - a trailing `int pid` in `struct mm_struct`, plus
fields in the iSCSI/NFS target headers and `genhd.h`/`writeback.h`.

A sweep of every define across `include/` and `arch/arm64/include/` found none of
them in `netdevice.h`, `skbuff.h`, `pci.h`, `sock.h` or `ethtool.h`, so nothing a
PCIe NIC driver dereferences changes shape - but they are passed anyway, since the
kernel tree is built with them and a mismatch has no upside.

The model-specific defines from the shipped file (`-DTSX55U -DX86_PARKER
-DQNAP_I2C_MV9235`) are dropped: that file records QNAP's x86 TS-X55U build, and
no `defined()` test in this tree references any of the three.

**Plain make variables too.** QNAP's wrapper also sets non-`CONFIG_` make
variables. There are exactly two in this tree (`grep -r 'ifeq ($(QNAP'` over all
Makefiles): `QNAP_NFS_QLOG` and `QNAP_NFS_VAAI`, both pairing with defines above.
`QNAP_NFS_QLOG=yes` is required to link, because `fs/nfsd/Makefile` builds
`qnap/nfsd_qtransport.o` unconditionally into `nfsd-y` while only building
`qnap/nfsd_qlog.o` - which defines and exports `qnap_nfsd_get_nl_func`, the symbol
qtransport calls - under that conditional.

### 4b. Driver feature flags

Realtek's `src/Makefile` defaults are kept, with ONE deliberate change made in
`build_driver.sh:patch_driver()`:

- **`ENABLE_RSS_SUPPORT = n` -> `y`.** The RTL8125 has 8 RX queues, so RX scales
  across the NAS's cores. QTS's stock module identifies itself as
  `9.007.01-NAPI` in dmesg - NAPI only, no RSS - so this is a real improvement
  over stock rather than parity with it.
- **`ENABLE_MULTIPLE_TX_QUEUE = n` -> `y`.** Capped at 2 rings
  (`R8125_MAX_TX_QUEUES`, `r8125.h:729`) and only taken when `irq_nvecs >= 19`
  (`r8125_n.c:15744`). Measured on a TS-433: **32** MSI-X vectors
  (`eth0-0..eth0-31` in `/proc/interrupts`), so the threshold is met. Worth it
  because TX concentrates on one vector - on that box `eth0-16` (`tx_ring[0]`)
  showed ~1.0M interrupts pinned to CPU0, more than any single RX ring, while
  vectors 17/18 sat idle.

- **`CONFIG_ASPM = y` -> `n`.** PCIe ASPM L1 exit latency stalls the DMA engine,
  the RX FIFO overruns, and every dropped frame becomes a TCP retransmit. Measured
  on a TS-433, 60s single-stream iperf3 into the NAS:

  | | ASPM on (Realtek default) | ASPM off |
  |---|---|---|
  | Throughput | 2.35Gb/s collapsing to 1.2-1.6 | 2.35Gb/s flat |
  | `rx_missed` | thousands | 223, then 0 on the next run |
  | TCP retransmits | 896 + 398 bursts | 223, then 0 |

  `rx_missed` and the sender's retransmit count matched exactly (223 = 223),
  which is the causal chain in one number. `CONFIG_ASPM` is tested in exactly one
  place (`r8125_n.c:277`) and only sets the default of the `aspm` module
  parameter, so this gates no other code - `insmod ... aspm=1` restores it. Costs
  a little idle power.

`build_driver.sh` asserts each of these actually reached gcc by grepping kbuild's
`.r8125_n.o.cmd`. Setting them in `src/Makefile` is NOT sufficient on its own: a
command-line `EXTRA_CFLAGS=` overrides every `EXTRA_CFLAGS +=` in that file, which
silently discarded all of them once already.

`ENABLE_S5WOL` is asserted rather than set, so a future release flipping the
default fails the build instead of silently shipping a driver that cannot wake
the NAS.

RSS is still runtime-gated (`r8125_n.c:15769`): it needs `HwSuppRssVer > 0` (NOT
set for `CFG_METHOD_2/3/6`, i.e. early RTL8125A), MSI-X up (`HwCurrIsrVer > 1`),
and `irq_nvecs >= num_rx_rings` where the ring count is
`min(8, netif_get_num_default_rss_queues())` = `min(8, num_online_cpus())`. It
falls back to a single ring rather than misbehaving. Confirm on the device:

```bash
ls /sys/class/net/ethX/queues/    # rx-0..rx-N
grep eth0 /proc/interrupts        # MSI-X vectors: named ethX-0..N, NOT r8125
ethtool -x ethX                   # RSS indirection table
```

The module version string is a free check on what got compiled: the suffixes come
from `NAPI_SUFFIX DASH_SUFFIX REALWOW_SUFFIX PTP_SUFFIX RSS_SUFFIX`, so
`9.018.00-NAPI-DASH-RSS` proves NAPI/DASH/RSS in and REALWOW/PTP out.

### 5. Driver source: Realtek's site is not scriptable

Realtek's download page (`realtek.com/Download/List?cate_id=584`) is a JS-rendered
SPA whose files sit behind a per-release download id plus a EULA confirmation POST.
There is no stable URL, and a hardcoded id breaks on the next release.

`versions.yml` therefore uses `driver_source_tag` against
`awesometic/realtek-r8125-dkms`, which vendors Realtek's pristine `src/` tree
alongside Realtek's own `REALTEK_README.txt`. Set `driver_url` to override with a
hand-obtained Realtek link or a local mirror; it takes precedence. The archive
just has to unpack to a tree containing `src/Makefile` (the build strips the
top-level directory with `--strip-components=1`).

### 6. Build System Architecture

```
versions.yml            # Single source of truth (driver + GPL + target platform)
     |
prepare_gpl_source.sh   # Downloads & extracts GPL source
     |
build.sh all            # Orchestrator; passes versions.yml values as build args
     |
+- build_image()        # Creates Docker image
|  +- Dockerfile        # Copies GPL tree + TS-X33 arm64 config
|     +- build_kernel.sh  # Builds the kernel tree FOR arm64 (cached layer)
|
+- compile_driver()     # Runs inside Docker
|  +- build_driver.sh   # Fetches, builds, and VERIFIES vermagic/ELF arch
|
+- create_qpkg()        # Packages driver
   +- build_qpkg.sh     # Uses QDK to create QPKG into arm_64/
```

### 7. QDK architecture directory

QDK's valid arch dirs are `arm-x09, arm-x19, arm-x31, arm-x41, arm_64, x86,
x86_ce53xx, x86_64` (see `qbuild`). arm64 is **`arm_64`** (underscore, not hyphen).
`qbuild` discovers the target from the directory's presence and stamps it into the
package name, so the output is `RTL8125_Driver_<ver>_arm_64.qpkg`.

`package_routines` matches on `uname -m` = `aarch64`.

---

## Things to know about the target

- QTS already ships its own r8125: the TS-X33 config has `CONFIG_QND_ETH_R8125=m`
  with `CONFIG_QND_ETH_R8125_VERSION="9.007.01"`. This package replaces a module
  that is already loaded and bound to the onboard 2.5GbE port, so the link drops
  briefly during install. The TS-433 has a second (1GbE) NIC.
- Boot order, from dmesg on a TS-433: QTS loads stock `9.007.01-NAPI` at ~t=22s
  and it becomes `eth0` (via an `eth1` -> `eth1_tmp_NNNNN` -> `eth0` rename
  dance). The QPKG service is meant to swap in ours later, once the data volume is
  mounted - a t=400s swap was observed on a boot that included a volume check. On
  a plain reboot it does NOT happen: stock `9.007.01` is still the loaded module
  and the package has to be reinstalled by hand. See "Autoload on boot" below.
- The NIC sits behind PCIe3 (`pcie@fe280000` / `3c0800000.pcie`, bus `0002:20`).
  `rockchip-snps-pcie3-phy fe8c0000.phy: failed to find rockchip,pipe_grf regmap`
  at ~t=3s is BENIGN - it appears on healthy boots too. The line that actually
  matters is `rk-pcie 3c0800000.pcie: PCIe Link up`; if that is absent, PCIe3 did
  not train and the NIC will not exist at all.
- U-Boot puts `pcie3test-pass` or `pcie3test-fail` on the kernel command line. It
  is computed fresh each boot, not latched, so `grep -o 'pcie3test[^ ]*'
  /proc/cmdline` is a reliable one-line check of whether PCIe3 came up.
- `CONFIG_R8169 is not set`, so the mainline driver is not in play.
- TS-X33 is the right config family for the TS-433: `CONFIG_ARCH_ROCKCHIP=y`
  (RK3568). Only four models ship a 5.10 arm64 config: TS-X16, TS-X33, TS-X35EU,
  TS-X42.

---

## Failure Lessons Learned

### What Doesn't Work

1. **Reusing the GPL tree as-is for arm64** - it is pre-built for x86_64. See #1.
2. **Vanilla Linux kernel** - symbol/config mismatch with QNAP's customizations.
3. **Relying on modprobe after install** - loads the cached stock module. Use
   `insmod` with an absolute path into the QPKG directory.
4. **Hardcoded URLs in scripts** - keep everything in `versions.yml`.
5. **Guessing vermagic** - derive it from `vermagic.h` and the config.

### What Works

1. Building QNAP's GPL tree for arm64 with the model's own config.
2. Cross-compiling from x86_64; no emulation.
3. Asserting vermagic and ELF arch at build time, so mismatches fail in CI rather
   than on the NAS.
4. `insmod /path/to/r8125.ko` from the QPKG dir (`/lib/modules` is read-only).
5. Verifying the loaded module by `srcversion`, never by size.

---

## Hazard: the NIC can vanish from PCIe entirely

Observed on a TS-433 after rebooting with **no cable in the 2.5GbE port**: the
RTL8125 stopped enumerating altogether. Not unbound - absent. `lsmod` showed our
module loaded with nothing to attach to, `/sys/bus/pci/devices/` had only the
RK3568 root port and the JMB585 SATA controller, and `dmesg` said nothing about
r8125 because the driver never probed anything.

Root cause chain:

1. `ENABLE_S5WOL` arms the NIC for wake-on-LAN as the system shuts down.
2. With no cable attached, it settles into a power state it does not leave.
3. A NAS keeps the standby rail energised after `poweroff`, so the state SURVIVES
   a soft power cycle - and a warm `reboot` even more so.
4. U-Boot's PCIe3 link test then fails and puts `pcie3test-fail` on the kernel
   command line; `3c0800000.pcie` never probes; there is no bus for the NIC.

**Recovery: unplug the power cord for ~60s.** Nothing less works - not `reboot`,
not `poweroff`. Only removing standby power resets the NIC. Plug the Ethernet
cable back in before powering on.

There is no software workaround from Linux: `rk-pcie` sets
`suppress_bind_attrs = true` (`drivers/pci/controller/dwc/pcie-dw-rockchip.c:2446`),
so the controller cannot be rebound, and `/sys/bus/pci/rescan` cannot help because
the host bridge itself never registered.

With a cable attached, warm reboots are fine and this does not reproduce. That is
why `ENABLE_S5WOL` is left ON: the trigger is an unplugged port, not the feature
itself. If you intend to run this NAS with the 2.5GbE port unused, build with
`ENABLE_S5WOL = n` or load with `s5wol=0`.

### Diagnosing it

```bash
grep -o 'pcie3test[^ ]*' /proc/cmdline   # pass/fail, computed fresh each boot
dmesg | grep '3c0800000.pcie'            # want "PCIe Link up, LTSSM is 0x130011"
ls /sys/bus/platform/drivers/rk-pcie/    # want BOTH 3c0400000 and 3c0800000
```

Ignore `rockchip-snps-pcie3-phy fe8c0000.phy: failed to find rockchip,pipe_grf
regmap` - it appears on healthy boots too and is not the fault.

---

## Autoload on boot

The ONLY mechanism that persists is `QPKG_SERVICE_PROGRAM`: QDK's `qinstall.sh`
writes `Shell = <install path>/RTL8125_Driver.sh` into `/etc/config/qpkg.conf`
(`qinstall.sh:720`) and QTS runs it with `start` for every `Enable = TRUE` package
at boot. `QPKG_RC_NUM` is only a preference - QDK's own developer guide says QTS
reassigns the number from the order in `qpkg.conf` after a reboot.

Do not write boot commands into `/etc/rc.local`. On QTS `/etc` is a ramdisk rebuilt
from the firmware image on every boot; only `/etc/config` is on the DOM. The edit
is writable, `sed` reports success, and it is gone before it would have run. An
earlier `package_routines` did exactly this and logged "Auto-load on boot
configured" while nothing was configured at all. `/etc/config/autorun.conf` is not
a QNAP file either (the real hook is `autorun.sh` on the DOM, gated on a Control
Panel setting), so that fallback never fired.

`RTL8125_Driver.sh start` therefore has to be the thing that works, and it has to
be honest about not working:

- It prepends `/sbin:/bin:/usr/sbin:/usr/bin` to `PATH`. QTS starts services at
  boot with a minimal one, and without this `lsmod`/`insmod`/`rmmod` are all
  "command not found" and every step silently no-ops.
- It logs every decision to `<install path>/service.log`. Nothing captures the
  script's stdout on an unattended boot, so this file is the only record.
- It verifies by `srcversion` and exits non-zero if the loaded module is not ours.
  The old version checked `lsmod | grep -q "^r8125 "` - presence, not identity - so
  the `insmod ... || modprobe r8125` fallback reloading the STOCK driver was
  reported as "started successfully (driver loaded)", which is exactly the state
  this package exists to replace.
- A missing `r8125.ko` is a logged error, not a silent skip: the package lives on
  the data volume, and being started before that volume mounts is a real candidate
  for the boot-time failure.

`QPKG_TIMEOUT` is `"start_timeout,stop_timeout"` in seconds. It used to be a bare
`"0"`, which does not match that format and asked QTS to wait zero seconds for a
start that loads a kernel module.

## Troubleshooting

### Verify the correct module is loaded

`/proc/modules` shows RUNTIME memory size, not file size. They always differ.
Use `srcversion`:

```bash
LOADED_SRC=$(cat /sys/module/r8125/srcversion)
QPKG_PATH=$(getcfg "RTL8125_Driver" Install_Path -f /etc/config/qpkg.conf)
FILE_SRC=$(strings "$QPKG_PATH/r8125.ko" | grep "^srcversion=" | cut -d= -f2)
[ "$LOADED_SRC" = "$FILE_SRC" ] && echo "Correct module" || echo "Wrong module"
```

From the build output: `strings output/driver/r8125.ko | grep "^srcversion="`

### "Invalid module format" / module refuses to load

```bash
modinfo -F vermagic output/driver/r8125.ko   # must be: 5.10.60-qnap SMP mod_unload aarch64
uname -r                                      # must be: 5.10.60-qnap
```

`build_driver.sh` already asserts this, so a mismatch here means the kernel on the
NAS is not the one in `versions.yml` - check the QTS version and update
`gpl_source`.

### NIC not detected

```bash
lsmod | grep r8125
cat /sys/module/r8125/version     # should be 9.018.00
lspci -nn | grep -i 10ec          # 10ec:8125 is the RTL8125
dmesg | grep -i r8125
ip link show
```

### Build fails "GPL source not found"

```bash
ls GPL_QTS/src/linux-5.10/Makefile || ./prepare_gpl_source.sh
```

---

## Development Workflow

### Driver version update

```bash
# versions.yml: bump driver_source_tag only, then
./build.sh all
./sync-version.sh    # propagate the built version into the committed files
```

`driver_source_tag` (e.g. `9.018.00-1`) is the only version input - it names the
tag fetched from `awesometic/realtek-r8125-dkms`. The Realtek version itself is
NOT configured anywhere: `build_driver.sh` parses `RTL8125_VERSION` out of the
`src/r8125.h` it downloaded (`9.018.00`), asserts the compiled module's
`modinfo -F version` agrees once the feature suffixes are stripped, and writes it
to `output/driver/driver_version`. `build.sh create_qpkg()` reads that file and
stamps it on the package, so the version on the QPKG cannot disagree with the code
inside it. `QPKG_VERSION=` still overrides for a packaging-only revision.

`sync-version.sh` no longer holds a version of its own; it copies
`output/driver/driver_version` (or an explicit argument) into `qpkg.cfg`, the web
UI and the docs. It deliberately does not touch `versions.yml`, since a blind
substitution there would rewrite `driver_source_tag`.

### New QTS version / kernel

1. Update `gpl_source` (kernel_version, qts_version, urls) in `versions.yml`
2. `rm -rf GPL_QTS && ./prepare_gpl_source.sh`
3. `./build.sh clean && ./build.sh all` - the kernel layer must be rebuilt
4. Re-check the vermagic table in section 3 against the new config

### Different QNAP model

Set `target_model` and `kernel_config` in `versions.yml`. `build.sh image` lists
the models that ship a matching config if the one you pick is missing. If the
model is not arm64, also update `kernel_arch`, `cross_compile`, `qpkg_arch` and
the `uname -m` case in `package_routines`.

---

## Key Files Reference

### Configuration
- `versions.yml` - versions, GPL URLs, and the target platform
- `Dockerfile` - build environment; takes the platform as build args
- `.dockerignore` - keeps the GPL tarballs and x86 build products out of context

### Build Scripts
- `build.sh` - orchestrator, parses `versions.yml`
- `prepare_gpl_source.sh` - GPL download & extract
- `build_kernel.sh` - **builds the GPL kernel tree for arm64** (image build time)
- `build_driver.sh` - driver fetch, compile, and verification
- `build_qpkg.sh` - QPKG packaging

### Installation
- `qpkg/RTL8125_Driver/package_routines` - install/remove logic
- `qpkg/RTL8125_Driver/qpkg.cfg` - package metadata

---

## Verification

Done (build host, x86_64):

- [x] Kernel tree configures and builds for arm64; `kernelrelease` = `5.10.60-qnap`
- [x] `Module.symvers` produced with 13844 built-in exports
- [x] Module compiles; modpost reports no unresolved symbols
- [x] `file` says `ELF 64-bit LSB relocatable, ARM aarch64`
- [x] `vermagic` = `5.10.60-qnap SMP mod_unload aarch64`
- [x] `version` = `9.018.00-NAPI-DASH-RSS`, PCI alias `10ec:8125` present, S5WOL in
- [x] QPKG builds as `RTL8125_Driver_9.018.00_arm_64.qpkg` (~129K)

Confirmed on a TS-433 (QTS 5.2.x, kernel 5.10.60-qnap, aarch64):

- [x] `insmod` accepts the module - so vermagic matched and every symbol resolved
      against the running kernel
- [x] Module binds the onboard RTL8125 and initialises it: `ethtool -l` reports
      pre-set maximums RX 8 / TX 2, matching `HwSuppNumRxQueues` and
      `R8125_MAX_TX_QUEUES`
- [x] RSS active with 4 RX rings = `min(8, num_online_cpus())`, 128-entry
      indirection table, Toeplitz hashing. Also proves the silicon is NOT a
      `CFG_METHOD_2/3/6` part (those have `HwSuppRssVer == 0`)
- [x] MSI-X allocates **32** vectors (`eth0-0..eth0-31`), comfortably over the
      `irq_nvecs >= 19` gate for a second TX ring
- [x] `ENABLE_MULTIPLE_TX_QUEUE` engages: `ethtool -l` reports TX 2 of a maximum
      2. Both queue dimensions are now at this hardware's ceiling - RX 4 limited
      by core count, TX 2 by the silicon
- [x] No panic or corruption, which is meaningful evidence that pinning
      `ARM64_PTR_AUTH`/`ARM64_MTE` off and dropping the stack canary produced a
      `task_struct` layout matching the running kernel

Still open:

- [x] Sustained 2.35Gb/s (line rate) for 60s, once ASPM is disabled

Known, unresolved: intermittent dips to ~1.58Gb/s

Single-stream iperf3 into the NAS mostly holds line rate but drops to a
repeatable ~1.58Gb/s plateau for a few seconds at unpredictable points. During
those stretches cwnd stays high and retransmits are zero, so it is a receiver-side
rate limit, not loss.

Ruled out by measurement on a TS-433:

| Hypothesis | Result |
|---|---|
| RX/TX sharing a core | **Refuted.** Pinned RX to CPU0/1 and TX to CPU2/3 via `r8125-tune.sh`; dips and `rx_missed` persisted across both ring combinations |
| CPU frequency scaling | **Refuted.** One OPP only - `scaling_available_frequencies` = `1992000` |
| DDR/DMC devfreq | **Refuted.** Only the NPU and video encoder have devfreq; no memory-controller domain |
| Thermal throttling | **Refuted.** `cpu-thermal` 38C, `gpu-thermal` 33C under load |

What remains is scheduling contention on the receive path. A single TCP flow
hashes to ONE RX ring no matter how many exist, so one core carries all the RX
softirq for 2.35Gb/s; if the userspace reader lands on that same core they
compete. Untested: pinning the receiving process away from the active RX ring
(`taskset -c N iperf3 -s`).

Note `rx_missed` tracks TCP retransmits EXACTLY (223=223, 271=271, 1015=1015
across separate runs), so any real frame loss is always RX ring overrun. A couple
of hundred over a 60s line-rate run appears to be this NIC's floor and does not
correlate with the dips.

IRQ tuning was tried and REMOVED from the QPKG because it failed its own test -
see `r8125-tune.sh`, kept as a diagnostic tool.
- [ ] Survives a reboot (the QPKG autoload path has not been exercised)
- [ ] Whether the second TX vector actually takes load under traffic (the ring
      exists; the counters in `/proc/interrupts` are what prove it is used)

Note: the build was exercised with `podman build` / `podman run` because Docker was
not reachable from the shell used. `build.sh` still calls `docker`; the two are
argument-compatible for everything used here, but `./build.sh all` itself has not
been run.
