#!bin/sh

## USAGE:
## .bootstrap.sh <disk> <hostname>
## https://wiki.archlinux.org/index.php/User:Altercation/Bullet_Proof_Arch_Install

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

echo "Partitioning $DISK"
/bin/bash partition.sh $DISK 

