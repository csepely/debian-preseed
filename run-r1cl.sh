#!/bin/sh

#
# Bare metal install script
#
# Debian Buster, raid1, crypted LVM, debootstrap
#
# Peter Csepely
#

set -e

DISK1=${1:-/dev/sda}
DISK2=${2:-/dev/sdb}

DISKS="$DISK1 $DISK2"

PARTITION_BOOT="${DISK1}2 ${DISK2}2"
PARTITION_ROOT="${DISK1}3 ${DISK2}3"

RAID_NAME_ROOT=ssdRootRaid1
RAID_NAME_BOOT=ssdBootRaid1

RAID_DISK_ROOT=/dev/md/${RAID_NAME_ROOT}
RAID_DISK_BOOT=/dev/md/${RAID_NAME_BOOT}

CRYPT_NAME="${RAID_NAME_ROOT}_crypt"

LUKS_PASSWORD="r00tme"
ROOT_PASSWORD="$LUKS_PASSWORD"

LVM_NAME="/dev/mapper/$CRYPT_NAME"

DEFAULT_HOSTNAME="debian-b$(date +%Y-%j-%H)"
ARG1="$3"
HOSTNAME_BARE="${ARG1:=$DEFAULT_HOSTNAME}"

echo "[info] Disks: ${DISKS}, Hostname: ${HOSTNAME_BARE}\nIs it correct? (y|n)"
read answer
if [[ "$answer" != "y" ]]
then
    echo "Usage: bash $0 [disk#1] [disk#2] [hostname]"
    exit -1
fi

echo "[anna-install] Loading components..."

# anna-install
anna-install cryptsetup-udeb\
 crypto-dm-modules\
 crypto-modules\
 dmsetup-udeb\
 lvm2-udeb\
 parted-udeb\
 mdadm-udeb
depmod -a

echo "[parted] Creating partitions..."
for d in ${DISKS}
do
    if [[ -e "$d" ]]
    then
        parted -a optimal -s $d \
    unit MB \
    mktable gpt \
    mkpart primary fat32 0% 538M \
    set 1 esp on \
    mkpart primary ext2 538M 1050M \
    set 2 raid on \
    mkpart primary 1050M 100% \
    set 3 raid on
    fi
done

# blockdev
for d in ${DISKS}
do
    if [[ -e $d ]]
    then
        blockdev --rereadpt $d
    fi
done

# mdadm
echo "[mdadm] Creating RAID..."

# zero-superblock
echo "[mdadm] Zero superblock(s)..."
for p in ${PARTITION_BOOT} ${PARTITION_ROOT}
do
    if [[ -e "$p" ]]
    then
        mdadm --misc --zero-superblock $p
    fi
done

echo "[mdadm] Create RAID..."
bootParts=""
for i in ${PARTITION_BOOT}
do
    if [[ -e "$i" ]]
    then
        bootParts="${bootParts}$i "
    else
        bootParts="${bootParts}missing "
    fi
done
mdadm --create -R --verbose --level=1 \
--metadata=1.2 --raid-devices=2 ${RAID_DISK_BOOT} \
$bootParts

rootParts=""
for i in ${PARTITION_ROOT}
do
    if [[ -e "$i" ]]
    then
        rootParts="${rootParts}$i "
    else
        rootParts="${rootParts}missing "
    fi
done
mdadm --create -R --verbose --level=1 \
--metadata=1.2 --raid-devices=2 ${RAID_DISK_ROOT} \
$rootParts

# cryptsetup
echo "[cryptsetup] Creating crypted partition..."
echo -n "$LUKS_PASSWORD" | cryptsetup \
--key-file=- \
luksFormat \
--type luks1 \
${RAID_DISK_ROOT}
echo -n "$LUKS_PASSWORD" | cryptsetup \
--key-file=- \
open ${RAID_DISK_ROOT} ${CRYPT_NAME}
sleep 3

# lvm
echo "[LVM] Creating LVM..."
pvcreate  -ff -y $LVM_NAME
vgcreate system $LVM_NAME
lvcreate -y -L 2GB system -n swap
lvcreate -y -l +100%FREE system -n root

