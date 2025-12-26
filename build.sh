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

[ ! -d "external/meta-rcar-demo" ] && die "no such directory: external/meta-rcar-demo"

# Temporary workaround for using out-of-tree PCIe firmware
if [ ! -f "external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin" ]; then
    dieif mkdir -p external/meta-rcar-demo/firmware
    dieif curl -o external/meta-rcar-demo/firmware/rcar_gen4_pcie.bin 'https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rcar_gen4_pcie.bin?id=e56e0a4c8985ec8559aa7b8a831cb841dc8505e6'
fi

./external/meta-rcar-demo/build.sh -a -u -v -r
