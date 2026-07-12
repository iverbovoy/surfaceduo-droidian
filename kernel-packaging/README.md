# Droidian kernel packaging - Surface Duo 1 (surfaceduo)

Package the stock msm-4.14 downstream kernel (branch
`surfaceduo/11/2022.902.48`) the Droidian way, so the stock Android 11
vendor HALs drive display/touch/WiFi/sensors via libhybris.

Clone the kernel tree and the common fragments into the repo root:

```
git clone --depth 1 -b surfaceduo/11/2022.902.48 \
  https://github.com/microsoft/surface-duo-oss-kernel.msm-4.14
git clone -b 4.14-android https://github.com/droidian-devices/common_fragments.git
```

## Layout

- `debian/` - Droidian kernel packaging (miatoll used as the msm-4.14
  reference). `debian/control` is *generated* from `kernel-info.mk` by
  `debian/rules debian/control`; the checked-in copy is a bootstrap.
- `droidian/surfaceduo.config` - device config fragment.
  Careful with comments: merge_config.sh treats any `# CONFIG_FOO ...`
  line as "unset CONFIG_FOO".
- `setup.sh` - rsyncs `debian/` + `droidian/` + the common 4.14-android
  fragments (from `../common_fragments`, gitignored clone) into the
  kernel tree.

## Build

Apply the kernel patches once per fresh clone (what they do: see
"Kernel patches" at the bottom):

```
git -C ../surface-duo-oss-kernel.msm-4.14 apply \
  "$PWD"/patches/0001-dwc3-msm-force-suspend-when-not-in-lpm.patch \
  "$PWD"/patches/0002-adsprpc-ratelimit-bad-ioctl-log.patch \
  "$PWD"/patches/0004-ext4-remove-android-umount_end-hook.patch
# 0003 applies inside techpack/audio - see "Audio modules" below
# 0005 applies to the boot ramdisk - tools/make-boot-image.sh does it
```

Skipping 0004 gets you a phone that freezes under I/O load and 40 s
GPS/geoclue startups - see `docs/FREEZE-FORENSICS.md`.

Then:

```
./setup.sh
cd ..
docker run --rm \
  -v "$PWD/packages:/buildd" \
  -v "$PWD/surface-duo-oss-kernel.msm-4.14:/buildd/sources" \
  quay.io/droidian/build-essential:current-amd64 \
  sh -c 'apt-get update -qq && apt-get install -y -qq linux-packaging-snippets && cd /buildd/sources && rm -f debian/control && debian/rules debian/control && RELENG_HOST_ARCH=arm64 releng-build-package'
```

(Newer `build-essential` images no longer ship
`linux-packaging-snippets`, and `debian/rules debian/control` needs it
before the build-deps step can install anything - hence the explicit
install.)

Debs land in `packages/` at the repo root. boot.img lives inside
`linux-bootimage-4.14-190-microsoft-surfaceduo_*.deb` (`dpkg -x`), copy
it to `out/boot-duo1-droidian.img` and run
`./tools/flash-safely.sh validate` before it goes anywhere near the
device. FLASH_ENABLED is 0 on purpose: apt must never flash boot -
only `tools/flash-safely.sh` does.

## Choices that need re-checking on hardware

- `datapart=/dev/sda6` in the cmdline (userdata, confirmed on device).
- api30 GSI rootfs (Android 11 vendor - matches build 2022.902.48);
  verify `ro.vendor.build.version.sdk` == 30 during the session.
- Toolchain clang-android-9.0 (stock used clang 8.0).
- dtbo: we build dtbo.img but keep the STOCK dtbo partition.

## WiFi module (qcacld-3.0)

The vendor partition's prebuilt `qca_cld3_wlan.ko` will NOT load into
this kernel (module_layout CRC mismatch - the Halium config fragments
shift the ABI). Build it from Microsoft's own OSS sources against your
kernel build instead:

```
for r in qcacld-3..0 qca-wifi-host-cmn fw-api; do
  git clone --depth 1 -b surfaceduo/11/2022.902.48 \
    https://github.com/microsoft/surface-duo-oss-platform.vendor.qcom-opensource.wlan.$r \
    wlan/${r/qcacld-3..0/qcacld-3.0}
done
# in the droidian build container, after the kernel build:
make -C <kernel> O=out/KERNEL_OBJ ARCH=arm64 CC=clang \
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- \
  M=<abs>/wlan/qcacld-3.0 WLAN_ROOT=<abs>/wlan/qcacld-3.0 \
  WLAN_COMMON_ROOT=../qca-wifi-host-cmn \
  WLAN_COMMON_INC=<abs>/wlan/qca-wifi-host-cmn \
  WLAN_FW_API=<abs>/wlan/fw-api \
  MODNAME=wlan WLAN_PROFILE=default CONFIG_QCA_CLD_WLAN=m -j$(nproc) modules
aarch64-linux-gnu-strip --strip-debug wlan/qcacld-3.0/wlan.ko
```

