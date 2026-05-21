#!/bin/bash
# Flatcar custom image build script (called from build.sh)

die () {
    echo >&2 "${0##*/}:${BASH_LINENO[0]}: ERROR:" "$@" && exit 1
}

dieif () {
    local exitcode
    "$@"
    exitcode="$?"
    if [ $exitcode -ne 0 ]; then
        echo >&2 "${0##*/}:${BASH_LINENO[0]}: ERROR: command \"$*\" failed with exit code $exitcode" && exit 1
    fi
}

cmdcheck () {
    local cmd
    for cmd in "$@"; do
        [ -z "$(which "$cmd")" ] && die "command $cmd not found"
    done
}

echo "=== Building Flatcar Container Linux image ==="

[ ! -d "${WORKDIR}/flatcar/scripts" ] && die "no such directory: ${WORKDIR}/flatcar/scripts"

cmdcheck docker

# need qemu-user-static for arm64 cross-build
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    die "qemu-user-static is not installed or binfmt is not registered. Install with: sudo apt install qemu-user-static"
fi

dieif cd "${WORKDIR}/flatcar/scripts"

# --- setting env ---
source ci-automation/ci_automation_common.sh
source sdk_container/.repo/manifests/version.txt

flatcar_version="stable-${FLATCAR_VERSION_ID}"
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
    ./build_packages --board="${FLATCAR_BOARD}" --nogetbinpkg

# Step2: build image
echo "--- Flatcar: Building image ---"
dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
    ./set_official --board="${FLATCAR_BOARD}" --noofficial

dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
    ./build_image --board="${FLATCAR_BOARD}" \
        --output_root="${FLATCAR_ARTIFACT_ROOT}" --nogetbinpkg --replace \
        prod

# Step3: convert image to qemu uefi image
echo "--- Flatcar: Converting to QEMU UEFI image ---"
dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
    ./image_to_vm.sh --format "qemu_uefi" --board="${FLATCAR_BOARD}" \
        --from "${FLATCAR_ARTIFACT_ROOT}/${FLATCAR_BOARD}/latest" \
        --image_compression_formats=none --nogetbinpkg

# copy build artifacts
FLATCAR_OUTPUT="artifacts/${FLATCAR_BOARD}/latest"
if [ -f "${FLATCAR_OUTPUT}/flatcar_production_qemu_uefi_image.img" ]; then
    echo "Copying Flatcar build output..."
    cp "${FLATCAR_OUTPUT}/flatcar_production_qemu_uefi_image.img" \
        "${WORKDIR}/flatcar/flatcar_production_qemu_uefi_image.img"
else
    die "Flatcar build output not found: ${FLATCAR_OUTPUT}/flatcar_production_qemu_uefi_image.img"
fi

# get kernel image
echo "Copying Flatcar kernel from build artifacts..."
dieif mkdir -p "${WORKDIR}/flatcar/kernel"
dieif cp "${FLATCAR_OUTPUT}/flatcar_production_image.vmlinuz" \
    "${WORKDIR}/flatcar/kernel/vmlinuz-a"

echo "=== Flatcar build complete ==="
