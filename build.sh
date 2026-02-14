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

cmdcheck moulin ninja

workdir="$PWD"

[ ! -d "external/meta-rcar-demo" ] && die "no such directory: external/meta-rcar-demo"

# Temporary workaround for using out-of-tree PCIe firmware
if [ ! -f "external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin" ]; then
    dieif mkdir -p external/meta-rcar-demo/firmware
    dieif curl -o external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin 'https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rcar_gen4_pcie.bin?id=e56e0a4c8985ec8559aa7b8a831cb841dc8505e6'
fi

# build AGL images
agl_branch="trout"
agl_version="trout_20.0.2"
local_conf_patch_tag="### This is modified by build.sh ###"

dieif cd "$workdir/agl"
if [ ! -d "meta-agl" ]; then
    dieif repo init -b "$agl_branch" -m "$agl_version".xml -u https://gerrit.automotivelinux.org/gerrit/AGL/AGL-repo
    dieif repo sync -j8
fi

IFS=$'\n' read -rd '' -a patches <<< "$(ls patches/meta-agl/*.patch 2>/dev/null | xargs realpath 2>/dev/null)"
for patch in "${patches[@]}"; do
    ! git -C meta-agl apply --reverse --check "$patch" 2>/dev/null && dieif git -C meta-agl am "$patch" && echo "$patch applied"
done
IFS=$'\n' read -rd '' -a patches <<< "$(ls patches/meta-agl-demo/*.patch 2>/dev/null | xargs realpath 2>/dev/null)"
for patch in "${patches[@]}"; do
    ! git -C meta-agl-demo apply --reverse --check "$patch" 2>/dev/null && dieif git -C meta-agl-demo am "$patch" && echo "$patch applied"
done

if [ -f patches/local.conf ] && ! grep -q "$local_conf_patch_tag" build/conf/local.conf; then
    echo "$local_conf_patch_tag" >> build/conf/local.conf
    cat patches/local.conf >> build/conf/local.conf
    echo "local.conf modified"
fi

# Separate the sourcing of aglsetup.sh into a subshell to avoid affecting the current shell environment,
# ensuring subsequent moulin commands are not impacted by environment changes.
dieif bash -c " \
    source meta-agl/scripts/aglsetup.sh -m virtio-aarch64 -b build agl-demo agl-devel agl-kvm && \
    cd "$workdir/agl" && \
    if [ -e site.conf ]; then cd build/conf && ln -sfr ../../site.conf && cd ../..; fi && \
    bitbake agl-ivi-demo-flutter-guest agl-cluster-demo-flutter-guest \
    "
dieif cd "$workdir"

./external/meta-rcar-demo/build.sh -a -u -v -r
