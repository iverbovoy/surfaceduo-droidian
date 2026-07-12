#!/bin/bash
# Safety-gated wrapper around fastboot flash/boot - v2 (hardened).
#
# Lesson from Duo 1 brick (2026-02): three consecutive `fastboot boot <custom.img>`
# attempts with kernels that panicked in early boot left the device unable to
# RAM-boot any image - even properly signed TWRP - with `Device critical
# unlocked` stuck at false. boot/dtbo/vbmeta live on UFS LUN 4, which is
# read-only from fastboot, so software recovery became impossible.
# Full post-mortem: docs/SAFETY.md ("The three failure mechanisms")
#
# v2 rules (v1 rules kept, gaps closed):
#   1. RAM-boot first; flash-boot only after a confirmed RAM-boot OF THE SAME
#      IMAGE (sha256-bound) ON THE SAME DEVICE (serial-bound).
#   2. Max 2 consecutive unconfirmed RAM-boots PER DEVICE. The counter is
#      keyed by serial number - a gate tripped on one device no longer
#      blocks (or excuses) another.
#   3. Image is structurally validated BEFORE it ever reaches the device:
#      header v2, ARM64 kernel magic, embedded DTB with FDT magic, matching
#      androidboot.hardware. A malformed image rejected (or panicking) on
#      the device is exactly the brick vector.
#   4. Device health baseline: slot-retry-count / slot-unbootable /
#      critical-unlock state are captured on first contact and compared on
#      every subsequent run. Degradation = hard stop.
#   5. Battery gates: >=20% for ram-boot, >=30% for flash.
#   6. Backup is attempted (fastboot fetch, then oem dump), but on the Duo
#      boot_a lives on read-only LUN 4 and cannot be dumped from fastboot.
#      If no backup can be made and none exists on disk, flashing requires
#      typing an explicit acknowledgment. Take the real backup from a
#      running system beforehand (dd /dev/block/by-name/boot_a).
#   7. Known brick signatures in fastboot output trigger a red STOP banner:
#      "Failed to load/authenticate boot image", "Device Error",
#      "Flashing is not allowed for Critical Partitions".
#
# State lives in out/flash-state.json (schema v2, keyed by device serial).
#
# Usage:
#   ./tools/flash-safely.sh validate <boot.img>             # offline image validation only
#   ./tools/flash-safely.sh preflight <boot.img>            # validate image + device, boot nothing
#   ./tools/flash-safely.sh ram-boot <boot.img>             # fastboot boot (gated)
#   ./tools/flash-safely.sh ram-boot <boot.img> --confirmed # record success of THIS image on THIS device
#   ./tools/flash-safely.sh flash-boot <boot.img>           # fastboot flash boot_<slot> (heavily gated)
#   ./tools/flash-safely.sh baseline                        # capture device health baseline
#   ./tools/flash-safely.sh status                          # print state
#   ./tools/flash-safely.sh reset                           # per-device counter reset (asks for serial)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/out"
STATE_FILE="$OUT_DIR/flash-state.json"
BACKUP_DIR="$OUT_DIR/backups"
UNPACK_BOOTIMG="$SCRIPT_DIR/mkbootimg/unpack_bootimg.py"
MAX_CONSECUTIVE=2
MIN_BATTERY_RAMBOOT=20
MIN_BATTERY_FLASH=30

mkdir -p "$OUT_DIR" "$BACKUP_DIR"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}$*${NC}"; }
ok() { echo -e "${GREEN}$*${NC}"; }
info() { echo -e "${CYAN}$*${NC}"; }

