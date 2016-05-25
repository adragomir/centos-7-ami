#!/bin/bash

# get the absolute path of the executable
SELF_PATH=$(cd -P -- "$(dirname -- "$0")" && pwd -P) && SELF_PATH=$SELF_PATH/$(basename -- "$0")
while [ -h $SELF_PATH ]; do
	DIR=$(dirname -- "$SELF_PATH")
	SYM=$(readlink $SELF_PATH)
	SELF_PATH=$(cd $DIR && cd $(dirname -- "$SYM") && pwd)/$(basename -- "$SYM")
done
D=$(dirname $SELF_PATH)

REQUIRED_RPMS=(yum-plugin-fastestmirror curl wget ruby ruby-devel kpartx parted vim gcc git-core bzip2 zlib-devel patch)
CFG_FILE=$HOME/.centos-ami-builder
USE_INSTANCE_VAR=1

## Builder functions ########################################################


build_ami() {
	get_root_device
	make_build_dirs
	make_img_file
	mount_img_file
	install_packages
	make_mounts
	setup_network
	install_grub
	execute_seeds
	enter_shell
	unmount_all
	bundle_ami
	upload_ami
	register_ami
	quit
}

# Determine what device our root partition is mounted on, and get its UUID
get_root_device() {
	read ROOT_DEV ROOT_FS_TYPE <<< $(awk '/^\/dev[^ ]+ \/ / {print $1" "$3}' /proc/mounts)
	[[ $ROOT_FS_TYPE == "xfs" ]] || fatal "Root file system on build host must be XFS (is $ROOT_FS_TYPE)"
	ROOT_UUID=$(/sbin/blkid -o value -s UUID $ROOT_DEV)
	if [[ "$ROOT_UUID" == "" ]];
    then
        ROOT_UUID=$(uuidgen)
    fi
	echo "Build host root device: $ROOT_DEV, UUID: $ROOT_UUID"
}


# Create the build hierarchy.  Unmount existing paths first, if need by
make_build_dirs() {
	AMI_ROOT="$BUILD_ROOT/$AMI_NAME"
	AMI_IMG="$AMI_ROOT/$AMI_NAME.img"
	AMI_MNT="$AMI_ROOT/mnt"
	AMI_OUT="$AMI_ROOT/out"

	if [[ "$OLD_AMI_NAME" != "" ]]; then
        OLD_AMI_IMG="$BUILD_ROOT/$OLD_AMI_NAME/$OLD_AMI_NAME.img"
    fi

	AMI_DEV=hda
	AMI_DEV_PATH=/dev/mapper/$AMI_DEV
	AMI_PART_PATH=${AMI_DEV_PATH}1

	output "Creating build hierarchy in $AMI_ROOT..."

	if grep -q "^[^ ]\+ $AMI_MNT" /proc/mounts; then
		yesno "$AMI_MNT is already mounted; unmount it"
		unmount_all
	fi

	mkdir -p $AMI_MNT $AMI_OUT || fatal "Unable to create create build hierarchy"
}