# filesystem
echo "[mkfs] Filesystems..."
mkfs.fat -F 32 ${DISK1}1
mkfs.ext2 -q -F ${RAID_DISK_BOOT}
mkfs.ext4 -q -F /dev/system/root
mkswap /dev/system/swap
echo "[mount] Creating mount point, mounting..."
mkdir /target
mount -t ext4 /dev/system/root /target
mkdir -p /target/boot
swapon /dev/system/swap
mount -t ext2 ${RAID_DISK_BOOT} /target/boot
mkdir -p /target/boot/efi
mount -t vfat ${DISK1}1 /target/boot/efi
echo "[debootstrap] Debootstraping..."
debootstrap --arch=amd64 buster /target http://ftp.hu.debian.org/debian

echo "[chroot] Mounting additional mount points..."
mount -o bind,ro /dev /target/dev
mount -t devpts /dev/pts /target/dev/pts
mount -t proc none /target/proc
mount -t sysfs none /target/sys
mount --rbind /run /target/run

echo "[bash] Generating script..."

cat <<EOF > /target/root/debootstrap.sh
#!/bin/bash

set -e

# mount, user, passwd, fstab, grub..., hosts, locale
# deb http://ftp.hu.debian.org/debian buster main
# deb-src http://ftp.hu.debian.org/debian buster main

# deb http://security.debian.org/debian-security buster/updates main
# deb-src http://security.debian.org/debian-security buster/updates main

# buster-updates, previously known as 'volatile'
# deb http://ftp.hu.debian.org/debian buster-updates main
# deb-src http://ftp.hu.debian.org/debian buster-updates main
cat <<EOF2 >> /etc/apt/sources.list
deb-src http://ftp.hu.debian.org/debian buster main
deb http://security.debian.org/debian-security buster/updates main
deb-src http://security.debian.org/debian-security buster/updates main
deb http://ftp.hu.debian.org/debian buster-updates main
deb-src http://ftp.hu.debian.org/debian buster-updates main
EOF2

#tzdata tzdata/Areas select Europe
#tzdata tzdata/Zones/Europe select Budapest

debconf-set-selections <<EOF2
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Budapest
EOF2

rm -f /etc/localtime /etc/timezone
DEBCONF_NONINTERACTIVE_SEEN=true dpkg-reconfigure -f noninteractive tzdata

# network/ens18
cat <<EOF2 >> /etc/network/interfaces
auto lo
iface lo inet loopback
allow-hotplug ens18
iface ens18 inet dhcp
EOF2

echo "Using ${HOSTNAME_BARE} as hostname..."
echo "${HOSTNAME_BARE}" > /etc/hostname

cat <<EOF2 > /etc/hosts
127.0.0.1       localhost
127.0.1.1       $HOSTNAME_BARE

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF2

cat > /etc/fstab <<EOF2
UUID=`blkid -o value ${RAID_DISK_BOOT} | head -n 1` /boot ext2 errors=remount-ro 0 1
UUID=`blkid -o value ${DISK1}1 | head -n 1` /boot/efi vfat defaults 0 1
/dev/mapper/system-swap none swap sw  0       0
/dev/mapper/system-root / ext4 errors=remount-ro 0 1
EOF2

debconf-set-selections <<EOF2
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
locales locales/default_environment_locale select en_US.UTF-8
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/model select Generic 105-key PC (intl.)
EOF2
# Stop anything overriding debconf's settings
rm -f /etc/default/locale /etc/locale.gen /etc/default/keyboard
export DEBIAN_FRONTEND=noninteractive
apt-get install -y locales console-setup
apt-get install -y linux-image-amd64 grub-efi-amd64 lvm2 mdadm cryptsetup

# crypto
echo "${CRYPT_NAME} UUID=$(blkid -s UUID -o value ${RAID_DISK_ROOT}) none luks,discard" >> /etc/crypttab

# grub, noclear
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
sed -i 's/quiet//g' /etc/default/grub
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cd /etc/systemd/system/getty@tty1.service.d/
cat <<EOF2 >noclear.conf
[Service]
TTYVTDisallocate=no
EOF2

grub-install --target=x86_64-efi
update-grub
update-initramfs -u
echo "root:${ROOT_PASSWORD}" | chpasswd
EOF

echo "[chroot] Executing additional steps inside chroot..."
chroot /target /bin/bash /root/debootstrap.sh
echo "[umount] Unmount chroot environment..."
for i in run sys proc dev/pts dev boot/efi boot
do
    umount /target/$i
done
umount /target
swapoff /dev/system/swap
sync
reboot
