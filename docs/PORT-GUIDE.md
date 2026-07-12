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
python3 tools/mkbootimg/mkbootimg.py --header_version 2 \
  --kernel Image.gz --ramdisk <droidian-initramfs> --dtb stock.dtb \
  --pagesize 4096 --base 0x0 --kernel_offset 0x8000 \
  --ramdisk_offset 0x1000000 --second_offset 0xf00000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version 11.0.0 --os_patch_level 2023-08 \
  --cmdline "<stock cmdline> console=tty0 datapart=/dev/sda6 droidian.lvm.prefer" \
  -o boot-duo1-droidian.img
tools/flash-safely.sh validate boot-duo1-droidian.img
```

The DTB **must** be the generic wildcard extracted from your stock
image (see SAFETY.md, "DTB scheme" - this was our silent-death root
cause). The ramdisk comes from the droidian kernel deb / nightly.
The full working cmdline (stock + droidian additions) is in
`kernel-packaging/debian/kernel-info.mk` (`KERNEL_BOOTIMAGE_CMDLINE`).

## 3. Rootfs

Droidian nightly `rootfs api30 arm64` (phosh phone variant). From TWRP:

```
mke2fs -t ext4 /dev/block/sda6           # userdata, wipes Android!
mount /dev/block/sda6 /data
adb push rootfs.img /data/rootfs.img     # verify sha256 after push
resize2fs /data/rootfs.img 8G            # give apt some room
```

The halium initramfs finds `/data/rootfs.img` by the `datapart=`
cmdline argument and loop-mounts it as /.

## 4. Adaptation

Build and inject `adaptation/` (see its README): USB RNDIS access +
sshd (the nightly ships none), the touch udev rule, bluetooth fixes
(start timeout + board-address), vendor-daemon taming with early ADSP
boot (without it the system I/O-deadlocks ~2 minutes after boot), the
suspend hooks and the geoclue/GPS drop-in. Loop-mount the rootfs image from TWRP
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
new RNDIS interface appears on the host. Tell NetworkManager to leave
it alone, then ssh in:

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
(kernel spi-hid → vendor touchpen HAL → uinput → udev rule). Phosh
treats the two panels as one span, so centered UI falls into the hinge
gap - a compositor-level fix is future work.

## Debug channels, in order of preference

1. ssh (adaptation package).
2. Persistent journald (`Storage=persistent` drop-in must sort AFTER
   droidian's `10-journald-volatile.conf` - name it `99-*`).
3. TWRP + loop-mount of rootfs.img - post-mortem file inspection.
4. pstore/ramoops after a crash (needs the ramoops DT node variant).
