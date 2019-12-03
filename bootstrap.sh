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
BOOT_SPACE=512M

# https://itsfoss.com/swap-size/
RAM_SIZE=$(free --giga | tail -n+2 | head -1 | awk '{print $2}')
SQRT_RAM_SIZE=$(echo "scale=2; sqrt($RAM_SIZE)" | bc -l)
SWAP_SPACE=$(($RAM_SIZE + $SQRT_RAM_SIZE))G

# Ensure there's a fresh GPT
sgdisk -og $DISK

# Partition the disk
sgdisk --clear \
        --new=1:0:+$EFI_SPACE  --typecode=1:ef00 --change-name=1:EFI \
        --new=2:0:+$BOOT_SPACE --typecode=2:8300 --change-name=2:cryptboot \
        --new=3:0:0            --typecode=2:8e00 --change-name=3:cryptlvm \
        $DISK

DISK_EFI="/dev/disk/by-partlabel/EFI"
DISK_BOOT="/dev/disk/by-partlabel/cryptboot"
DISK_LVM="/dev/disk/by-partlabel/cryptlvm"

sgdisk -p $DISK

# Make sure everything knows about the new partition table
partprobe $DISK
fdisk -l $DISK

# Format the EFI partition as fat32
mkfs.vfat -F 32 $DISK_EFI

# Create the encrypted boot partition
cryptsetup -c aes-xts-plain64 -h sha512 -s 512 --use-random luksFormat $DISK_BOOT

# Open the encrypted boot partition with the label "boot"
echo "Opening encrypted boot partition"
cryptsetup open $DISK_BOOT boot

# Format the boot partition as ext4
mkfs.ext4 /dev/mapper/boot

# Create the encrypted LVM partition
cryptsetup -c aes-xts-plain64 -h sha512 -s 512 --use-random luksFormat $DISK_LVM

# Open the encrypted LVM partition with the label "lvm"
echo "Opening encrypted LVM partition"
cryptsetup open $DISK_LVM lvm

# Create the encrypted ???
pvcreate /dev/mapper/lvm

# Create the ???
vgcreate ArchVG /dev/mapper/lvm

# Create the ???
lvcreate -L +$SWAP_SPACE ArchVG -n swap
lvcreate -l +100%FREE ArchVG -n root

# Create the swap partition
mkswap /dev/mapper/ArchVG-swap

# ... and turn it on (?)
swapon /dev/mapper/ArchVG-swap

# Format the root partition as ext4
mkfs.ext4 /dev/mapper/ArchVG-root

# Mount the root partition
mount /dev/mapper/ArchVG-root /mnt

# Create the boot directory in root
mkdir /mnt/boot

# ... and mount the encrypted boot partition there
mount /dev/mapper/boot /mnt/boot

# Create the efi directory in root
mkdir /mnt/boot/efi

# ... and mount the efi partition there
mount $DISK_EFI /mnt/boot/efi

# Install base system
pacstrap /mnt base linux linux-firmware intel-ucode grub-efi-x86_64 efibootmgr dialog wpa_supplicant vim

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Ensure that we can see the swap
#sed -i "s+LABEL=swap+/dev/mapper/swap+" /mnt/etc/fstab

# Set the hostname
echo $HOST > /mnt/etc/hostname

# Set locale
echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" >> /mnt/etc/locale.conf

# Set default keymap
echo "KEYMAP=sv-latin1" > /mnt/etc/vconsole.conf

# Set name servers
echo 'name_servers="1.1.1.1 1.0.0.1"' >> /mnt/etc/resolvconf.conf

# Set timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime

# ... and clock
arch-chroot /mnt hwclock --systohc --utc

# Set ntp
arch-chroot /mnt timedatectrl set-ntp true

# Start time sync service on boot
arch-chrood /mnt systemctl enable systemd-timesyncd.service

# Update boot hooks
sed -i "s/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt lvm2
resume filesystems fsck)/" /mnt/etc/mkinitcpio.conf

## --- CONTIHUE HERE ---

# Regenerate initramfs image
arch-chroot /mnt mkinitcpio -p linux #TODO is arch-chroot needed?

# Enable boot partition from encrypted LVM
sed -i 's/# \(GRUB_ENABLE_CRYPTODISK=y)/\1/' /etc/default/grub

exit 0

# Install grub
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Archerino

GRUB_CMDLINE_LINUX="cryptdevice=${DISK_LVM}:lvm resume=/dev/mapper/ArchVG-swap i915.enable_guc=3"

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Let all wheel users use sudo
sed -i 's/# \(%wheel ALL=(ALL) ALL\)/\1/' /mnt/etc/sudoers

# Set root password
echo "Set password for root"
arch-chroot /mnt passwd

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

arch-chroot /mnt useradd --create-home -m -G wheel,storage,power,video,audio $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd --root /mnt

unset USERPASS
