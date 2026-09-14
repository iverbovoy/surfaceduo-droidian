#!/bin/bash
# Inject ssh access into the Droidian rootfs.img on the device, from
# TWRP (RAM-booted, adb in recovery mode). Run on the HOST.
#
# What it does on the device:
#   e2fsck -fy /data/rootfs.img          (journal is usually dirty)
#   loop-mount rootfs.img rw
#   copy the openssh bundle, IF there is one, -> /var/cache/sfduo-ssh/
#   (recent nightlies ship sshd, so the bundle is optional)
#   install sfduo-ssh-firstboot.{service,sh} + enable symlink
#   write authorized_keys for root and droidian (uid/gid 32011)
#   sshd_config drop-in (root = key-only)
#   umount + sync
#
# On next RAM-boot of your validated boot image the firstboot unit
# dpkg -i's the bundle and starts sshd. Then: ssh root@172.16.42.1
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEBS="$ROOT/out/ssh-debs"
PUBKEY="${SFDUO_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
MNT=/mnt/sfduo-root

# The openssh bundle is OPTIONAL. Recent Droidian nightlies ship sshd
# themselves, and the old hard requirement of 11 debs pushed at least
# one porter into padding the directory with packages nothing needed.
# What this script really injects is the key, the firstboot unit and,
# when it has been built, the adaptation deb.
if [ -d "$DEBS" ] && [ -n "$(ls "$DEBS"/*.deb 2>/dev/null)" ]; then
    HAVE_BUNDLE=1
    echo "== openssh bundle: $(ls "$DEBS"/*.deb | wc -l) debs"
else
    HAVE_BUNDLE=0
    echo "== no openssh bundle in $DEBS - assuming the rootfs ships sshd"
fi
[ -f "$PUBKEY" ] || { echo "ERROR: pubkey missing: $PUBKEY (set SFDUO_PUBKEY)"; exit 1; }

state="$(adb get-state 2>/dev/null || true)"
[ "$state" = "recovery" ] || { echo "ERROR: device not in recovery/TWRP (adb state: '${state:-none}')"; exit 1; }
serial="$(adb get-serialno)"
echo "== device $serial (TWRP), pubkey: $PUBKEY"

adb shell "ls /data/rootfs.img" >/dev/null || { echo "ERROR: /data/rootfs.img not found on device"; exit 1; }

echo "== push bundle"
adb shell "rm -rf /tmp/sfduo-ssh && mkdir -p /tmp/sfduo-ssh"
if [ "$HAVE_BUNDLE" = 1 ]; then          # not `[ ] && cmd`: set -e would
    adb push "$DEBS"/*.deb /tmp/sfduo-ssh/ >/dev/null   # exit on the false test
fi
# adaptation package rides along if built (adaptation/package/build.sh)
adapt="$(ls "$ROOT"/out/adaptation-droidian-surfaceduo_*_arm64.deb 2>/dev/null | sort -V | tail -1 || true)"
if [ -n "$adapt" ]; then
    echo "   + $(basename "$adapt")"
    adb push "$adapt" /tmp/sfduo-ssh/ >/dev/null
fi
adb push "$HERE/sfduo-ssh-firstboot.service" "$HERE/sfduo-ssh-firstboot.sh" /tmp/sfduo-ssh/ >/dev/null
adb push "$PUBKEY" /tmp/sfduo-ssh/authorized_keys >/dev/null

echo "== fsck rootfs.img (dirty journal is normal after a session)"
adb shell "e2fsck -fy /data/rootfs.img" || true

echo "== mount + install"
adb shell "mkdir -p $MNT && mount -o loop,rw /data/rootfs.img $MNT"
adb shell "set -e
R=$MNT
mkdir -p \$R/var/cache/sfduo-ssh
ls /tmp/sfduo-ssh/*.deb >/dev/null 2>&1 && cp /tmp/sfduo-ssh/*.deb \$R/var/cache/sfduo-ssh/ || true
cp /tmp/sfduo-ssh/sfduo-ssh-firstboot.sh \$R/usr/local/sbin/sfduo-ssh-firstboot.sh
chmod 755 \$R/usr/local/sbin/sfduo-ssh-firstboot.sh
cp /tmp/sfduo-ssh/sfduo-ssh-firstboot.service \$R/etc/systemd/system/
ln -sf /etc/systemd/system/sfduo-ssh-firstboot.service \$R/etc/systemd/system/multi-user.target.wants/sfduo-ssh-firstboot.service
# keys: root
mkdir -p \$R/root/.ssh && chmod 700 \$R/root/.ssh
cp /tmp/sfduo-ssh/authorized_keys \$R/root/.ssh/authorized_keys
chmod 600 \$R/root/.ssh/authorized_keys && chown -R 0:0 \$R/root/.ssh
# keys: droidian (32011:32011)
mkdir -p \$R/home/droidian/.ssh && chmod 700 \$R/home/droidian/.ssh
cp /tmp/sfduo-ssh/authorized_keys \$R/home/droidian/.ssh/authorized_keys
chmod 600 \$R/home/droidian/.ssh/authorized_keys && chown -R 32011:32011 \$R/home/droidian/.ssh
# sshd drop-in: root key-only
mkdir -p \$R/etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\n' > \$R/etc/ssh/sshd_config.d/10-sfduo.conf
"
# TWRP adb does not always propagate exit codes - verify explicitly
echo "== verify"
ok="$(adb shell "test -f $MNT/root/.ssh/authorized_keys && test -L $MNT/etc/systemd/system/multi-user.target.wants/sfduo-ssh-firstboot.service && echo INJECT_OK" | tr -d '\r')"
[ "$ok" = "INJECT_OK" ] || { echo "ERROR: verification failed - do NOT boot, inspect $MNT on device"; exit 1; }
if [ "$HAVE_BUNDLE" = 1 ]; then
    adb shell "ls $MNT/var/cache/sfduo-ssh/openssh-server_*.deb >/dev/null 2>&1 && echo BUNDLE_OK" \
        | tr -d '\r' | grep -q BUNDLE_OK \
        || { echo "ERROR: bundle was pushed but openssh-server is not in it"; exit 1; }
fi

echo "== umount + sync"
adb shell "umount $MNT && sync"
echo "== DONE. RAM-boot your validated boot image; ~60s after Phosh: ssh root@172.16.42.1"