# Create our image file
make_img_file() {

	output "Creating image file $AMI_IMG..."
    if [[ -e $AMI_DEV_PATH ]]; then
        yesno "$AMI_DEV_PATH is already defined; redefine it"
        undefine_hvm_dev
    fi
    if [[ "$OLD_AMI_NAME" != "" ]]; then
        output "Copying old AMI image: $OLD_AMI_IMG"

        cp $OLD_AMI_IMG $AMI_IMG
        # Set up the the image file as a loop device so we can create a dm volume for it
        LOOP_DEV=$(losetup -f)
        losetup $LOOP_DEV $AMI_IMG || fatal "Failed to bind $AMI_IMG to $LOOP_DEV."
        # Create a device mapper volume from our loop dev
        DM_SIZE=$(($AMI_SIZE * 2048))
        DEV_NUMS=$(cat /sys/block/$(basename $LOOP_DEV)/dev)
        dmsetup create $AMI_DEV <<< "0 $DM_SIZE linear $DEV_NUMS 0" || \
            fatal "Unable to define devicemapper volume $AMI_DEV_PATH"
        kpartx -s -a $AMI_DEV_PATH || \
            fatal "Unable to read partition table from $AMI_DEV_PATH"
        udevadm settle
    else
        [[ -f $AMI_IMG ]] && yesno "$AMI_IMG already exists; overwrite it"
        # Create a sparse file
        rm -f $AMI_IMG && sync
        dd if=/dev/zero status=none of=$AMI_IMG bs=1M count=1 seek=$(($AMI_SIZE - 1))  || \
            fatal "Unable to create image file: $AMI_IMG"

        # Create a primary partition
        parted $AMI_IMG --script -- "unit s mklabel msdos mkpart primary 2048 100% set 1 boot on print quit" \
            || fatal "Unable to create primary partition for $AMI_IMG"
        sync; udevadm settle

        # Set up the the image file as a loop device so we can create a dm volume for it
        LOOP_DEV=$(losetup -f)
        losetup $LOOP_DEV $AMI_IMG || fatal "Failed to bind $AMI_IMG to $LOOP_DEV."

        # Create a device mapper volume from our loop dev
        DM_SIZE=$(($AMI_SIZE * 2048))
        DEV_NUMS=$(cat /sys/block/$(basename $LOOP_DEV)/dev)
        dmsetup create $AMI_DEV <<< "0 $DM_SIZE linear $DEV_NUMS 0" || \
            fatal "Unable to define devicemapper volume $AMI_DEV_PATH"
        kpartx -s -a $AMI_DEV_PATH || \
            fatal "Unable to read partition table from $AMI_DEV_PATH"
        udevadm settle

        # Create our xfs partition and clone our builder root UUID onto it
        mkfs.xfs -f $AMI_PART_PATH  || \
            fatal "Unable to create XFS filesystem on $AMI_PART_PATH"
        xfs_admin -U $ROOT_UUID $AMI_PART_PATH  || \
            fatal "Unable to assign UUID '$ROOT_UUID' to $AMI_PART_PATH"
        sync
    fi
}


# Mount the image file and create and mount all of the necessary devices
mount_img_file()
{
	output "Mounting image file $AMI_IMG at $AMI_MNT..."

    mount -o nouuid /dev/mapper/hda1 $AMI_MNT

	# Make our chroot directory hierarchy
	mkdir -p $AMI_MNT/{dev,etc,proc,sys,var/{cache,log,lock,lib/rpm}}
    rm -rf $AMI_MNT/var/{run,lock}
    ln -sf $AMI_MNT/var/run /run
    ln -sf $AMI_MNT/var/lock /run/lock

	# Create our special devices
	mknod -m 600 $AMI_MNT/dev/console c 5 1
	mknod -m 600 $AMI_MNT/dev/initctl p
	mknod -m 666 $AMI_MNT/dev/full c 1 7
	mknod -m 666 $AMI_MNT/dev/null c 1 3
	mknod -m 666 $AMI_MNT/dev/ptmx c 5 2
	mknod -m 666 $AMI_MNT/dev/random c 1 8
	mknod -m 666 $AMI_MNT/dev/tty c 5 0
	mknod -m 666 $AMI_MNT/dev/tty0 c 4 0
	mknod -m 666 $AMI_MNT/dev/urandom c 1 9
	mknod -m 666 $AMI_MNT/dev/zero c 1 5
	ln -s null $AMI_MNT/dev/X0R

	# Bind mount /dev and /proc from our builder machine
	mount -o bind /dev $AMI_MNT/dev
	mount -o bind /dev/pts $AMI_MNT/dev/pts
	mount -o bind /dev/shm $AMI_MNT/dev/shm
	mount -o bind /proc $AMI_MNT/proc
	mount -o bind /sys $AMI_MNT/sys
}


