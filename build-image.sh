#!/bin/bash

# Script variables
location=/opt/ec2/test1
name=centos7
size=3000 # in MB
# we are taking the file type and things from current root
current_root=/dev/xvda1
mapper=hda
full_mapper=/dev/mapper/$mapper
full_mapper_p=${full_mapper}p
# AWS
private_key=/var/tmp/pk.pem
certificate=/var/tmp/cert.pem
aws_user=1111111111 # account id
s3_location=my/s3/location/for/amis
access_key=...
secret_key=...
region=eu-west-1

mkdir -p $location $location/mnt $location/tmp $location/out

# disable Selinux
setenforce Permissive

# update packages so that the AMI has the latest ones
yum update

# tools 
yum install curl wget ruby unzip

# save rpms
rpm -qa > $location/rpms

# ec2-ami-tools
curl -O http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools-1.5.3.noarch.rpm
rpm -ivh ec2-ami-tools-1.5.3.noarch.rpm

# ec2-api-tools
wget http://s3.amazonaws.com/ec2-downloads/ec2-api-tools.zip
unzip ec2-api-tools.zip

# MAKEDEV package from centos 6, no longer available in 7. TODO: make it work with mknod
wget http://mirror.centos.org/centos/6/os/x86_64/Packages/MAKEDEV-3.24-6.el6.x86_64.rpm
rpm -ivh MAKEDEV-3.24-6.el6.x86_64.rpm

# awscli
wget https://bootstrap.pypa.io/get-pip.py
python get-pip.py
pip install awscli

# Java for amazon ec2-ami-tools, ec2-api-tools
wget --no-cookies --no-check-certificate --header "Cookie: gpw_e24=http%3A%2F%2Fwww.oracle.com%2F; oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jdk/7u67-b01/jdk-7u67-linux-x64.rpm"
rpm -ivh jdk-7u67-linux-x64.rpm

