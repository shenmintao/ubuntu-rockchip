#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

function cleanup_loopdev {
    sync --file-system
    sync

    if [ -b "${loop}" ]; then
        umount "${loop}"* 2> /dev/null || true
        losetup -d "${loop}" 2> /dev/null || true
    fi
}
trap cleanup_loopdev EXIT

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p images build && cd build

for rootfs in *.rootfs.tar.xz; do
    if [ ! -e "${rootfs}" ]; then
        echo "Error: could not find any rootfs tarfile, please run build-rootfs.sh"
        exit 1
    fi

    # Create an empty disk image
    img="../images/$(basename "${rootfs}" .rootfs.tar.xz).img"
    size="$(xz -l "${rootfs}" | tail -n +2 | sed 's/,//g' | awk '{print int($5 + 1)}')"
    truncate -s "$(( size + 2048 + 512 ))M" "${img}"

    # Create loop device for disk image
    loop="$(losetup -f)"
    losetup "${loop}" "${img}"
    disk="${loop}"

    # Ensure disk is not mounted
    mount_point=/tmp/mnt
    umount "${disk}"* 2> /dev/null || true
    umount ${mount_point}/* 2> /dev/null || true
    mkdir -p ${mount_point}

    # Setup partition table
    dd if=/dev/zero of="${disk}" count=4096 bs=512
    parted --script "${disk}" \
    mklabel gpt \
    mkpart primary fat32 64MiB 512MiB \
    mkpart primary ext4 512MiB 100%

    set +e

    # Create partitions
    (
    echo t
    echo 1
    echo 1
    echo t
    echo 2
    echo 20
    echo w
    ) | fdisk "${disk}"

    set -eE

    partprobe "${disk}"

    sleep 2

    # Generate random uuid for bootfs
    boot_uuid=$(uuidgen | head -c8)

    # Generate random uuid for rootfs
    root_uuid=$(uuidgen)
    
    # Create filesystems on partitions
    partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"
    mkfs.vfat -i "${boot_uuid}" -F32 -n boot "${disk}${partition_char}1"
    dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 > /dev/null
    mkfs.ext4 -U "${root_uuid}" -L root "${disk}${partition_char}2"

    # Mount partitions
    mkdir -p ${mount_point}/{boot,root} 
    mount "${disk}${partition_char}1" ${mount_point}/boot
    mount "${disk}${partition_char}2" ${mount_point}/root

    # Copy the rootfs to root partition
    echo -e "Decompressing $(basename "${rootfs}")\n"
    tar -xpJf "${rootfs}" -C ${mount_point}/root

    # Create fstab entries
    mkdir -p ${mount_point}/root/boot/firmware
    boot_uuid="${boot_uuid:0:4}-${boot_uuid:4:4}"
    echo "# <file system>      <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/root/etc/fstab
    echo "UUID=${boot_uuid^^}  /boot/firmware vfat    defaults    0       2" >> ${mount_point}/root/etc/fstab
    echo "UUID=${root_uuid,,}  /              ext4    defaults    0       1" >> ${mount_point}/root/etc/fstab
    echo "/swapfile            none           swap    sw          0       0" >> ${mount_point}/root/etc/fstab

    # Extract grub arm64-efi to host system 
    if [ ! -d "/usr/lib/grub/arm64-efi" ]; then
        rm -f /usr/lib/grub/arm64-efi
        ln -s ${mount_point}/root/usr/lib/grub/arm64-efi /usr/lib/grub/arm64-efi
    fi

    # Install grub 
    mkdir -p ${mount_point}/boot/efi/boot
    mkdir -p ${mount_point}/boot/boot/grub
    grub-install --target=arm64-efi --efi-directory=${mount_point}/boot --boot-directory=${mount_point}/boot/boot --removable --recheck

    # Remove grub arm64-efi if extracted
    if [ -L "/usr/lib/grub/arm64-efi" ]; then
        rm -f /usr/lib/grub/arm64-efi
    fi

    # Grub config
    cat > ${mount_point}/boot/boot/grub/grub.cfg << EOF
insmod gzio
set background_color=black
set default=0
set timeout=10

GRUB_RECORDFAIL_TIMEOUT=

menuentry 'Boot' {
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    linux /boot/vmlinuz root=UUID=${root_uuid} console=ttyS2,115200 console=tty1 rootfstype=ext4 rootwait rw
    initrd /boot/initrd.img
}
EOF

    # Uboot script
    cat > ${mount_point}/boot/boot.cmd << EOF
env set bootargs "root=UUID=${root_uuid} console=ttyS2,1500000 console=tty1 rootfstype=ext4 rootwait rw"
fatload \${devtype} \${devnum}:1 \${fdt_addr_r} /rk3588s-orangepi-5.dtb
fdt addr \${fdt_addr_r} && fdt resize 0x2000
fatload \${devtype} \${devnum}:1 \${fdtoverlay_addr_r} /overlays/rk3588-wifi-ap6275p.dtbo
fdt apply \${fdtoverlay_addr_r}
ext4load \${devtype} \${devnum}:2 \${ramdisk_addr_r} /boot/vmlinuz
unzip \${ramdisk_addr_r} \${kernel_addr_r} \${filesize}
ext4load \${devtype} \${devnum}:2 \${ramdisk_addr_r} /boot/initrd.img
booti \${kernel_addr_r} \${ramdisk_addr_r}:\${filesize} \${fdt_addr_r}
EOF
    mkimage -A arm64 -O linux -T script -C none -n "Boot Script" -d ${mount_point}/boot/boot.cmd ${mount_point}/boot/boot.scr

    # Copy device tree blobs
    mkdir -p ${mount_point}/boot/overlays
    cp -r linux-orangepi/arch/arm64/boot/dts/rockchip/rk3588s-orangepi-5.dtb ${mount_point}/boot

    # Copy device tree overlays
    mkdir -p ${mount_point}/boot/overlays
    cp -r linux-orangepi/arch/arm64/boot/dts/rockchip/overlay/rk3588*.dtbo ${mount_point}/boot/overlays

    # Write bootloader to disk image
    dd if=u-boot-orangepi/idbloader.img of="${loop}" seek=64 conv=notrunc
    dd if=u-boot-orangepi/u-boot.itb of="${loop}" seek=16384 conv=notrunc

    sync --file-system
    sync

    # Umount partitions
    umount "${disk}${partition_char}1"
    umount "${disk}${partition_char}2"

    # Remove loop device
    losetup -d "${loop}"

    echo -e "\nCompressing $(basename "${img}.xz")\n"
    xz -9 --extreme --force --keep --quiet --threads=0 "${img}"
    rm -f "${img}"
done