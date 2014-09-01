#!/bin/bash

function install_tooling {
  yum -y update
  # disable Selinux
  setenforce Permissive
  yum install -y gdisk patch curl wget ruby unzip vim
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

  cat > image.rb.patch <<EOF
--- image.rb	2014-04-30 11:45:54.000000000 +0300
+++ image.rb	2014-08-31 18:59:26.000000000 +0300
@@ -382,7 +382,7 @@
          info = fsinfo( root )
          label= info[:label]
          uuid = info[:uuid]
-          type = info[:type] || 'ext3'
+          type = info[:type] || 'xfs'
          execute('modprobe loop') unless File.blockdev?('/dev/loop0')

          target = nil
@@ -648,7 +648,7 @@
          raise FatalError.new("image already mounted") if mounted?(IMG_MNT)
          dirs = ['mnt', 'proc', 'sys', 'dev']
          if self.is_disk_image?
-            execute( 'mount -t %s %s %s' % [@fstype, @target, IMG_MNT] )
+            execute( 'mount -t %s -o nouuid %s %s' % [@fstype, @target, IMG_MNT] )
            dirs.each{|dir| FileUtils.mkdir_p( '%s/%s' % [IMG_MNT, dir])}
            make_special_devices
            execute( 'mount -o bind /proc %s/proc' % IMG_MNT )
@@ -741,8 +741,12 @@
            fstab_content = make_fstab
            File.open( fstab, 'w' ) { |f| f.write( fstab_content ) }
            puts "/etc/fstab:"
-            fstab_content.each do |s|
-              puts "\t #{s}"
+            if fstab_content.kind_of?(Array)
+              fstab_content.each do |s|
+                puts "\t #{s}"
+              end
+            else
+              puts "\t ${fstab_content}"
            end
          end
        end
EOF

  patch -p0 /usr/lib/ruby/site_ruby/ec2/platform/linux/image.rb < image.rb.patch

mkdir -p $HOME/.aws
cat $HOME/.aws/config <<EOF
[default]
output = json
region = eu-west-1
aws_access_key_id = $access_key
aws_secret_access_key = $secret_key
EOF

}

function prepare_mount_image_partitioned {
  image=$1
  export loop=$(losetup -f)
  losetup $loop $location/out/$name
  export dmsize=$(($size * 1024 * 1024 / 512))
  export loopname=$(basename $loop)
  export majmin=$(cat /sys/block/$loopname/dev)
  echo 0 $dmsize linear $majmin 0 | dmsetup create hda
  kpartx -a /dev/mapper/hda
}

function finish_unmount_image_partitioned {
  kpartx -d /dev/mapper/hda
  dmsetup remove hda
  losetup -D
}

function make_fstab {
  loc=$1
  uuid=$(/sbin/blkid -o value -s UUID $current_root)
  cat > $loc <<EOF
UUID=$uuid /         xfs    defaults,noatime 1 1
EOF
}

function make_sysconfig_network {
  cat >$1 <<EOF
NETWORKING=yes
NETWORKING_IPV6=no
HOSTNAME=localhost.localdomain
EOF
}

function make_sysconfig_network_script {
  cat >$1 <<EOF
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=yes
PEERDNS=yes
IPV6INIT=no
PERSISTENT_DHCLIENT=yes
EOF
}

function make_sshd_config {
cat >>$1 <<EOF
PasswordAuthentication no
UseDNS no
PermitRootLogin without-password
EOF
}

function make_grub_conf {
  loc=$1
  root=$2
  console=$3
  uuid=$4
  kernelver=$(rpm -qa | grep '^kernel-3'  | sed -e 's/kernel-//' | head -n 1)
  cat > $loc <<EOF
default=0
timeout=hiddenmenu0

title CentOS Linux ($kernelver) 7 (Core)
	root $root
	kernel /boot/vmlinuz-$kernelver ro root=UUID=$uuid console=$console LANG=en_US.UTF-8 loglvl=all sync_console console_to_ring earlyprintk=xen xen_emul_unplug=unnecessary
	initrd /boot/initramfs-$kernelver.img
EOF
}

function make_image_grub_conf {
  grub_dir=$1
  ln -s /boot/grub/grub.conf $grub_dir/menu.lst
}

function make_mbr_image {
  image=$1
  size=$2
  uuid=$3
  dd if=/dev/zero status=noxfer of=$image bs=1M count=1 seek=$(($size - 1))

  # make an MBR/msdos partition
  parted --script $image -- 'unit s mklabel msdos mkpart primary 63 -1s set 1 boot on print quit'
  sync; /sbin/udevadm settle
  sync; /sbin/udevadm settle

  # setup loop device
  prepare_mount_image_partitioned $image $size
  sync; /sbin/udevadm settle

  # create an XFS partition
  /sbin/mkfs.xfs /dev/mapper/hda1
  # take the existing root uuid and copy it
  /usr/sbin/xfs_admin -U $uuid /dev/mapper/hda1

  sync
}

function prepare_dirs {
  loc=$1
  mkdir -p $loc $loc/mnt $loc/tmp $loc/out
}

function make_raw_image {
  image=$1
  size=$2
  uuid=$3
  dd if=/dev/zero status=noxfer of=$image bs=1M count=1 seek=$size
  /sbin/mkfs.xfs $image
  /usr/sbin/xfs_admin -U $uuid $image
  sync
}

