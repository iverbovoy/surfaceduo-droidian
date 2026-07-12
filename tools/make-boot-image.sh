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
(cd "$WORK/rd" && fakeroot sh -c 'find . | cpio -o -H newc --quiet' | gzip -9) > "$WORK/ramdisk.gz"

# 3. pack (header v2, offsets/os_version mirror the stock MS boot.img -
# same values kernel-packaging/debian/kernel-info.mk encodes)
CMDLINE="console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xa90000 androidboot.hardware=surfaceduo androidboot.hardware.platform=qcom androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 loop.max_part=7 androidboot.usbcontroller=a600000.dwc3 kpti=off buildvariant=user console=tty0 datapart=/dev/sda6 droidian.lvm.prefer"
python3 "$HERE/mkbootimg/mkbootimg.py" --header_version 2 \
    --kernel "$KERNEL" --ramdisk "$WORK/ramdisk.gz" --dtb "$DTB" \
    --pagesize 4096 --base 0x0 --kernel_offset 0x8000 \
    --ramdisk_offset 0x1000000 --second_offset 0xf00000 --tags_offset 0x100 \
    --dtb_offset 0x1f00000 --os_version 11.0.0 --os_patch_level 2023-08 \
    --cmdline "$CMDLINE" -o "$OUT"

echo "== packed: $OUT"
"$HERE/flash-safely.sh" validate "$OUT"