# Install packages into AMI via yum
install_packages() {
	if [[ "$OLD_AMI_NAME" != "" ]]; then
       output "Copying old ami, don't install packages"
       return
    fi

	output "Installing packages into $AMI_MNT..."
	# Create our YUM config
	YUM_CONF=$AMI_ROOT/yum.conf
	cat > $YUM_CONF <<-EOT
	[main]
	reposdir=
	plugins=0

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
	gpgkey=http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7

	[epel-debuginfo]
	name=Extra Packages for Enterprise Linux 7 - \$basearch - Debug
	#baseurl=http://download.fedoraproject.org/pub/epel/7/\$basearch/debug
	mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-debug-7&arch=\$basearch
	failovermethod=priority
	enabled=0
	gpgkey=http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
	gpgcheck=1

	[epel-source]
	name=Extra Packages for Enterprise Linux 7 - \$basearch - Source
	#baseurl=http://download.fedoraproject.org/pub/epel/7/SRPMS
	mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-source-7&arch=\$basearch
	failovermethod=priority
	enabled=0
	gpgkey=http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
	gpgcheck=1

	[elrepo]
	name=ELRepo.org Community Enterprise Linux Repository - el7
	baseurl=http://elrepo.org/linux/elrepo/el7/\$basearch/
			http://mirrors.coreix.net/elrepo/elrepo/el7/\$basearch/
			http://jur-linux.org/download/elrepo/elrepo/el7/\$basearch/
			http://repos.lax-noc.com/elrepo/elrepo/el7/\$basearch/
			http://mirror.ventraip.net.au/elrepo/elrepo/el7/\$basearch/
	mirrorlist=http://mirrors.elrepo.org/mirrors-elrepo.el7
	enabled=1
	gpgcheck=1
	gpgkey=https://www.elrepo.org/RPM-GPG-KEY-elrepo.org

	[elrepo-kernel]
	name=ELRepo.org Community Enterprise Linux Kernel Repository - el7
	baseurl=http://elrepo.org/linux/kernel/el7/\$basearch/
			http://mirrors.coreix.net/elrepo/kernel/el7/\$basearch/
			http://jur-linux.org/download/elrepo/kernel/el7/\$basearch/
			http://repos.lax-noc.com/elrepo/kernel/el7/\$basearch/
			http://mirror.ventraip.net.au/elrepo/kernel/el7/\$basearch/
	mirrorlist=http://mirrors.elrepo.org/mirrors-elrepo-kernel.el7
	enabled=1
	gpgcheck=1
	gpgkey=https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
EOT

	# Install base pacakges
	yum --config=$YUM_CONF --installroot=$AMI_MNT --quiet --assumeyes groupinstall Base
	[[ -f $AMI_MNT/bin/bash ]] || fatal "Failed to install base packages into $AMI_MNT"

	# Install additional packages that we are definitely going to want
	yum --config=$YUM_CONF --installroot=$AMI_MNT --assumeyes install \
        jq psmisc grub2 dhclient ntp e2fsprogs curl wget sudo elrepo-release kernel-lt \
		openssh-clients vim-minimal postfix yum-plugin-fastestmirror sysstat \
		epel-release python python-setuptools gcc make xinetd rsyslog microcode_ctl \
		gnupg2 bzip2 cloud-utils-growpart cloud-init openssh-server vim parted openssl pcre parted bind-utils ruby ruby-devel kpartx parted wget

	# Remove unnecessary RPMS
	yum --config=$YUM_CONF --installroot=$AMI_MNT --assumeyes erase \
		plymouth plymouth-scripts plymouth-core-libs chrony firewalld

	# extra tools
	cp /etc/resolv.conf $AMI_MNT/etc/
	chroot $AMI_MNT /usr/bin/curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
	chroot $AMI_MNT /usr/bin/sudo /usr/bin/python "get-pip.py"

	chroot $AMI_MNT /usr/bin/pip install --upgrade awscli
	chroot $AMI_MNT /usr/bin/easy_install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz

	# make sure we use the certfi lib released on 2015.04.28
	# (latest version breaks aws-cli tools)
	chroot $AMI_MNT /usr/bin/pip uninstall -y certifi
	chroot $AMI_MNT /usr/bin/pip install certifi==2015.04.28

	# Enable our required services
	chroot $AMI_MNT /bin/systemctl -q enable rsyslog ntpd sshd cloud-init cloud-init-local \
		cloud-config cloud-final elastic-network-interfaces

	# Create our default bashrc files
	cat > $AMI_MNT/root/.bashrc <<-EOT
	alias rm='rm -i' cp='cp -i' mv='mv -i'
	[ -f /etc/bashrc ] && . /etc/bashrc
EOT
	cp $AMI_MNT/root/.bashrc $AMI_MNT/root/.bash_profile
}


