# Port guide - Droidian on Surface Duo 1, step by step

Prerequisites: a Surface Duo 1 (any storage size) with an unlockable
bootloader, a Linux host with docker + adb/fastboot + python3 +
device-tree-compiler, and [docs/SAFETY.md](SAFETY.md) read twice.

## 0. Backups (non-negotiable)

Unlock the bootloader (Microsoft's official instructions). RAM-boot TWRP
(`surfaceduo1-twrp.img`, do NOT flash it):

```
fastboot boot surfaceduo1-twrp.img
adb shell
  cd /dev/block/platform/soc/1d84000.ufshc/by-name
  dd if=boot_a of=/sdcard/boot_a.img
  dd if=boot_b of=/sdcard/boot_b.img
  dd if=misc   of=/sdcard/misc.img
adb pull /sdcard/boot_a.img; adb pull /sdcard/boot_b.img; adb pull /sdcard/misc.img
```

## 1. Kernel

See `kernel-packaging/README.md`. In short: clone Microsoft's OSS tree
(branch `surfaceduo/11/2022.902.48`), run `setup.sh` to install the
packaging, build in the Droidian container. The important choices are
already encoded in the config fragment:

- `CONFIG_SPI_HID=y` - the touch controller driver, built in (the
  droidian rootfs installs no modules, and MODULE_SIG blocks foreign
  ones).
- `CONFIG_MODULE_SIG_FORCE=n` - lets the *stock vendor partition's own
  modules* (`qca_cld3_wlan`, `audio_*`) load into our kernel; they are
  built from this exact tree version.
- pstore/ramoops for crash logs, `pr_info_ratelimited` patch for the
  adsprpcd ioctl flood.

Harvest `out/KERNEL_OBJ/arch/arm64/boot/Image.gz` even if the deb's
boot.img assembly step fails - the flight image is packed manually:

## 2. Boot image

```
tools/extract-stock-dtb.sh boot_b.img stock.dtb   # from YOUR backup
tools/make-boot-image.sh Image.gz <droidian-boot.img-or-initramfs> stock.dtb
```

`make-boot-image.sh` patches the halium initramfs in flight
(data=ordered instead of the 2014 data=journal workaround - without it
the phone stalls under write bursts, see docs/FREEZE-FORENSICS.md),
packs the v2 header with the right offsets/cmdline and validates the
result. The DTB **must** be the generic wildcard extracted from your
stock image (see SAFETY.md, "DTB scheme" - this was our silent-death
root cause). The ramdisk comes from the droidian kernel deb / nightly
boot image.

## 3. Rootfs

Use the **Droidian 101 release** image, `rootfs api30 arm64` (phosh
phone variant), not the current nightly.

This is not caution for its own sake. Everything in this repository was
built and verified against 101 (2025-11-30), and a later nightly has
already broken this port once, in a way that costs a whole evening to
find: newer `lxc-android` waits for the container through
`droidian-apex`, which never sees `apexd.status` reach `ready` on this
device even though apexd sets it within five seconds. `lxc@android`
then fails on a 90 second timeout, `android-service@hwcomposer` fails
on the dependency, `phosh` fails on that, and the phone boots to the
Debian logo and then two black panels with no obvious cause. The 101
image waits through `waitforservice` instead, which reads the property
directly and does not hit this at all.

If you do run a newer base and the screens stay black after the logo,
check `systemctl status lxc@android` first.

From TWRP:

```
mke2fs -t ext4 /dev/block/sda6           # userdata, wipes Android!
mount /dev/block/sda6 /data
adb push rootfs.img /data/rootfs.img     # verify sha256 after push
resize2fs /data/rootfs.img 8G            # give apt some room
```

The halium initramfs finds `/data/rootfs.img` by the `datapart=`
cmdline argument and loop-mounts it as /.

## 4. Adaptation

Build the package (`adaptation/package/build.sh`, or take the .deb from a
release) and inject it with `adaptation/ssh/inject-ssh-twrp.sh`: USB RNDIS access +
sshd (the nightly ships none), the touch udev rule, bluetooth fixes
(start timeout + board-address), vendor-daemon taming with early ADSP
boot (without it the system I/O-deadlocks ~2 minutes after boot), the
suspend hooks. Loop-mount the rootfs image from TWRP
(`e2fsck -fy` first - the journal is usually dirty) and run the inject
script.

## 5. First boot

```
fastboot getvar current-slot   # see SAFETY.md - slots flip on their own
fastboot set_active a
fastboot erase misc && fastboot flash misc misc-brake.img   # tools/make-misc-brake.sh
tools/flash-safely.sh ram-boot boot-duo1-droidian.img
```

~60-90 s later both panels show the Phosh lock screen (PIN 1234) and a
new RNDIS interface appears on the host.

If instead the screens go black right after the Debian logo and the
power key looks dead, the system underneath is almost certainly fine:
plymouth has taken DRM master away from the vendor composer. See the
plymouth trap in the top-level README. The short cure is `systemctl
mask plymouth-start.service`, and the adaptation's
`sfduo-composer-watchdog` covers the cases it can detect. Get in over
ssh first, the network comes up regardless of what the panels do.

Tell NetworkManager to leave the RNDIS interface alone, then ssh in:

```
nmcli device set <iface> managed no
ip addr replace 172.16.42.2/24 dev <iface>; ip link set <iface> up
ssh root@172.16.42.1
```

If your host routes 172.16.42.0/24 elsewhere you will "connect" to
something that is not the phone - a sub-2 ms ping RTT is the tell that
you are actually on the USB link.

## 6. What to expect

See the status matrix in the top-level README. Touch works end-to-end
(kernel spi-hid → vendor touchpen HAL → uinput → udev rule). Stock
phosh treats the two panels as one span, so centered UI falls into the
hinge gap; the adaptation's experimental shell (`adaptation/shell/`) works
around that from outside phosh - run `sudo sfduo-shell-setup` once the
device is online to give it what it needs.

## Debug channels, in order of preference

1. ssh (adaptation package).
2. Persistent journald (`Storage=persistent` drop-in must sort AFTER
   droidian's `10-journald-volatile.conf` - name it `99-*`).
3. TWRP + loop-mount of rootfs.img - post-mortem file inspection.
4. pstore/ramoops after a crash (needs the ramoops DT node variant).
5. The initramfs panic shell, for when the boot dies before any of the
   above exist. See below.

## When the boot dies before the rootfs

Symptom: no Debian logo at all, no ssh, the phone just sits there.
Plymouth lives in the rootfs, not in the initramfs, so if even the logo
is missing the rootfs was never mounted.

The halium initramfs does not die quietly in that case. It brings up a
USB RNDIS gadget, runs a DHCP server on it (`192.168.2.20-90`) and
starts telnetd with a root shell. Note the address is **not** the
172.16.42.1 the adaptation uses later:

```
telnet 192.168.2.15
```

Inside, two commands explain almost everything:

```
ls /tmpmnt          # userdata as the initramfs sees it
dmesg | tail -40    # the initramfs logs each decision it makes
```

`/tmpmnt` is the mounted userdata. `identify_file_layout()` looks there
for `rootfs.img`, then `ubuntu.img`, then a `halium-rootfs` directory,
and if none of them exist it falls through to assuming the rootfs sits
on the system partition, which on this device it does not. That
fall-through is silent, and it is the usual cause of a boot with no
logo: the image is missing, misnamed, or landed somewhere else.
