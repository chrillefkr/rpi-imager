#!/bin/bash
set -eufo pipefail
set -x

debootstrap_deb_cache_path="$( realpath ./deb-cache )"
debootstrap_fs_cache_path="$( realpath ./fs-cache )"

snapshot_mirror="https://snapshot.debian.org/archive/debian/20210614T023909Z/"

MIRROR="${MIRROR:-$snapshot_mirror}"

skip_debootstrap="${skip_debootstrap:-no}"

IMAGE_FILE="${IMAGE_FILE:-./rpi4_debian.img}"
image_file_real="$( realpath "$IMAGE_FILE" )"


PARTITION_LAYOUT="${PARTITION_LAYOUT:-default}"
partition_layout_dir="$( realpath ./partition_layouts)"
partition_layout_prefix="${partition_layout_dir}/${PARTITION_LAYOUT}"

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

SKIP_PARTITIONING="${SKIP_PARTITIONING:-no}"

if [ "x$SKIP_PARTITIONING" != "xyes" ]; then

    log "Creating image file:" "$image_file_real"

    qemu-img create -f raw "$image_file_real" 2048M

    log "Writing partition table"
    sudo sfdisk "$image_file_real" < "${partition_layout_dir}/${PARTITION_LAYOUT}.sfdisk"

fi

log "Mounting image file (and partitions)"
sudo losetup --show -Pf "$image_file_real"

blockdev="$( sudo losetup -j "$image_file_real" | cut -d':' -f1 | head -n1 )"
trap_add "sudo losetup -vd \"$blockdev\";" EXIT

if [ -z "$blockdev" ]; then
    echo "Couldn't find block device. Exiting"
    exit
fi

readarray -t partitions < <(sudo lsblk "$blockdev" -o path | tail -n +3) &>/dev/null

SKIP_FORMATTING="${SKIP_FORMATTING:-no}"

if [ "x$SKIP_FORMATTING" != "xyes" ]; then

    log "Formating partitions"
    while read -r mountpoint partnum fs label; do
        partition="${partitions[$partnum]}"
        if [ "$fs" == "vfat" ]; then
            if [ -z "$label" ]; then
                sudo mkfs -t vfat "$partition"
            else
                sudo mkfs -t vfat -n "$label" "$partition"
            fi
        elif [ "$fs" == "ext4" ]; then
            if [ -z "$label" ]; then
                sudo mkfs -F -t ext4 "$partition"
            else
                sudo mkfs -F -t ext4 -L "$label" "$partition"
            fi
        elif [ "$fs" == "swap" ]; then
            if [ -z "$label" ]; then
                sudo mkswap "$partition"
            else
                sudo mkswap -L "$label" "$partition"
            fi
        else
            fatal "Filesystem type $fs not yet supported :)"
        fi
    done < <( grep -vE '^\s*#.*$|^$' "${partition_layout_dir}/${PARTITION_LAYOUT}.fs" )
fi

log "Creating root mountpoint"
root_mountpoint="$( mktemp -d )"
trap_add "rmdir -v \"$root_mountpoint\";" EXIT

mountpoints=()

log "Mounting filesystems at:" "$root_mountpoint"
while read -r mountpoint partnum fs label; do
    partition="${partitions[$partnum]}"
    real_mountpoint="${root_mountpoint}/${mountpoint}"

    sudo mkdir -p "${real_mountpoint}"
    sudo mount -v "$partition" "${real_mountpoint}"
    trap_add "sudo umount -vrf \"${real_mountpoint}\"" EXIT
    mountpoints+=("${real_mountpoint}")
done < <( grep -vE '^\s*#.*$|^$' "${partition_layout_dir}/${PARTITION_LAYOUT}.fs" )


log "Mounting bind mounts (dev, proc, etc)"
while read -r p; do
    mp="${root_mountpoint}${p}"
    sudo mkdir -vp "$mp"
    sudo mount --bind "$p" "$mp"
    trap_add "sudo umount -vrf \"${mp}\"" EXIT
done <<EOF
/dev
/dev/pts
/proc
/tmp
EOF


mkdir -p "$debootstrap_fs_cache_path"

if [ "x$skip_debootstrap" != "xyes" ]; then
    sudo mkdir -p "$debootstrap_deb_cache_path"
    sudo rm -rf "${debootstrap_fs_cache_path}"
    mkdir -p "$debootstrap_fs_cache_path"
    sudo chown root: "$debootstrap_fs_cache_path"
    log "Running debootstrap"
    sudo debootstrap --cache-dir "$debootstrap_deb_cache_path" --arch arm64 --variant -  --components main,contrib,non-free bullseye "$debootstrap_fs_cache_path" "$MIRROR"
fi

SKIP_FS_COPY="${SKIP_FS_COPY:-no}"

