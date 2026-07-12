#!/bin/bash
# Build adaptation-droidian-surfaceduo_<ver>_arm64.deb into out/.
# Folds the hand-injected USB access files (../access) into a real package so
# they persist across rootfs updates; postinst migrates away the hand-injected
# copies. Touch/wifi/sensor adaptation lands here as it gets figured out.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ACCESS="$HERE/../access"
BUSYBOX="$ROOT/out/busybox-arm64"
VER="${1:-0.9.3}"
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
WLANKO="$ROOT/out/wlan.ko"  # built per kernel-packaging/README.md
if [ -f "$WLANKO" ]; then
    mkdir -p "$PKG/usr/lib/sfduo"
    install -m644 "$WLANKO" "$PKG/usr/lib/sfduo/wlan.ko"
    cat > "$PKG/usr/lib/systemd/system/sfduo-wlan.service" <<'UNIT'
[Unit]
Description=sfduo: load the qcacld-3.0 wlan module
ConditionPathExists=/usr/lib/sfduo/wlan.ko
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'grep -q ^wlan /proc/modules || insmod /usr/lib/sfduo/wlan.ko'
# WoWLAN keeps the association alive through deep sleep, so WiFi (and ssh
# over it) come back instantly on wake instead of rescanning.
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do iw phy phy0 wowlan enable any 2>/dev/null && break; sleep 1; done; true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
else
    echo "NOTE: $WLANKO not found - building without wifi module"
fi

# Audio (2026-07-11): 23 techpack modules built from MS's audio-kernel OSS
# repo in-tree (see kernel-packaging README). They only produce a sound
# card if the ADSP is booted BEFORE apr_dlkm loads and enumerates its DT
# children. On stock, adsprpcd boots/holds the ADSP - we kill those (see
# tame-vendor), so boot it ourselves via adsp_loader's sysfs, then load
# the chain in vendor order. Codec on Duo 1 answers as TAVIL (wcd934x,
# chip id 0x108) - the pahu DT node stays silent, ignore its -6 probe.
AUDIOKO_DIR="$ROOT/out/audio-modules"  # *_dlkm.ko per kernel-packaging/README.md
if [ -d "$AUDIOKO_DIR" ] && [ -n "$(find "$AUDIOKO_DIR" -name '*.ko' 2>/dev/null | head -1)" ]; then
    mkdir -p "$PKG/usr/lib/sfduo/audio"
    find "$AUDIOKO_DIR" -name '*.ko' -exec install -m644 {} "$PKG/usr/lib/sfduo/audio/" \;
    cat > "$PKG/usr/local/sbin/sfduo-audio-up.sh" <<'AUDIO'
