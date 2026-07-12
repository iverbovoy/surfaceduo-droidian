#!/bin/sh
# Create misc-brake.img - a 2 KB one-shot "parking brake" BCB.
# Flashed into the misc partition, it makes ABL stop in fastboot on the
# NEXT boot (then clears itself). Arm it before every risky step so an
# unattended reset can never let stock Android normal-boot over a
# foreign userdata (the BCB-poison scenario - see docs/SAFETY.md).
#
#   ./tools/make-misc-brake.sh              # writes ./misc-brake.img
#   fastboot flash misc misc-brake.img      # arm from the bootloader
#   dd if=misc-brake.img of=/dev/disk/by-partlabel/misc   # arm from Linux
set -e
OUT="${1:-misc-brake.img}"
dd if=/dev/zero of="$OUT" bs=2048 count=1 2>/dev/null
printf 'bootonce-bootloader' | dd of="$OUT" conv=notrunc 2>/dev/null
echo "OK: $OUT (2048 bytes, BCB command 'bootonce-bootloader')"
