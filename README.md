# RTL8157 driver for QNAP TS-216

This repository builds Realtek's `r8152.ko` with RTL8157 support for the QNAP
TS-216/TS-416 (`TS-X16`, Rockchip RK3566, aarch64) by using GitHub Actions. It
does not require a compiler, SDK, Docker image, or QNAP toolchain on your own
computer.

The driver source is pinned to
[`RikshaDriver/realtek-r8152-linux`](https://github.com/RikshaDriver/realtek-r8152-linux/tree/8a0c34389618ea9c4c833bd3fd6631a12e78e6db),
driver version 2.20.1. That source registers RTL8157 USB ID `0bda:8157`.
The build uses QNAP's QTS 5.2.0 GPL kernel source and the `TS-X16` ARM64 config.

## Compatibility check first

Run these commands over SSH on the NAS before installing anything:

```sh
uname -m
uname -r
cat /proc/version
getcfg System Version -f /etc/config/uLinux.conf
getcfg System Build Number -f /etc/config/uLinux.conf
getcfg System Model -f /etc/config/uLinux.conf
lsusb
zcat /proc/config.gz | grep -E 'CONFIG_(MODVERSIONS|LOCALVERSION|SMP|MODULE_UNLOAD)'
```

The current build requires all of the following:

- `uname -m` is `aarch64`.
- `uname -r` is exactly `5.10.60-qnap`.
- The model is TS-216 or another confirmed `TS-X16` model.
- `lsusb` shows `0bda:8157` for the adapter.

Do not install the QPKG if those values differ. A QTS firmware update can change
the kernel ABI, requiring a rebuild from that firmware's matching GPL source.

## Build with GitHub Actions

1. Fork this repository to your GitHub account.
2. Open the fork's **Actions** tab and enable workflows if GitHub asks.
3. Select **Build TS-216 RTL8157 driver**.
4. Choose **Run workflow**, leave **Ignore saved Docker layer cache** off, and run it.
5. When the job finishes, download the `ts216-rtl8157-*` artifact from the run.

The first run downloads about 810 MB of QNAP GPL source and builds the ARM64
kernel tree, so it can take a long time. Later runs reuse GitHub's cache.

The artifact contains:

- `r8152.ko`: the raw ARM64 kernel module.
- `module_info.txt`: version, vermagic, and device aliases.
- `r8152.ko.sha256`: checksum.
- `RTL8152_Driver_2.20.1_arm_64.qpkg`: installable package, if QDK packaging succeeds.

The workflow rejects the result unless the module is AArch64, its vermagic is
exactly `5.10.60-qnap SMP mod_unload aarch64`, and its aliases contain USB ID
`0bda:8157`.

## Installation warning

Install from QTS App Center's **Install Manually** dialog. The package validates
the NAS architecture, running kernel, and RTL8157 alias before it unloads the
existing `r8152` module. Loading a network driver interrupts interfaces already
using `r8152`; do this from a different management interface or with local access
available. The service falls back to QTS's stock `r8152` if loading fails.

After installation, verify over SSH:

```sh
lsmod | grep r8152
cat /sys/module/r8152/version
dmesg | grep -iE 'r8152|rtl8157'
ip link show
```

The TS-216 USB 3.2 Gen 1 port has a raw 5 Gbps bus rate. Protocol overhead and
the shared USB path mean full sustained 5GbE line rate is not realistic.

## Sources

- [QNAP TS-216 hardware specifications](https://www.qnap.com/zh-hk/product/ts-216/specs/hardware)
- [QNAP QTS 5.2.0 GPL source](https://sourceforge.net/projects/qosgpl/files/QNAP%20NAS%20GPL%20Source/QTS%205.2.0/)
- [RTL8157-capable Realtek r8152 source](https://github.com/RikshaDriver/realtek-r8152-linux)
- [TS-216 RK3566 platform reference](https://github.com/PegionFish/QNAP_TS216_Debian)

This is an experimental community build, not a QNAP or Realtek release.
