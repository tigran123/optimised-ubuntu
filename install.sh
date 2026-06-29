#!/bin/bash
# install.sh — flash a portable OS image or block device onto a target SSD.
#
# Reads SOURCE/TARGET/MNT/SRC from the environment (or the defaults below) so
# this script can be driven from CI or a rescue environment without editing
# source. Run with --dry-run to print every destructive command without
# executing it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portable-common.sh
. "$SCRIPT_DIR/portable-common.sh"

# -----------------------------------------------------------------------------
# Configuration
#
# NOTE: TARGET has no default. install.sh is destructive — a stray /dev/sdd
# default could silently overwrite the user's fourth disk if they ever ran
# it without arguments. Operator must set it via flag or environment.
# SOURCE defaults to the local image filename, which is read-only and safe.
# -----------------------------------------------------------------------------
SOURCE="${SOURCE:-Ubuntu26-Portable-16GB.img}"
TARGET="${TARGET:-}"
MNT="${MNT:-/mnt}"
SRC="${SRC:-/altroot}"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image|--source) SOURCE="$2"; shift 2 ;;
        --target)         TARGET="$2"; shift 2 ;;
        --mnt)            MNT="$2"; shift 2 ;;
        --src)            SRC="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)
            cat <<USAGE
Usage: $0 --target DEV [--image FILE|DEV] [--mnt DIR] [--src DIR] [--dry-run]
  --image FILE|DEV Source image or block device to flash (default: Ubuntu26-Portable-16GB.img)
  --target DEV     Target block device                   (required)
  --mnt DIR        Mount point for the target root       (default: /mnt)
  --src DIR        Mount point for the source data       (default: /altroot)
  --dry-run        Print destructive commands instead of running them

TARGET and SOURCE may also be passed via the environment.
USAGE
            exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Dry-run wrapper — runs the actual command unless DRY_RUN=1
# -----------------------------------------------------------------------------
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# -----------------------------------------------------------------------------
# Sanity: ensure TARGET was supplied, and that the source isn't the target.
# -----------------------------------------------------------------------------
[ -n "$TARGET" ] || die "TARGET is required (set --target DEV or export TARGET=…)"

if [ -e "$TARGET" ] && [ "$(readlink -f "$SOURCE")" = "$(readlink -f "$TARGET")" ]; then
    die "SOURCE and TARGET resolve to the same path/device: $SOURCE"
fi

TGT_INFO=$(lsblk -n -d -o SIZE,MODEL "$TARGET" 2>/dev/null | xargs || echo "Unknown")
TGT_MODEL=$(lsblk -n -d -o MODEL "$TARGET" 2>/dev/null | xargs)
if [ -z "$TGT_MODEL" ]; then
    TGT_MODEL="Portable Image"
fi

echo "Installing from \"$SOURCE\" to \"$TARGET\" ($TGT_INFO)"
echo "Using \"$MNT\" and \"$SRC\" mount points"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run mode — destructive commands will be printed, not executed)"
fi
confirm_prompt "Press any key to proceed or Ctrl+C to break"

sudo mkdir -p "$MNT" "$SRC"

# Determine target partition prefix
P=$(partition_prefix "$TARGET")
EFI="${TARGET}${P}2"
BOOT="${TARGET}${P}3"
SWAP="${TARGET}${P}4"
ROOT="${TARGET}${P}5"

LOOP_DEV=""

echo "=========================================="
echo " Phase 1: Resolving Source Architecture   "
echo "=========================================="
if [ -b "$SOURCE" ]; then
    echo "Source detected as a physical block device: $SOURCE"
    SP=$(partition_prefix "$SOURCE")
    validate_disk_structure "$SOURCE" "$SP" || die "Source block device lacks required GPT layout."
    
    SRC_EFI="${SOURCE}${SP}2"
    SRC_BOOT="${SOURCE}${SP}3"
    SRC_ROOT="${SOURCE}${SP}4"
    
elif [ -f "$SOURCE" ]; then
    echo "Source detected as a flat file image: $SOURCE"
    if [ "$DRY_RUN" -eq 1 ]; then
        LOOP_DEV="/dev/loop0"
        echo "[dry-run] sudo losetup -P -f --show \"$SOURCE\"  # would yield: $LOOP_DEV"
    else
        LOOP_DEV=$(sudo losetup -P -f --show "$SOURCE")
        echo "Image mapped to loop device: $LOOP_DEV"
    fi
    
    # Loop devices always utilize the 'p' prefix
    SRC_EFI="${LOOP_DEV}p2"
    SRC_BOOT="${LOOP_DEV}p3"
    SRC_ROOT="${LOOP_DEV}p4"
else
    die "Source '$SOURCE' is neither a valid block device nor a regular file."
fi