# Grub Legacy for PV-grub compatibility
wget http://mirror.centos.org/centos/6/os/x86_64/Packages/grub-0.97-83.el6.x86_64.rpm
mkdir -p grub
rm -rf grub/*
pushd grub && rpm2cpio ../grub-0.97-83.el6.x86_64.rpm | cpio -idmv && popd
cp -a grub/sbin/* /sbin/
cp -a grub/usr/* /usr/

echo "Making image !!!"
dd if=/dev/zero status=noxfer of=$location/$name bs=1M count=1 seek=$(($size - 1))

# detect partition type
uuid=$(/sbin/blkid -o value -s UUID $current_root)
parttype=$(/sbin/blkid -o value -s TYPE $current_root)
# make an MBR/msdos partition
parted --script $location/$name -- 'unit s mklabel msdos mkpart primary 63 -1s set 1 boot on print quit'
sync; /sbin/udevadm settle
sync; /sbin/udevadm settle

# setup loop device
loop=$(losetup -f)
losetup $loop $location/$name
dmsize=$(($size * 1024 * 1024 / 512))
loopname=$(basename $loop)
majmin=$(cat /sys/block/$loopname/dev)
echo 0 $dmsize linear $majmin 0 | dmsetup create $mapper
kpartx -a $full_mapper

sync; /sbin/udevadm settle

# create an XFS partition
/sbin/mkfs.xfs ${full_mapper}1
# take the existing root uuid and copy it
/usr/sbin/xfs_admin -U $uuid ${full_mapper}1
sync
# nouuid so that we don't throw errors
mount -t xfs -o nouuid ${full_mapper}1 $location/mnt

# create a minimal system for chroot
mkdir -p $location/mnt/{dev,etc,proc,sys}
mkdir -p $location/mnt/var/{cache,log,lock,lib/rpm}
/sbin/MAKEDEV -d $location/mnt/dev -x console
/sbin/MAKEDEV -d $location/mnt/dev -x null
/sbin/MAKEDEV -d $location/mnt/dev -x zero
/sbin/MAKEDEV -d $location/mnt/dev -x urandom
ln -s null $location/mnt/dev/X0R
mount -o bind /dev $location/mnt/dev
mount -o bind /dev/pts $location/mnt/dev/pts
mount -o bind /dev/shm $location/mnt/dev/shm
mount -o bind /proc $location/mnt/proc
mount -o bind /sys $location/mnt/sys

# prepare packages installation
cat > $location/yum-xen.conf <<EOF
[base]
name=CentOS-7 - Base
mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=os
#baseurl=http://mirror.centos.org/centos/7/os/x86_64/
gpgcheck=1
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

#released updates
[updates]
name=CentOS-7 - Updates
mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=updates
#baseurl=http://mirror.centos.org/centos/7/updates/x86_64/
gpgcheck=1
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

#additional packages that may be useful
[extras]
name=CentOS-7 - Extras
mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=extras
#baseurl=http://mirror.centos.org/centos/7/extras/x86_64/
gpgcheck=1
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

#additional packages that extend functionality of existing packages
[centosplus]
name=CentOS-7 - Plus
mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=centosplus
#baseurl=http://mirror.centos.org/centos/7/centosplus/x86_64/
gpgcheck=1
enabled=0
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

#contrib - packages by Centos Users
[contrib]
name=CentOS-7 - Contrib
mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=contrib
#baseurl=http://mirror.centos.org/centos/7/contrib/x86_64/
gpgcheck=1
enabled=0
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

[epel]
name=Extra Packages for Enterprise Linux 7 - \$basearch
#baseurl=http://download.fedoraproject.org/pub/epel/7/\$basearch
mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-7&arch=\$basearch
failovermethod=priority
enabled=1
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7

[epel-debuginfo]
name=Extra Packages for Enterprise Linux 7 - \$basearch - Debug
#baseurl=http://download.fedoraproject.org/pub/epel/7/\$basearch/debug
mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-debug-7&arch=\$basearch
failovermethod=priority
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
gpgcheck=1

[epel-source]
name=Extra Packages for Enterprise Linux 7 - \$basearch - Source
#baseurl=http://download.fedoraproject.org/pub/epel/7/SRPMS
mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-source-7&arch=\$basearch
failovermethod=priority
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
gpgcheck=1
EOF

# install current rpms on the image
yum -c $location/yum-xen.conf --installroot=$location/mnt install `cat rpms.txt`
# install necessary packages
yum -c $location/yum-xen.conf --installroot=$location/mnt -y install dhclient grub e2fsprogs selinux-policy selinux-policy-targeted chrony cloud-utils-growpart cloud-init

# enable packages
/usr/sbin/chroot $location/mnt /bin/systemctl enable acpid
/usr/sbin/chroot $location/mnt /bin/systemctl enable sshd
/usr/sbin/chroot $location/mnt /bin/systemctl enable chronyd
/usr/sbin/chroot $location/mnt /bin/systemctl enable cloud-init
/usr/sbin/chroot $location/mnt /bin/systemctl enable cloud-init-local
/usr/sbin/chroot $location/mnt /bin/systemctl enable cloud-config
/usr/sbin/chroot $location/mnt /bin/systemctl enable cloud-final
/usr/sbin/chroot $location/mnt /bin/systemctl enable sshd

# yeah, unsecure
sed -i s/SELINUX=enforcing/SELINUX=disabled/g $location/mnt/etc/selinux/config

# minimal fstab
cat > $location/mnt/etc/fstab <<EOF
UUID=$uuid /         $parttype    defaults,noatime 1 1
EOF

# networking
cat > $location/mnt/etc/sysconfig/network <<EOF
NETWORKING=yes
NETWORKING_IPV6=no
HOSTNAME=localhost.localdomain
EOF

cat >$location/mnt/etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=yes
PEERDNS=yes
IPV6INIT=no
PERSISTENT_DHCLIENT=yes
EOF

# sshd for AWS
cat >>$location/mnt/etc/ssh/sshd_config <<EOF
PasswordAuthentication no
UseDNS no
PermitRootLogin without-password
EOF

# Install Grub. This might throw errors, just run it another time
cat > $location/mnt/boot/grub/device.map <<EOF
(hd0) $full_mapper
EOF
echo "Installing grub !!!!!!!!!!!!!!"
if [ ! -f $location/mnt/etc/mtab ];
then
  ln -s /proc/mounts $location/mnt/etc/mtab
fi
ln -s ./hda1 $location/mnt${full_mapper_p}1
cp -a /usr/share/grub/x86_64-redhat/stage{1,2} $location/mnt/boot/grub/
cp -a /usr/share/grub/x86_64-redhat/*_stage1_5 $location/mnt/boot/grub/
setarch x86_64 chroot $location/mnt env -i echo -e "device (hd0) $full_mapper\nroot (hd0,0)\nsetup (hd0)" | grub --device-map=/dev/null --batch
cp -a /boot/grub/grub.conf $location/mnt/boot/grub/
ln -s /boot/grub/grub.conf $location/mnt/boot/grub/menu.lst

sync; sync; sync; sync

# unmount partition
umount -d $location/mnt/sys
umount -d $location/mnt/proc
umount -d $location/mnt/dev/shm
umount -d $location/mnt/dev/pts
umount -d $location/mnt/dev
umount -d $location/mnt

kpartx -d $full_mapper
dmsetup remove $mapper
losetup -d $loop

# Prepare bundling
RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-bundle-image --privatekey $private_key --cert $certificate --user $aws_user --image $location/$name --prefix $name --destination $location/out --arch x86_64 --block-device-mapping ami=/dev/sda,root=/dev/sda
# upload
RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-upload-bundle --bucket $s3_location --manifest $location/out/$name.manifest.xml --access-key $access_key --secret-key $secret_key --retry --region $region
# register
aws ec2 register-image --image-location $s3_location/$name.manifest.xml --name $name --region $region --architecture x86_64 --kernel aki-58a3452f
