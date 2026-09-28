# Arm Mali r54p0 x86 Simulated Platform Lab

This repository is an implementation workspace for the Arm GPU Bug Bounty **x86 “Simulated Platform Device”** virtual-platform procedure using the Arm Mali 5th Gen **r54p0** Kbase source and Arm's supplied six-patch virtual-device series.

## Authority

Read `plan.md` first. The Arm PDFs in `documents/` and the supplied patch bundle in `patches/` are the primary technical references. `setup_arm_r54p0_x86.sh` is an implementation helper, not a replacement for the Arm procedure.

## Canonical workspace

```text
$HOME/arm-mali-r54p0-x86
```

## Repository layout

```text
.
├── AGENTS.md
├── plan.md
├── README.md
├── setup_arm_r54p0_x86.sh
├── documents/
│   ├── arm_gpu_bug_bounty_faq.pdf
│   ├── arm_gpu_bug_bounty_how_to_guide.pdf
│   ├── arm_gpu_virtual_platform_how_to_guide.pdf
│   └── arm_gpu_bug_bounty_device_configuration_guidelines.pdf
├── patches/
│   └── patches_for_virtual_device.zip
├── drivers/
├── source/
├── kernel/
├── rootfs/
├── artifacts/
├── qemu/
├── fuzz/
├── research/
└── logs/
```

## Arm-documented x86 configuration

```text
CONFIG_MALI_MIDGARD=m
CONFIG_MALI_CSF_SUPPORT=y
CONFIG_MALI_EXPERT=y
CONFIG_MALI_NO_MALI=y
# CONFIG_MALI_REAL_HW is not set
CONFIG_MALI_NO_MALI_DEFAULT_GPU="tKRx"
CONFIG_MALI_PLATFORM_NAME="vexpress"
# CONFIG_MALI_DEBUG is not set
```

Arm's x86 guide says the supplied six patches apply cleanly to **Mali 5th Gen r54p0**.

## r54p0 source

Obtain the r54p0 source from Arm's official Mali 5th Gen kernel-driver page:

```text
https://developer.arm.com/downloads/-/mali-drivers/5th-gen-gpu-architecture-kernel
```

Package recorded for this project:

```text
AX504X08X-SW-99002-r54p0-01eac0.tar.gz
MD5: 3bcd3870b58f83442b16b83e432e2f97
```

The driver source archive is deliberately not committed to this repository.

## Reference host

Arm's Virtual Platform guide says the instructions were tested on Ubuntu **24.04.2 LTS** with 16 GB RAM, 256 GB disk and 4+ vCPUs.

## Build

Install prerequisites:

```bash
sudo apt update
sudo apt install -y \
  build-essential gcc g++ clang llvm lld \
  make bc bison flex \
  libssl-dev libelf-dev dwarves \
  patch unzip xz-utils cpio gzip \
  busybox-static curl wget git \
  qemu-system-x86 qemu-utils \
  python3 python3-pip cmake ninja-build \
  ripgrep jq gdb
```

Place both inputs in `downloads/` and run:

```bash
chmod +x setup_arm_r54p0_x86.sh

MALI_TARBALL="$HOME/arm-mali-r54p0-x86/downloads/AX504X08X-SW-99002-r54p0-01eac0.tar.gz" \
PATCH_ZIP="$HOME/arm-mali-r54p0-x86/downloads/patches_for_virtual_device.zip" \
./setup_arm_r54p0_x86.sh
```

The helper verifies prerequisites, validates the six patch names, applies the patches sequentially to a fresh integrated tree, configures the Arm x86 dummy-model build, builds `mali_kbase.ko`, creates an initramfs, and writes a QEMU launcher.

## QEMU

```bash
$HOME/arm-mali-r54p0-x86/run.sh
```

The generated launcher uses KVM when available and falls back to QEMU TCG.

## Expected successful probe

```text
mali mali.0: Kernel DDK version r54p0-00eac0
mali mali.0: Using Dummy Model
mali mali.0: GPU metrics tracepoint support enabled
mali mali.0: Probed as mali0
```

Then check:

```bash
cat /sys/module/mali_kbase/version
ls -l /dev/mali*
```

## libGPUCounters smoke test

Arm recommends:

```bash
git clone https://github.com/ARM-software/libGPUCounters.git
cd libGPUCounters
cmake -DHWCPIPE_BUILD_EXAMPLES=ON -B build .
cmake --build build -j"$(nproc)"
./build/examples/api-example
```

With the dummy model, counter values are expected to be zero while the example should still identify the virtual Mali device.

## Research boundary

`CONFIG_MALI_NO_MALI=y` is an investigation environment. Arm's FAQ states that the dummy model does not execute GPU firmware and does not emulate real GPU hardware behavior. Dummy-model-only vulnerabilities are therefore not final bounty findings.
