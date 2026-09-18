#!/bin/bash
# Build adaptation-droidian-surfaceduo_<ver>_arm64.deb into out/.
# Folds the hand-injected USB access files (../access) into a real package so
# they persist across rootfs updates; postinst migrates away the hand-injected
# copies. Touch/wifi/sensor adaptation lands here as it gets figured out.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ACCESS="$HERE/../access"
SYSTEM="$HERE/../system"
SHELLDIR="$HERE/../shell"
BUSYBOX="$ROOT/out/busybox-arm64"
VER="${1:-0.13.1}"
OUT="$ROOT/out"
PKG="$OUT/pkgroot"

mkdir -p "$OUT"
[ -f "$BUSYBOX" ] || { echo "ERROR: $BUSYBOX missing - static arm64 busybox (extract /bin/busybox from Debian's busybox-static arm64 deb)"; exit 1; }

rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/usr/local/sbin" "$PKG/usr/local/bin" \
         "$PKG/usr/lib/systemd/system" \
         "$PKG/etc/NetworkManager/conf.d" \
         "$PKG/etc/udev/rules.d"

# Touch (2026-07-11): surface_touchscreen is a uinput device created by
# the android touchpen HAL (it reads hidraw0 from our spi-hid driver).
# It advertises pen bits too, so udev classifies it ID_INPUT_TABLET and
# phosh/libinput ignore it - force the touchscreen class.
cat > "$PKG/etc/udev/rules.d/99-sfduo-touch.rules" <<'RULES'
SUBSYSTEM=="input", ATTRS{name}=="surface_touchscreen", ENV{ID_INPUT_TOUCHSCREEN}="1", ENV{ID_INPUT_TABLET}=""
RULES

install -m755 "$ACCESS/sfduo-usb-gadget.sh" "$PKG/usr/local/sbin/"
install -m755 "$BUSYBOX"                     "$PKG/usr/local/bin/busybox"
install -m644 "$ACCESS/sfduo-usb.service"   "$PKG/usr/lib/systemd/system/"
install -m644 "$ACCESS/99-sfduo-usb.conf"   "$PKG/etc/NetworkManager/conf.d/"

# WiFi (2026-07-11): wlan.ko = qcacld-3.0 built from Microsoft's OSS
# wlan repos (branch surfaceduo/11/2022.902.48) against OUR kernel tree
# (vendor's own prebuilt .ko fails module_layout CRC - halium fragments
# shift the ABI). Kernel must have MODULE_SIG_FORCE=n (v5+). Loaded by
# sfduo-wlan.service; NetworkManager picks wlan0 up as a normal wifi
# device. Rebuild recipe: kernel-packaging/README.md.
#
# Modules are per kernel release (2026-09): out/modules/<uname -r>/wlan.ko and
# out/modules/<uname -r>/audio/*_dlkm.ko, installed under
# /usr/lib/sfduo/modules/<uname -r>/. The 4.14-190 builds and the 4.14-190-perf
# ones (kernel-packaging/droidian/surfaceduo-perf.config) do not share a
# module ABI - CONFIG_MODVERSIONS refuses the other kernel's modules - and a
# device RAM-booting one kernel while the other is flashed needs both sets:
# without its audio modules a kernel never boots the ADSP, and the system
# freezes a few minutes in. The units below pick the set for the running
# kernel, and say so when there is none.
MODSETS="$ROOT/out/modules"
HAVE_WLAN=0; HAVE_AUDIO=0
for set in "$MODSETS"/*/; do
    [ -d "$set" ] || continue
    rel=$(basename "$set")
    if [ -f "$set/wlan.ko" ]; then
        install -Dm644 "$set/wlan.ko" "$PKG/usr/lib/sfduo/modules/$rel/wlan.ko"
        HAVE_WLAN=1
    else
        echo "NOTE: no wlan.ko for $rel - that kernel gets no wifi"
    fi
    if [ -n "$(find "$set/audio" -name '*.ko' 2>/dev/null | head -1)" ]; then
        mkdir -p "$PKG/usr/lib/sfduo/modules/$rel/audio"
        find "$set/audio" -name '*.ko' -exec install -m644 {} "$PKG/usr/lib/sfduo/modules/$rel/audio/" \;
        HAVE_AUDIO=1
    else
        echo "NOTE: no audio modules for $rel - that kernel cannot boot the ADSP"
    fi
    echo "modules for $rel: wlan=$([ -f "$set/wlan.ko" ] && echo yes || echo no) audio=$(find "$set/audio" -name '*.ko' 2>/dev/null | wc -l)"
done
if [ "$HAVE_WLAN" = 1 ]; then
    cat > "$PKG/usr/lib/systemd/system/sfduo-wlan.service" <<'UNIT'
[Unit]
Description=sfduo: load the qcacld-3.0 wlan module
ConditionDirectoryNotEmpty=/usr/lib/sfduo/modules
Before=NetworkManager.service

[Service]
Type=oneshot
# The module for the running kernel; another kernel's would be refused anyway
ExecStart=/bin/sh -c 'M=/usr/lib/sfduo/modules/$(uname -r)/wlan.ko; [ -f "$M" ] || { echo "sfduo-wlan: no wlan module for $(uname -r) in /usr/lib/sfduo/modules" >&2; exit 0; }; grep -q ^wlan /proc/modules || insmod "$M"'
# WoWLAN keeps the association alive through deep sleep, so WiFi (and ssh
# over it) come back instantly after a deliberate wake (wakeonlan <mac>).
# magic-packet, NOT any: "any" means every LAN broadcast wakes the phone
# (measured: 26 s of sleep on a home network). WARNING: never reconfigure
# wowlan on a live driver - a runtime enable-mode switch soft-locked a
# qcacld thread and took all block I/O down with it (2026-07-12).
# qcacld registers phy0 asynchronously (fw load can take 60s+) - wide retry
ExecStartPost=/bin/sh -c 'for i in $(seq 1 45); do iw phy phy0 wowlan enable magic-packet 2>/dev/null && break; sleep 2; done; true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
else
    echo "NOTE: no wlan.ko in $MODSETS/*/ - building without wifi module"
fi

# Audio (2026-07-11): 23 techpack modules built from MS's audio-kernel OSS
# repo in-tree (see kernel-packaging README). They only produce a sound
# card if the ADSP is booted BEFORE apr_dlkm loads and enumerates its DT
# children. On stock, adsprpcd boots/holds the ADSP - we kill those (see
# tame-vendor), so boot it ourselves via adsp_loader's sysfs, then load
# the chain in vendor order. Codec on Duo 1 answers as TAVIL (wcd934x,
# chip id 0x108) - the pahu DT node stays silent, ignore its -6 probe.
if [ "$HAVE_AUDIO" = 1 ]; then
    cat > "$PKG/usr/local/sbin/sfduo-audio-up.sh" <<'AUDIO'
