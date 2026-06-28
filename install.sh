#!/bin/bash
# install.sh — flash Ubuntu26-Portable-13GB.img onto a target SSD.
#
# Reads IMAGE/TARGET/MNT/SRC from the environment (or the defaults below) so
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
# IMAGE defaults to the image filename shipped next to this script, which
# is read-only and therefore safe.
# -----------------------------------------------------------------------------
IMAGE="${IMAGE:-Ubuntu26-Portable-13GB.img}"
TARGET="${TARGET:-}"
MNT="${MNT:-/mnt}"
SRC="${SRC:-/altroot}"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image)     IMAGE="$2"; shift 2 ;;
        --target)    TARGET="$2"; shift 2 ;;
        --mnt)       MNT="$2"; shift 2 ;;
        --src)       SRC="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)
            cat <<USAGE
Usage: $0 --target DEV [--image FILE] [--mnt DIR] [--src DIR] [--dry-run] [--force]
  --image FILE   Source image to flash    (default: Ubuntu26-Portable-16GB.img)
  --target DEV   Target block device      (required)
  --mnt DIR      Mount point for the target root (default: /mnt)
  --src DIR      Mount point for the source image (default: /altroot)
  --dry-run      Print destructive commands instead of running them

TARGET may also be passed via the environment.
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
# Sanity: ensure TARGET was supplied, and that the source image isn't
# accidentally the same node as TARGET.
# -----------------------------------------------------------------------------
[ -n "$TARGET" ] || die "TARGET is required (set --target DEV or export TARGET=…)"

if [ -e "$TARGET" ] && [ "$(readlink -f "$IMAGE")" = "$(readlink -f "$TARGET")" ]; then
    die "IMAGE and TARGET resolve to the same path: $IMAGE"
fi

TGT_INFO=$(lsblk -n -d -o SIZE,MODEL "$TARGET" | xargs)
TGT_MODEL=$(lsblk -n -d -o MODEL "$TARGET" | xargs)
if [ -z "$TGT_MODEL" ]; then
    TGT_MODEL="Portable Image"
fi

echo "Installing \"$IMAGE\" to \"$TARGET\" ($TGT_INFO)"
echo "Using \"$MNT\" and \"$SRC\" mount points"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run mode — destructive commands will be printed, not executed)"
fi
confirm_prompt "Press any key to proceed or Ctrl+C to break"

sudo mkdir -p "$MNT" "$SRC"

# Determine partition prefix (p for NVMe / MMCblk, "" for /dev/sd*)
P=$(partition_prefix "$TARGET")
EFI="${TARGET}${P}2"
BOOT="${TARGET}${P}3"
ROOT="${TARGET}${P}4"

# Loop device set in Phase 1; detached at end of script.
LOOP_DEV=""

echo "=========================================="
echo " Phase 1: Mapping the Source Image        "
echo "=========================================="
echo "Scanning the image and mapping partitions to loop devices..."
if [ "$DRY_RUN" -eq 1 ]; then
    LOOP_DEV="/dev/loop0"  # placeholder for the rest of the dry-run
    echo "[dry-run] sudo losetup -P -f --show \"$IMAGE\"  # would yield: $LOOP_DEV"
else
    LOOP_DEV=$(sudo losetup -P -f --show "$IMAGE")
    echo "Image mapped to: $LOOP_DEV"
fi

# Extract the old UUIDs from the image so we can translate them later
if [ "$DRY_RUN" -eq 1 ]; then
    OLD_UUID_EFI="00000000-0000-0000-0000-000000000001"
    OLD_UUID_BOOT="00000000-0000-0000-0000-000000000002"
    OLD_UUID_ROOT="00000000-0000-0000-0000-000000000003"
    echo "[dry-run] would read UUIDs from ${LOOP_DEV}p2/p3/p4"
else
    OLD_UUID_EFI=$(blkid_uuid "${LOOP_DEV}p2")
    OLD_UUID_BOOT=$(blkid_uuid "${LOOP_DEV}p3")
    OLD_UUID_ROOT=$(blkid_uuid "${LOOP_DEV}p4")
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
run sudo parted -s "$TARGET" mkpart primary ext4 770MiB 100%

# Erase any stale filesystem signatures left in the partitions by a previous run.
# parted only rewrites the GPT, so the old superblocks remain and make mkfs print
# "contains a file system ... last mounted on ..." warnings. Wiping them first
# gives mkfs a clean slate (and keeps any genuine mkfs errors visible).
run sudo wipefs -q -a "$EFI" "$BOOT" "$ROOT"

# Root inode budget: ~4M inodes per 1 TiB (one inode per 256 KiB of capacity).
# bytes-per-inode is a ratio, so mke2fs derives the count from the real partition
# size — this single value scales it linearly: 2M for 512 GiB, 8M for 2 TiB, etc.
ROOT_BYTES_PER_INODE=$(( 1024**4 / (4 * 1024**2) ))   # 1 TiB / 4Mi

# Format target filesystems
run sudo mkfs.fat -F32 -n EFI "$EFI" > /dev/null
run sudo mkfs.ext4 -qF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$BOOT"
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

# Mount Source Image
sudo mkdir -p "$SRC"
sudo mount -r -o noatime "${LOOP_DEV}p4" "$SRC"
sudo mount -r -o noatime "${LOOP_DEV}p3" "$SRC/boot"
sudo mount -r "${LOOP_DEV}p2" "$SRC/boot/efi"

echo "Rsyncing filesystems. This will take a moment..."
run sudo rsync -ahqHAXS --numeric-ids --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/mnt/*","/lost+found"} "$SRC/" "$MNT/"

echo "=========================================="
echo " Phase 4: Filesystem Translation (UUIDs)  "
echo "=========================================="
echo "Translating fstab mappings from image UUIDs to physical target UUIDs..."
run sudo sed -i "s/$OLD_UUID_EFI/$NEW_UUID_EFI/g" "$MNT/etc/fstab"
run sudo sed -i "s/$OLD_UUID_BOOT/$NEW_UUID_BOOT/g" "$MNT/etc/fstab"
run sudo sed -i "s/$OLD_UUID_ROOT/$NEW_UUID_ROOT/g" "$MNT/etc/fstab"

echo "Enforcing Root UUID mapping in GRUB default..."
# Replace only the root=UUID=… token inside GRUB_CMDLINE_LINUX, preserving any
# other kernel parameters (mitigations=, systemd.unified_cgroup_hierarchy=, etc.).
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
    sudo losetup -d "$LOOP_DEV" 2>/dev/null
fi

echo "Done. Disk $TARGET is fully prepared."