# Create the AMI's fstab
make_mounts() {
    output "Creating mount points for ephemeral storage..."
	mkdir -p $AMI_MNT/mnt/data_1
    chmod 775 $AMI_MNT/mnt/data_1
    output "Fixing journalctl configuration..."
    sed -i 's/^.*Storage=.*$/Storage=persistent/' $AMI_MNT/etc/systemd/journald.conf
    sed -i 's/^.*ForwardToSyslog=.*$/ForwardToSyslog=yes/' $AMI_MNT/etc/systemd/journald.conf
    sed -i 's/^.*ForwardToKMsg=.*$/ForwardToKMsg=yes/' $AMI_MNT/etc/systemd/journald.conf

    output "\"Fixing\" sudoers"
    sed -i "s/^Defaults    requiretty/#Defaults    requiretty/" $AMI_MNT/etc/sudoers
    output "\"Fixing\" selinux..."
    mkdir -p -m 755 $AMI_MNT/etc/selinux
    cat > $AMI_MNT/etc/selinux/config <<-EOT
SELINUX=disabled
SELINUXTYPE=targeted
EOT
    sed -i 's/^SELINUX=.*$/SELINUX=disabled/' $AMI_MNT/etc/selinux/config

	output "Creating fstab..."
    FSTAB_ROOT="/dev/sda1	   /	 xfs	defaults,noatime 1 1"

	cat > $AMI_MNT/etc/fstab <<-EOT
$FSTAB_ROOT
none /dev/pts devpts gid=5,mode=620 0 0
none /proc proc defaults 0 0
none /sys sysfs defaults 0 0
EOT

    mkdir -p -m 755 /usr/local/bin
    cat > $AMI_MNT/usr/local/bin/early-boot-aws.sh <<-EOT
#!/bin/bash

VAR_EXPANSION_ENABLED="0"
if [ "\$VAR_EXPANSION_ENABLED" == "1" ]; then
    root_size=\$(parted /dev/xvda1 unit MB print | awk '{y=x; x=\$4};END{print y}' | sed 's/MB$//')
    echo "XXXXX: \$root_size"
    if (( \$root_size < 20000 )); then
        exists=0
        if [ -b /dev/xvdb ]; then
            exists=1
        fi

        if [ \$exists == 1 -a ! -b /dev/xvdb1 ]; then
            /sbin/parted -s -a optimal /dev/xvdb mklabel gpt -- mkpart primary xfs 1 -1
            /sbin/partprobe /dev/xvdb
            /sbin/mkfs.xfs /dev/xvdb1
        fi

        mounted=0
        if [ \$exists == 1 ]; then
            /bin/mount /dev/xvdb1 /mnt/data_1
            mounted=1
        fi

        if [ \$mounted == 1 -a ! -d /mnt/data_1/var ]; then
            mkdir -p -m 777 /mnt/data_1/var
            /bin/rsync -a /var/* /mnt/data_1/var/
            mv /var /var.old
            mkdir -p -m 755 /var
        fi

        if [ \$mounted == 1 ]; then
            /bin/mount --bind /mnt/data_1/var /var
        fi
    fi
fi
EOT
    chmod 755 $AMI_MNT/usr/local/bin/early-boot-aws.sh

    cat > $AMI_MNT/etc/systemd/system/early-boot-aws.service <<-EOT
[Unit]
Description=Create AWS partitions
DefaultDependencies=false
After=-.mount
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/early-boot-aws.sh
RemainAfterExit=yes

[Install]
RequiredBy=local-fs.target
EOT
    chmod 644 $AMI_MNT/etc/systemd/system/early-boot-aws.service

rm -rf $AMI_MNT/etc/systemd/system/local-fs.target.*
rm -rf $AMI_MNT/etc/systemd/system/local-fs-pre.target.*

mkdir -p -m 755 $AMI_MNT/etc/systemd/system/local-fs.target.requires
ln -s /etc/systemd/system/early-boot-aws.service $AMI_MNT/etc/systemd/system/local-fs.target.requires/early-boot-aws.service

    cat > $AMI_MNT/etc/cloud/cloud.cfg.d/01_mounts.cfg <<-EOT
mounts:
 - [ephemeral0, null]
EOT

}

# Create our eth0 ifcfg script and our SSHD config
setup_network() {
	if [[ "$OLD_AMI_NAME" != "" ]]; then
       return
    fi

	output "Setting up network..."

	# Create our DHCP-enabled eth0 config
	cat > $AMI_MNT/etc/sysconfig/network-scripts/ifcfg-eth0 <<-EOT
	DEVICE=eth0
	BOOTPROTO=dhcp
	ONBOOT=yes
	TYPE=Ethernet
	USERCTL=yes
	PEERDNS=yes
	IPV6INIT=no
	PERSISTENT_DHCLIENT=yes
EOT

	cat > $AMI_MNT/etc/sysconfig/network <<-EOT
	NETWORKING=yes
	NOZEROCONF=yes
EOT

	# Amend our SSHD config
	cat >> $AMI_MNT/etc/ssh/sshd_config <<-EOT
	PasswordAuthentication no
	UseDNS no
	PermitRootLogin without-password
EOT

	chroot $AMI_MNT chkconfig network on
}


# Create the grub config
install_grub() {
	if [[ "$OLD_AMI_NAME" != "" ]]; then
       return
    fi

	AMI_BOOT_PATH=$AMI_MNT/boot
	AMI_KERNEL_VER=$(ls $AMI_BOOT_PATH | egrep -o '[34]\..*' | head -1)

	# Install our grub.conf for only the PV machine, as it is needed by PV-GRUB
    output "Installing GRUB2..."
    cat > $AMI_MNT/etc/default/grub <<-EOT
    GRUB_TIMEOUT=1
    GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
    GRUB_DEFAULT=saved
    GRUB_DISABLE_SUBMENU=true
    GRUB_TERMINAL="serial console"
    GRUB_SERIAL_COMMAND="serial --speed=115200"
    GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 vconsole.font=latarcyrheb-sun16 crashkernel=auto vconsole.keymap=us plymouth.enable=0 net.ifnames=0 biosdevname=0 systemd.journald.forward_to_syslog=1 systemd.journald.forward_to_kmsg=1 systemd.journald.forward_to_console=1"
    GRUB_DISABLE_RECOVERY="true"
EOT

    AMI_GRUB_PATH=$AMI_BOOT_PATH/grub2
    mkdir -p $AMI_GRUB_PATH
    echo "(hd0) $LOOP_DEV" > $AMI_GRUB_PATH/device.map
    chroot $AMI_MNT dracut --force --add-drivers "ixgbevf virtio" --kver $AMI_KERNEL_VER
    chroot $AMI_MNT grub2-install --no-floppy --modules='biosdisk part_msdos ext2 xfs configfile normal multiboot' $LOOP_DEV
    chroot $AMI_MNT grub2-mkconfig -o /boot/grub2/grub.cfg
}

execute_seeds() {
	cp /etc/resolv.conf $AMI_MNT/etc
	cp -a $D/seed/* $AMI_MNT/root/
	for f in $AMI_MNT/root/*.sh; do
        chroot $AMI_MNT /bin/bash /root/$(basename $f)
    done
	rm -f $AMI_MNT/{etc/resolv.conf,root/.bash_history}
}

# Allow user to make changes to the AMI outside of the normal build process
enter_shell() {
	# output "Entering AMI chroot; customize as needed.  Enter 'exit' to finish build."
	cp /etc/resolv.conf $AMI_MNT/etc
	PS1="[${AMI_NAME}-chroot \W]# " chroot $AMI_MNT &> /dev/tty
	rm -f $AMI_MNT/{etc/resolv.conf,root/.bash_history}
}


# Unmount all of the mounted devices
unmount_all() {
	umount -ldf $AMI_MNT/{dev/pts,dev/shm,dev,proc,sys,}
	sync
	grep -q "^[^ ]\+ $AMI_MNT" /proc/mounts && \
		fatal "Failed to unmount all devices mounted under $AMI_MNT!"

	# Also undefine our hvm devices if they are currently set up with this image file
	losetup | grep -q $AMI_IMG && undefine_hvm_dev
}


# Remove the dm volume and loop dev for an HVM image file
undefine_hvm_dev() {
	kpartx -d $AMI_DEV_PATH  || fatal "Unable remove partition map for $AMI_DEV_PATH"
	sync; udevadm settle
	dmsetup remove $AMI_DEV  || fatal "Unable to remove devmapper volume for $AMI_DEV"
	sync; udevadm settle
	OLD_LOOPS=$(losetup -j $AMI_IMG | sed 's#^/dev/loop\([0-9]\+\).*#loop\1#' | paste -d' ' - -)
	[[ -n $OLD_LOOPS ]] && losetup -d $OLD_LOOPS
	losetup -D
	sleep 1; sync; udevadm settle
}


# Create an AMI bundle from our image file
bundle_ami() {
	output "Bundling AMI for upload..."
	RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-bundle-image --privatekey $AWS_PRIVATE_KEY --cert $AWS_CERT \
		--user $AWS_USER --image $AMI_IMG --prefix $AMI_NAME --destination $AMI_OUT --arch x86_64 || \
		fatal "Failed to bundle image!"
	AMI_MANIFEST=$AMI_OUT/$AMI_NAME.manifest.xml
}


# Upload our bundle to our S3 bucket
upload_ami() {
	output "Uploading AMI to $AMI_S3_DIR..."
	RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-upload-bundle --bucket $AMI_S3_DIR --manifest $AMI_MANIFEST \
		--access-key $AWS_ACCESS --secret-key $AWS_SECRET --retry --region $S3_REGION  || \
		fatal "Failed to upload image!"
}


# Register our uploading S3 bundle as a valid AMI
register_ami() {

	# If this is a PV image, we need to find the latest PV-GRUB kernel image
    aws ec2 register-image --image-location $AMI_S3_DIR/$AMI_NAME.manifest.xml --name $AMI_NAME --region $S3_REGION \
        --architecture x86_64 --virtualization-type hvm  || \
        fatal "Failed to register image!"
}


## Utilitiy functions #######################################################


# Print a message and exit
quit() {
	output "$1"
	exit 1
}


# Print a fatal message and exit
fatal() {
	quit "FATAL: $1"
}


# Perform our initial setup routines
do_setup() {

	source $CFG_FILE  || get_config_opts
	install_setup_rpms
	setup_aws
	sanity_check

	# Add /usr/local/bin to our path if it doesn't exist there
	[[ ":$PATH:" != *":/usr/local/bin"* ]] && export PATH=$PATH:/usr/local/bin

	output "All build requirements satisfied."
}


# Read config opts and save them to disk
get_config_opts() {

	source $CFG_FILE

	get_input "Path to local build folder (i.e. /mnt/amis)" "BUILD_ROOT"
	get_input "AMI size (in MB)" "AMI_SIZE"
	get_input "AWS User ID #" "AWS_USER"
	get_input "Path to S3 AMI storage (i.e. bucket/dir)" "S3_ROOT"
	get_input "S3 bucket region (i.e. us-west-2)" "S3_REGION"
	get_input "AWS R/W access key" "AWS_ACCESS"
	get_input "AWS R/W secret key" "AWS_SECRET"
	get_input "Path to AWS X509 key" "AWS_PRIVATE_KEY"
	get_input "Path to AWS X509 certifcate" "AWS_CERT"

	# Create our AWS config file
	mkdir -p ~/.aws
	chmod 700 ~/.aws
	cat > $HOME/.aws/config <<-EOT
	[default]
	output = json
	region = $S3_REGION
	aws_access_key_id = $AWS_ACCESS
	aws_secret_access_key = $AWS_SECRET
EOT

	# Write our config options to a file for subsequent runs
	rm -f $CFG_FILE
	touch $CFG_FILE
	chmod 600 $CFG_FILE
	for f in BUILD_ROOT AMI_SIZE AWS_USER S3_ROOT S3_REGION AWS_ACCESS AWS_SECRET AWS_PRIVATE_KEY AWS_CERT; do
		eval echo $f=\"\$$f\" >> $CFG_FILE
	done

}


# Read a variable from the user
get_input()
{
	# Read into a placeholder variable
	ph=
	eval cv=\$${2}
	while [[ -z $ph ]]; do
		printf "%-45.45s : " "$1" &> /dev/tty
		read -e -i "$cv" ph &> /dev/tty
	done

	# Assign placeholder to passed variable name
	eval ${2}=\"$ph\"
}


# Present user with a yes/no question, quit if answer is no
yesno() {
	read -p "${1}? y/[n] " answer &> /dev/tty
	[[ $answer == "y" ]] || quit "Exiting"
}


output() {
	echo $* > /dev/tty
}


# Sanity check what we can
sanity_check() {


	# Make sure our ami size is numeric
	[[ "$AMI_SIZE" =~ ^[0-9]+$ ]] || fatal "AMI size must be an integer!"
	(( "$AMI_SIZE" >= 1000 )) || fatal "AMI size must be at least 1000 MB (currently $AMI_SIZE MB!)"

	# Check for ket/cert existance
	[[ ! -f $AWS_PRIVATE_KEY ]] && fatal "EC2 private key '$AWS_PRIVATE_KEY' doesn't exist!"
	[[ ! -f $AWS_CERT ]] && fatal "EC2 certificate '$AWS_CERT' doesn't exist!"

	# Check S3 access and file existence
	aws s3 ls s3://$S3_ROOT &> /dev/null
	[[ $? -gt 1 ]] && fatal "S3 bucket doesn't exist or isn't readable: s3://${S3_ROOT}"
	[[ -n $(aws s3 ls s3://$AMI_S3_DIR) ]] && \
		fatal "AMI S3 path ($AMI_S3_DIR) already exists;  Refusing to overwrite it"

}


# Install RPMs required by setup
install_setup_rpms() {

	RPM_LIST=/tmp/rpmlist.txt

	# dump rpm list to disk
	rpm -qa > $RPM_LIST

	# Iterate over required rpms and install missing ones
	TO_INSTALL=
	for rpm in "${REQUIRED_RPMS[@]}"; do
		if ! grep -q "^${rpm}-[0-9]" $RPM_LIST; then
			TO_INSTALL="$rpm $TO_INSTALL"
		fi
	done

	if [[ -n $TO_INSTALL ]]; then
		output "Installing build requirements: $TO_INSTALL..."
		yum -y install $TO_INSTALL
	fi
}

# wait for aws status
aws_wait() {
	[[ $# = 3 ]] || { echo "Internal error calling wait-for" ; exit 99 ; }
	cmd=$1
	pattern=$2
	target=$3
	loop=1
    echo "Waiting for $cmd | jq $pattern -r"
	while [[ $loop -le 600 ]]; do
		STATE=`$cmd | jq $pattern -r`
		if [[ $STATE == $target ]]; then
			return 0
		fi
		sleep 1
		printf "."
		loop=$(( $loop + 1 ))
	done
	return 1
}

build_ami_from_current() {
	get_root_device
	make_build_dirs

	AWS_AZ=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
	INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
	echo "AZ: $AWS_AZ, Instance: $INSTANCE_ID, Size: $AMI_SIZE_GB"

	echo "Creating volume"
	VOLUME_ID=$(aws ec2 create-volume --size $AMI_SIZE_GB --availability-zone $AWS_AZ --volume-type gp2 --no-encrypted | jq .VolumeId -r)
	aws_wait "aws ec2 describe-volumes --volume-id $VOLUME_ID" ".Volumes[0].State" "available"

	echo "Attaching volume to $INSTANCE_ID"
	aws ec2 attach-volume --instance $INSTANCE_ID --volume $VOLUME_ID --device xvdh
	aws_wait "aws ec2 describe-volumes --volume-id $VOLUME_ID" ".Volumes[0].Attachments[0].State" "attached"

    echo "Dd-ing current disk content"
    # write with dd
    dd if=${AMI_FROM_IMG} of=/dev/xvdh bs=4k
    sleep 2
    partprobe /dev/xvdh
    sleep 2

    echo "Mounting partition..."
    mount -t xfs -o nouuid /dev/xvdh1 $AMI_MNT

    echo "Fix early-boot-aws for EBS backed image..."
    sed -i 's/^VAR_EXPANSION_ENABLED=.*$/VAR_EXPANSION_ENABLED=0/' $AMI_MNT/usr/local/bin/early-boot-aws.sh

    # clean up machine
    echo "Clean up user data"
    rm -rf $AMI_MNT/var/tmp/*
    find $AMI_MNT/root/ -mindepth 1 -maxdepth 1 -regextype posix-egrep -not -regex ".*(\.|\.ssh|\.bash_profile|\.bashrc|\.rb)$" -print0 | xargs -0 rm -rf
    find $AMI_MNT/home/centos/ -mindepth 1 -maxdepth 1 -regextype posix-egrep -not -regex ".*(\.|\.ssh|\.bash_profile|\.bashrc)$" -print0 | xargs -0 rm -rf

    # fix up cloud init
    echo "Clean-up cloud-init"
    rm -rf $AMI_MNT/var/lib/cloud/instance
    rm -rf $AMI_MNT/var/lib/cloud/sem/*
    rm -rf $AMI_MNT/var/lib/cloud/instances/*

    chroot $AMI_MNT /bin/systemctl -q enable rsyslog ntpd sshd cloud-init cloud-init-local \
        cloud-config cloud-final elastic-network-interfaces

	sync;sync;sync;sync && umount $AMI_MNT

	echo "Detach volume"
	aws ec2 detach-volume --volume-id $VOLUME_ID
	aws_wait "aws ec2 describe-volumes --volume-id $VOLUME_ID" ".Volumes[0].State" "available"

	echo "Making snapshot..."
	SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $VOLUME_ID --description "" | jq '.SnapshotId' -r)
	aws_wait "aws ec2 describe-snapshots --snapshot-id ${SNAPSHOT_ID}" ".Snapshots[0].State" "completed"
	sudo aws ec2 register-image --name $AMI_NAME \
		--region $S3_REGION \
		--architecture x86_64 \
		--virtualization-type hvm \
		--root-device-name "/dev/sda1" \
		--block-device-mappings "[{ \"DeviceName\": \"/dev/sda1\", \"Ebs\": {\"SnapshotId\": \"${SNAPSHOT_ID}\"}}]"
}

# Set up our various EC2/S3 bits and bobs
setup_aws() {
	setenforce Permissive
	if [[ ! -f /usr/local/bin/jq ]]; then
		wget -O /usr/local/bin/jq http://stedolan.github.io/jq/download/linux64/jq
		chmod +x /usr/local/bin/jq
	fi

	# ec2-ami-tools
	if [[ ! -f /usr/local/bin/ec2-bundle-image ]]; then
		output "Installing EC2 AMI tools..."
		rpm -ivh http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools-1.5.7.noarch.rpm
	fi

    if [[ ! -f /usr/local/bin/openssl ]]; then
        git clone http://github.com/openssl/openssl
        pushd openssl
        ./config
        make
        cp ./apps/openssl /usr/local/bin
        popd
        rm -rf openssl
    fi

    if [[ ! -f /usr/local/bin/pigz ]]; then
        wget http://zlib.net/pigz/pigz-2.3.3.tar.gz
        tar zxf pigz-2.3.3.tar.gz
        pushd pigz-2.3.3
        make
        cp pigz /usr/local/bin
        popd
        rm -rf pigz-2.3.3*
    fi

    cat > ec2.perf.patch <<-EOT
diff -U 3 -r ./ec2/amitools/bundle.rb /usr/lib/ruby/site_ruby/ec2/amitools/bundle.rb
--- ./ec2/amitools/bundle.rb	2015-08-06 13:32:47.009581525 +0000
+++ /usr/lib/ruby/site_ruby/ec2/amitools/bundle.rb	2015-03-26 21:39:24.000000000 +0000
@@ -87,10 +87,10 @@
       openssl = EC2::Platform::Current::Constants::Utility::OPENSSL
       pipeline = EC2::Platform::Current::Pipeline.new('image-bundle-pipeline', debug)
       pipeline.concat([
-        ['tar', "#{openssl} sha1 < #{digest_pipe} & " + tar.expand],
+        ['tar', "/usr/local/bin/#{openssl} sha1 < #{digest_pipe} & " + tar.expand],
         ['tee', "tee #{digest_pipe}"],
-        ['gzip', 'gzip -9'],
-        ['encrypt', "#{openssl} enc -e -aes-128-cbc -K #{key} -iv #{iv} > #{bundled_file_path}"]
+        ['gzip', '/usr/local/bin/pigz -9'],
+        ['encrypt', "/usr/local/bin/#{openssl} enc -e -aes-128-cbc -K #{key} -iv #{iv} > #{bundled_file_path}"]
         ])
       digest = nil
       begin
EOT
    grep "pigz" /usr/lib/ruby/site_ruby/ec2/amitools/bundle.rb >/dev/null
    if [[ $? -eq 1 ]]; then
        patch -p1 -d /usr/lib/ruby/site_ruby < ec2.perf.patch
    fi

	# PIP (needed to install aws cli)
	curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
	sudo python "get-pip.py"
	pip install --upgrade awscli
	if [[ ! -f /bin/pip ]]; then
		output "Installing PIP..."
		easy_install pip
	fi
	if [[ ! -f /usr/bin/aws ]]; then
		output "Installing aws-cli"
		pip install --upgrade awscli
	fi

	# Set the target directory for our upload
	AMI_S3_DIR=$S3_ROOT/$AMI_NAME

	# Create our AWS config file
	mkdir -p ~/.aws
	chmod 700 ~/.aws
	cat > $HOME/.aws/config <<-EOT
	[default]
	output = json
	region = $S3_REGION
	aws_access_key_id = $AWS_ACCESS
	aws_secret_access_key = $AWS_SECRET
EOT
}

# Main code #################################################################


# Blackhole stdout of all commands unless debug mode requested
# [[ "$3" != "debug" ]] && exec &> /dev/null

case "$1" in
	reconfig)
		get_config_opts
		;;
	cleanup)
		AMI_NAME=${2// /_}
		[[ -z $AMI_NAME ]] && quit "Usage: $0 <hvm_name>"
		unmount_all
		;;
	hvm)
		AMI_NAME=${2// /_}
		AMI_SIZE="${3}"
        OLD_AMI_NAME="${4}"
		AMI_TYPE=hvm
		[[ -z $AMI_NAME ]] && quit "Usage: $0 hvm <hvm_name>"
		do_setup
		build_ami
		;;
	convert_image_hvm)
		AMI_NAME=${2// /_}
		AMI_SIZE_GB=$3
		AMI_FROM_IMG=$4
		AMI_TYPE=hvm
		[[ -z $AMI_NAME ]] && quit "Usage: $0 convert_instance_hvm <hvm_name> <SIZE_GB> <image_source_file.img>"
		do_setup
		build_ami_from_current
		;;
	*)
    quit "Usage: $0 <reconfig | hvm HVM_NAME HVM_SIZE $oldami | convert_image_hvm SIZE_GB SOURCE_IMAGE > [debug]"
esac

# vim: tabstop=4 shiftwidth=4 expandtab