#!/bin/sh
# Boot the ADSP, then load the audio techpack chain in vendor order.
KVER=$(uname -r)
SET=/usr/lib/sfduo/modules/$KVER/audio
[ -n "$(ls $SET/*.ko 2>/dev/null)" ] || {
    echo "sfduo-audio: no audio modules for kernel $KVER in /usr/lib/sfduo/modules - the ADSP cannot be booted" >&2
    exit 1
}
mkdir -p /lib/modules/$KVER
cp -un $SET/*.ko /lib/modules/$KVER/ 2>/dev/null
depmod -a 2>/dev/null
[ -e /sys/kernel/boot_adsp/boot ] || modprobe adsp_loader_dlkm 2>/dev/null
echo 1 > /sys/kernel/boot_adsp/boot 2>/dev/null
# wait for the adsp subsystem to report ONLINE (<=15s)
i=0
while [ $i -lt 15 ]; do
    grep -q ONLINE /sys/bus/msm_subsys/devices/subsys1/state 2>/dev/null && break
    i=$((i+1)); sleep 1
done
# HARD GATE: loading the audio chain (and letting bluebinder start)
# against a dead ADSP soft-locks the kernel - fail loudly instead.
grep -q ONLINE /sys/bus/msm_subsys/devices/subsys1/state 2>/dev/null || {
    echo "sfduo-audio: ADSP did not come ONLINE - refusing to load audio chain" >&2
    exit 1
}
for m in wglink_dlkm q6_pdr_dlkm q6_notifier_dlkm apr_dlkm q6_dlkm \
         native_dlkm pinctrl_wcd_dlkm swr_dlkm swr_ctrl_dlkm platform_dlkm \
         hdmi_dlkm wcd_spi_dlkm stub_dlkm wcd_core_dlkm wcd9xxx_dlkm \
         mbhc_dlkm wsa881x_dlkm wcd934x_dlkm machine_dlkm; do
    modprobe $m 2>/dev/null
done
# Verify the chain actually landed. A half-dead audio/ADSP state is
# exactly when a bluetooth init soft-locks the kernel; bluebinder has
# its own ADSP gate (sfduo-adsp-gate) for that, so silence is the safe
# mode on both sides.
for m in apr_dlkm q6_dlkm wcd934x_dlkm machine_dlkm; do
    grep -q "^$m " /proc/modules || {
        echo "sfduo-audio: critical module $m failed to load" >&2
        exit 1
    }
done
i=0
while [ $i -lt 10 ]; do
    grep -q sm8150 /proc/asound/cards 2>/dev/null && exit 0
    i=$((i+1)); sleep 1
done
echo "sfduo-audio: sound card did not register" >&2
exit 1
AUDIO
    chmod 755 "$PKG/usr/local/sbin/sfduo-audio-up.sh"
    cat > "$PKG/usr/lib/systemd/system/sfduo-audio.service" <<'UNIT'
[Unit]
Description=sfduo: boot ADSP and load the audio techpack modules
After=lxc@android.service sfduo-tame-vendor.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sfduo-audio-up.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
else
    cat >&2 <<'NOAUDIO'
ERROR: no audio modules found in out/modules/<kernel release>/audio/.

They are not optional, and this costs far more than sound.
sfduo-audio.service is the only thing that boots the ADSP (via
adsp_loader sysfs). Measured on hardware without it: the ADSP never
leaves OFFLINING, and the two adsprpcd daemons burn ~24% CPU each
forever because of it (with a live ADSP they sit at 0%). Bluetooth
against a dead ADSP then soft-locks the kernel and takes all I/O with
it, which looks exactly like a dead phone.

Build them per kernel-packaging/README.md, then build this package.

If you understand all of the above and want the package anyway, set
SFDUO_ALLOW_NO_AUDIO=1. Bluetooth will refuse to start on the result.
NOAUDIO
    [ "${SFDUO_ALLOW_NO_AUDIO:-0}" = "1" ] || exit 1
fi

# The ADSP gate, shipped ALWAYS and deliberately not tied to the audio
# build. bluebinder against a dead ADSP soft-locks the kernel
# (queued_write_lock_slowpath) and takes all I/O down. The old drop-in
# gated on Requires=sfduo-audio.service, so a package built without the
# audio modules carried no protection at all - exactly the build that
# needs it most. Gate on the real precondition instead: the ADSP being
# ONLINE.
install -m755 /dev/stdin "$PKG/usr/local/sbin/sfduo-adsp-gate" <<'GATE'
#!/bin/sh
# Exit 0 once the ADSP subsystem reports ONLINE, non-zero if it never
# does. Used as ExecStartPre for bluebinder: better no bluetooth than a
# soft-locked kernel.
find_adsp() {
    for d in /sys/bus/msm_subsys/devices/*/; do
        [ "$(cat "$d/name" 2>/dev/null)" = "adsp" ] && { echo "${d%/}/state"; return; }
    done
    echo /sys/bus/msm_subsys/devices/subsys1/state   # historical fallback
}
STATE="$(find_adsp)"
i=0
while [ $i -lt 30 ]; do
    grep -q ONLINE "$STATE" 2>/dev/null && exit 0
    i=$((i+1)); sleep 1
done
echo "sfduo: ADSP is not ONLINE ($STATE) - refusing to start bluetooth," >&2
echo "sfduo: it soft-locks the kernel in this state. Fix the ADSP first." >&2
exit 1
GATE
mkdir -p "$PKG/etc/systemd/system/bluebinder.service.d"
# ExecCondition=, not ExecStartPre=: a failing condition makes systemd
# SKIP the unit rather than fail it, so bluebinder's Restart=always does
# not turn the refusal into an endless retry loop (measured on device:
# 6 restarts in 4 minutes with ExecStartPre, 0 with ExecCondition).
printf '[Unit]\nAfter=sfduo-audio.service\n\n[Service]\nExecCondition=/usr/local/sbin/sfduo-adsp-gate\n' \
    > "$PKG/etc/systemd/system/bluebinder.service.d/20-sfduo-after-adsp.conf"

