#!/usr/bin/env bash
set -euo pipefail

# Arm GPU Bug Bounty x86 "Simulated Platform Device" bootstrap.
# Based on Arm's 20250623-1.0 Virtual Platform How-To Guide and the supplied
# patches_for_virtual_device.zip.
#
# Canonical workspace:
#   $HOME/arm-mali-r54p0-x86
#
# This helper implements the r54p0 x86 baseline. It does not claim that the
# x86 NO_MALI environment is the final bounty validation environment.

ROOT="${ROOT:-$HOME/arm-mali-r54p0-x86}"
KVER="${KVER:-6.12.111}"
KERNEL_URL="${KERNEL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz}"
MALI_TARBALL="${MALI_TARBALL:-}"
PATCH_ZIP="${PATCH_ZIP:-}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

EXPECTED_MALI_MD5="3bcd3870b58f83442b16b83e432e2f97"
EXPECTED_PATCHES=(
  0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch
  0002-Fix-x86-build-error-for-missing-asm-arch_timer.h.patch
  0003-Workaround-arch_timer-funcs-undefined-for-NO_MALI.patch
  0004-Workaround-no-definition-of-dmb-in-non-Arm-platforms.patch
  0005-Fix-unused-function-warnings.patch
  0006-Fix-make-clean-when-no-arbitration-code-present.patch
)

usage() {
  cat <<'USAGE'
Usage:
  MALI_TARBALL=/path/to/AX504X08X-SW-99002-r54p0-01eac0.tar.gz \
  PATCH_ZIP=/path/to/patches_for_virtual_device.zip \
  ./setup_arm_r54p0_x86.sh

Optional:
  ROOT=$HOME/arm-mali-r54p0-x86
  KVER=6.12.111
  KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-<KVER>.tar.xz
  FORCE_REBUILD=1

The script builds:
  - x86_64 Linux kernel
  - Arm Mali 5th Gen Kbase r54p0 as mali_kbase.ko
  - minimal BusyBox initramfs for driver bring-up

The Arm driver archive must be obtained separately from Arm's official
Mali 5th Gen download page and used according to its license/terms.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ -n "$MALI_TARBALL" ]] || { usage; exit 2; }
[[ -n "$PATCH_ZIP" ]] || { usage; exit 2; }
[[ -f "$MALI_TARBALL" ]] || { echo "ERROR: missing MALI_TARBALL: $MALI_TARBALL" >&2; exit 1; }
[[ -f "$PATCH_ZIP" ]] || { echo "ERROR: missing PATCH_ZIP: $PATCH_ZIP" >&2; exit 1; }

for cmd in \
  gcc g++ clang make flex bison bc cpio gzip xz patch unzip tar curl \
  busybox qemu-system-x86_64 qemu-img sha256sum md5sum find grep sed awk; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  }
done

mkdir -p "$ROOT"/{downloads,source,kernel/baseline,patches/arm-virtual-device,rootfs/baseline,artifacts/baseline,qemu/logs,research,logs,work}

LOG="$ROOT/logs/setup.log"
exec > >(tee -a "$LOG") 2>&1

