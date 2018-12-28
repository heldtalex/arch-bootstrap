#!/bin/sh

## USAGE:
## .bootstrap.sh <disk> <hostname>

## resume example https://gist.github.com/fervic/c0a5eea4cf31a0a31fa5af57ba38f8ab

DISK=$1
HOSTNAME=$2

if [ -z "$DISK" ]; then
    echo "You must set the DISK env var (this WILL be formatted so be careful!)"
    exit 1
fi

if [ ! -e "$DISK" ]; then
    echo "'$DISK' does not exist"
    exit 1
fi

if [ -z "$HOSTNAME" ]; then
    echo "You must provide a hostname as the second argument"
    exit 1
fi

PARTITION_PREFIX=""
if echo "$DISK" | grep -q "nvme"; then
    PARTITION_PREFIX="p"
fi

# Clear the disk
wipefs -fa $DISK
sgdisk -Z $DISK

EFI_SPACE=512M
# set to half amount of RAM
SWAP_SPACE=$(($(free --giga | tail -n+2 | head -1 | awk '{print $2}') / 2))G
# special case when there's very little ram
if [ "$SWAP_SPACE" = "0G" ]; then
    SWAP_SPACE="1G"
fi

# Ensure there's a fresh GPT
sgdisk -og $DISK

# Partition the disk
sgdisk --clear \
       --new=1:0:+$EFI_SPACE  --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+$SWAP_SPACE --typecode=2:8200 --change-name=2:cryptswap \
       --new=3:0:0            --typecode=2:8200 --change-name=3:cryptroot \
         $DISK

DISK_EFI="/dev/disk/by-partlabel/EFI"
DISK_SWAP="/dev/disk/by-partlabel/cryptswap"
DISK_ROOT="/dev/disk/by-partlabel/cryptroot"

sgdisk -p $DISK

# Make sure everything knows about the new partition table
partprobe $DISK
fdisk -l $DISK

# Create the encrypted root partition
cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 $DISK_ROOT

# Open the encrypted root partition with the label "root"
cryptsetup open $DISK_ROOT root

# format the root partition as btrfs
mkfs.btrfs --force --label root /dev/mapper/root

# Format the EFI partition
mkfs.vfat -n EFI $DISK_EFI

# Open the swap partition with a random key with the label "swap"
cryptsetup open --type plain --key-file=/dev/random $DISK_SWAP swap

# Create the swap partition
mkswap -L swap /dev/mapper/swap
swapon -L swap

MOUNT_OPTIONS=rw,noatime,compress=lzo,ssd,x-mount.mkdir #space_cache?

# Mount root and create btrfs subvolumes
mount -o $MOUNT_OPTIONS LABEL=root /mnt

# TODO create @var?
cd /mnt
btrfs subvolume create @
btrfs subvolume create @home
btrfs subvolume create @snapshots
cd

umount -R /mnt

mount -t btrfs -o subvol=@,$MOUNT_OPTIONS LABEL=root /mnt
mount -t btrfs -o subvol=@home,$MOUNT_OPTIONS LABEL=root /mnt/home
mount -t btrfs -o subvol=@snapshots,$MOUNT_OPTIONS LABEL=root /mnt/.snapshots

# Mount EFI partition
mkdir /mnt/boot
mount LABEL=EFI /mnt/boot

# Install base system
pacstrap /mnt base base-devel btrfs-progs intel-ucode zsh vim dialog wpa_supplicant

# Generate fstab
genfstab -L -p /mnt >> /mnt/etc/fstab

# Ensure that we can see the swap
sed -i "s+LABEL=swap+/dev/mapper/swap+" /mnt/etc/fstab

# Add the swap to crypttab to be opened on boot
echo "swap $DISK_SWAP /dev/urandom swap,cipher=aes-cbc-essiv:sha256,size=256" >> /mnt/etc/crypttab

# Set the hostname
echo $HOST > /mnt/etc/hostname

#TODO set hosts

# Set locale
echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" >> /mnt/etc/locale.conf

# Set timezone and clock
ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime

hwclock --systohc --utc

# TODO enable synced clock

# Set default keymap
echo "KEYMAP=sv-latin1" > /mnt/etc/vconsole.conf

# Update boot hooks
sed -i "s/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems btrfs)/" /mnt/etc/mkinitcpio.conf

# Regenerate initramfs image
arch-chroot /mnt mkinitcpio -p linux #TODO is arch-chroot needed?

# Install systemd-boot loader
arch-chroot /mnt bootctl --path=/boot install

# Configure the boot loader
cat > /mnt/boot/loader/loader.conf << EOF
default	arch
timeout	3
editor	0
EOF

# Add default entry to boot loader
ROOT_PARTUUID=$(blkid -s PARTUUID -o value $DISK_ROOT)
cat > /mnt/boot/loader/entries/arch.conf << EOF
title	Archerino
linux	/vmlinuz-linux
initrd  /intel-ucode.img
initrd	/initramfs-linux.img
options cryptdevice=PARTUUID=$ROOT_PARTUUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@
EOF

# Let all wheel users use sudo
arch-chroot /mnt echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo

# Set root password
echo "Set password for root"
passwd

# set user name and password
read -p "Enter user name: " USERNAME

while [ -z "$USERPASS" ]; do
  read -s -p "Enter password for ${USERNAME}: " USERPASS
  echo
  read -s -p "Confirm password : " USERPASS2
  echo
  if [ "$USERPASS" != "$USERPASS2" ]; then
      echo "Different passwords given, try again."
      unset USERPASS
  fi
  unset USERPASS2
done

useradd -m -G wheel,storage,power,video,audio $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd

unset USERPASS