# Suspend hook (2026-07-11 night): dwc3-msm in peripheral mode never
# reaches LPM by itself and aborts every system suspend (see kernel patch
# in dwc3_msm_pm_suspend, v6+). Belt-and-suspenders: park the controller
# around sleep so the forced path has the easiest job, and restore the
# gadget afterwards. Requires v6 kernel for the forced-suspend fallback.
# droidian ships AllowSuspend=no (10-droidian-sleep.conf) - the verb is
# refused before the kernel is even asked. Our 99- wins the sort order.
# board-address: the Duo has no bdaddr property, so bluebinder_post.sh needs
# the file. Derived from the wifi MAC + 1, whenever wlan0 first exists.
cat > "$PKG/usr/local/sbin/sfduo-bt-address" <<'BTADDR'
#!/bin/sh
# Write /var/lib/bluetooth/board-address once, from wlan0's MAC + 1.
F=/var/lib/bluetooth/board-address
[ -s "$F" ] && exit 0
WMAC=$(cat /sys/class/net/wlan0/address 2>/dev/null) || exit 0
[ -n "$WMAC" ] || exit 0
head=$(echo "${WMAC%:*}" | tr a-f A-F)
last=$(printf '%02X' $(( (0x${WMAC##*:} + 1) & 0xff )))
mkdir -p /var/lib/bluetooth
printf '%s:%s\n' "$head" "$last" > "$F"
chmod 644 "$F"
BTADDR
chmod 755 "$PKG/usr/local/sbin/sfduo-bt-address"
printf '[Service]\nExecStartPre=-/usr/local/sbin/sfduo-bt-address\n' \
    > "$PKG/etc/systemd/system/bluebinder.service.d/15-sfduo-bt-address.conf"
# bluebinder: chip re-init takes ~65s after a stop; stock unit allows 60
mkdir -p "$PKG/etc/systemd/system/bluebinder.service.d"
printf '[Service]\nTimeoutStartSec=180\n' > "$PKG/etc/systemd/system/bluebinder.service.d/10-sfduo-timeout.conf"

# GPS (2026-07-12): the vendor GNSS stack works out of the box and the
# droidian geoclue hybris source delivers ~4m fixes (TTFF ~100s cold, no
# xtra assistance - container has no DNS). geoclue idle-exits after 60s,
# so every fix pays DBus-activation startup again; keep it resident.
# (The 40s sandbox stall that once made activation time out entirely is
# fixed at the root by kernel patch 0004 - see docs/FREEZE-FORENSICS.md.)
mkdir -p "$PKG/etc/systemd/system/geoclue.service.d"
cat > "$PKG/etc/systemd/system/geoclue.service.d/99-sfduo-keepalive.conf" <<'GCLUE'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-success
RestartSec=2
# (with kernel patch 0004 the old 40s mount-ns sandbox stall is gone -
# a resident geoclue is now just a GPS-latency nicety, not a bug fix)

[Install]
WantedBy=multi-user.target
GCLUE

mkdir -p "$PKG/etc/systemd/sleep.conf.d"
# SuspendState=mem ONLY: systemd's default list (mem standby freeze) falls
# back to s2idle when deep suspend returns EBUSY (e.g. a wakeup arriving
# mid-entry) - and s2idle races UFS runtime PM on this platform: the host
# controller never resumes ("parent (1d84000.ufshc) is not active") and
# every write to sda6 hangs forever. A failed suspend beats a dead disk.
printf '[Sleep]\nAllowSuspend=yes\nSuspendState=mem\n' > "$PKG/etc/systemd/sleep.conf.d/99-sfduo.conf"

mkdir -p "$PKG/usr/lib/systemd/system-sleep"
cat > "$PKG/usr/lib/systemd/system-sleep/sfduo-usb" <<'SLEEP'
#!/bin/sh
SSUSB=/sys/bus/platform/devices/a600000.ssusb
G=/sys/kernel/config/usb_gadget/sfduo
case "$1" in
    pre)
        cat $G/UDC 2>/dev/null > /run/sfduo-udc-saved
        echo "" > $G/UDC 2>/dev/null
        echo none > $SSUSB/mode 2>/dev/null
        ;;
    post)
        echo peripheral > $SSUSB/mode 2>/dev/null
        sleep 1
        UDC=$(cat /run/sfduo-udc-saved 2>/dev/null)
        [ -n "$UDC" ] && echo "$UDC" > $G/UDC 2>/dev/null
        ;;
esac
exit 0
SLEEP
chmod 755 "$PKG/usr/lib/systemd/system-sleep/sfduo-usb"

# Panels re-init at resume and can reset their DCS brightness register
# to hardware default (max) while gsd-power still holds the user value -
# screen at full blast, indicator unchanged. Nudge gsd after resume:
# re-setting its Brightness property to its own value makes it rewrite
# both panel backlights.
cat > "$PKG/usr/lib/systemd/system-sleep/sfduo-brightness" <<'SLEEP'
#!/bin/sh
[ "$1" = "post" ] || exit 0
(
  ENV="XDG_RUNTIME_DIR=/run/user/32011 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus"
  for i in 1 2 3 4 5; do
    B=$(sudo -u droidian env $ENV busctl --user get-property \
        org.gnome.SettingsDaemon.Power /org/gnome/SettingsDaemon/Power \
        org.gnome.SettingsDaemon.Power.Screen Brightness 2>/dev/null | awk '{print $2}')
    [ -n "$B" ] && { sudo -u droidian env $ENV busctl --user set-property \
        org.gnome.SettingsDaemon.Power /org/gnome/SettingsDaemon/Power \
        org.gnome.SettingsDaemon.Power.Screen Brightness i "$B" && break; }
    sleep 2
  done
) &
exit 0
SLEEP
chmod 755 "$PKG/usr/lib/systemd/system-sleep/sfduo-brightness"

# The keypress/finger-touch that wakes the SoC is consumed during resume
# and never reaches the compositor - phosh stays blanked and a short
# power press "looks dead". Inject KEY_WAKEUP after every resume so the
# lockscreen lights up regardless of what woke us.
cat > "$PKG/usr/lib/systemd/system-sleep/sfduo-unblank" <<'SLEEP'
#!/bin/sh
[ "$1" = "post" ] || exit 0
python3 - <<PY &
from evdev import UInput, ecodes as e
ui = UInput({e.EV_KEY: [e.KEY_WAKEUP]}, name="sfduo-wake-nudge")
ui.write(e.EV_KEY, e.KEY_WAKEUP, 1); ui.syn()
ui.write(e.EV_KEY, e.KEY_WAKEUP, 0); ui.syn()
ui.close()
PY
exit 0
SLEEP
chmod 755 "$PKG/usr/lib/systemd/system-sleep/sfduo-unblank"

# Wake-from-suspend sources (2026-07-12): short power press and the
# fingerprint sensor. qpnp_pon input wakeup is default-disabled (only
# the PMIC hardware long-press worked); fpc1020 arms enable_irq_wake at
# probe unconditionally, its wakeup_enable knob just arms the ISR ttw
# wakelock so the finger event survives the resume race. NOTE: a finger
# resting on the sensor during suspend entry aborts it (wakeup pending,
# EBUSY) - working as designed.
cat > "$PKG/usr/local/sbin/sfduo-wakeup-sources.sh" <<'WAKE'
#!/bin/sh
# Devices appear asynchronously during boot - retry until both armed.
i=0
while [ $i -lt 30 ]; do
    for d in /sys/class/input/input*/; do
        [ "$(cat $d/name 2>/dev/null)" = "qpnp_pon" ] && echo enabled > $d/device/power/wakeup 2>/dev/null
    done
    echo enable  > /sys/bus/platform/devices/soc:fpc1020/wakeup_enable 2>/dev/null
    echo enabled > /sys/bus/platform/devices/soc:fpc1020/power/wakeup  2>/dev/null
    pon=$(grep -l qpnp_pon /sys/class/input/input*/name 2>/dev/null | head -1)
    fpc=/sys/bus/platform/devices/soc:fpc1020/power/wakeup
    [ -n "$pon" ] && [ "$(cat ${pon%name}device/power/wakeup 2>/dev/null)" = enabled ] \
        && [ "$(cat $fpc 2>/dev/null)" = enabled ] && exit 0
    i=$((i+1)); sleep 2
done
echo "sfduo-wakeup: some wake sources not armed after 60s" >&2
exit 1
WAKE
chmod 755 "$PKG/usr/local/sbin/sfduo-wakeup-sources.sh"
cat > "$PKG/usr/lib/systemd/system/sfduo-wakeup.service" <<'UNIT'
[Unit]
Description=sfduo: arm power-key and fingerprint wake-from-suspend sources

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sfduo-wakeup-sources.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Android vendor init sets 10-minute laptop-mode writeback
# (vm.dirty_writeback_centisecs=60000) and KEEPS re-setting it at runtime
# (power HAL, charge events). Dirty pages then pile up for 10 minutes and
# hit the loop-backed rootfs as one giant burst - the exact load pattern
# behind the I/O stalls docs/FREEZE-FORENSICS.md describes. /etc/sysctl.d
# alone loses the race (it runs before lxc@android), so a timer re-asserts.
mkdir -p "$PKG/etc/sysctl.d"
cat > "$PKG/etc/sysctl.d/99-sfduo-writeback.conf" <<'SYSCTL'
vm.laptop_mode = 0
vm.dirty_writeback_centisecs = 500
vm.dirty_expire_centisecs = 3000
SYSCTL
cat > "$PKG/usr/lib/systemd/system/sfduo-writeback.service" <<'UNIT'
[Unit]
Description=sfduo: keep sane writeback sysctls (android init sets 10-minute laptop-mode values)

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w vm.laptop_mode=0 vm.dirty_writeback_centisecs=500 vm.dirty_expire_centisecs=3000
UNIT
cat > "$PKG/usr/lib/systemd/system/sfduo-writeback.timer" <<'UNIT'
[Unit]
Description=sfduo: re-assert writeback sysctls (android side rewrites them at runtime)

[Timer]
OnBootSec=90
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

# Hinge (posture) sensor: our patched sensorfw adds hybrishingeadaptor +
# hingesensor (android.sensor.hinge_angle, type 36, degrees 0..360, via
# the MS sns_fold sensor on the SLPI). Map the adaptor here; the patched
# sensorfw debs must be installed (see sensorfw-hinge-patch/).
mkdir -p "$PKG/etc/sensorfw"
cat > "$PKG/etc/sensorfw/70-sfduo-surfaceduo.conf" <<'SFW'
[plugins]
hingeadaptor = hybrishingeadaptor
SFW
# NOTE: sensorfwd runs with -c=/etc/sensorfw/sensord-hybris.conf and reads
# ONLY that file (no conf.d!) - the 70- file above is documentation-ware;
# the postinst appends the mapping to the real config (verified working:
# live hinge degrees over DBus 2026-07-11).

# Tame vendor daemons that hurt the system (findings 2026-07-11):
# adsprpcd x2 spin at 33% CPU each on a fastrpc ioctl (0xc00c5211) our
# 4.14 kernel does not implement, flooding dmesg ~40 msg/s. ctl.stop is
# ignored; killing them works and they stay down. aDSP compute offload
# is not used by our stack.
cat > "$PKG/usr/local/sbin/sfduo-tame-vendor.sh" <<'TAME'
#!/bin/sh
# wait for the android container services to come up, then kill spinners
sleep 25
for i in 1 2 3; do
    pkill -9 -x adsprpcd 2>/dev/null
    sleep 5
done
exit 0
TAME
chmod 755 "$PKG/usr/local/sbin/sfduo-tame-vendor.sh"

cat > "$PKG/usr/lib/systemd/system/sfduo-tame-vendor.service" <<'UNIT'
[Unit]
Description=sfduo: kill vendor daemons that spin on unsupported fastrpc ioctls
After=lxc@android.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sfduo-tame-vendor.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# DRM-master watchdog. Failure mode (hit on two consecutive boots,
# 2026-07-14): an early client takes DRM master on /dev/dri/card0 and
# exits; the vendor composer, which opened the device meanwhile, is left
# non-master forever. Every atomic commit then fails with EACCES
# ("DRMAtomicReq::Validate ... Permission denied" in logcat), phoc spams
# "validate failed for display 0: 2", both panels stay black with the
# backlight on, and the power key appears dead. A fresh composer
# instance acquires master cleanly, so the cure is to kill it (android
# init respawns it) and restart phosh. ctl.restart via setprop does NOT
# restart it - kill is required (verified on device).
cat > "$PKG/usr/local/sbin/sfduo-composer-watchdog" <<'WDOG'
#!/bin/sh
# Check that the vendor hwcomposer ended up as DRM master; bounce it if not.
CLIENTS=/sys/kernel/debug/dri/0/clients

composer_pid() { pgrep -f 'composer@2\.4-service' | head -n1; }
# clients columns: command pid dev master a uid magic ("composer@2.4-se ... y ...")
master_ok() {
    awk '$1 ~ /composer/ && $4 == "y" {found=1} END {exit !found}' "$CLIENTS" 2>/dev/null
}

[ -r "$CLIENTS" ] || { echo "no $CLIENTS (debugfs?) - cannot judge, skipping"; exit 0; }

# wait for the container to bring the composer up at all
i=0; while [ $i -lt 60 ]; do
    [ -n "$(composer_pid)" ] && break
    sleep 2; i=$((i+1))
done
PID=$(composer_pid)
[ -n "$PID" ] || { echo "composer never appeared - nothing to watch"; exit 0; }

# grace period: a healthy composer takes master within seconds of starting
i=0; while [ $i -lt 10 ]; do
    master_ok && { echo "composer (pid $PID) is DRM master - healthy"; exit 0; }
    sleep 2; i=$((i+1))
done

echo "composer (pid $PID) holds no DRM master - bouncing it"
cat "$CLIENTS"
kill -9 "$PID" 2>/dev/null

i=0; while [ $i -lt 15 ]; do
    NEW=$(composer_pid)
    [ -n "$NEW" ] && [ "$NEW" != "$PID" ] && break
    sleep 2; i=$((i+1))
done
i=0; while [ $i -lt 10 ]; do
    master_ok && break
    sleep 2; i=$((i+1))
done

if master_ok; then
    echo "composer reacquired DRM master - restarting phosh"
    systemctl try-restart phosh.service 2>/dev/null || true
    exit 0
fi
echo "composer still has no DRM master - manual attention needed"
cat "$CLIENTS"
exit 1
WDOG
chmod 755 "$PKG/usr/local/sbin/sfduo-composer-watchdog"

cat > "$PKG/usr/lib/systemd/system/sfduo-composer-watchdog.service" <<'UNIT'
[Unit]
Description=sfduo: DRM-master watchdog for the vendor hwcomposer
After=lxc@android.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sfduo-composer-watchdog
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT

# Brightness: gsd-power writes BOTH panel backlights (panel0/1-backlight,
# 0-255) directly - measured on device 2026-07-12; the WLED node
# (/sys/class/backlight/backlight) drives nothing visible on these OLED
# panels. The 0.9.0-0.9.3 udev rule that mirrored WLED onto the panels
# was a SECOND writer: anything poking WLED (android side at resume /
# unblank leaves it at 4095) slammed the panels to max while the phosh
# indicator kept gsd's value. One writer only - the rule is gone; the
# resume-time panel reset is handled by the sfduo-brightness sleep hook.
cat > "$PKG/usr/local/sbin/sfduo-brightness-sync.sh" <<'BRT'
#!/bin/sh
# Manual/debug helper ONLY (not hooked to udev - see build.sh comment):
# mirror the WLED node (0-4095) onto the two panel backlights (0-255).
B=$(cat /sys/class/backlight/backlight/brightness 2>/dev/null) || exit 0
P=$((B * 255 / 4095))
[ "$P" -gt 255 ] && P=255
echo "$P" > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
echo "$P" > /sys/class/backlight/panel1-backlight/brightness 2>/dev/null
exit 0
BRT
chmod 755 "$PKG/usr/local/sbin/sfduo-brightness-sync.sh"
cat > "$PKG/etc/udev/rules.d/98-sfduo-backlight.rules" <<'RULES'
SUBSYSTEM=="backlight", GROUP="video", MODE="0664"
RULES

# Flashlight: let the video group drive the torch LEDs without root.
cat > "$PKG/etc/udev/rules.d/60-sfduo-torch.rules" <<'RULES'
SUBSYSTEM=="leds", KERNEL=="led:torch_*", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys%p/brightness && chmod 0664 /sys%p/brightness'"
SUBSYSTEM=="leds", KERNEL=="led:switch_*", ACTION=="add", RUN+="/bin/sh -c 'chgrp video /sys%p/brightness && chmod 0664 /sys%p/brightness'"
RULES

# Fold-to-sleep (2026-07-12, GPIO number from Tygerpro's port): the hall
# sensor on GPIO 121 reads 1 open / 0 fully closed. A small daemon
# bridges it to a uinput SW_LID switch and logind does the rest:
# fold -> suspend (verified end-to-end: Lid closed -> deep sleep ->
# wake by long power press, WiFi re-attaches thanks to WoWLAN).
cat > "$PKG/usr/local/sbin/sfduo-lid-daemon" <<'LID'
#!/usr/bin/env python3
# Surface Duo fold-to-lid bridge v2: hall sensor on GPIO 121 (1 open,
# 0 fully closed) exposed as a uinput SW_LID switch. On open it also
# wakes the session (KEY_WAKEUP) and forces the panel backlights back
# on. The poll loop times out every 2s and re-reads the sensor - GPIO
# edges are lost while the system sleeps, so state is reconciled, not
# just edge-triggered (unfold-while-asleep used to leave the system
# convinced the lid was still closed).
import os, struct, fcntl, select, time

GPIO = "/sys/class/gpio/gpio121"
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_SWBIT = 0x40045564, 0x40045565, 0x4004556D
UI_DEV_CREATE = 0x5501
EV_SYN, EV_KEY, EV_SW = 0x00, 0x01, 0x05
SW_LID, KEY_WAKEUP = 0x00, 143

def setup_gpio():
    if not os.path.isdir(GPIO):
        with open("/sys/class/gpio/export", "w") as f:
            f.write("121")
        time.sleep(0.2)
    with open(GPIO + "/direction", "w") as f:
        f.write("in")
    with open(GPIO + "/edge", "w") as f:
        f.write("both")

def make_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SW)
    fcntl.ioctl(fd, UI_SET_SWBIT, SW_LID)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_WAKEUP)
    dev = struct.pack("80sHHHHi", b"Surface Duo Lid Switch", 0x19, 0, 0, 0, 0)
    dev += b"\x00" * (64 * 4 * 4)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.2)
    return fd

