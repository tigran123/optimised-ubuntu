#!/bin/bash
set -euo pipefail

# An example of install.sh in use: backup.sh in reverse, on another machine.
# The clone that backup.sh keeps on the portable disk (sdd here) is synced onto
# this machine's internal disks -- root on sdb, swap and /data/disk1 on sda --
# and --preserve leaves the machine's own network and Bluetooth state alone.
# The data partition is mirrored afterwards, never alongside: --remap has
# install.sh open that partition itself (see backup.sh).
# The device names are this machine's own.

BIOS="/dev/sdb1"
ESP="/dev/sdb2"
ROOT="/dev/sdb3"
DISK3="/dev/sdb4"

SWAP="/dev/sda1"
DISK1="/dev/sda2"

# Sync root
./install.sh --source-efi /dev/sdd2 --source-root /dev/sdd3 \
             --target-bios-boot $BIOS --target-efi $ESP --target-root $ROOT --target-swap $SWAP \
             --remap /data/disk1=$DISK1 --remap /data/disk3=$DISK3 \
             --preserve /etc/netplan --preserve /etc/NetworkManager/system-connections --preserve /var/lib/NetworkManager \
             --preserve /var/lib/bluetooth \
             --update --no-trim --yes

# Sync data
sudo mount -r -o noatime /dev/sdd6 /data
sudo mount $DISK3 /mnt
sudo rsync --exclude=/swap --exclude=/lost+found --delete -ahvHAX /data/ /mnt/
sudo umount /mnt /data
