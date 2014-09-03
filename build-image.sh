#!/bin/bash
source config_aws
config=$1
source $config
source functions.sh

prepare_dirs $location

# detect partition type
uuid=$(/sbin/blkid -o value -s UUID /dev/xvda1)

make_raw_image $location/out/$name $size $uuid
# nouuid so that we don't throw errors
mount_raw_image $location/out/$name $location/mnt

# create a minimal system for chroot
prepare_chroot $location/mnt
# prepare packages installation
install_packages_in_chroot $location $location/mnt

# minimal fstab
make_fstab $location/mnt/etc/fstab "false" "uuid"
# networking
make_sysconfig_network  $location/mnt/etc/sysconfig/network 
make_sysconfig_network_script  $location/mnt/etc/sysconfig/network-scripts/ifcfg-eth0
# sshd for AWS
make_sshd_config $location/mnt/etc/ssh/sshd_config

make_grub_conf $location/mnt/boot/grub "(hd0)" hvc0 $uuid

unmount_image

bundle_image $location/out/$name $name $location/out ""
upload_bundle $location/out/${name}.manifest.xml $s3_location
register_image paravirtual $s3_location/$name.manifest.xml $name 