def ev(fd, etype, code, value):
    os.write(fd, struct.pack("qqHHi", 0, 0, etype, code, value))

def emit_lid(fd, closed):
    ev(fd, EV_SW, SW_LID, 1 if closed else 0)
    ev(fd, EV_SYN, 0, 0)

def screens_on(fd):
    ev(fd, EV_KEY, KEY_WAKEUP, 1); ev(fd, EV_SYN, 0, 0)
    ev(fd, EV_KEY, KEY_WAKEUP, 0); ev(fd, EV_SYN, 0, 0)
    for p in ("panel0-backlight", "panel1-backlight"):
        try:
            with open("/sys/class/backlight/%s/bl_power" % p, "w") as f:
                f.write("0")
        except OSError:
            pass
    os.system("/usr/local/sbin/sfduo-brightness-sync.sh")

def main():
    setup_gpio()
    ufd = make_uinput()
    vfd = os.open(GPIO + "/value", os.O_RDONLY)

    def read_val():
        os.lseek(vfd, 0, os.SEEK_SET)
        return int(os.read(vfd, 8).strip())

    last = read_val()
    emit_lid(ufd, last == 0)
    po = select.poll()
    po.register(vfd, select.POLLPRI | select.POLLERR)
    while True:
        po.poll(2000)          # edge OR 2s reconcile tick
        time.sleep(0.05)       # debounce the magnet bounce
        val = read_val()
        if val != last:
            last = val
            emit_lid(ufd, val == 0)
            if val == 1:
                screens_on(ufd)