stop_banner() {
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    while [ $# -gt 0 ]; do
        printf "${RED}║  %-52s║${NC}\n" "$1"; shift
    done
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
}

# ─── State (schema v2, keyed by serial) ────────────────────────────────
# py_state <op> [args...]  - tiny JSON state helper.
#   get <serial> <key> [default]
#   set <serial> <key> <value>      (value auto-typed: int/bool/null/str)
#   baseline-save <serial> <json>
#   baseline-get <serial>
py_state() {
    python3 - "$STATE_FILE" "$@" <<'PY'
import json, sys, os, time

path, op = sys.argv[1], sys.argv[2]
state = {"version": 2, "devices": {}}
if os.path.exists(path):
    try:
        loaded = json.load(open(path))
        if loaded.get("version") == 2:
            state = loaded
        # v1 file (flat) is intentionally NOT migrated: its counter came
        # from whatever device was used last and must not gate a new one.
    except Exception:
        pass

def dev(serial):
    return state["devices"].setdefault(serial, {
        "consecutive_unconfirmed": 0,
        "confirmed_sha256": None,
        "product": None,
        "baseline": None,
        "history": [],
    })

def save():
    json.dump(state, open(path, "w"), indent=1)

if op == "get":
    serial, key = sys.argv[3], sys.argv[4]
    default = sys.argv[5] if len(sys.argv) > 5 else ""
    v = dev(serial).get(key)
    print(default if v is None else v)
elif op == "set":
    serial, key, value = sys.argv[3], sys.argv[4], sys.argv[5]
    if value == "null": value = None
    elif value in ("true", "false"): value = value == "true"
    elif value.lstrip("-").isdigit(): value = int(value)
    dev(serial)[key] = value
    save()
elif op == "log":
    serial, entry = sys.argv[3], sys.argv[4]
    d = dev(serial)
    d["history"].append({"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "event": entry})
    d["history"] = d["history"][-50:]
    save()
elif op == "baseline-save":
    serial, blob = sys.argv[3], sys.argv[4]
    dev(serial)["baseline"] = json.loads(blob)
    save()
elif op == "baseline-get":
    serial = sys.argv[3]
    b = dev(serial).get("baseline")
    print(json.dumps(b) if b else "")
PY
}

sha256() { sha256sum "$1" | awk '{print $1}'; }

# ─── Device probing ────────────────────────────────────────────────────
# Fills PROBE_* globals from `fastboot getvar all` (+ oem device-info).
probe_device() {
    fastboot devices 2>/dev/null | grep -q . || die "no device in fastboot mode"

    local vars
    vars=$(timeout 20 fastboot getvar all 2>&1) || die "fastboot getvar all failed"

    _var() { echo "$vars" | grep -oE "\(bootloader\) $1:.*" | head -1 | sed "s/(bootloader) $1://" | tr -d ' \r'; }

    PROBE_SERIAL=$(_var "serialno")
    PROBE_PRODUCT=$(_var "product")
    PROBE_UNLOCKED=$(_var "unlocked")
    PROBE_SLOT=$(_var "current-slot")
    PROBE_BATTERY=$(_var "battery-level")
    PROBE_RETRY_A=$(_var "slot-retry-count:a")
    PROBE_RETRY_B=$(_var "slot-retry-count:b")
    PROBE_UNBOOTABLE_A=$(_var "slot-unbootable:a")
    PROBE_UNBOOTABLE_B=$(_var "slot-unbootable:b")

    # Critical-unlock state: appears as free-text on some bootloaders
    # ("Device critical unlocked: false"), possibly only via oem device-info.
    PROBE_CRITICAL="unknown"
    local crit
    crit=$(echo "$vars" | grep -i "critical unlocked" | head -1 || true)
    if [ -z "$crit" ]; then
        crit=$(timeout 15 fastboot oem device-info 2>&1 | grep -i "critical unlocked" | head -1 || true)
    fi
    case "$crit" in
        *rue*)  PROBE_CRITICAL="true" ;;
        *alse*) PROBE_CRITICAL="false" ;;
    esac

    [ -n "$PROBE_SERIAL" ] || die "could not read device serial"
    [ -n "$PROBE_PRODUCT" ] || die "could not read device product"
}

print_probe() {
    info "Device: $PROBE_PRODUCT  serial=$PROBE_SERIAL  slot=$PROBE_SLOT  battery=${PROBE_BATTERY}%"
    info "  unlocked=$PROBE_UNLOCKED  critical_unlocked=$PROBE_CRITICAL"
    info "  slot a: retry=$PROBE_RETRY_A unbootable=$PROBE_UNBOOTABLE_A | slot b: retry=$PROBE_RETRY_B unbootable=$PROBE_UNBOOTABLE_B"
}

# ─── Health baseline ───────────────────────────────────────────────────
capture_baseline() {
    local blob
    blob=$(printf '{"retry_a":"%s","retry_b":"%s","unbootable_a":"%s","unbootable_b":"%s","critical":"%s","product":"%s","captured":"%s"}' \
        "$PROBE_RETRY_A" "$PROBE_RETRY_B" "$PROBE_UNBOOTABLE_A" "$PROBE_UNBOOTABLE_B" \
        "$PROBE_CRITICAL" "$PROBE_PRODUCT" "$(date '+%Y-%m-%d %H:%M:%S')")
    py_state baseline-save "$PROBE_SERIAL" "$blob"
    ok "Baseline captured for $PROBE_SERIAL"
}

check_health() {
    local base
    base=$(py_state baseline-get "$PROBE_SERIAL")
    if [ -z "$base" ]; then
        warn "No health baseline for this device yet - capturing one now."
        capture_baseline
        return 0
    fi

    local verdict
    verdict=$(BASE="$base" RA="$PROBE_RETRY_A" RB="$PROBE_RETRY_B" UA="$PROBE_UNBOOTABLE_A" UB="$PROBE_UNBOOTABLE_B" CR="$PROBE_CRITICAL" python3 <<'PY'
import json, os
b = json.loads(os.environ["BASE"])
problems = []
def num(x):
    try: return int(x)
    except Exception: return None
for slot, cur_key, base_key in (("a", "RA", "retry_a"), ("b", "RB", "retry_b")):
    cur, base = num(os.environ[cur_key]), num(b.get(base_key, ""))
    if cur is not None and base is not None and cur < base:
        problems.append(f"slot-retry-count:{slot} dropped {base} -> {cur}")
for slot, key in (("a", "UA"), ("b", "UB")):
    if os.environ[key] == "yes":
        problems.append(f"slot {slot} marked unbootable")
if b.get("critical") == "true" and os.environ["CR"] == "false":
    problems.append("critical_unlocked flipped true -> false (BRICK SIGNATURE)")
print(";".join(problems))
PY
)
    if [ -n "$verdict" ]; then
        stop_banner "DEVICE HEALTH DEGRADED SINCE BASELINE" "" \
            "$(echo "$verdict" | tr ';' '\n' | head -1)" \
            "This matches the pre-brick pattern from the first" \
            "Duo 1. Do NOT boot or flash anything." \
            "Investigate before any further fastboot commands."
        echo "  details: $verdict"
        py_state log "$PROBE_SERIAL" "HEALTH-STOP: $verdict"
        exit 3
    fi
    ok "Health check vs baseline: OK"
}

# ─── Image validation ──────────────────────────────────────────────────
# validate_image <boot.img>
# Exports IMG_HARDWARE (androidboot.hardware value from cmdline).
validate_image() {
    local img="$1"
    [ -n "$img" ] && [ -f "$img" ] || die "image not found: $img"
    [ -f "$UNPACK_BOOTIMG" ] || die "unpack_bootimg.py not found at $UNPACK_BOOTIMG"

    info "Validating $img ..."
    IMG_HARDWARE=$(python3 - "$UNPACK_BOOTIMG" "$img" <<'PY'
import gzip, os, re, subprocess, sys, tempfile

unpack, img = sys.argv[1], sys.argv[2]
fail = lambda m: (print(f"FAIL: {m}", file=sys.stderr), sys.exit(1))

size = os.path.getsize(img)
if size < 4 * 1024 * 1024:
    fail(f"image is only {size} bytes - not a real boot.img")
if size > 100 * 1024 * 1024:
    fail(f"image is {size} bytes - larger than the boot partition")

with open(img, "rb") as f:
    if f.read(8) != b"ANDROID!":
        fail("missing ANDROID! boot magic")

tmp = tempfile.mkdtemp(prefix="bootval-")
try:
    out = subprocess.run(
        [sys.executable, unpack, "--boot_img", img, "--out", tmp],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        fail(f"unpack_bootimg failed: {out.stderr.strip()[:200]}")
    hdr = out.stdout

    def field(name):
        m = re.search(rf"^{re.escape(name)}: (.*)$", hdr, re.M)
        return m.group(1).strip() if m else ""

    hv = field("boot image header version")
    if hv != "2":
        fail(f"header version {hv}, expected 2 (Duo ABL requirement)")

    if int(field("kernel_size") or 0) == 0:
        fail("kernel payload is empty")
    if int(field("dtb size") or 0) == 0:
        fail("no DTB embedded - a header-v2 image without DTB will not boot on the Duo")

    osv = field("os version")
    if not osv or osv in ("0.0.0", "None"):
        fail("os version missing from header - strict ABLs reject this (see sunfish issue)")

    cmdline = field("command line args")
    m = re.search(r"androidboot\.hardware=(\S+)", cmdline)
    if not m:
        fail("cmdline lacks androidboot.hardware=")
    hardware = m.group(1)
    if hardware not in ("surfaceduo", "surfaceduo2"):
        fail(f"androidboot.hardware={hardware} is not a Duo target")

    # DTB must carry the FDT magic
    with open(os.path.join(tmp, "dtb"), "rb") as f:
        if f.read(4) != b"\xd0\x0d\xfe\xed":
            fail("embedded DTB has no FDT magic (0xd00dfeed)")

    # Kernel must be a real ARM64 Linux Image ("ARM\x64" at offset 56
    # of the decompressed image) - strict ABLs verify this before boot.
    kpath = os.path.join(tmp, "kernel")
    with open(kpath, "rb") as f:
        head = f.read(2)
    if head == b"\x1f\x8b":
        with gzip.open(kpath, "rb") as f:
            kern = f.read(64)
    else:
        with open(kpath, "rb") as f:
            kern = f.read(64)
    if len(kern) < 60 or kern[56:60] != b"ARM\x64":
        fail("kernel payload lacks ARM64 Linux Image magic at offset 56")

    print(hardware)  # stdout → IMG_HARDWARE
finally:
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
PY
    ) || exit 1
    ok "Image OK: header v2, ARM64 kernel, DTB present, hardware=$IMG_HARDWARE"
}

# device product ↔ image hardware must agree
check_target_match() {
    local expected
    case "$IMG_HARDWARE" in
        surfaceduo)  expected="surfaceduo" ;;
        surfaceduo2) expected="surfaceduo2" ;;
    esac
    if [ "$PROBE_PRODUCT" != "$expected" ]; then
        stop_banner "IMAGE/DEVICE MISMATCH" "" \
            "Image targets: $IMG_HARDWARE" \
            "Connected device: $PROBE_PRODUCT ($PROBE_SERIAL)" \
            "Refusing to touch this device."
        exit 1
    fi
}

