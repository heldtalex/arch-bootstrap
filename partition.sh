#!bin/sh

## USAGE:
## ./partition.sh <disk>

DISK=$1

PARTITION_PREFIX=""
if echo "$DISK" | grep -q "nvme"; then
    PARTITION_PREFIX="p"
fi

echo "Will completely erase and format '$DISK', proceed? (y/n)"
read answer
if ! echo "$answer" | grep '^[Yy].*' 2>&1>/dev/null; then
    echo "Ok bye."
    exit
fi

# Clear the disk
wipefs -fa $DISK
sgdisk -Z $DISK

EFI_SPACE=500M
# set to half amount of RAM
SWAP_SPACE=$(($(free --giga | tail -n+2 | head -1 | awk '{print $2}') / 2))G
# special case when there's very little ram
if [ "$SWAP_SPACE" = "0G" ]; then
    SWAP_SPACE="1G"
fi

# Ensure there's a fresh GPT
sgdisk -og $DISK

# Create partitions
sgdisk -n 0:0:+$EFI_SPACE -t 0:ef00 -c 0:"efi" $DISK
sgdisk -n 0:0:+$SWAP_SPACE -t 0:8200 -c 0:"cryptswap" $DISK
sgdisk -n 0:0:0 -t 0:8300 -c 0:"cryptsystem" $DISK

DISK_EFI=$DISK$PARTITION_PREFIX"1"
DISK_SWAP=$DISK$PARTITION_PREFIX"2"
DISK_SYSTEM=$DISK$PARTITION_PREFIX"3"

sgdisk -p $DISK

# Make sure everything knows about the new partition table
partprobe $DISK
fdisk -l $DISK

# Format the EFI partition
mkfs.fat -F32 -n $DISK_EFI

cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 $DISK_SYSTEM
cryptsetup open $DISK_SYSTEM system

cryptsetup open --type plain --key-file /dev/urandom $DISK_SWAP swap
mkswap -L swap /dev/mapper/swap
swapon -L swap

mkfs.btrfs --force --label system /dev/mapper/system

o=defaults,x-mount.dirs
o_btrfs=$o,compress=zstd,ssd,noatime #rw? space_cache?

# Mount system and create subvolume
mount -t btrfs LABEL=system /mnt
btrfs subvolume create /mnt/boot
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/snapshots

# Unmount and via subvolumes
umount -R /mnt

mount -t btrfs -o subvol=root,$o_btrfs LABEL=system /mnt
mount -t btrfs -o subvol=home,$o_btrfs LABEL=system /mnt/home
mount -t btrfs -o subvol=snapshots,$o_btrfs LABEL=system /mnt/.snapshots

mkdir /mnt/boot
mount LABEL=efi /mnt/boot