Requires `CONFIG_MODULE_SIG_FORCE=n` (already in the device fragment).
Drop the stripped `wlan.ko` at `out/wlan.ko` (repo root) - the
adaptation package picks it up and autoloads it before NetworkManager.
The Android container's ueventd serves the firmware requests
(`wlan/qca_cld/WCNSS_qcom_cfg.ini`) - no extra plumbing needed.

## Audio modules (techpack)

Clone microsoft/surface-duo-oss-platform.vendor.opensource.audio-kernel
(same branch) INTO the kernel tree as `techpack/audio`, then a plain
`make ... AUDIO_BLD_DIR=/src modules` builds 23 `*_dlkm.ko`. Two fixups
(see patches/0003-audio-kernel-build-fixups.patch): add private-header include paths to
`soc/Kbuild`, and repoint the dangling `include/soc/internal.h` symlink
(it assumes the repo-manifest layout) to
`../../../../drivers/base/regmap/internal.h`. The card only registers if
the ADSP is booted BEFORE `apr_dlkm` loads - the adaptation's
`sfduo-audio.service` handles the ordering. Codec answers as TAVIL
(wcd934x); the pahu DT node stays silent (-6) - that is normal.

Copy the built modules to where `adaptation/package/build.sh` picks
them up:

```
mkdir -p out/audio-modules   # at the repo root
find <kernel>/out/KERNEL_OBJ/techpack -name '*.ko' -exec cp {} out/audio-modules/ \;
```

## Kernel patches (patches/)

- `dwc3-msm.c`: in peripheral mode nothing drives the OTG state machine
  to IDLE, so the controller never reaches LPM and EVERY system suspend
  aborts with -EBUSY. The patch forces `dwc3_msm_suspend()` from the PM
  callbacks instead of aborting.
- Also needed: droidian ships `AllowSuspend=no` - the adaptation
  overrides it; a system-sleep hook parks/restores the USB gadget.
- Wake: LONG power-button press. RTC alarms do not yet fire through
  deep sleep (open item), and there is no autosleep governor yet.
- `adsprpc.c`: `pr_info` → `pr_info_ratelimited` for the "bad ioctl"
  retry noise.
- `initramfs` (0005, applies to `scripts/halium` INSIDE the boot
  ramdisk, not to the kernel tree): the halium initramfs mounts an ext4
  userdata with `data=journal` - a 2014 Ubuntu Touch workaround
  (lp#1387214). With the rootfs being a loop-mounted image ON that
  partition, every root write goes through the outer journal twice;
  under write bursts (a plain `dpkg -i` is enough) jbd2 starves and the
  loop device throws failing bios - the system stalls for minutes.
  `data=ordered` (the modern ext4 default) fixes it: a 300MB fsync
  burst runs clean at full UFS speed. `tools/make-boot-image.sh`
  applies this patch automatically when assembling the boot image.
  Trade-off, stated honestly: lp#1387214 was about data loss on dirty
  power-offs of 2014-era eMMC devices. With `data=ordered` a sudden
  power cut can lose recently written file *content* (not filesystem
  consistency - the journal still covers metadata). If you see
  userdata damage after hard power cuts, this is the knob you traded.
  Evidence for both fixes: `docs/FREEZE-FORENSICS.md`.
- `ext4/super.c` (0004): remove the Android-only `umount_end` hook. It
  fired on every user umount(2) while the superblock was still active
  in another namespace - i.e. on every systemd sandbox teardown of the
  loop-backed root - silently switched the error policy to remount-ro
  and issued a synchronous `ext4_commit_super()` against the live
  filesystem. Under systemd this escalates harmless journald write
  hiccups into a read-only root ("the phone freezes but still pings").
  Mainline ext4 has no such hook; droidian does not need Android's
  skip-fsck-on-reboot semantics. Likely relevant to every
  Droidian/Halium port on an msm-4.14 kernel.