check_unlocked() {
    if [ "$PROBE_UNLOCKED" != "yes" ]; then
        die "device is not unlocked (getvar unlocked=$PROBE_UNLOCKED)"
    fi
    if [ "$PROBE_CRITICAL" = "false" ]; then
        warn "NOTE: 'Device critical unlocked' reads FALSE."
        warn "On the bricked Duo 1 this state (while 'unlock_critical' answered"
        warn "'already unlocked') was the brick fingerprint. On a healthy device"
        warn "it may be normal - but if unlock_critical claims success and this"
        warn "stays false, STOP immediately."
    fi
}

check_battery() {
    local min="$1"
    if [ -n "$PROBE_BATTERY" ] && [ "$PROBE_BATTERY" -lt "$min" ] 2>/dev/null; then
        die "battery ${PROBE_BATTERY}% < ${min}% - charge first (a mid-flash power loss on LUN 4 is unrecoverable)"
    fi
}

# run a fastboot command, mirror output, and scan for brick signatures
run_fastboot_watched() {
    local outfile
    outfile=$(mktemp)
    set +e
    fastboot "$@" 2>&1 | tee "$outfile"
    local rc=${PIPESTATUS[0]}
    set -e
    if grep -qiE "Failed to load/authenticate boot image|Device Error|not allowed for Critical Partitions|Load Error" "$outfile"; then
        stop_banner "BRICK-SIGNATURE OUTPUT DETECTED" "" \
            "The bootloader answered with a known pre-brick" \
            "error. DO NOT RETRY. Do not cycle lock/unlock." \
            "Record the exact output and investigate offline." \
            "See docs/SAFETY.md"
        py_state log "$PROBE_SERIAL" "BRICK-SIGNATURE during: fastboot $*"
        rm -f "$outfile"
        exit 4
    fi
    rm -f "$outfile"
    return $rc
}