if [ "x$SKIP_FS_COPY" != "xyes" ]; then
    log "Copying debootstrap fs cache to disk"
    sudo cp -a "$debootstrap_fs_cache_path/." "$root_mountpoint/"
fi


log "Setting /etc/apt/sources.list"
cat <<EOF | sudo tee "${root_mountpoint}/etc/apt/sources.list" >/dev/null
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
# Backports are _not_ enabled by default.
# Enable them by uncommenting the following line:
# deb http://deb.debian.org/debian bullseye-backports main contrib non-free
EOF

function chroot_run {
    sudo chroot "$root_mountpoint" $@
}

log "Installing packages"
chroot_run apt-get update -y
chroot_run apt-get install -y ${packages[@]}

log "Finalizing installation"

#install -m 644 -o root -g root image-specs/rootfs/etc/fstab "${root_mountpoint}/etc/fstab"

sudo install -m 644 -o root -g root "${partition_layout_prefix}.fstab" "${root_mountpoint}/etc/fstab"

sudo install -m 644 -o root -g root image-specs/rootfs/etc/network/interfaces.d/eth0 "${root_mountpoint}/etc/network/interfaces.d/eth0"
sudo install -m 600 -o root -g root image-specs/rootfs/etc/network/interfaces.d/wlan0 "${root_mountpoint}/etc/network/interfaces.d/wlan0"

sudo install -m 755 -o root -g root image-specs/rootfs/usr/local/sbin/rpi-set-sysconf "${root_mountpoint}/usr/local/sbin/rpi-set-sysconf"
sudo install -m 644 -o root -g root image-specs/rootfs/etc/systemd/system/rpi-set-sysconf.service "${root_mountpoint}/etc/systemd/system/"
sudo install -m 644 -o root -g root image-specs/rootfs/boot/firmware/sysconf.txt "${root_mountpoint}/boot/firmware/sysconf.txt"
sudo mkdir -p "${root_mountpoint}/etc/systemd/system/basic.target.requires/"
sudo ln -s /etc/systemd/system/rpi-set-sysconf.service "${root_mountpoint}/etc/systemd/system/basic.target.requires/rpi-set-sysconf.service"

sudo install -m 644 -o root -g root image-specs/rootfs/etc/systemd/system/rpi-reconfigure-raspi-firmware.service "${root_mountpoint}/etc/systemd/system/"
sudo mkdir -p "${root_mountpoint}/etc/systemd/system/multi-user.target.requires/"
sudo ln -s /etc/systemd/system/rpi-reconfigure-raspi-firmware.service "${root_mountpoint}/etc/systemd/system/multi-user.target.requires/rpi-reconfigure-raspi-firmware.service"

sudo install -m 644 -o root -g root image-specs/rootfs/etc/systemd/system/rpi-generate-ssh-host-keys.service "${root_mountpoint}/etc/systemd/system/"
sudo ln -s /etc/systemd/system/rpi-generate-ssh-host-keys.service "${root_mountpoint}/etc/systemd/system/multi-user.target.requires/rpi-generate-ssh-host-keys.service"
sudo rm -f "${root_mountpoint}"/etc/ssh/ssh_host_*_key*


chroot_run install -m 644 -o root -g root /usr/lib/linux-image-*-arm64/broadcom/bcm*rpi*.dtb /boot/firmware/
chroot_run apt-get clean
chroot_run rm -rf /var/lib/apt/lists


chroot_run sed -i 's/root=/console=ttyS1,115200 root=/' /boot/firmware/cmdline.txt
chroot_run sed -i 's#root=/dev/mmcblk0p2#root=LABEL=RASPIROOT#' /boot/firmware/cmdline.txt
chroot_run sed -i 's/^#ROOTPART=.*/ROOTPART=LABEL=RASPIROOT/' /etc/default/raspi*-firmware

chroot_run sed -i 's/cma=64M //' /boot/firmware/cmdline.txt

chroot_run rm "${ROOT?}/etc/resolv.conf"

chroot_run rm -f /etc/machine-id /var/lib/dbus/machine-id


log "Cleaning up image file"

for mountpoint in "${mountpoints[@]}"; do
    sudo umount -vrf "$mountpoint"
done

RUN_DEFRAG="${RUN_DEFRAG:-yes}"
if [ "z$RUN_DEFRAG" == "xyes" ]; then
    for partition in "${partitions[@]}"; do
        sudo e4defrag -v "$partition" || true
    done
fi

RUN_ZEROFREE="${RUN_ZEROFREE:-yes}"
if [ "z$RUN_ZEROFREE" == "xyes" ]; then
    for partition in "${partitions[@]}"; do
        sudo zerofree -v "$partition" || true
    done
fi


exit

