#!/bin/bash
source config_aws
config=$1
source $config
source functions.sh

prepare_dirs $location

uuid=$(/sbin/blkid -o value -s UUID /dev/xvda1)

make_fstab $location/tmp/fstab "true" "simple"
make_grub_conf $location/tmp/grub.conf "(hd0,0)" "ttyS0" $uuid

#bundle_vol 3500 $location $name "${block_device_mapping}" "mbr" $location/tmp/fstab $location/tmp/grub.conf
# the following replace bundle_vol
make_mbr_image $location/out/$name $size $uuid
prepare_mount_image_partitioned $location/out/$name $size
mount_partitioned_image $location/mnt
prepare_chroot $location/mnt
copy_root_to_chroot $location/mnt
install_grub $location/mnt
make_fstab $location/mnt/etc/fstab "true" "simple"
unmount_image $location/mnt
finish_unmount_image_partitioned 

bundle_image $location/out/$name $name $location/out ""
upload_bundle $location/out/$name.manifest.xml $s3_location
register_image "hvm" $s3_location/$name.manifest.xml $name