# ─── Commands ──────────────────────────────────────────────────────────

cmd_validate() {
    # Image-only checks - no device required.
    validate_image "$1"
    info "(device checks skipped - run 'preflight' with the phone connected)"
}

cmd_preflight() {
    local img="$1"
    validate_image "$img"
    probe_device
    print_probe
    check_target_match
    check_unlocked
    check_health
    check_battery "$MIN_BATTERY_RAMBOOT"
    local count
    count=$(py_state get "$PROBE_SERIAL" consecutive_unconfirmed 0)
    info "Unconfirmed RAM-boot counter for this device: $count/$MAX_CONSECUTIVE"
    ok "Preflight PASSED - ram-boot is permitted."
}

cmd_ram_boot() {
    local img="$1"
    local confirmed_flag="${2:-}"

    validate_image "$img"
    probe_device
    print_probe
    check_target_match

    local sha
    sha=$(sha256 "$img")

    if [ "$confirmed_flag" = "--confirmed" ]; then
        local last
        last=$(py_state get "$PROBE_SERIAL" last_image_sha256 "")
        if [ "$last" != "$sha" ]; then
            die "confirmation refused: this image (sha $sha) is not the one last RAM-booted on $PROBE_SERIAL"
        fi
        py_state set "$PROBE_SERIAL" consecutive_unconfirmed 0
        py_state set "$PROBE_SERIAL" confirmed_sha256 "$sha"
        py_state log "$PROBE_SERIAL" "CONFIRMED ram-boot of $sha"
        # A successful boot to userspace is also the freshest possible baseline.
        capture_baseline
        ok "RAM-boot confirmed for this image on this device. flash-boot is now permitted."
        exit 0
    fi

    check_unlocked
    check_health
    check_battery "$MIN_BATTERY_RAMBOOT"

    local count
    count=$(py_state get "$PROBE_SERIAL" consecutive_unconfirmed 0)
    if [ "$count" -ge "$MAX_CONSECUTIVE" ]; then
        stop_banner "SAFETY GATE TRIPPED ($count unconfirmed RAM-boots)" "" \
            "On the first Duo 1 a third consecutive boot of a" \
            "panicking kernel preceded the brick." "" \
            "Before trying again:" \
            "  1. read the serial console (earlycon=qcom_geni)" \
            "  2. re-check kernel config + DTB" \
            "  3. re-run preflight" "" \
            "Deliberate override: ./tools/flash-safely.sh reset"
        exit 2
    fi

    count=$((count + 1))
    py_state set "$PROBE_SERIAL" consecutive_unconfirmed "$count"
    py_state set "$PROBE_SERIAL" confirmed_sha256 null
    py_state set "$PROBE_SERIAL" last_image_sha256 "$sha"
    py_state set "$PROBE_SERIAL" product "$PROBE_PRODUCT"
    py_state log "$PROBE_SERIAL" "ram-boot attempt $count/$MAX_CONSECUTIVE sha=$sha"

    info "Attempt $count/$MAX_CONSECUTIVE: fastboot boot $img"
    warn "If the device reaches userspace, confirm with:"
    warn "  $0 ram-boot $img --confirmed"
    warn "If it panics or bounces back to the bootloader: STOP. Do not re-run."
    echo ""
    run_fastboot_watched boot "$img"
}

