#!/usr/bin/env bash
if [ -z "$1" ]; then
	echo "Usage: modify_netboot_ip.sh <initrd.uimg>"
	exit 1
fi
dd if="$1" of="rootfs.gz" bs=64 skip=1
gunzip -d "rootfs.gz"
rm -rf r
mkdir r
sudo mount -o loop rootfs r
sudo vim r/mnt/stateful_partition/dev_image/etc/lsb-factory
sudo umount r
rmdir r
sync
pigz -9 rootfs
mkimage -A x86 -O linux -T ramdisk -a 0x12008000 \
	-n "Factory Install RootFS" -C gzip -d rootfs.gz \
	initrd.uimg
rm -f rootfs.gz
