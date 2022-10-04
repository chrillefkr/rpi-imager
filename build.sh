#!/bin/bash
set -eufo pipefail
set -x

debootstrap_deb_cache_path="$( realpath ./deb-cache )"
debootstrap_fs_cache_path="$( realpath ./fs-cache )"

snapshot_mirror="https://snapshot.debian.org/archive/debian/20210614T023909Z/"

MIRROR="${MIRROR:-$snapshot_mirror}"

skip_debootstrap="${skip_debootstrap:-no}"

image_file="./pimox.img"
image_file_real="$( realpath "$image_file" )"

boot_label="RASPIFIRM"
root_label="RASPIROOT"

packages=(
    ca-certificates
    dosfstools
    iw
    parted
    ssh
    wpasupplicant
    systemd-timesyncd
    linux-image-arm64
    raspi-firmware
    firmware-brcm80211
)

trap 'echo Finished cleaning up' EXIT

log() { printf '%s\n' "$*"; }
error() { log "ERROR: $*" >&2; }
fatal() { error "$@"; exit 1; }

trap_add() {
    trap_add_cmd=$1
    shift || fatal "${FUNCNAME} usage error"
    for trap_add_name in "$@"; do
        trap -- "$(
            # helper fn to get existing trap command from output of trap -p
            extract_trap_cmd() { printf '%s\n' "$3"; }
            # print the new trap command
            printf '%s\n' "${trap_add_cmd}"
            # print existing trap command with newline
            eval "extract_trap_cmd $(trap -p "${trap_add_name}")"
        )" "${trap_add_name}" \
            || fatal "unable to add to trap ${trap_add_name}"
    done
}


qemu-img create -f raw "$image_file_real" 2048M

sudo parted -s "$image_file_real" mklabel msdos

sudo parted -s "$image_file_real" -- mkpart primary fat32 4MiB 20%

sudo parted -s "$image_file_real" -- mkpart primary ext2 20% 100%

#sudo kpartx -asv "$image_file" 2>&1
#trap_add 'sudo kpartx -d "$image_file";' EXIT
sudo losetup --show -Pf "$image_file_real"

blockdev="$( sudo losetup -j "$image_file_real" | cut -d':' -f1 | head -n1 )"
trap_add 'sudo losetup -d "$blockdev";' EXIT

if [ -z "$blockdev" ]; then
    echo "Couldn't find block device. Exiting"
    exit
fi

#readarray partitions < <(sudo kpartx -r "$image_file" | cut -d' ' -f1) &>/dev/null
readarray -t partitions < <(sudo lsblk "$blockdev" -o path | tail -n +3) &>/dev/null


#echo "${partitions[@]}"
#echo "part1: ${partitions[0]};"
#echo "part2: ${partitions[1]};"

bootdev="${partitions[0]}"
rootdev="${partitions[1]}"

sudo /sbin/mkfs -t vfat -n RASPIFIRM "${bootdev}"
sudo /sbin/mkfs -F -t ext4 -L RASPIROOT "${rootdev}"

root_mountpoint="$( mktemp -d )"
boot_mountpoint="${root_mountpoint}/boot/firmware"
trap_add "rmdir -v \"$root_mountpoint\";" EXIT

sudo mount "$rootdev" "${root_mountpoint}"
trap_add 'sudo umount "${root_mountpoint}"' EXIT

sudo mkdir -p "${boot_mountpoint}"

sudo mount "$bootdev" "${boot_mountpoint}"
trap_add 'sudo umount "${boot_mountpoint}"' EXIT

mkdir -p "$debootstrap_fs_cache_path"

if [ "x$skip_debootstrap" != "xyes" ]; then
    sudo mkdir -p "$debootstrap_deb_cache_path"
    sudo chown root: "$debootstrap_fs_cache_path"
    sudo debootstrap --cache-dir "$debootstrap_deb_cache_path" --arch arm64 --variant -  --components main,contrib,non-free bullseye "$debootstrap_fs_cache_path" "$MIRROR"
fi

sudo cp -a "$debootstrap_fs_cache_path/." "$root_mountpoint/"


cat <<EOF | sudo tee "${root_mountpoint}/etc/apt/sources.list" >/dev/null
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
# Backports are _not_ enabled by default.
# Enable them by uncommenting the following line:
# deb http://deb.debian.org/debian bullseye-backports main contrib non-free
EOF