function prepare_chroot {
  mount_point=$1
  mkdir -p $mount_point/{dev,etc,proc,sys}
  mkdir -p $mount_point/var/{cache,log,lock,lib/rpm}
  /sbin/MAKEDEV -d $mount_point/dev -x console
  /sbin/MAKEDEV -d $mount_point/dev -x null
  /sbin/MAKEDEV -d $mount_point/dev -x zero
  /sbin/MAKEDEV -d $mount_point/dev -x urandom
  ln -s null $mount_point/dev/X0R
  mount -o bind /dev $mount_point/dev
  mount -o bind /dev/pts $mount_point/dev/pts
  mount -o bind /dev/shm $mount_point/dev/shm
  mount -o bind /proc $mount_point/proc
  mount -o bind /sys $mount_point/sys
}

function install_packages_in_chroot {
  image_root=$1
  chroot=$2
  cat > $image_root/yum-xen.conf <<EOF
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

rpm -qa > $image_root/rpms.txt
yum -c $image_root/yum-xen.conf --installroot=$chroot install `cat $image_root/rpms.txt`
# install necessary packages
yum -c $image_root/yum-xen.conf --installroot=$chroot -y install dhclient grub e2fsprogs selinux-policy selinux-policy-targeted chrony cloud-utils-growpart cloud-init

/usr/sbin/chroot $mount_point /bin/systemctl enable acpid
/usr/sbin/chroot $mount_point /bin/systemctl enable sshd
/usr/sbin/chroot $mount_point /bin/systemctl enable chronyd
/usr/sbin/chroot $mount_point /bin/systemctl enable cloud-init
/usr/sbin/chroot $mount_point /bin/systemctl enable cloud-init-local
/usr/sbin/chroot $mount_point /bin/systemctl enable cloud-config
/usr/sbin/chroot $mount_point /bin/systemctl enable cloud-final
/usr/sbin/chroot $mount_point /bin/systemctl enable sshd
}

function mount_partitioned_image {
  mount_point=$1
  mount -t xfs -o nouuid /dev/mapper/hda1 $mount_point
}

function mount_raw_image {
  image=$1
  mount_point=$2
  mount -t xfs -o nouuid $image $mount_point
}

function install_grub {
  chroot=$1
  # Install Grub. This might throw errors, just run it another time
  cat > $chroot/boot/grub/device.map <<EOF
  (hd0) /dev/mapper/hda
EOF
  if [ ! -f $chroot/etc/mtab ];
  then
    ln -s /proc/mounts $chroot/etc/mtab
  fi
  ln -s ./hda1 ${chroot}/dev/mapper/hdap1
  cp -a /usr/share/grub/x86_64-redhat/stage{1,2} $chroot/boot/grub/
  cp -a /usr/share/grub/x86_64-redhat/*_stage1_5 $chroot/boot/grub/
  setarch x86_64 chroot $chroot env -i echo -e "device (hd0) /dev/mapper/hda\nroot (hd0,0)\nsetup (hd0)" | grub --device-map=/dev/null --batch
}

function unmount_image {
  mount_point=$1
  umount -d $mount_point/sys
  umount -d $mount_point/proc
  umount -d $mount_point/dev/shm
  umount -d $mount_point/dev/pts
  umount -d $mount_point/dev
  umount -d $mount_point
}

function bundle_vol {
  size=$1
  out=$2
  name=$3
  block_device_mapping=$4
  partition=$5
  RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-bundle-vol \
    -d $out/out \
    --block-device-mapping $block_device_mapping \
    -p $name \
    -s 3500 \
    --partition $partition \
    --fstab $out/tmp/fstab \
    --grub-config $out/tmp/grub.conf \
    -e /mnt,/opt \
    --no-filter \
    --no-inherit \
    --debug \
    -r x86_64 \
    -c $certificate \
    -k $private_key \
    -u $aws_user
}

function bundle_image {
  image=$1
  prefix=$2
  destination=$3
  block_device_mapping=$4
  if [ "${block_device_mapping}" == "" ]
  then
    RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-bundle-image --privatekey $private_key --cert $certificate --user $aws_user --image $location/out/$name --prefix $name --destination $location/out --arch x86_64
  else
    RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-bundle-image --privatekey $private_key --cert $certificate --user $aws_user --image $location/out/$name --prefix $name --destination $location/out --arch x86_64 --block-device-mapping $block_device_mapping
  fi
}

function upload_bundle {
  image_manifest=$1
  dest=$2
  RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-upload-bundle --bucket $dest --manifest $image_manifest --access-key $access_key --secret-key $secret_key --retry --region $region
}

function register_image {
  ami_type=$1
  shift
  s3=$1
  shift
  name=$1
  shift
  echo "AAAAAAAAAAAAAAAAA"
  echo $ami_type
  if [ $ami_type == "paravirtual" ]
  then
    aws ec2 register-image --image-location $s3_location/$name.manifest.xml --name $name --region $region --architecture x86_64 --kernel $aki --virtualization-type pv $*
  else
    echo aws ec2 register-image --image-location $s3_location/$name.manifest.xml --name $name --region $region --architecture x86_64 --virtualization-type hvm $*
    aws ec2 register-image --image-location $s3_location/$name.manifest.xml --name $name --region $region --architecture x86_64 --virtualization-type hvm $*
  fi
}