cmd_flash_boot() {
    local img="$1"
    local nobackup_flag="${2:-}"

    validate_image "$img"
    probe_device
    print_probe
    check_target_match
    check_unlocked
    check_health
    check_battery "$MIN_BATTERY_FLASH"

    local sha confirmed
    sha=$(sha256 "$img")
    confirmed=$(py_state get "$PROBE_SERIAL" confirmed_sha256 "")

    if [ "$confirmed" != "$sha" ]; then
        stop_banner "FLASH BLOCKED" "" \
            "No confirmed RAM-boot of THIS image on THIS device." \
            "(different image, different device, or none at all)" "" \
            "Required sequence:" \
            "  1. preflight <img>" \
            "  2. ram-boot <img>  → device reaches userspace" \
            "  3. ram-boot <img> --confirmed" \
            "  4. flash-boot <img>"
        exit 2
    fi

    # Backup: fetch (modern), then oem dump. On the Duo boot_a is on
    # read-only LUN 4 and both will likely fail - that is exactly why the
    # real backup must be taken from a running system beforehand.
    local ts backup slot have_backup=""
    ts=$(date +%Y%m%d-%H%M%S)
    slot="${PROBE_SLOT:-a}"
    backup="$BACKUP_DIR/boot-${PROBE_PRODUCT}-${PROBE_SERIAL}-${ts}.img"
    info "Attempting boot_${slot} backup → $backup"
    if fastboot fetch "boot_${slot}" "$backup" >/dev/null 2>&1 && [ -s "$backup" ]; then
        have_backup="$backup"
    elif fastboot oem dump "boot_${slot}" "$backup" >/dev/null 2>&1 && [ -s "$backup" ]; then
        have_backup="$backup"
    else
        rm -f "$backup"
    fi

    if [ -n "$have_backup" ]; then
        ok "Backup saved: $have_backup"
    else
        local existing
        existing=$(ls -1 "$BACKUP_DIR"/boot-"${PROBE_PRODUCT}"-"${PROBE_SERIAL}"-*.img 2>/dev/null | tail -1 || true)
        if [ -n "$existing" ]; then
            warn "fastboot cannot dump boot_${slot} (expected on the Duo - LUN 4)."
            warn "Using earlier on-disk backup as rollback reference: $existing"
        elif [ "$nobackup_flag" = "--i-understand-no-backup" ]; then
            warn "Proceeding WITHOUT any boot backup (explicit override)."
        else
            stop_banner "NO BOOT BACKUP AVAILABLE" "" \
                "fastboot cannot read boot_${slot} on the Duo (LUN 4)," \
                "and no earlier backup exists in out/backups/." "" \
                "Take one from the RAM-booted running system first:" \
                "  dd if=/dev/block/by-name/boot_${slot} of=/tmp/boot.img" \
                "  (then scp it into out/backups/)" "" \
                "To flash anyway: flash-boot <img> --i-understand-no-backup"
            exit 2
        fi
    fi

    info "Flashing: fastboot flash boot_${slot} $img"
    run_fastboot_watched flash "boot_${slot}" "$img"

    py_state set "$PROBE_SERIAL" confirmed_sha256 null
    py_state set "$PROBE_SERIAL" consecutive_unconfirmed 0
    py_state log "$PROBE_SERIAL" "FLASHED boot_${slot} sha=$sha"
    ok "Flash done. Confirmation cleared - the next image needs its own confirmed RAM-boot."
}