if __name__ == "__main__":
    main()
LID
chmod 755 "$PKG/usr/local/sbin/sfduo-lid-daemon"
# Folding with a cable attached must NOT suspend: an aborted suspend
# (dwc3 refuses with an active USB link) leaves the DSI panels dead
# until a cold power cycle. On external power a fold just locks.
# 0.13: a fold locks on battery too. Suspend is off in the session as the
# port is set up today, so "suspend" there only meant "nothing happens";
# ../system/README.md has the reasoning and what to change if that does.
install -Dm644 "$SYSTEM/50-sfduo-lid.conf" \
    "$PKG/etc/systemd/logind.conf.d/50-sfduo-lid.conf"

cat > "$PKG/usr/lib/systemd/system/sfduo-lid.service" <<'UNIT'
[Unit]
Description=sfduo: fold sensor (GPIO 121) to SW_LID bridge

[Service]
ExecStart=/usr/local/sbin/sfduo-lid-daemon
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

# System pieces (../system/README.md): each was found necessary on hardware.
# The slot guard and the modem unit were hand-installed into /etc before
# 0.13; postinst moves those copies out of the way of the packaged ones.
install -m644 "$SYSTEM/sfduo-slot-guard.service" "$PKG/usr/lib/systemd/system/"
install -m644 "$SYSTEM/sfduo-modem.service"      "$PKG/usr/lib/systemd/system/"
install -m755 "$SYSTEM/sfduo-modem"              "$PKG/usr/local/sbin/"
# the CPUs off powersave while the screen is on (../system/sfduo-cpufreq:
# mobile-power-saver misses the first screen-on at boot, and its dozing cycle
# restarts on StopDozing with the screen on)
install -m644 "$SYSTEM/sfduo-cpufreq.service"    "$PKG/usr/lib/systemd/system/"
install -m755 "$SYSTEM/sfduo-cpufreq"            "$PKG/usr/local/sbin/"
install -m755 "$SYSTEM/sfduo-screens"            "$PKG/usr/local/sbin/"
install -Dm644 "$SYSTEM/dconf/50-sfduo-phoc"       "$PKG/etc/dconf/db/local.d/50-sfduo-phoc"
install -Dm644 "$SYSTEM/dconf/locks/50-sfduo-phoc" "$PKG/etc/dconf/db/local.d/locks/50-sfduo-phoc"
install -Dm644 "$SYSTEM/dconf/profile-user"        "$PKG/etc/dconf/profile/user"
install -Dm644 "$SYSTEM/dconf/51-sfduo-background" "$PKG/etc/dconf/db/local.d/51-sfduo-background"
install -Dm644 "$SYSTEM/dconf/52-sfduo-idle"       "$PKG/etc/dconf/db/local.d/52-sfduo-idle"
install -Dm644 "$SYSTEM/dconf/53-sfduo-apps"       "$PKG/etc/dconf/db/local.d/53-sfduo-apps"
# Applications (2026-09-18): the grid hides what the port does not want
# (../system/apps/hidden.list - an override per desktop id in
# /usr/local/share/applications, which XDG_DATA_DIRS lists first; the
# packages stay, see the list for why) and sfduo-apps installs what it adds
# once the device is online (Telegram, what Claude Code needs).
install -m755  "$SYSTEM/sfduo-apps"       "$PKG/usr/local/sbin/"
install -Dm644 "$SYSTEM/apps/hidden.list"           "$PKG/usr/lib/sfduo/apps/hidden.list"
install -Dm644 "$SYSTEM/apps/cool-retro-term.json"  "$PKG/usr/lib/sfduo/apps/cool-retro-term.json"
mkdir -p "$PKG/usr/local/share/applications"
sed 's/#.*//' "$SYSTEM/apps/hidden.list" | awk 'NF' | while read -r id; do
    printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n# hidden by adaptation-droidian-surfaceduo - see /usr/lib/sfduo/apps/hidden.list\n' "${id%.desktop}" \
        > "$PKG/usr/local/share/applications/$id"
