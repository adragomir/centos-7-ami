#!/bin/bash
source config_aws
config=$1
source $config
source functions.sh

prepare_dirs $location

uuid=$(/sbin/blkid -o value -s UUID /dev/xvda1)

make_fstab $location/tmp/fstab
make_grub_conf $location/tmp/grub.conf "(hd0,0)" "ttyS0" $uuid

bundle_vol 3500 $location $name "${block_device_mapping}" "mbr" $location/tmp/fstab $location/tmp/grub.conf
# fuck instance afterward

upload_bundle $location/out/$name.manifest.xml $s3_location

register_image "hvm" $s3_location/$name.manifest.xml $name
