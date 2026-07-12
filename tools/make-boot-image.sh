#!/bin/bash
# Assemble the Droidian boot image for the Surface Duo 1:
#
#   ./tools/make-boot-image.sh <Image.gz> <ramdisk-source> <stock.dtb> [out.img]
#
#   Image.gz       - kernel built per kernel-packaging/README.md
#   ramdisk-source - a droidian boot.img (ramdisk is extracted) OR a raw
#                    gzipped initramfs
#   stock.dtb      - the generic SoC DTB extracted from YOUR backup
#                    (tools/extract-stock-dtb.sh)
#
# The halium initramfs is patched in flight with
# kernel-packaging/patches/0005-initramfs-halium-data-ordered.patch -
# without it the phone stalls for minutes under any write burst (see
# docs/FREEZE-FORENSICS.md). Two people building "the same kernel" must
# not end up with different boot images, hence this script.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KERNEL="${1:?usage: $0 <Image.gz> <ramdisk-source> <stock.dtb> [out.img]}"
RDSRC="${2:?ramdisk source (droidian boot.img or gzipped initramfs) required}"
DTB="${3:?stock dtb required (tools/extract-stock-dtb.sh)}"
OUT="${4:-$ROOT/out/boot-duo1-droidian.img}"
PATCH="$ROOT/kernel-packaging/patches/0005-initramfs-halium-data-ordered.patch"

for f in "$KERNEL" "$RDSRC" "$DTB" "$PATCH"; do
    [ -f "$f" ] || { echo "ERROR: $f not found"; exit 1; }
done
for tool in fakeroot cpio patch python3; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool required"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. get the raw ramdisk
case "$(file -b "$RDSRC")" in
    Android\ bootimg*|*Android*boot*)
        python3 "$HERE/mkbootimg/unpack_bootimg.py" --boot_img "$RDSRC" --out "$WORK/parts" >/dev/null
        RD="$WORK/parts/ramdisk"
        ;;
    *)  RD="$RDSRC" ;;
esac

# 2. unpack, patch, repack
mkdir -p "$WORK/rd"
gzip -dc "$RD" | (cd "$WORK/rd" && fakeroot cpio -idm --quiet)
if (cd "$WORK/rd" && patch -p1 --dry-run -s) < "$PATCH" >/dev/null 2>&1; then
    (cd "$WORK/rd" && patch -p1 -s) < "$PATCH"
    echo "== initramfs: data-ordered patch applied"
elif grep -q "data=ordered," "$WORK/rd/scripts/halium" 2>/dev/null; then
    echo "== initramfs: already patched"
else
    echo "ERROR: patch does not apply and initramfs is not already patched"
    exit 1
fi
# Deterministic repack: initramfs mtimes are meaningless, so normalize
# them (extraction dirs and patched files carry build-time stamps),
# sort the file list, renumber inodes/devices (newc records both and
# they vary per checkout), and strip gzip's timestamp - same inputs,
# same bytes. --reproducible = GNU cpio >= 2.12.
(cd "$WORK/rd" && fakeroot sh -c '
    find . -print0 | xargs -0 touch -h -d "@1" 2>/dev/null || true
    find . | LC_ALL=C sort | cpio -o -H newc --quiet --reproducible' | gzip -9 -n) > "$WORK/ramdisk.gz"

# 3. pack. Header fields come from kernel-packaging/debian/kernel-info.mk -
# the single source of truth the deb build uses too.
MK="$ROOT/kernel-packaging/debian/kernel-info.mk"
mk_get() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$MK" | head -1; }
CMDLINE="$(mk_get KERNEL_BOOTIMAGE_CMDLINE)"
[ -n "$CMDLINE" ] || { echo "ERROR: KERNEL_BOOTIMAGE_CMDLINE not found in $MK"; exit 1; }
python3 "$HERE/mkbootimg/mkbootimg.py" \
    --header_version "$(mk_get KERNEL_BOOTIMAGE_VERSION)" \
    --kernel "$KERNEL" --ramdisk "$WORK/ramdisk.gz" --dtb "$DTB" \
    --pagesize   "$(mk_get KERNEL_BOOTIMAGE_PAGE_SIZE)" \
    --base       "$(mk_get KERNEL_BOOTIMAGE_BASE_OFFSET)" \
    --kernel_offset  "$(mk_get KERNEL_BOOTIMAGE_KERNEL_OFFSET)" \
    --ramdisk_offset "$(mk_get KERNEL_BOOTIMAGE_INITRAMFS_OFFSET)" \
    --second_offset  "$(mk_get KERNEL_BOOTIMAGE_SECONDIMAGE_OFFSET)" \
    --tags_offset    "$(mk_get KERNEL_BOOTIMAGE_TAGS_OFFSET)" \
    --dtb_offset     "$(mk_get KERNEL_BOOTIMAGE_DTB_OFFSET)" \
    --os_version     "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" \
    --os_patch_level "$(mk_get KERNEL_BOOTIMAGE_PATCH_LEVEL)" \
    --cmdline "$CMDLINE" -o "$OUT"

echo "== packed: $OUT"
"$HERE/flash-safely.sh" validate "$OUT"
