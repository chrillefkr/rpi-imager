#!/bin/bash
set -eufo pipefail

log() { printf '%s\n' "$*"; }
error() { log "ERROR: $*" >&2; }
fatal() { error "$@"; exit 1; }

trap_add() {
    trap_add_cmd=$1; shift || fatal "${FUNCNAME} usage error"
    for trap_add_name in "$@"; do
        trap -- "$(
            # helper fn to get existing trap command from output
            # of trap -p
            extract_trap_cmd() { printf '%s\n' "$3"; }
            # print existing trap command with newline
            eval "extract_trap_cmd $(trap -p "${trap_add_name}")"
            # print the new trap command
            printf '%s\n' "${trap_add_cmd}"
        )" "${trap_add_name}" \
            || fatal "unable to add to trap ${trap_add_name}"
    done
}

MIRROR=

blockdev="./pimox.img"
mountpoint="$( mktemp -d )"
trap_add 'rmdir -v "$mountmoint;' EXIT

parted=/usr/sbin/parted

qemu-img create -f raw "$blockdev" 2048M
#fallocate -l 2000M "$blockdev"
#dd if=/dev/zero of="$blockdev" bs=1024 count="$( python -c 'print(1024*2000)' )"

$parted -s "$blockdev" mklabel msdos

$parted -s "$blockdev" -- mkpart primary fat32 4MiB 20%

$parted -s "$blockdev" -- mkpart primary ext2 20% 100%

_partitions="$(sudo kpartx -asv "$blockdev" 2>&1)"
readarray partitions < <(sudo kpartx -r "$blockdev" | cut -d' ' -f1)

trap_add 'sudo kpartx -d "$blockdev";' EXIT

echo "${partitions[@]}"
echo "part1: ${partitions[0]};"
echo "part2: ${partitions[1]};"

bootdev="${partitions[0]}"
rootdev="${partitions[1]}"

/sbin/mkfs -t vfat -n RASPIFIRM "${bootdev}"