function rootfs_copy {
    file="$1"
    perm="${2:-0755}"
    dest="${root_mountpoint}/$file"
    dest_dir="$( dirname "$dest" )"
    sudo mkdir -p "$dest_dir"
    sudo cp -av "image-specs/image-specs/rootfs/$file" "$dest"
    chmod "$perm" "$dest"
}

function chroot_run {
    sudo chroot "$root_mountpoint" $@
}


#cp -av image-specs/image-specs/rootfs/etc/initramfs-tools/hooks/rpi-resizerootfs "${root_mountpoint}"
rootfs_copy /etc/initramfs-tools/hooks/rpi-resizerootfs
rootfs_copy /etc/initramfs-tools/scripts/local-bottom/rpi-resizerootfs

chroot_run apt-get update
chroot_run apt-get install ${packages[@]}

install -m 644 -o root -g root image-specs/rootfs/etc/fstab "${root_mountpoint}/etc/fstab"

install -m 644 -o root -g root image-specs/rootfs/etc/network/interfaces.d/eth0 "${root_mountpoint}/etc/network/interfaces.d/eth0"
install -m 600 -o root -g root image-specs/rootfs/etc/network/interfaces.d/wlan0 "${root_mountpoint}/etc/network/interfaces.d/wlan0"

install -m 755 -o root -g root image-specs/rootfs/usr/local/sbin/rpi-set-sysconf "${root_mountpoint}/usr/local/sbin/rpi-set-sysconf"
install -m 644 -o root -g root image-specs/rootfs/etc/systemd/system/rpi-set-sysconf.service "${root_mountpoint}/etc/systemd/system/"
install -m 644 -o root -g root image-specs/rootfs/boot/firmware/sysconf.txt "${root_mountpoint}/boot/firmware/sysconf.txt"
mkdir -p "${root_mountpoint}/etc/systemd/system/basic.target.requires/"
ln -s /etc/systemd/system/rpi-set-sysconf.service "${root_mountpoint}/etc/systemd/system/basic.target.requires/rpi-set-sysconf.service"

# Resize script is now in the initrd for first boot; no need to ship it.
rm -f "${root_mountpoint}/etc/initramfs-tools/hooks/rpi-resizerootfs"
rm -f "${root_mountpoint}/etc/initramfs-tools/scripts/local-bottom/rpi-resizerootfs"

install -m 644 -o root -g root image-specs/rootfs/etc/systemd/system/rpi-reconfigure-raspi-firmware.service "${root_mountpoint}/etc/systemd/system/"
mkdir -p "${root_mountpoint}/etc/systemd/system/multi-user.target.requires/"
ln -s /etc/systemd/system/rpi-reconfigure-raspi-firmware.service "${root_mountpoint}/etc/systemd/system/multi-user.target.requires/rpi-reconfigure-raspi-firmware.service"

install -m 644 -o root -g root image-specs/rootfs/etc/systemd/system/rpi-generate-ssh-host-keys.service "${root_mountpoint}/etc/systemd/system/"
ln -s /etc/systemd/system/rpi-generate-ssh-host-keys.service "${root_mountpoint}/etc/systemd/system/multi-user.target.requires/rpi-generate-ssh-host-keys.service"
rm -f "${root_mountpoint}"/etc/ssh/ssh_host_*_key*


chroot_run install -m 644 -o root -g root /usr/lib/linux-image-*-arm64/broadcom/bcm*rpi*.dtb /boot/firmware/
chroot_run apt-get clean
chroot_run rm -rf /var/lib/apt/lists


chroot_run sed -i 's/root=/console=ttyS1,115200 root=/' /boot/firmware/cmdline.txt
chroot_run sed -i 's#root=/dev/mmcblk0p2#root=LABEL=RASPIROOT#' /boot/firmware/cmdline.txt
chroot_run sed -i 's/^#ROOTPART=.*/ROOTPART=LABEL=RASPIROOT/' /etc/default/raspi*-firmware

chroot_run sed -i 's/cma=64M //' /boot/firmware/cmdline.txt

chroot_run rm "${ROOT?}/etc/resolv.conf"

chroot_run rm -f /etc/machine-id /var/lib/dbus/machine-id


echo "Now exiting"

exit

