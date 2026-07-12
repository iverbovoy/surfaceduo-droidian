#!/bin/bash
# Extract the GENERIC SoC DTB from your own stock boot image backup.
#
# The stock Surface Duo boot.img (header v2) carries a CONCATENATED pile
# of DTBs in its dtb section; ABL picks one by board-id and then merges
# the dtbo overlay. The one a Droidian boot image must ship is the
# generic wildcard ("SM8150 v2 SoC", qcom,board-id <0 0>) - shipping a
# specific prototype-board DTB silent-kills early boot.
#
# We do not redistribute device blobs: every Duo owner has this file on
# their own device - back it up from TWRP first:
#   dd if=/dev/block/platform/soc/1d84000.ufshc/by-name/boot_b of=/sdcard/boot_b.img
#
# Usage: ./extract-stock-dtb.sh <stock-boot.img> [out.dtb]
# Requires: python3, fdtget (device-tree-compiler package)
set -euo pipefail

IMG="${1:?usage: $0 <stock-boot.img> [out.dtb]}"
OUT="${2:-dtb-stock.dtb}"
command -v fdtget >/dev/null || { echo "ERROR: install device-tree-compiler (fdtget)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$IMG" "$WORK" <<'EOF'
import struct, sys, os
img = open(sys.argv[1], 'rb').read()
work = sys.argv[2]
assert img[:8] == b'ANDROID!', "not an Android boot image"
(kernel_size, _, ramdisk_size, _, second_size, _,
 _, page_size, header_version, _) = struct.unpack_from('<10I', img, 8)
assert header_version == 2, f"expected header v2, got v{header_version}"
recovery_dtbo_size, = struct.unpack_from('<I', img, 1632)
dtb_size, = struct.unpack_from('<I', img, 1648)
assert dtb_size > 0, "image has no DTB section"
pages = lambda n: (n + page_size - 1) // page_size * page_size
o = page_size + pages(kernel_size) + pages(ramdisk_size) \
    + pages(second_size) + pages(recovery_dtbo_size)
blob = img[o:o + dtb_size]
i = n = 0
while i + 8 <= len(blob) and blob[i:i+4] == b'\xd0\x0d\xfe\xed':
    total = struct.unpack_from('>I', blob, i + 4)[0]
    open(os.path.join(work, f"{n:03d}.dtb"), 'wb').write(blob[i:i+total])
    n += 1
    i += total
print(f"split {n} DTBs from the section ({dtb_size} bytes)")
EOF

echo "index | model | qcom,board-id"
PICK=""
for f in "$WORK"/*.dtb; do
    model="$(fdtget -t s "$f" / model 2>/dev/null || echo '?')"
    bid="$(fdtget -t x "$f" / qcom,board-id 2>/dev/null || echo '?')"
    echo "$(basename "$f") | $model | $bid"
    # Duo 1 target: the generic wildcard for ITS SoC. The pile also holds
    # SA8155 (automotive) wildcards with the same <0 0> board-id - match
    # the model string exactly ("SM8150 v2 SoC", not SM8150P).
    case "$model" in
        *"SM8150 v2 SoC") [ "$bid" = "0 0" ] && [ -z "$PICK" ] && PICK="$f" ;;
    esac
done

[ -n "$PICK" ] || { echo "ERROR: no generic 'SM8150 v2 SoC' (board-id 0 0) DTB found - pick manually from the list"; exit 1; }
cp "$PICK" "$OUT"
echo "OK: $OUT <- $(basename "$PICK") ($(stat -c%s "$OUT") bytes, $(fdtget -t s "$OUT" / model))"
