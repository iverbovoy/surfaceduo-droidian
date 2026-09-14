#!/bin/bash
# Offline self-test for the image validator in flash-safely.sh. Needs no
# device and no real kernel.
#
# The existing boot-image self-test only ever feeds the validator a GOOD
# image, so a validator that returned 0 unconditionally would pass CI.
# This one builds deliberately broken images and asserts every guard
# actually fires. These guards are what stands between a user and a
# device with no EDL recovery path, so they are worth testing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MKBOOT="$HERE/mkbootimg/mkbootimg.py"
MK="$ROOT/kernel-packaging/debian/kernel-info.mk"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
mk_get() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$MK" | head -1; }

# rejects <image> <description> <substring the complaint must contain>
# The substring matters: a test that only asserts "it said no" would pass
# even if the wrong guard fired for the wrong reason.
rejects() {
    local img="$1" why="$2" expect="$3" out
    if out="$("$HERE/flash-safely.sh" validate "$img" 2>&1)"; then
        fail "validate ACCEPTED a broken image ($why)"
    fi
    case "$out" in
        *"$expect"*) : ;;
        *) fail "rejected $why, but not for that reason (wanted '$expect'): $out" ;;
    esac
    echo "ok: rejected - $why"
}

# --- fixtures ---------------------------------------------------------
# structurally valid fake ARM64 kernel: "ARM\x64" at offset 56 of the
# decompressed payload, padded past the 4 MB size floor with random
# bytes so gzip cannot shrink it back under
mkkernel() {  # $1 = magic bytes to place at offset 56, $2 = out.gz
    { head -c 56 /dev/urandom; printf '%b' "$1"; head -c 5000000 /dev/urandom; } \
        | gzip -n > "$2"
}
mkkernel 'ARM\x64' "$WORK/kernel-good.gz"
mkkernel 'XXXX'    "$WORK/kernel-nomagic.gz"

mkdtb() {  # $1 = magic bytes, $2 = out
    printf '%b' "$1" > "$2"
    head -c 4096 /dev/zero >> "$2"
}
mkdtb '\xd0\x0d\xfe\xed' "$WORK/dtb-good"
mkdtb '\xde\xad\xbe\xef' "$WORK/dtb-nomagic"

(cd "$WORK" && printf '%s' "" | cpio -o -H newc --quiet 2>/dev/null | gzip -n) > "$WORK/ramdisk.gz"

CMDLINE="$(mk_get KERNEL_BOOTIMAGE_CMDLINE)"
[ -n "$CMDLINE" ] || fail "KERNEL_BOOTIMAGE_CMDLINE missing from $MK"

# pack an image straight through mkbootimg so header fields can be bent
# in ways make-boot-image.sh would never produce
pack() {  # pack <out> [extra mkbootimg args ...]
    local out="$1"; shift
    python3 "$MKBOOT" \
        --kernel "$WORK/kernel-good.gz" --ramdisk "$WORK/ramdisk.gz" \
        --pagesize "$(mk_get KERNEL_BOOTIMAGE_PAGE_SIZE)" \
        -o "$out" "$@" >/dev/null
}

# --- 0: a good image must PASS, or every case below is meaningless ----
pack "$WORK/good.img" --header_version 2 --dtb "$WORK/dtb-good" \
     --os_version "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" --cmdline "$CMDLINE"
"$HERE/flash-safely.sh" validate "$WORK/good.img" >/dev/null \
    || fail "validate rejected a good image - the fixtures are wrong, not the validator"
echo "ok: baseline good image accepted"

# --- size floor -------------------------------------------------------
head -c 1000000 "$WORK/good.img" > "$WORK/tiny.img"
rejects "$WORK/tiny.img" "under the 4 MB size floor" "not a real boot.img"

# --- size ceiling (sparse, costs no disk) -----------------------------
cp "$WORK/good.img" "$WORK/huge.img"
truncate -s 101M "$WORK/huge.img"
rejects "$WORK/huge.img" "over the 100 MB size ceiling" "larger than the boot partition"

# --- boot magic -------------------------------------------------------
cp "$WORK/good.img" "$WORK/nomagic.img"
printf 'DROIDIAN' | dd of="$WORK/nomagic.img" bs=1 seek=0 conv=notrunc status=none
rejects "$WORK/nomagic.img" "ANDROID! boot magic clobbered" "missing ANDROID! boot magic"

# --- header version ---------------------------------------------------
for hv in 0 1; do
    pack "$WORK/hv$hv.img" --header_version "$hv" \
         --os_version "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" --cmdline "$CMDLINE"
    rejects "$WORK/hv$hv.img" "header version $hv instead of 2" "expected 2"
done

# --- DTB --------------------------------------------------------------
# mkbootimg refuses to build a v2 image without a DTB ("DTB image must
# not be empty"), so this one is forged by hand: dtb_size sits at offset
# 1648 of the v2 header. Third-party images can and do arrive like this,
# and such an image will not boot on the Duo.
cp "$WORK/good.img" "$WORK/nodtb.img"
printf '\0\0\0\0' | dd of="$WORK/nodtb.img" bs=1 seek=1648 conv=notrunc status=none
rejects "$WORK/nodtb.img" "header v2 declaring no DTB" "no DTB embedded"

pack "$WORK/dtbjunk.img" --header_version 2 --dtb "$WORK/dtb-nomagic" \
     --os_version "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" --cmdline "$CMDLINE"
rejects "$WORK/dtbjunk.img" "DTB without FDT magic" "no FDT magic"

# --- os version -------------------------------------------------------
pack "$WORK/noosv.img" --header_version 2 --dtb "$WORK/dtb-good" --cmdline "$CMDLINE"
rejects "$WORK/noosv.img" "os version missing from the header" "os version missing"

# --- cmdline target ---------------------------------------------------
pack "$WORK/wronghw.img" --header_version 2 --dtb "$WORK/dtb-good" \
     --os_version "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" \
     --cmdline "androidboot.hardware=sunfish console=ttyMSM0,115200n8"
rejects "$WORK/wronghw.img" "androidboot.hardware naming another device" "is not a Duo target"

pack "$WORK/nohw.img" --header_version 2 --dtb "$WORK/dtb-good" \
     --os_version "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" \
     --cmdline "console=ttyMSM0,115200n8"
rejects "$WORK/nohw.img" "cmdline with no androidboot.hardware at all" "cmdline lacks androidboot.hardware"

# --- kernel payload ---------------------------------------------------
python3 "$MKBOOT" --kernel "$WORK/kernel-nomagic.gz" --ramdisk "$WORK/ramdisk.gz" \
    --pagesize "$(mk_get KERNEL_BOOTIMAGE_PAGE_SIZE)" --header_version 2 \
    --dtb "$WORK/dtb-good" --os_version "$(mk_get KERNEL_BOOTIMAGE_OS_VERSION)" \
    --cmdline "$CMDLINE" -o "$WORK/badkernel.img" >/dev/null
rejects "$WORK/badkernel.img" "kernel without the ARM64 Image magic" "ARM64 Linux Image magic"

echo "ALL PASS"