done
# A clean image has no `dconf` to compile these with until the shell's setup
# step has run, and until then neither the lock nor the black background
# would apply. Ship the database compiled; postinst's `dconf update` rebuilds
# it from local.d whenever the tool is there, so the two never disagree.
if command -v dconf >/dev/null 2>&1; then
    dconf compile "$PKG/etc/dconf/db/local" "$PKG/etc/dconf/db/local.d"
else
    echo "NOTE: no dconf on this host - the settings apply only after sfduo-shell-setup"
fi
# sfduo-screens ships without its sudoers rule: nothing in the package calls
# it as the user any more, and a NOPASSWD rule with no caller is only a hole.

# The two-panel shell (../shell/README.md) - EXPERIMENTAL. A dock across both
# panels that tiles what it launches onto the panel that was tapped, and the
# CSS that keeps phosh's own furniture off the hinge. It autostarts with the
# session; removing /etc/xdg/autostart/sfduo-dock.desktop turns it off.
# With a stock phosh the dock can sit on the lock screen after a reboot until
# the first unlock; the patched phosh below fixes that, and
# `sfduo-phosh-install --restore` is how a user goes back to the stock one.
install -m755 "$SHELLDIR/sfduo-dock"       "$PKG/usr/local/bin/"
install -m755 "$SHELLDIR/sfduo-brightness" "$PKG/usr/local/bin/"
install -m755 "$SHELLDIR/sfduo-shell-setup" "$PKG/usr/local/sbin/"
install -m755 "$SHELLDIR/sfduo-phosh-install" "$PKG/usr/local/sbin/"
# The patched phosh (../shell/phosh-patches 0001-0003, nothing else), built
# per ../shell/README.md. Version-locked: see sfduo-phosh-install.
PHOSH_BIN="$ROOT/out/phosh/phosh-0.49.0-cf38ab5-sfduo"
if [ -f "$PHOSH_BIN" ]; then
    install -Dm755 "$PHOSH_BIN" "$PKG/usr/lib/sfduo/phosh/phosh"
    echo "0.49.0+git20250824213429.cf38ab5.next.phosh.0.49" > "$PKG/usr/lib/sfduo/phosh/version"
else
    echo "NOTE: $PHOSH_BIN not found - building without the patched phosh"
fi
# The patched phoc (../shell/phoc-patches/0001): tiled windows stop short of
# the hinge named by `tiling-seam` in phoc.ini. Version-locked like phosh:
# see sfduo-phoc-install. Built per ../shell/README.md.
install -m755 "$SHELLDIR/sfduo-phoc-install" "$PKG/usr/local/sbin/"
PHOC_BIN="$ROOT/out/phoc/phoc-0.47.0-98211ea-sfduo"
if [ -f "$PHOC_BIN" ]; then
    install -Dm755 "$PHOC_BIN" "$PKG/usr/lib/sfduo/phoc/phoc"
    echo "0.47.0-1~git20250520212245.98211ea.next.phosh.0.47" > "$PKG/usr/lib/sfduo/phoc/version"
else
    echo "NOTE: $PHOC_BIN not found - building without the patched phoc"
fi
# The patched on-screen keyboard (../shell/osk-patches/0001): on this display
# it takes the right panel instead of both. Version-locked like the others.
install -m755 "$SHELLDIR/sfduo-osk-install" "$PKG/usr/local/sbin/"
OSK_BIN="$ROOT/out/osk/phosh-osk-stub-0.47.0-43ef51f-sfduo"
if [ -f "$OSK_BIN" ]; then
    install -Dm755 "$OSK_BIN" "$PKG/usr/lib/sfduo/osk/phosh-osk-stub"
    echo "0.47.0+git20250520212740.43ef51f.next.phosh.0.47" > "$PKG/usr/lib/sfduo/osk/version"
else
    echo "NOTE: $OSK_BIN not found - building without the patched keyboard"
