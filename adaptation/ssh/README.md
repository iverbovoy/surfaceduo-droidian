# Offline openssh-server for the Droidian rootfs

The api30 nightly ships no sshd, and the busybox telnetd fallback has no
pty (truncated output - see ../access/README.md). This bundle installs a
real openssh-server **offline**: 11 debs pre-downloaded from the Droidian
rolling snapshot, injected from TWRP, installed by a one-shot systemd
unit on the next boot.

Verified 2026-07-11 on the host in a qemu-aarch64 chroot of the exact
rootfs (Droidian 101/20251130, Debian 13): `dpkg -i` of the bundle exits
0, enables ssh.service, `sshd -t` passes. Host keys are generated on the
device by the postinst, so each install gets unique keys.

## Files

- `inject-ssh-twrp.sh` - run on the HOST while the device sits in
  RAM-booted TWRP. Pushes debs + unit + your pubkey, loop-mounts
  /data/rootfs.img, installs, verifies, unmounts.
- `sfduo-ssh-firstboot.{service,sh}` - the on-device one-shot installer
  (`dpkg -i /var/cache/sfduo-ssh/*.deb`, guarded by
  /var/lib/sfduo-ssh-installed).
- debs live in `out/ssh-debs/` at the repo root (gitignored). Releases from
  0.13.0 carry them as `ssh-debs-droidian-101.tar`, downloaded on a 101
  image with `apt-get install --download-only openssh-server`; the chroot
  recipe below rebuilds them for another base.

## Usage

```
# device in TWRP (RAM-boot surfaceduo1-twrp.img from the WOA SurfaceDuo-Guides)
./inject-ssh-twrp.sh                       # uses ~/.ssh/id_ed25519.pub
SFDUO_PUBKEY=~/.ssh/other.pub ./inject-ssh-twrp.sh
# then RAM-boot your validated boot image; ~60 s after boot:
ssh root@172.16.42.1        # key-only
ssh droidian@172.16.42.1    # key or password 1234
```

Access: root = key-only (sshd_config.d/10-sfduo.conf), droidian =
key + password fallback. The USB network itself comes from the gadget
unit in ../access/ (172.16.42.1, host side 172.16.42.2/24).

## Rebuilding the deb bundle

```
cp <droidian-nightly-rootfs>.img /some/work.img
truncate -s 6G /some/work.img && e2fsck -fy /some/work.img && resize2fs /some/work.img
sudo mount -o loop /some/work.img /mnt/x
sudo mount -t proc proc /mnt/x/proc; sudo mount --bind /dev /mnt/x/dev
sudo cp /etc/resolv.conf /mnt/x/etc/resolv.conf
sudo mount --bind <hostdir> /mnt/x/var/cache/apt/archives   # image is 100% full
sudo chroot /mnt/x apt-get update                            # sig warning OK, cached index used
sudo chroot /mnt/x apt-get install -y --download-only openssh-server
```