# Extract the old UUIDs from the source so we can translate them later
if [ "$DRY_RUN" -eq 1 ]; then
    OLD_UUID_EFI="00000000-0000-0000-0000-000000000001"
    OLD_UUID_BOOT="00000000-0000-0000-0000-000000000002"
    OLD_UUID_ROOT="00000000-0000-0000-0000-000000000003"
    echo "[dry-run] would read UUIDs from source partitions"
else
    OLD_UUID_EFI=$(blkid_uuid "$SRC_EFI")
    OLD_UUID_BOOT=$(blkid_uuid "$SRC_BOOT")
    OLD_UUID_ROOT=$(blkid_uuid "$SRC_ROOT")
fi

echo "=========================================="
echo " Phase 2: Target Drive Preparation        "
echo "=========================================="
echo "Initialising disk $TARGET: EFI=$EFI, BOOT=$BOOT, ROOT=$ROOT"

run sudo parted -s "$TARGET" mklabel gpt
run sudo parted -s "$TARGET" mkpart primary 1MiB 2MiB
run sudo parted -s "$TARGET" set 1 bios_grub on
run sudo parted -s "$TARGET" mkpart primary fat32 2MiB 258MiB
run sudo parted -s "$TARGET" set 2 esp on
run sudo parted -s "$TARGET" mkpart primary ext4 258MiB 770MiB
run sudo parted -s "$TARGET" mkpart primary linux-swap 770MiB 16GiB
run sudo parted -s "$TARGET" mkpart primary ext4 16GiB 100%

# Erase any stale filesystem signatures
run sudo wipefs -q -a "$EFI" "$BOOT" "$ROOT"

# Root inode budget: ~4M inodes per 1 TiB (one inode per 256 KiB of capacity).
ROOT_BYTES_PER_INODE=$(( 1024**4 / (4 * 1024**2) ))

# Format target filesystems
run sudo mkfs.fat -F32 -n EFI "$EFI" > /dev/null
run sudo mkfs.ext4 -qF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$BOOT"
run sudo mkswap -q "$SWAP"
run sudo mkfs.ext4 -qF -m 0 -L root -i "$ROOT_BYTES_PER_INODE" -E lazy_itable_init=0,lazy_journal_init=0 -O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed "$ROOT"

# Capture the new target UUIDs
NEW_UUID_EFI=$(blkid_uuid "$EFI")
NEW_UUID_BOOT=$(blkid_uuid "$BOOT")
NEW_UUID_ROOT=$(blkid_uuid "$ROOT")

echo "=========================================="
echo " Phase 3: Mounting & Data Synchronization "
echo "=========================================="
# Mount Target
sudo mount "$ROOT" "$MNT"
sudo mkdir -p "$MNT/boot"
sudo mount "$BOOT" "$MNT/boot"
sudo mkdir -p "$MNT/boot/efi"
sudo mount "$EFI" "$MNT/boot/efi"

# Mount Source (dynamically routed from Block or Loop)
sudo mkdir -p "$SRC"
sudo mount -r -o noatime "$SRC_ROOT" "$SRC"
sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot"
sudo mount -r "$SRC_EFI" "$SRC/boot/efi"

echo "Rsyncing filesystems. This will take a moment..."
run sudo rsync -ahqHAXS --numeric-ids --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/mnt/*","/lost+found"} "$SRC/" "$MNT/"

echo "=========================================="
echo " Phase 4: Filesystem Translation (UUIDs)  "
echo "=========================================="
echo "Translating fstab mappings from source UUIDs to physical target UUIDs..."
run sudo sed -i "s/$OLD_UUID_EFI/$NEW_UUID_EFI/g" "$MNT/etc/fstab"
run sudo sed -i "s/$OLD_UUID_BOOT/$NEW_UUID_BOOT/g" "$MNT/etc/fstab"
run sudo sed -i "s/$OLD_UUID_ROOT/$NEW_UUID_ROOT/g" "$MNT/etc/fstab"

echo "Enforcing Root UUID mapping in GRUB default..."
if grep -q '^GRUB_CMDLINE_LINUX=' "$MNT/etc/default/grub"; then
    run sudo sed -i -E "s|root=UUID=[a-fA-F0-9-]+|root=UUID=$NEW_UUID_ROOT|g" "$MNT/etc/default/grub"
fi

rewrite_grub_distributor

echo "=========================================="
echo " Phase 5: The Headless chroot Environment "
echo "=========================================="
run_chroot_block

echo "=========================================="
echo " Phase 6: Teardown & Cleanup              "
echo "=========================================="
echo "[Teardown] Unmounting filesystems and releasing locks..."
sudo umount -R -q "$SRC" "$MNT" 2>/dev/null

if [ -n "${LOOP_DEV:-}" ]; then
    echo "Detaching loop device: $LOOP_DEV"
    sudo losetup -d "$LOOP_DEV" 2>/dev/null
fi

echo "Done. Disk $TARGET is fully prepared."