log() { printf '\n[+] %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log "Preflight"
{
  echo "date=$(date -Is)"
  echo "root=$ROOT"
  echo "kernel=$KVER"
  echo "kernel_url=$KERNEL_URL"
  echo "host_uname=$(uname -a)"
  echo "host_arch=$(uname -m)"
  gcc --version | head -1
  clang --version | head -1
  qemu-system-x86_64 --version | head -1
} | tee "$ROOT/logs/host.txt"

[[ "$(uname -m)" == "x86_64" ]] || fail "This x86 Simulated Platform build expects an x86_64 host."

# 1) Verify exact r54p0 archive.
log "Verifying r54p0 source archive"
MALI_MD5="$(md5sum "$MALI_TARBALL" | awk '{print $1}')"
echo "MALI_MD5=$MALI_MD5"
[[ "$MALI_MD5" == "$EXPECTED_MALI_MD5" ]] || \
  fail "r54p0 archive MD5 mismatch. Expected $EXPECTED_MALI_MD5, got $MALI_MD5"
sha256sum "$MALI_TARBALL" | tee "$ROOT/logs/mali-source.sha256"

# 2) Validate the six supplied patches and preserve them unchanged.
log "Extracting and validating Arm patch bundle"
rm -rf "$ROOT/work/patches-extracted"
mkdir -p "$ROOT/work/patches-extracted"
unzip -q "$PATCH_ZIP" -d "$ROOT/work/patches-extracted"

mapfile -t PATCHES < <(find "$ROOT/work/patches-extracted" -maxdepth 1 -type f -name '*.patch' -printf '%f\n' | sort)
[[ "${#PATCHES[@]}" -eq 6 ]] || fail "Expected exactly 6 patches, found ${#PATCHES[@]}"

for expected in "${EXPECTED_PATCHES[@]}"; do
  [[ -f "$ROOT/work/patches-extracted/$expected" ]] || fail "Missing expected patch: $expected"
done

rm -rf "$ROOT/patches/arm-virtual-device"
mkdir -p "$ROOT/patches/arm-virtual-device"
for p in "${EXPECTED_PATCHES[@]}"; do
  cp -a "$ROOT/work/patches-extracted/$p" "$ROOT/patches/arm-virtual-device/$p"
done
sha256sum "$ROOT/patches/arm-virtual-device"/*.patch | tee "$ROOT/logs/patch-hashes.txt"

# 3) Download/cache selected official Linux source.
log "Preparing Linux $KVER source"
KERNEL_ARCHIVE="$ROOT/downloads/linux-${KVER}.tar.xz"
KERNEL_CLEAN="$ROOT/source/linux-${KVER}-clean"
KDIR="$ROOT/source/linux-${KVER}-integrated"

if [[ ! -f "$KERNEL_ARCHIVE" ]]; then
  curl -L --fail --retry 3 -o "$KERNEL_ARCHIVE" "$KERNEL_URL"
fi

mkdir -p "$ROOT/source"
if [[ ! -d "$KERNEL_CLEAN" ]]; then
  # The archive normally contains linux-${KVER}/.
  TMP_EXTRACT="$ROOT/work/linux-extract-${KVER}"
  rm -rf "$TMP_EXTRACT"
  mkdir -p "$TMP_EXTRACT"
  tar -xJf "$KERNEL_ARCHIVE" -C "$TMP_EXTRACT"
  [[ -d "$TMP_EXTRACT/linux-${KVER}" ]] || fail "Kernel archive did not contain linux-${KVER}/"
  mv "$TMP_EXTRACT/linux-${KVER}" "$KERNEL_CLEAN"
  rm -rf "$TMP_EXTRACT"
fi

if [[ -d "$KDIR" ]]; then
  if [[ "$FORCE_REBUILD" != "1" ]]; then
    fail "Integrated tree already exists: $KDIR. Use a fresh workspace or FORCE_REBUILD=1."
  fi
  rm -rf "$KDIR"
fi
cp -a "$KERNEL_CLEAN" "$KDIR"

# 4) Unpack r54p0 and locate the Kbase kernel directory.
log "Unpacking r54p0 source"
rm -rf "$ROOT/work/mali-src"
mkdir -p "$ROOT/work/mali-src"
tar -xf "$MALI_TARBALL" -C "$ROOT/work/mali-src"
MALI_KERNEL_DIR="$(find "$ROOT/work/mali-src" -type d -path '*/driver/product/kernel' -print -quit)"
[[ -n "$MALI_KERNEL_DIR" ]] || fail "Could not find */driver/product/kernel inside r54p0 archive"

MALI_RELEASE_FILE="$MALI_KERNEL_DIR/drivers/gpu/arm/midgard/Kbuild"
[[ -f "$MALI_RELEASE_FILE" ]] || fail "Missing Kbase Kbuild: $MALI_RELEASE_FILE"
grep -n 'MALI_RELEASE_NAME' "$MALI_RELEASE_FILE" | tee "$ROOT/logs/driver-release.txt"
grep -q 'r54p0' "$MALI_RELEASE_FILE" || fail "Kbase source does not report r54p0"

# 5) Arm's documented in-tree integration.
log "Integrating Kbase into Linux"
cp -a "$MALI_KERNEL_DIR"/* "$KDIR"/
cd "$KDIR"
printf '%s\n' 'obj-$(CONFIG_MALI_MIDGARD) += arm/' >> drivers/gpu/Makefile
sed -i '$i source "drivers/gpu/arm/Kconfig"' drivers/video/Kconfig

# 6) Sequential non-destructive patch preflight.
log "Sequential dry-run of all six Arm x86 patches"
DRY="$ROOT/work/patch-dryrun"
rm -rf "$DRY"
cp -a "$KDIR" "$DRY"
(
  cd "$DRY"
  for expected in "${EXPECTED_PATCHES[@]}"; do
    patch_file="$ROOT/patches/arm-virtual-device/$expected"
    echo "DRY-RUN: $expected"
    patch --dry-run -p3 -i "$patch_file"
    patch -p3 -i "$patch_file"
  done
)
rm -rf "$DRY"

# 7) Apply the exact Arm patch series to the real integrated tree.
log "Applying all six Arm x86 patches"
(
  cd "$KDIR"
  for expected in "${EXPECTED_PATCHES[@]}"; do
    patch_file="$ROOT/patches/arm-virtual-device/$expected"
    echo "APPLY: $expected"
    patch -p3 -i "$patch_file"
  done
) | tee "$ROOT/logs/patch-apply.txt"

# 8) Configure x86_64 Simulated Platform Device.
log "Configuring x86_64 Mali Simulated Platform Device"
BUILD="$ROOT/kernel/baseline"
rm -rf "$BUILD"
mkdir -p "$BUILD"
make O="$BUILD" x86_64_defconfig

SCRIPTS="$KDIR/scripts/config"
[[ -x "$SCRIPTS" ]] || fail "Missing kernel scripts/config helper"

"$SCRIPTS" --file "$BUILD/.config" \
  --disable OF \
  --enable MODULES \
  --enable BLK_DEV_INITRD \
  --enable DEVTMPFS \
  --enable DEVTMPFS_MOUNT \
  --enable SERIAL_8250 \
  --enable SERIAL_8250_CONSOLE \
  --module MALI_MIDGARD \
  --enable MALI_CSF_SUPPORT \
  --enable MALI_EXPERT \
  --enable MALI_NO_MALI \
  --disable MALI_REAL_HW \
  --disable MALI_DEBUG \
  --set-str MALI_NO_MALI_DEFAULT_GPU tKRx \
  --set-str MALI_PLATFORM_NAME vexpress

make O="$BUILD" olddefconfig

log "Auditing Mali configuration"
{
  grep -E '^(CONFIG_MALI_|# CONFIG_MALI_|CONFIG_OF=|# CONFIG_OF )' "$BUILD/.config" || true
  echo
  echo '=== state ==='
  "$SCRIPTS" --file "$BUILD/.config" --state MALI_MIDGARD
  "$SCRIPTS" --file "$BUILD/.config" --state MALI_CSF_SUPPORT
  "$SCRIPTS" --file "$BUILD/.config" --state MALI_EXPERT
  "$SCRIPTS" --file "$BUILD/.config" --state MALI_NO_MALI
  "$SCRIPTS" --file "$BUILD/.config" --state MALI_REAL_HW
  "$SCRIPTS" --file "$BUILD/.config" --state MALI_DEBUG
  "$SCRIPTS" --file "$BUILD/.config" --state OF
} | tee "$ROOT/logs/config-baseline.txt"

[[ "$("$SCRIPTS" --file "$BUILD/.config" --state MALI_MIDGARD)" == "m" ]] || fail "MALI_MIDGARD is not m"
[[ "$("$SCRIPTS" --file "$BUILD/.config" --state MALI_CSF_SUPPORT)" == "y" ]] || fail "MALI_CSF_SUPPORT is not y"
[[ "$("$SCRIPTS" --file "$BUILD/.config" --state MALI_EXPERT)" == "y" ]] || fail "MALI_EXPERT is not y"
[[ "$("$SCRIPTS" --file "$BUILD/.config" --state MALI_NO_MALI)" == "y" ]] || fail "MALI_NO_MALI is not y"
[[ "$("$SCRIPTS" --file "$BUILD/.config" --state MALI_REAL_HW)" == "n" ]] || fail "MALI_REAL_HW is not n"
[[ "$("$SCRIPTS" --file "$BUILD/.config" --state MALI_DEBUG)" == "n" ]] || fail "MALI_DEBUG is not n"
[[ "$("$SCRIPTS" --file "$BUILD/.config" --state OF)" == "n" ]] || fail "CONFIG_OF is not n"
grep -q '^CONFIG_MALI_NO_MALI_DEFAULT_GPU="tKRx"$' "$BUILD/.config" || fail 'MALI_NO_MALI_DEFAULT_GPU is not "tKRx"'
grep -q '^CONFIG_MALI_PLATFORM_NAME="vexpress"$' "$BUILD/.config" || fail 'MALI_PLATFORM_NAME is not "vexpress"'
grep -E '^CONFIG_LARGE_PAGE_SUPPORT=' "$BUILD/.config" | tee "$ROOT/logs/large-page.txt" || true

# Baseline is intentionally not instrumented.
"$SCRIPTS" --file "$BUILD/.config" --disable KASAN --disable UBSAN --disable KCOV
make O="$BUILD" olddefconfig

# 9) Build.
log "Building kernel and Mali module"
make -C "$KDIR" O="$BUILD" -j"$(nproc)" bzImage modules \
  2>&1 | tee "$ROOT/logs/build-baseline.txt"

MALI_KO="$(find "$BUILD" -type f -name mali_kbase.ko -print -quit)"
[[ -n "$MALI_KO" ]] || fail "mali_kbase.ko was not produced"
[[ -f "$BUILD/arch/x86/boot/bzImage" ]] || fail "bzImage was not produced"
[[ -f "$BUILD/vmlinux" ]] || fail "vmlinux was not produced"

# 10) Save artifacts.
log "Saving baseline artifacts"
cp "$MALI_KO" "$ROOT/artifacts/baseline/mali_kbase.ko"
cp "$BUILD/arch/x86/boot/bzImage" "$ROOT/artifacts/baseline/bzImage"
cp "$BUILD/vmlinux" "$ROOT/artifacts/baseline/vmlinux"
cp "$BUILD/.config" "$ROOT/artifacts/baseline/kernel.config"
sha256sum \
  "$ROOT/artifacts/baseline/mali_kbase.ko" \
  "$ROOT/artifacts/baseline/bzImage" \
  "$ROOT/artifacts/baseline/vmlinux" \
  "$ROOT/artifacts/baseline/kernel.config" \
  | tee "$ROOT/artifacts/baseline/SHA256SUMS"

# 11) Minimal initramfs.
log "Creating BusyBox initramfs"
RFS="$ROOT/rootfs/baseline"
rm -rf "$RFS"
mkdir -p "$RFS"/{bin,dev,etc,proc,sys,tmp}
BUSYBOX_BIN="$(command -v busybox)"
cp "$BUSYBOX_BIN" "$RFS/bin/busybox"
chmod 0755 "$RFS/bin/busybox"
for app in sh mount umount ls cat echo dmesg insmod rmmod sleep grep mkdir uname id ps; do
  ln -sf busybox "$RFS/bin/$app"
done
cp "$ROOT/artifacts/baseline/mali_kbase.ko" "$RFS/mali_kbase.ko"

cat > "$RFS/init" <<'INIT'
#!/bin/sh

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

printf '\n=== Arm Mali r54p0 x86 virtual lab ===\n'
uname -a
printf '\n--- loading mali_kbase.ko ---\n'
insmod /mali_kbase.ko
RC=$?
printf 'insmod exit=%s\n' "$RC"

printf '\n--- Mali dmesg ---\n'
dmesg | grep -i mali || true

printf '\n--- device nodes ---\n'
ls -l /dev/mali* 2>/dev/null || true

printf '\n--- module version ---\n'
cat /sys/module/mali_kbase/version 2>/dev/null || true

printf '\nType commands here; Ctrl-] is the QEMU escape.\n'
exec /bin/sh
INIT
chmod 0755 "$RFS/init"

( cd "$RFS" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 > "$ROOT/artifacts/baseline/mali-initramfs.cpio.gz"

# 12) QEMU launcher with KVM/TCG fallback.
log "Writing QEMU launcher"
cat > "$ROOT/run.sh" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL=(-accel kvm -cpu host)
  echo "[+] Using KVM"
else
  ACCEL=(-accel tcg,thread=multi -cpu max)
  echo "[!] /dev/kvm unavailable; using QEMU TCG"
fi

exec qemu-system-x86_64 \
  -machine pc \
  "${ACCEL[@]}" \
  -m 4096 \
  -smp 4 \
  -kernel "$ROOT/artifacts/baseline/bzImage" \
  -initrd "$ROOT/artifacts/baseline/mali-initramfs.cpio.gz" \
  -append 'console=ttyS0' \
  -nographic \
  -no-reboot
RUN
chmod +x "$ROOT/run.sh"

# 13) Report.
{
  echo "ROOT=$ROOT"
  echo "KVER=$KVER"
  echo "KERNEL_URL=$KERNEL_URL"
  echo "KDIR=$KDIR"
  echo "MALI_KERNEL_DIR=$MALI_KERNEL_DIR"
  echo "MALI_RELEASE=$(grep 'MALI_RELEASE_NAME' "$MALI_RELEASE_FILE" | head -1)"
  echo
  echo '=== config ==='
  grep -E '^(CONFIG_MALI_|# CONFIG_MALI_|CONFIG_OF=|# CONFIG_OF )' "$BUILD/.config" || true
  echo
  echo '=== artifacts ==='
  ls -lh \
    "$ROOT/artifacts/baseline/mali_kbase.ko" \
    "$ROOT/artifacts/baseline/bzImage" \
    "$ROOT/artifacts/baseline/vmlinux" \
    "$ROOT/artifacts/baseline/mali-initramfs.cpio.gz"
} | tee "$ROOT/artifacts/baseline/build-report.txt"

log "BUILD COMPLETE"
cat <<DONE
Artifacts:
  $ROOT/artifacts/baseline/bzImage
  $ROOT/artifacts/baseline/vmlinux
  $ROOT/artifacts/baseline/mali_kbase.ko
  $ROOT/artifacts/baseline/mali-initramfs.cpio.gz
  $ROOT/artifacts/baseline/kernel.config
  $ROOT/artifacts/baseline/build-report.txt

Run:
  $ROOT/run.sh

Expected Arm probe signature includes:
  mali mali.0: Kernel DDK version r54p0-00eac0
  mali mali.0: Using Dummy Model
  mali mali.0: Probed as mali0
DONE
