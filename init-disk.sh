#!/bin/bash

TARGET=/dev/sde
EFI=${TARGET}2
BOOT=${TARGET}3
ROOT=${TARGET}4

sudo parted -s "$TARGET" mklabel gpt
sudo parted -s "$TARGET" mkpart primary 1MiB 2MiB
sudo parted -s "$TARGET" set 1 bios_grub on
sudo parted -s "$TARGET" mkpart primary fat32 2MiB 258MiB
sudo parted -s "$TARGET" set 2 esp on
sudo parted -s "$TARGET" mkpart primary ext4 258MiB 770MiB
sudo parted -s "$TARGET" mkpart primary ext4 770MiB 100%
sudo wipefs -q -a "$EFI" "$BOOT" "$ROOT"
sudo mkfs.fat -F32 -n EFI "$EFI"
sudo mkfs.ext4 -vF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$BOOT"

ROOT_BYTES_PER_INODE=$(( 1024**4 / (12 * 1024**2) ))   # 1 TiB / 8Mi = 131072
sudo mkfs.ext4 -vF -m 0 -L root -i "$ROOT_BYTES_PER_INODE" -E lazy_itable_init=0,lazy_journal_init=0 -O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed "$ROOT"
