# Raspberry Pi Imager

## Why not just fork image-specs ?

Had problems with vmdb2. Couldn't enable old repos nor trust pimox gpg keys without modifying source.
I also want LVM out of the box.

## Requirements

```bash
git submodule update --init
```

### Debian

```bash
apt install -y qemu-utils kpartx parted dosfstools lvm2 debootstrap binfmt-support e4fsprogs 
```