fi
install -Dm644 "$SHELLDIR/sfduo-dock.desktop"       "$PKG/etc/xdg/autostart/sfduo-dock.desktop"
install -Dm644 "$SHELLDIR/sfduo-brightness.desktop" "$PKG/etc/xdg/autostart/sfduo-brightness.desktop"
install -Dm644 "$SHELLDIR/dock.json" "$PKG/usr/share/sfduo/dock.json.example"
# The output scale (2026-09-18): Droidian's generic phoc.ini says 3, which
# makes the panels 928x600 logical - a phone's worth of space, in which GNOME
# Calculator does not fit. 2 gives 1392x900 and, GTK3 drawing at integer
# scales, 60 fps on the lock screen where 2.5 (drawn at 3) gave 40 - see
# docs/PERF.md. phosh-session takes /etc/phosh/phoc.ini whole when it is
# there, so the package ships Droidian's file with the one line changed. The
# shell's CSS depends on the scale, so it is a template filled in by
# sfduo-shell-css: here for the scale shipped, and again in postinst for
# whatever phoc.ini is in place by then. A conffile: a user's edit survives
# an upgrade.
install -Dm644 "$SHELLDIR/phoc.ini"        "$PKG/etc/phosh/phoc.ini"
install -Dm644 "$SHELLDIR/gtk.css.in"      "$PKG/usr/share/sfduo/gtk.css.in"
install -m755  "$SHELLDIR/sfduo-shell-css" "$PKG/usr/local/sbin/"
SHELL_SCALE=$(sed -n '/^\[output:HWCOMPOSER-1\]/,/^\[/{s/^scale = //p}' "$SHELLDIR/phoc.ini" | head -1)
python3 "$SHELLDIR/sfduo-shell-css" --scale "$SHELL_SCALE" \
    --template "$SHELLDIR/gtk.css.in" -o "$PKG/usr/share/sfduo/gtk.css"
echo "/etc/phosh/phoc.ini" >> "$PKG/DEBIAN/conffiles"

cat > "$PKG/DEBIAN/control" <<EOF
Package: adaptation-droidian-surfaceduo
Version: $VER
Architecture: arm64
Maintainer: Ivan Verbovoy <ivanverbovoy@gmail.com>
Section: misc
Priority: optional
Recommends: python3-gi, python3-gi-cairo, python3-cairo, gir1.2-gtk-3.0, gir1.2-gtklayershell-0.1, wlrctl, wtype, dconf-cli
Description: Surface Duo 1 adaptation for Droidian (sfduo)
 USB RNDIS gadget access (172.16.42.1, telnet fallback) and, as bring-up
 progresses, touch / wifi / sensor plumbing for the Microsoft Surface Duo 1.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# migrate off the hand-injected copies (shadow the packaged unit if left)
rm -f /etc/systemd/system/sfduo-usb.service \
      /etc/systemd/system/multi-user.target.wants/sfduo-usb.service
# hinge adaptor mapping: sensorfwd reads ONLY the file given by -c=
if [ -f /etc/sensorfw/sensord-hybris.conf ] && \
   ! grep -q hingeadaptor /etc/sensorfw/sensord-hybris.conf; then
    printf '\n[plugins]\nhingeadaptor = hybrishingeadaptor\n' >> /etc/sensorfw/sensord-hybris.conf
fi
# Bluetooth (2026-07-11 night): the morning bluebinder kernel-lockup was
# collateral of the dead-ADSP chaos, NOT a bluebinder bug - with a healthy
# system it runs fine. Two real fixes: (1) the chip needs ~65s to reinit
# after a stop while the unit allows 60 (drop-in below raises it);
# (2) no bdaddr property exists on the Duo - pre-provide board-address
# (derived from the wifi MAC + 1) so bluebinder_post.sh passes.
rm -f /etc/systemd/system/bluebinder.service \
      /etc/systemd/system/bluetooth.service \
      /etc/systemd/system/dbus-org.bluez.service
