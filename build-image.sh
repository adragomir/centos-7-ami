#!/bin/bash
source config_aws
config=$1
source $config
source functions.sh

prepare_dirs $location

# detect partition type
uuid=$(/sbin/blkid -o value -s UUID /dev/xvda1)

echo "Making image !!!"
if [ $mode == "partitioned" ];
then
  make_mbr_image $location/out/$name $size $uuid
  # nouuid so that we don't throw errors
  mount_partitioned_image $location/mnt
else
  make_raw_image $location/out/$name $size $uuid
  # nouuid so that we don't throw errors
  mount_raw_image $location/out/$name $location/mnt
fi

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

if [ $mode == "partitioned"];
then
  # Install Grub. This might throw errors, just run it another time
  cat > $location/mnt/boot/grub/device.map <<EOF
  (hd0) $full_mapper
EOF
  install_grub $location/mnt
  make_grub_conf $location/mnt "(hd0,0)" hvc0 $uuid
  # fix device.map
  cat > $location/mnt/boot/grub/device.map <<EOF
  (hd0) /dev/xvda
EOF
  sync; sync; sync; sync
else
  make_grub_conf $location/mnt/boot/grub "(hd0)" hvc0 $uuid
fi

unmount_image

if [ $mode == "partitioned" ];
then
  finish_unmount_image_partitioned
fi

# Prepare bundling
bundle_image $location/out/$name $name $location/out ""
# upload
upload_bundle $location/out/$name $s3_location
RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-upload-bundle --bucket $s3_location --manifest $location/out/$name.manifest.xml --access-key $access_key --secret-key $secret_key --retry --region $region
# register
register_image paravirtual $s3_location/$name.manifest.xml $name 
