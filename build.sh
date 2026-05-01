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

# setting value for flatcar
ENABLE_FLATCAR_BUILD=yes
FLATCAR_ARCH=arm64
FLATCAR_BOARD="${FLATCAR_ARCH}-usr"
FLATCAR_CONTAINER_NAME=flatcar-sodev-build
FLATCAR_ARTIFACT_ROOT=/home/sdk/trunk/src/scripts/artifacts

cmdcheck moulin ninja

workdir="$PWD"

[ ! -d "external/meta-rcar-demo" ] && die "no such directory: external/meta-rcar-demo"

# Temporary workaround for using out-of-tree PCIe firmware
if [ ! -f "external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin" ]; then
    dieif mkdir -p external/meta-rcar-demo/firmware
    dieif curl -o external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin 'https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rcar_gen4_pcie.bin?id=e56e0a4c8985ec8559aa7b8a831cb841dc8505e6'
fi

# Build flatcar custum image
if [ "${ENABLE_FLATCAR_BUILD}" = "yes" ]; then
    echo "=== Building Flatcar Container Linux image ==="

    [ ! -d "flatcar/scripts" ] && die "no such directory: flatcar/scripts"

    cmdcheck docker

    # need to qemu-user-static
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        die "qemu-user-static is not installed or binfmt is not registered. Install with: sudo apt install qemu-user-static"
    fi

    dieif cd "$workdir/flatcar/scripts"

    # --- setting env---
    source ci-automation/ci_automation_common.sh
    source sdk_container/.repo/manifests/version.txt

    flatcar_version="alpha-${FLATCAR_VERSION_ID}"
    check_version_string "${flatcar_version}"
    sdk_version="${CUSTOM_SDK_VERSION:-$FLATCAR_SDK_VERSION}"

    # sdk container
    sdk_name="flatcar-sdk-${FLATCAR_ARCH}"
    docker_sdk_vernum="$(vernum_to_docker_image_version "${sdk_version}")"
    sdk_image="$(docker_image_fullname "${sdk_name}" "${docker_sdk_vernum}")"

    # create version.txt
    (
        source sdk_lib/sdk_container_common.sh
        create_versionfile "${sdk_version}" "${flatcar_version}"
    )

    # Step1: build packages
    echo "--- Flatcar: Building packages ---"
    dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" \
        -a "${FLATCAR_ARCH}" -v "${flatcar_version}" \
        -C "${sdk_image}" \
        ./build_packages --board="${FLATCAR_BOARD}" --nousepkg --nogetbinpkg

    # Step2: build image
    echo "--- Flatcar: Building image ---"
    dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
        ./set_official --board="${FLATCAR_BOARD}" --noofficial

    dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
        ./build_image --board="${FLATCAR_BOARD}" \
            --output_root="${FLATCAR_ARTIFACT_ROOT}" --nogetbinpkg --replace \
            prod oem_sysext

    # Step3: convert image to qemu uefi image
    echo "--- Flatcar: Converting to QEMU UEFI image ---"
    dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" --rm -a "${FLATCAR_ARCH}"\
        ./image_to_vm.sh --format "qemu_uefi" --board="${FLATCAR_BOARD}" \
            --from "${FLATCAR_ARTIFACT_ROOT}/${FLATCAR_BOARD}/latest" \
            --image_compression_formats=none --nogetbinpkg

    # copy build artifacts
    FLATCAR_OUTPUT="artifacts/${FLATCAR_BOARD}/latest"
    if [ -f "${FLATCAR_OUTPUT}/flatcar_production_qemu_uefi_image.img" ]; then
        echo "Copying Flatcar build output..."
        cp "${FLATCAR_OUTPUT}/flatcar_production_qemu_uefi_image.img" \
            "$workdir/flatcar/flatcar_production_qemu_uefi_image.img"
    else
        die "Flatcar build output not found: ${FLATCAR_OUTPUT}/flatcar_production_qemu_uefi_image.img"
    fi

    # get kernel image
    echo "Copying Flatcar kernel from build artifacts..."
    dieif mkdir -p "$workdir/flatcar/kernel"
    dieif cp "${FLATCAR_OUTPUT}/flatcar_production_image.vmlinuz" \
        "$workdir/flatcar/kernel/vmlinuz-a"

    dieif cd "$workdir"
fi

# convert image from qcow to raw 
if [ "${ENABLE_FLATCAR_BUILD}" = "yes" ]; then
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

./external/meta-rcar-demo/build.sh -a -u -v -r -z --enable-flatcar
