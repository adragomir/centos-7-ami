yum -y update
yum remove -y kernel-headers kernel-tools kernel-tools-libs
yum --enablerepo "elrepo-kernel" install -y kernel-lt kernel-lt-devel kernel-lt-headers kernel-lt-tools kernel-lt-tools-libs kernel-lt-tools-libs-devel selinux-policy selinux-policy-targeted
kver=$(echo $(rpm -q kernel-lt) | sed 's/kernel-lt-//')
#yum install -y kmod-ixgbevf.x86_64
yum install -y make rpm-build gcc
wget "https://sourceforge.net/projects/e1000/files/ixgbevf%20stable/3.1.2/ixgbevf-3.1.2.tar.gz"
BUILD_KERNEL=${kver} KSRC=/usr/src/kernels/${kver}/ rpmbuild -tb ixgbevf-3.1.2.tar.gz
cp -a /root/rpmbuild/RPMS/x86_64/ixgbevf-3.1.2-1.x86_64.rpm /
yum erase gcc make rpm-build
rpm -ivh --force /ixgbevf-3.1.2-1.x86_64.rpm
depmod -aq ${kver}

sudo sed -i '/^GRUB\_CMDLINE\_LINUX/s/\"$/\ net\.ifnames\=0\"/' /etc/default/grub

sudo grub2-mkconfig -o /boot/grub2/grub.cfg