# On a first install there is no wlan0 yet - this package is what loads the
# wifi module - and under `set -e` the failed read of its address used to
# end the postinst right here, before anything was enabled: no USB access,
# no units, nothing (found by installing on a clean Droidian 101 image).
# The script is safe to run early; bluebinder runs it again before it starts.
/usr/local/sbin/sfduo-bt-address || true
# Index the audio modules now rather than on the audio unit's first run. The
# kernel autoloads them early in boot (~37 s) once depmod knows them, and they
# have to be loaded BEFORE the ADSP comes up: loaded after it, they miss
# "Q6 is Up" and the sound card never registers for that boot. Measured on a
# clean image - the first boot after an install had no sound, every later
# one did.
# Every set the package carries, not only the running kernel's: the first
# boot of another kernel (a RAM-boot of the perf build, say) found an empty
# /lib/modules/<release>/, the audio unit loaded the chain itself at 80 s,
# after the ADSP, and no sound card registered on that boot. depmod takes a
# release explicitly, so the index for a kernel that is not running is fine.
for set in /usr/lib/sfduo/modules/*/; do
    [ -d "$set/audio" ] || continue
    rel=$(basename "$set")
    mkdir -p "/lib/modules/$rel"
    cp -un "$set/audio/"*.ko "/lib/modules/$rel/" 2>/dev/null || true
    depmod -a "$rel" 2>/dev/null || true
done
KVER=$(uname -r)
[ -d "/usr/lib/sfduo/modules/$KVER/audio" ] || \
    echo "sfduo: no modules for the running kernel ($KVER) in this package - sets: $(ls /usr/lib/sfduo/modules 2>/dev/null | tr '\n' ' ')" >&2
# older packages put them here; the units read /usr/lib/sfduo/modules now
rm -f /usr/lib/sfduo/wlan.ko; rm -rf /usr/lib/sfduo/audio
# pre-0.12 installs shipped an experimental wayfire session; its units
# are gone from the package - drop the leftover enable symlink
rm -f /etc/systemd/system/multi-user.target.wants/sfduo-powerkey.service \
      /etc/systemd/system/graphical.target.wants/wayfire-duo.service
# android_bootctl reaches the boot HAL through lxc-attach, and on this device
# lxc-attach swallows the last argument unless Droidian's wrapper is told to
# pad it - this file is how it is told. Without it every bootctl call is an
# empty command: the slot guard fails, no boot is ever marked successful, and
# the bootloader's retry counter runs down until it switches slots. It was
# made by hand on the development device in July and forgotten; an install
# from scratch had a failed slot guard on its first real boot.
mkdir -p /var/lib/droidian
touch /var/lib/droidian/lxc_attach_workaround
# A first install comes up at full brightness - the panels' power-on default,
# on two OLEDs a hand's width from the face. Seed systemd-backlight's saved
# state at about a third, and set it now as well, so the value it saves at
# the first shutdown is the same one. Only where nothing has been saved yet:
# on a device that has been used, the owner's level is left alone.
for p in panel0-backlight panel1-backlight; do
    f="/var/lib/systemd/backlight/platform-ae00000.qcom,mdss_mdp:backlight:$p"
    if [ ! -e "$f" ]; then
        mkdir -p /var/lib/systemd/backlight
        echo 90 > "$f"
        [ -w "/sys/class/backlight/$p/brightness" ] && \
            echo 90 > "/sys/class/backlight/$p/brightness" || true
    fi
done
# plymouth takes DRM master on card0 and the vendor composer, which opened
# the device meanwhile, is left without it for good: black panels after the
# Debian logo (the README's plymouth trap). The composer watchdog repairs it,
# but only a couple of minutes into the boot - measured on an install from
# scratch, where the screen came up at 3.5 minutes instead of 1.5. Without
# plymouth there is no race. The splash is all that is lost.
ln -sf /dev/null /etc/systemd/system/plymouth-start.service
# 0.13: the slot guard and the modem unit used to be copied into /etc by
# hand; a unit there shadows the packaged one forever.
rm -f /etc/systemd/system/sfduo-slot-guard.service \
      /etc/systemd/system/sfduo-modem.service \
      /etc/systemd/system/multi-user.target.wants/sfduo-slot-guard.service \
      /etc/systemd/system/multi-user.target.wants/sfduo-modem.service
# the dconf lock on sm.puri.phoc auto-maximize only counts once compiled
command -v dconf >/dev/null 2>&1 && dconf update || true
# the patched shell, if this is the phosh it was built for
/usr/local/sbin/sfduo-phosh-install || true
/usr/local/sbin/sfduo-phoc-install || true
/usr/local/sbin/sfduo-osk-install || true
# the shell's CSS for the output scale actually configured (a user may have
# changed /etc/phosh/phoc.ini - it is a conffile and theirs to change)
/usr/local/sbin/sfduo-shell-css || true
# The shell's CSS has to live in the user's own config - GTK reads it from
# nowhere else. Link it rather than copy it, so an upgrade reaches it; a file
# somebody put there themselves is left alone. The dock's config directory is
# made here as the user, because made by root the dock cannot write to it.
if id droidian >/dev/null 2>&1; then
    H=$(getent passwd droidian | cut -d: -f6)
    for d in "$H/.config" "$H/.config/gtk-3.0" "$H/.config/sfduo"; do
        [ -d "$d" ] || install -d -o droidian -g droidian "$d"
    done
    chown droidian:droidian "$H/.config/sfduo"
    if [ ! -e "$H/.config/gtk-3.0/gtk.css" ] || \
       cmp -s "$H/.config/gtk-3.0/gtk.css" /usr/share/sfduo/gtk.css; then
        ln -sfn /usr/share/sfduo/gtk.css "$H/.config/gtk-3.0/gtk.css"
        chown -h droidian:droidian "$H/.config/gtk-3.0/gtk.css"
    else
        echo "sfduo: $H/.config/gtk-3.0/gtk.css is not ours - left alone;" >&2
        echo "sfduo: the shell's CSS is at /usr/share/sfduo/gtk.css" >&2
    fi
fi
if [ -d /run/systemd/system ]; then
    # `systemctl enable` reloads the manager every time, and on this kernel a
    # reload is half a minute (a debug-heavy config: every allocation is
    # checked). A dozen of them made the install take nine minutes. So:
    # enable without reloading, reload once, then start.
    START=""
    en()     { systemctl --no-reload enable "$@"; }
    en_now() { systemctl --no-reload enable "$@" && START="$START $*"; }
    systemctl daemon-reload
    en sfduo-slot-guard.service || true
    en_now sfduo-modem.service || true
    en_now sfduo-cpufreq.service || true
    en_now sfduo-usb.service || true
    en bluebinder.service bluetooth.service 2>/dev/null || true
    en sfduo-composer-watchdog.service || true
    en_now sfduo-lid.service || true
    en_now sfduo-writeback.timer || true
    en_now sfduo-wakeup.service || true
    udevadm control --reload 2>/dev/null || true
    udevadm trigger -s backlight -s leds 2>/dev/null || true
    # geoclue is a static unit; the drop-in adds [Install] so it can start at boot
    en_now geoclue.service 2>/dev/null || START="$START geoclue.service"
    [ -d /usr/lib/sfduo/modules ] && en_now sfduo-wlan.service || true
    # sfduo-tame-vendor kills adsprpcd, and sfduo-audio.service is what
    # boots the ADSP afterwards. Measured on hardware: adsprpcd cannot
    # bring the ADSP up on this port at all, so with no starter the
    # daemons just respawn and spin (~24% CPU each) against a subsystem
    # stuck at OFFLINING. Killing them there buys nothing, so the killer
    # only goes in alongside the starter.
    if [ -x /usr/local/sbin/sfduo-audio-up.sh ]; then
        en sfduo-audio.service || true
        en_now sfduo-tame-vendor.service || true
    else
        echo "sfduo: built without audio modules, so there is no ADSP" >&2
        echo "sfduo: starter. Expect adsprpcd to spin and bluetooth to" >&2
        echo "sfduo: refuse to start (it would soft-lock the kernel)." >&2
        echo "sfduo: Build the audio modules and reinstall." >&2
    fi
    systemctl daemon-reload
    # --no-block: on a first boot this runs before multi-user.target, and a
    # unit that waits for the modem would hold the whole boot with it.
    for u in $START; do systemctl --no-block start "$u" || true; done
else
    ln -sf /usr/lib/systemd/system/sfduo-usb.service \
       /etc/systemd/system/multi-user.target.wants/sfduo-usb.service
    ln -sf /usr/lib/systemd/system/sfduo-slot-guard.service \
       /etc/systemd/system/multi-user.target.wants/sfduo-slot-guard.service
    ln -sf /usr/lib/systemd/system/sfduo-modem.service \
       /etc/systemd/system/multi-user.target.wants/sfduo-modem.service
    mkdir -p /etc/systemd/system/graphical.target.wants
    ln -sf /usr/lib/systemd/system/sfduo-cpufreq.service \
       /etc/systemd/system/graphical.target.wants/sfduo-cpufreq.service
    # same pairing rule as above, offline: the ADSP starter and the
    # adsprpcd killer go in together or not at all
    if [ -x /usr/local/sbin/sfduo-audio-up.sh ]; then
        ln -sf /usr/lib/systemd/system/sfduo-audio.service \
           /etc/systemd/system/multi-user.target.wants/sfduo-audio.service
        ln -sf /usr/lib/systemd/system/sfduo-tame-vendor.service \
           /etc/systemd/system/multi-user.target.wants/sfduo-tame-vendor.service
    fi
fi
EOF
chmod 755 "$PKG/DEBIAN/postinst"

mkdir -p "$OUT"
dpkg-deb --build --root-owner-group "$PKG" \
    "$OUT/adaptation-droidian-surfaceduo_${VER}_arm64.deb"
rm -rf "$PKG"
echo "OK: $OUT/adaptation-droidian-surfaceduo_${VER}_arm64.deb"
