#!/bin/bash


usage () {
    cat >&2 <<END
Usage: ${0##*/} [opts]
          -h: show this message
END
}

die () {
    echo >&2 "${0##*/}:${BASH_LINENO[0]}: ERROR:" "$@" && exit 1
}

dieif () {
    local exitcode
    # shellcheck disable=SC2154
    (( echon )) && echo "$@" >&2
    "$@"
    exitcode="$?"
    if [ $exitcode -ne 0 ]; then
        echo >&2 "${0##*/}:${BASH_LINENO[0]}: ERROR: command \"$*\" failed with exit code $exitcode" && exit 1
    fi
}

cmdcheck () {
    local cmd remote die=die
    [ "$1" = "-r" ] && remote=remote && die=dier && shift
    for cmd in "$@"; do
        [ -z "$($remote which "$cmd")" ] && $die "command $cmd not found"
    done
}

build_opts=()

# setting value for flatcar
ENABLE_FLATCAR_BUILD=no
FLATCAR_ARCH=arm64
FLATCAR_BOARD="${FLATCAR_ARCH}-usr"
FLATCAR_CONTAINER_NAME=flatcar-sodev-build
FLATCAR_ARTIFACT_ROOT=/mnt/host/artifacts

[ "$ENABLE_FLATCAR_BUILD" = "yes" ] && build_opts+=(--enable-flatcar)

cmdcheck moulin ninja

workdir="$PWD"

[ ! -d "external/meta-rcar-demo" ] && die "no such directory: external/meta-rcar-demo"

# Temporary workaround for using out-of-tree PCIe firmware
if [ ! -f "external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin" ]; then
    dieif mkdir -p external/meta-rcar-demo/firmware
    dieif curl -o external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin 'https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rcar_gen4_pcie.bin?id=e56e0a4c8985ec8559aa7b8a831cb841dc8505e6'
fi

# Build flatcar custom image
if [ "${ENABLE_FLATCAR_BUILD}" = "yes" ]; then
    dieif env \
        WORKDIR="$workdir" \
        FLATCAR_ARCH="$FLATCAR_ARCH" \
        FLATCAR_BOARD="$FLATCAR_BOARD" \
        FLATCAR_CONTAINER_NAME="$FLATCAR_CONTAINER_NAME" \
        FLATCAR_ARTIFACT_ROOT="$FLATCAR_ARTIFACT_ROOT" \
        bash "$workdir/flatcar/build-flatcar.sh"

    # convert image from qcow to raw 
    if [ -f "flatcar/flatcar_production_qemu_uefi_image.img" ]; then
        # QCOW2 → raw convert
        echo "Converting Flatcar QCOW2 image to raw..."
        cmdcheck qemu-img
        dieif qemu-img convert -f qcow2 -O raw \
            flatcar/flatcar_production_qemu_uefi_image.img \
            flatcar/flatcar_production_qemu_uefi_image.raw
    else
        die "Flatcar build output not found: flatcar_production_qemu_uefi_image.img"
    fi
fi

# build AGL images
agl_branch="trout-sodev"
local_conf_patch_tag="### This is modified by build.sh ###"

dieif cd "$workdir/agl"
if [ ! -d "meta-agl" ]; then
    dieif repo init -b "$agl_branch" -u https://github.com/automotive-grade-linux/AGL-repo.git
    dieif repo sync -j8
fi

if [ -f patches/local.conf ] && ! grep -q "$local_conf_patch_tag" build/conf/local.conf; then
    echo "$local_conf_patch_tag" >> build/conf/local.conf
    cat patches/local.conf >> build/conf/local.conf
    echo "local.conf modified"
fi

# Separate the sourcing of aglsetup.sh into a subshell to avoid affecting the current shell environment,
# ensuring subsequent moulin commands are not impacted by environment changes.
dieif bash -c " \
    source meta-agl/scripts/aglsetup.sh -m virtio-aarch64 -b build agl-demo agl-devel agl-kvm agl-ic && \
    cd "$workdir/agl" && \
    if [ -e site.conf ]; then cd build/conf && ln -sfr ../../site.conf && cd ../..; fi && \
    bitbake agl-ivi-demo-flutter-guest agl-cluster-demo-flutter-guest agl-instrument-cluster-standalone-demo \
    "
dieif cd "$workdir"

./external/meta-rcar-demo/build.sh -u -v -r -z "${build_opts[@]}"
