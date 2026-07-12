########################################################################
# Kernel settings - Microsoft Surface Duo 1 (surfaceduo, SM8150)
#
# Values mirror the stock MS boot.img (header v2) - same 8 fields that
# tools/flash-safely.sh `validate` checks, and the same offsets already
# proven against this device's stock boot.img.
########################################################################

# Android ("downstream") kernel
VARIANT = android

# Kernel base version (msm-4.14, branch surfaceduo/11/2022.902.48)
KERNEL_BASE_VERSION = 4.14-190

# Stock cmdline (extracted from out/recovery/images/boot.img) plus the
# Droidian bits: console=tty0, datapart (userdata = /dev/sda6 on LUN 0,
# confirmed from live Android) and LVM preference.
KERNEL_BOOTIMAGE_CMDLINE = console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xa90000 androidboot.hardware=surfaceduo androidboot.hardware.platform=qcom androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 loop.max_part=7 androidboot.usbcontroller=a600000.dwc3 kpti=off buildvariant=user console=tty0 datapart=/dev/sda6 droidian.lvm.prefer

DEVICE_VENDOR = microsoft
DEVICE_MODEL = surfaceduo
DEVICE_FULL_NAME = Microsoft Surface Duo

# No init_boot partition on the Duo
DEVICE_HAS_INIT_BOOT = 0

# Base defconfig = stock MS defconfig; Halium/Droidian deltas come from
# configuration fragments (see kernel-snippet.mk). The snippet hardcodes
# droidian/common_fragments/halium.config + droidian.config, then applies
# droidian/surfaceduo.config (device fragment) and the extras below.
KERNEL_CONFIG_USE_FRAGMENTS = 1
KERNEL_CONFIG_EXTRA_FRAGMENTS = common_fragments/container.config
KERNEL_DEFCONFIG = vendor/surfaceduo_defconfig

# Header v2: DTB lives inside boot.img.
# LESSON 2026-07-11 (prime suspect for the session-1 silent death):
# stock boot.img and the proven TWRP image both carry the GENERIC
# wildcard SoC DTB - "SM8150 v2 SoC", board-id (0,0) - and let ABL merge
# the board specifics from the stock dtbo partition. dts/surface/*.dtb
# are full DV/EV prototype boards (the retail board-id is NOT among
# them); shipping those forces ABL to pick a wrong-revision board or
# mis-merge its overlay → silent death in early boot.
#   old (broken): KERNEL_IMAGE_DTB = arch/arm64/boot/dts/surface/*.dtb
# NOTE 2026-07-11: qcom/sm8150-v2.dtb is not a target this tree builds -
# the packaging step died with "DTB image must not be empty". Point at a
# dtb that DOES build so the deb assembles; the deb's boot.img is never
# flashed as-is anyway: the flight image is repacked with the STOCK
# device DTB (out/dtb-sm8150v2-stock.dtb, extracted from this unit's
# boot_b) via tools/mkbootimg + known-good header params.
KERNEL_IMAGE_WITH_DTB = 1
KERNEL_IMAGE_DTB = arch/arm64/boot/dts/surface/surface-duo-dv-a.dtb

# Overlay build disabled (see droidian/surfaceduo.config): the in-tree
# dtc can't compile the .dtbo files and we keep the STOCK dtbo partition
# on the device anyway - ABL merges its overlay onto our base DTB.
KERNEL_IMAGE_WITH_DTB_OVERLAY = 0
KERNEL_IMAGE_WITH_DTB_OVERLAY_IN_KERNEL = 0

# mkbootimg parameters - identical to stock (validated fields)
KERNEL_BOOTIMAGE_PAGE_SIZE = 4096
KERNEL_BOOTIMAGE_BASE_OFFSET = 0x00000000
KERNEL_BOOTIMAGE_KERNEL_OFFSET = 0x00008000
KERNEL_BOOTIMAGE_INITRAMFS_OFFSET = 0x01000000
KERNEL_BOOTIMAGE_SECONDIMAGE_OFFSET = 0x00f00000
KERNEL_BOOTIMAGE_TAGS_OFFSET = 0x00000100
KERNEL_BOOTIMAGE_DTB_OFFSET = 0x01f00000

# Match stock os_version/patch level (ABL on the Duo rejects images with
# an os_version older than the installed stock)
KERNEL_BOOTIMAGE_OS_VERSION = 11.0.0
KERNEL_BOOTIMAGE_PATCH_LEVEL = 2023-08

# Launched with Android 10 → header version 2
KERNEL_BOOTIMAGE_VERSION = 2

# Non-GKI → gzip initramfs, no vendor_boot
KERNEL_INITRAMFS_COMPRESSION = gz
KERNEL_BOOTIMAGE_GENERATE_VENDOR_BOOT = 0

########################################################################
# Android verified boot
########################################################################

# Ship an empty vbmeta.img (disables verified boot). Flashing it is a
# manual decision - same image WOA uses.
DEVICE_VBMETA_REQUIRED = 1
DEVICE_VBMETA_IS_SAMSUNG = 0
KERNEL_BOOTIMAGE_PARTITION_SIZE =

########################################################################
# Automatic flashing on package upgrades
########################################################################

# DISABLED on purpose: all flashing on this device goes through
# tools/flash-safely.sh (RAM-boot gates, health baseline, BCB checks).
# Never let apt flash the boot partition behind our back.
FLASH_ENABLED = 0

FLASH_IS_AONLY = 0
FLASH_IS_LEGACY_DEVICE = 0
FLASH_IS_EXYNOS = 0
FLASH_USE_TELNET = 0
FLASH_INFO_MANUFACTURER = Microsoft
FLASH_INFO_MODEL = Surface Duo
FLASH_INFO_CPU = Qualcomm Technologies, Inc SM8150
FLASH_INFO_DEVICE_IDS = duo

########################################################################
# Kernel build settings
########################################################################

BUILD_CROSS = 1
BUILD_TRIPLET = aarch64-linux-android-
BUILD_CLANG_TRIPLET = aarch64-linux-gnu-
# Stock was built with clang 8.0; Droidian's recommended toolchain for
# Android-10-launch devices is clang-android-9.0 - the closest packaged
# match. Fall back to 6.0-4691093 (or gcc-4.9) if the build trips.
BUILD_CC = clang
BUILD_LLVM = 0
BUILD_SKIP_MODULES = 0
CLANG_VERSION = 9.0-r353983c
CLANG_CUSTOM = 0
BUILD_PATH = /usr/lib/llvm-android-$(CLANG_VERSION)/bin
DEB_TOOLCHAIN = linux-initramfs-halium-generic:arm64, binutils-aarch64-linux-gnu, clang-android-9.0-r353983c, gcc-4.9-aarch64-linux-android, g++-4.9-aarch64-linux-android, libgcc-4.9-dev-aarch64-linux-android-cross
DEB_BUILD_ON = amd64
DEB_BUILD_FOR = arm64
KERNEL_ARCH = arm64
KERNEL_BUILD_TARGET = Image.gz
