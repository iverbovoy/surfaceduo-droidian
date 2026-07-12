#!/bin/bash
# Install the Droidian packaging into the Surface Duo downstream kernel
# tree (kernel/surface-duo-oss-kernel.msm-4.14). Idempotent: run again
# after editing anything here.
#
# Layout it produces in the kernel tree:
#   debian/    - packaging (control, rules, kernel-info.mk, ...)
#   droidian/  - kernel config fragments (device + common 4.14-android)
#
# Build afterwards inside the Droidian build container (debs land one
# level above the sources mount, i.e. in kernel/packages):
#   docker run --rm \
#     -v "$(pwd)/../packages:/buildd" \
#     -v "$(pwd)/../surface-duo-oss-kernel.msm-4.14:/buildd/sources" \
#     quay.io/droidian/build-essential:current-amd64 \
#     sh -c 'cd /buildd/sources && rm -f debian/control && debian/rules debian/control && RELENG_HOST_ARCH=arm64 releng-build-package'

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_TREE="$SCRIPT_DIR/../surface-duo-oss-kernel.msm-4.14"
FRAGMENTS_REPO="$SCRIPT_DIR/../common_fragments"

if [ ! -d "$KERNEL_TREE/arch/arm64/configs/vendor" ]; then
    echo "ERROR: kernel tree not found at $KERNEL_TREE"
    exit 1
fi

if [ ! -f "$FRAGMENTS_REPO/halium.config" ]; then
    echo "ERROR: common_fragments (branch 4.14-android) not found at $FRAGMENTS_REPO"
    echo "  git clone https://github.com/droidian-devices/common_fragments.git"
    echo "  git -C common_fragments checkout 4.14-android"
    exit 1
fi

# kernel-snippet.mk hardcodes droidian/common_fragments/{halium,droidian}.config;
# the rest (container.config etc.) goes through KERNEL_CONFIG_EXTRA_FRAGMENTS.
rsync -a --delete "$SCRIPT_DIR/debian/" "$KERNEL_TREE/debian/"
mkdir -p "$KERNEL_TREE/droidian/common_fragments"
rsync -a "$SCRIPT_DIR/droidian/" "$KERNEL_TREE/droidian/"
rsync -a "$FRAGMENTS_REPO"/*.config "$KERNEL_TREE/droidian/common_fragments/"

echo "Packaging installed into $KERNEL_TREE"
ls "$KERNEL_TREE/debian" "$KERNEL_TREE/droidian"
