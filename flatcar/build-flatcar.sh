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

# Logging output of Flatcar build scripts..
BUILD_LOG="${WORKDIR}/flatcar/build-flatcar.log"
exec > >(tee -a "${BUILD_LOG}") 2>&1

echo "=== Building Flatcar Container Linux image ($(date -u '+%F %T UTC')) ==="

[ ! -d "${WORKDIR}/flatcar/scripts" ] && die "no such directory: ${WORKDIR}/flatcar/scripts"

cmdcheck docker

# need qemu-user-static for arm64 cross-build
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    die "qemu-user-static is not installed or binfmt is not registered. Install with: sudo apt install qemu-user-static"
fi

dieif cd "${WORKDIR}/flatcar/scripts"

# Save version file
VERSION_FILE="${WORKDIR}/flatcar/scripts/sdk_container/.repo/manifests/version.txt"
VERSION_FILE_BAK="$(mktemp)"
cp "${VERSION_FILE}" "${VERSION_FILE_BAK}"

extract_portage_logs() {
    echo "--- Copying portage build logs to host ---"
    # Copy portage log files
    local dest="${WORKDIR}/flatcar/portage-logs"
    rm -rf "${dest}"
    docker cp "${FLATCAR_CONTAINER_NAME}:/build/${FLATCAR_BOARD}/var/log/portage" \
        "${dest}" 2>/dev/null || \
        echo "WARNING: could not copy portage logs (container may not exist)"
}

cleanup() {
    # Capture the exit code first
    local exit_code=$?

    # Restore version file
    cp "${VERSION_FILE_BAK}" "${VERSION_FILE}"
    rm -f "${VERSION_FILE_BAK}"

    if [ "${exit_code}" -ne 0 ]; then
        # On failure, get the portage log filess out and point the user to them.
        extract_portage_logs
        echo ""
        echo "=================================================================="
        echo "ERROR: Flatcar build failed (exit code ${exit_code})"
        echo "Logs for investigation:"
        echo "  - Full build log : ${BUILD_LOG}"
        echo "  - Portage logs   : ${WORKDIR}/flatcar/portage-logs/"
        echo "=================================================================="
    fi
}
trap cleanup EXIT

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

# Bind-mount a host artifacts directory onto the container-side FLATCAR_ARTIFACT_ROOT.
HOST_ARTIFACT_DIR="${WORKDIR}/flatcar/artifacts"
dieif mkdir -p "${HOST_ARTIFACT_DIR}"
ARTIFACT_MOUNT=(-m "${HOST_ARTIFACT_DIR}:${FLATCAR_ARTIFACT_ROOT}")

# create version.txt
(
    source sdk_lib/sdk_container_common.sh
    create_versionfile "${sdk_version}" "${flatcar_version}"
)

# Configure wget User-Agent so that distfile downloads succeed from crate.io.
echo "--- Flatcar: Configuring wget User-Agent for distfile fetches ---"
dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" \
    -a "${FLATCAR_ARCH}" -v "${flatcar_version}" \
    -C "${sdk_image}" "${ARTIFACT_MOUNT[@]}" \
    sudo tee -a /etc/wgetrc \
    <<<'user_agent = sodev-flatcar-build/1.0 (+https://github.com/example/repo)'

# Step1: build packages
echo "--- Flatcar: Building packages ---"
dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" \
    -a "${FLATCAR_ARCH}" -v "${flatcar_version}" \
    -C "${sdk_image}" "${ARTIFACT_MOUNT[@]}" \
    ./build_packages --board="${FLATCAR_BOARD}" --nogetbinpkg

# Step2: build image
echo "--- Flatcar: Building image ---"
dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
    "${ARTIFACT_MOUNT[@]}" \
    ./set_official --board="${FLATCAR_BOARD}" --noofficial

dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
    "${ARTIFACT_MOUNT[@]}" \
    ./build_image --board="${FLATCAR_BOARD}" \
        --output_root="${FLATCAR_ARTIFACT_ROOT}" --nogetbinpkg --replace \
        prod

# Step3: convert image to qemu uefi image
echo "--- Flatcar: Converting to QEMU UEFI image ---"
dieif ./run_sdk_container -n "${FLATCAR_CONTAINER_NAME}" -a "${FLATCAR_ARCH}" \
    "${ARTIFACT_MOUNT[@]}" \
    ./image_to_vm.sh --format "qemu_uefi" --board="${FLATCAR_BOARD}" \
        --from "${FLATCAR_ARTIFACT_ROOT}/${FLATCAR_BOARD}/latest" \
        --image_compression_formats=none --nogetbinpkg

# copy build artifacts (read from the host-side artifacts directory)
FLATCAR_OUTPUT="${HOST_ARTIFACT_DIR}/${FLATCAR_BOARD}/latest"
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
