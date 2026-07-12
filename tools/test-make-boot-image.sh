#!/bin/bash
# Offline self-test for make-boot-image.sh. Needs no device and no real
# kernel: it fabricates a fake Image.gz, a fake DTB and a tiny initramfs
# that contains scripts/halium with the data=journal line, then checks:
#   1. the data=journal -> data=ordered patch is actually applied
#   2. a ramdisk WITHOUT the target line fails the build (no silent pass)
#   3. the packed image passes flash-safely.sh validate
#   4. two builds from identical inputs are byte-identical (deterministic)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# --- fixtures ---------------------------------------------------------
# a fake but structurally valid ARM64 Image.gz: "ARM\x64" magic at
# offset 56 of the decompressed payload (what the validator checks) and
# >4MB of random bytes so gzip can't shrink it below the size floor
{ head -c 56 /dev/urandom; printf 'ARM\x64'; head -c 5000000 /dev/urandom; } | gzip -n > "$WORK/Image.gz"
# a minimal DTB (FDT magic + padding); validator only checks the magic
printf '\xd0\x0d\xfe\xed' > "$WORK/fake.dtb"
head -c 4096 /dev/zero >> "$WORK/fake.dtb"

make_ramdisk() {  # $1 = halium script content, $2 = out.gz
    local rd="$WORK/rd"; rm -rf "$rd"; mkdir -p "$rd/scripts"
    printf '%s\n' "$1" > "$rd/scripts/halium"
    (cd "$rd" && find . | cpio -o -H newc --quiet | gzip -n) > "$2"
}

# full context of the 0005 hunk - patch(1) needs the surrounding lines
# to anchor, not just the target line (offset from line 824 is fine)
GOOD='
		# Mount the data partition to a temporary mount point
		# FIXME: data=journal used on ext4 as a workaround for bug 1387214
		[ `blkid $path -o value -s TYPE` = "ext4" ] && OPTIONS="data=journal,"
		mount -o discard,$OPTIONS $path /tmpmnt

		# Set $_syspart if it is specified as systempart= on the command line'
BAD='		mount -o defaults $path /tmpmnt   # nothing to patch here'

# --- 1 + 3: happy path patches and validates --------------------------
make_ramdisk "$GOOD" "$WORK/rd-good.gz"
"$HERE/make-boot-image.sh" "$WORK/Image.gz" "$WORK/rd-good.gz" "$WORK/fake.dtb" "$WORK/out1.img" >/dev/null \
    || fail "build rejected a valid input (or validate failed)"
# unpack and confirm the substitution really happened
u="$WORK/u"; python3 "$HERE/mkbootimg/unpack_bootimg.py" --boot_img "$WORK/out1.img" --out "$u" >/dev/null
mkdir -p "$u/rd"; (cd "$u/rd" && gzip -dc "$u/ramdisk" | cpio -idm --quiet)
grep -q 'data=ordered,' "$u/rd/scripts/halium" || fail "data=ordered not present in packed ramdisk"
grep -q 'data=journal,' "$u/rd/scripts/halium" && fail "data=journal survived in packed ramdisk"
echo "ok 1+3: patch applied, image validates"

# --- 2: a ramdisk with nothing to patch must FAIL, not pass silently --
make_ramdisk "$BAD" "$WORK/rd-bad.gz"
if "$HERE/make-boot-image.sh" "$WORK/Image.gz" "$WORK/rd-bad.gz" "$WORK/fake.dtb" "$WORK/out-bad.img" >/dev/null 2>&1; then
    fail "build silently accepted an unpatchable ramdisk"
fi
echo "ok 2: unpatchable ramdisk correctly rejected"

# --- 4: deterministic ------------------------------------------------
"$HERE/make-boot-image.sh" "$WORK/Image.gz" "$WORK/rd-good.gz" "$WORK/fake.dtb" "$WORK/out2.img" >/dev/null
a=$(sha256sum "$WORK/out1.img" | cut -d' ' -f1)
b=$(sha256sum "$WORK/out2.img" | cut -d' ' -f1)
[ "$a" = "$b" ] || fail "identical inputs produced different images ($a != $b)"
echo "ok 4: byte-for-byte reproducible"

echo "ALL PASS"