cmd_baseline() {
    probe_device
    print_probe
    capture_baseline
}

cmd_status() {
    info "Flash safety state ($STATE_FILE)"
    if [ -f "$STATE_FILE" ]; then
        python3 -m json.tool "$STATE_FILE" 2>/dev/null || cat "$STATE_FILE"
    else
        echo "(no state yet)"
    fi
    echo ""
    echo "Max consecutive unconfirmed RAM-boots per device: $MAX_CONSECUTIVE"
}

cmd_reset() {
    # Deliberate, per-device: you must type the serial you are resetting.
    probe_device 2>/dev/null || true
    if [ -n "${PROBE_SERIAL:-}" ]; then
        echo "Connected device serial: $PROBE_SERIAL"
    fi
    echo -n "Type the serial number of the device whose counter you want to reset: "
    read -r serial
    [ -n "$serial" ] || die "no serial entered"
    py_state set "$serial" consecutive_unconfirmed 0
    py_state set "$serial" confirmed_sha256 null
    py_state log "$serial" "manual reset"
    ok "Counter reset for $serial (baseline and history preserved)."
}

case "${1:-}" in
    validate)     shift; cmd_validate "$@" ;;
    preflight)    shift; cmd_preflight "$@" ;;
    ram-boot)     shift; cmd_ram_boot "$@" ;;
    flash-boot)   shift; cmd_flash_boot "$@" ;;
    baseline)     cmd_baseline ;;
    status)       cmd_status ;;
    reset)        cmd_reset ;;
    *)
        echo "Usage: $0 {validate <img> | preflight <img> | ram-boot <img> [--confirmed] | flash-boot <img> [--i-understand-no-backup] | baseline | status | reset}"
        exit 1
        ;;
esac