#!/bin/sh
# Boot the ADSP, then load the audio techpack chain in vendor order.
KVER=$(uname -r)
mkdir -p /lib/modules/$KVER
cp -un /usr/lib/sfduo/audio/*.ko /lib/modules/$KVER/ 2>/dev/null
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
# Verify the chain actually landed. Failing here also keeps bluebinder
# off (Requires=) - a half-dead audio/ADSP state is exactly when a
# bluetooth init soft-locks the kernel, so silence is the safe mode.
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
    # bluebinder against a dead-ADSP system soft-locks the kernel
    # (queued_write_lock_slowpath) and takes ALL I/O down. Requires= (not
    # just After=) - if the ADSP gate above fails, bluetooth stays off
    # rather than wedging the kernel.
    mkdir -p "$PKG/etc/systemd/system/bluebinder.service.d"
    printf '[Unit]\nAfter=sfduo-audio.service\nRequires=sfduo-audio.service\n' \
        > "$PKG/etc/systemd/system/bluebinder.service.d/20-sfduo-after-adsp.conf"
else
    echo "NOTE: audio modules not found - building without audio"
fi

# Suspend hook (2026-07-11 night): dwc3-msm in peripheral mode never
# reaches LPM by itself and aborts every system suspend (see kernel patch
# in dwc3_msm_pm_suspend, v6+). Belt-and-suspenders: park the controller
# around sleep so the forced path has the easiest job, and restore the
# gadget afterwards. Requires v6 kernel for the forced-suspend fallback.
# droidian ships AllowSuspend=no (10-droidian-sleep.conf) - the verb is
# refused before the kernel is even asked. Our 99- wins the sort order.
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
printf '[Sleep]\nAllowSuspend=yes\n' > "$PKG/etc/systemd/sleep.conf.d/99-sfduo.conf"

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

# Brightness (2026-07-12, sysfs paths spotted in Tygerpro's UT port): the
# phosh slider drives /sys/class/backlight/backlight (WLED, 0-4095) but
# the panels listen to panel0/1-backlight (0-255) - without the sync the
# panels sit at a constant level forever. The change uevent fires on
# every brightness store, verified on device.
cat > "$PKG/usr/local/sbin/sfduo-brightness-sync.sh" <<'BRT'
#!/bin/sh
# Mirror the main WLED backlight (0-4095) onto the two panel backlights (0-255).
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
SUBSYSTEM=="backlight", KERNEL=="backlight", ACTION=="change", RUN+="/usr/local/sbin/sfduo-brightness-sync.sh"
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
mkdir -p "$PKG/etc/systemd/logind.conf.d"
printf '[Login]\nHandleLidSwitchExternalPower=lock\n' \
    > "$PKG/etc/systemd/logind.conf.d/50-sfduo-lid.conf"

cat > "$PKG/usr/lib/systemd/system/sfduo-lid.service" <<'UNIT'
[Unit]
Description=sfduo: fold sensor (GPIO 121) to SW_LID bridge

[Service]
ExecStart=/usr/local/sbin/sfduo-lid-daemon
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

cat > "$PKG/DEBIAN/control" <<EOF
Package: adaptation-droidian-surfaceduo
Version: $VER
Architecture: arm64
Maintainer: Ivan Verbovoy <ivanverbovoy@gmail.com>
Section: misc
Priority: optional
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
if [ ! -f /var/lib/bluetooth/board-address ]; then
    WMAC=$(cat /sys/class/net/wlan0/address 2>/dev/null)
    if [ -n "$WMAC" ]; then
        mkdir -p /var/lib/bluetooth
        printf "%s\n" "$WMAC" | awk -F: "{printf \"%s:%s:%s:%s:%s:%02X\n\", toupper(\$1),toupper(\$2),toupper(\$3),toupper(\$4),toupper(\$5), strtonum(\"0x\" \$6)+1}" > /var/lib/bluetooth/board-address
        chmod 644 /var/lib/bluetooth/board-address
    fi
fi
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable --now sfduo-usb.service || true
    systemctl enable bluebinder.service bluetooth.service 2>/dev/null || true
    systemctl enable --now sfduo-tame-vendor.service || true
    systemctl enable --now sfduo-lid.service || true
    udevadm control --reload 2>/dev/null || true
    udevadm trigger -s backlight -s leds 2>/dev/null || true
    # geoclue is a static unit; the drop-in adds [Install] so it can start at boot
    systemctl enable --now geoclue.service 2>/dev/null || systemctl start geoclue.service || true
    [ -f /usr/lib/sfduo/wlan.ko ] && systemctl enable --now sfduo-wlan.service || true
    [ -x /usr/local/sbin/sfduo-audio-up.sh ] && systemctl enable sfduo-audio.service || true
else
    ln -sf /usr/lib/systemd/system/sfduo-usb.service \
       /etc/systemd/system/multi-user.target.wants/sfduo-usb.service
    ln -sf /usr/lib/systemd/system/sfduo-tame-vendor.service \
       /etc/systemd/system/multi-user.target.wants/sfduo-tame-vendor.service
fi
EOF
chmod 755 "$PKG/DEBIAN/postinst"

mkdir -p "$OUT"
dpkg-deb --build --root-owner-group "$PKG" \
    "$OUT/adaptation-droidian-surfaceduo_${VER}_arm64.deb"
rm -rf "$PKG"
echo "OK: $OUT/adaptation-droidian-surfaceduo_${VER}_arm64.deb"
