#!/bin/sh
# One-shot: install openssh-server from the offline bundle injected by
# inject-ssh-twrp.sh into /var/cache/sfduo-ssh, then start it.
# Verified 2026-07-11 in a qemu chroot of the exact rootfs (api30 101.20251130):
# dpkg -i of the 11 debs exits 0 and enables ssh.service itself.
# The bundle may also carry adaptation-droidian-surfaceduo - installed in
# the same pass (its postinst migrates the hand-injected access files).
set -e

# The bundle is optional: recent rootfs images ship sshd themselves and
# then this directory holds only the adaptation deb, or nothing at all.
if ls /var/cache/sfduo-ssh/*.deb >/dev/null 2>&1; then
    dpkg -i /var/cache/sfduo-ssh/*.deb || dpkg --configure -a
fi

systemctl daemon-reload
# The 101 image ships no sshd, and without the offline bundle there is none
# to enable. Failing here (set -e) skipped the flag below, and the whole
# bundle was installed again on every boot.
if [ -x /usr/sbin/sshd ]; then
    systemctl enable --now ssh.service || true
fi

touch /var/lib/sfduo-ssh-installed
sync

# One reboot, once. The adaptation arrives too late in this boot to do its
# job: the ADSP ordering, the audio modules' early autoload and the slot
# guard all belong to the start of a boot, and a system left running
# without them has no sound and, measured, can freeze within minutes. The
# flag above is written first, so this cannot loop.
if dpkg-query -W -f='${Status}' adaptation-droidian-surfaceduo 2>/dev/null \
        | grep -q 'install ok installed'; then
    echo "sfduo: adaptation installed - rebooting once to start with it" >&2
    systemctl --no-block reboot
fi
