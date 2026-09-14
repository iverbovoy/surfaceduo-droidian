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
systemctl enable --now ssh.service

touch /var/lib/sfduo-ssh-installed
