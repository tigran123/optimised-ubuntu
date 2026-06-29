#!/bin/bash
# backup.sh — synchronise an offline hybrid-system onto a target SSD.
#
# Reads SRC_DISK/TGT_DISK/MNT/SRC from the environment (or the defaults
# below) so this script can be driven from CI / a rescue environment.
# Run with --dry-run to print every destructive command without
# executing it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portable-common.sh
. "$SCRIPT_DIR/portable-common.sh"

# -----------------------------------------------------------------------------
# Configuration
#
# NOTE: SRC_DISK and TGT_DISK have no defaults. backup.sh is destructive —
# a stray /dev/sda default would silently overwrite the user's first disk
# if they ever ran it without arguments. Operator must set both via flag
# or environment.
# -----------------------------------------------------------------------------
SRC_DISK="${SRC_DISK:-}"
TGT_DISK="${TGT_DISK:-}"
MNT="${MNT:-/mnt}"
SRC="${SRC:-/altroot}"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --src-disk)   SRC_DISK="$2"; shift 2 ;;
        --tgt-disk)   TGT_DISK="$2"; shift 2 ;;
        --mnt)        MNT="$2"; shift 2 ;;
        --src)        SRC="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)
            cat <<USAGE
Usage: $0 --src-disk DEV --tgt-disk DEV [--mnt DIR] [--src DIR] [--dry-run]
  --src-disk DEV   Source block device to clone from (required)
  --tgt-disk DEV   Target block device to write to  (required)
  --mnt DIR        Mount point for the target root   (default: /mnt)
  --src DIR        Mount point for the source root   (default: /altroot)
  --dry-run        Print destructive commands instead of running them

SRC_DISK and TGT_DISK may also be passed via the environment.
USAGE
            exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Sanity: source and target must be different physical devices
# -----------------------------------------------------------------------------
[ -n "$SRC_DISK" ] || die "SRC_DISK is required (set --src-disk DEV or export SRC_DISK=…)"
[ -n "$TGT_DISK" ] || die "TGT_DISK is required (set --tgt-disk DEV or export TGT_DISK=…)"
if [ "$(readlink -f "$SRC_DISK")" = "$(readlink -f "$TGT_DISK")" ]; then
    die "SRC_DISK and TGT_DISK resolve to the same device: $SRC_DISK"
fi

# -----------------------------------------------------------------------------
# Dry-run wrapper
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

# Loop device creation is irrelevant for backup.sh; teardown no-ops on it.
LOOP_DEV=""

sudo mkdir -p "$MNT" "$SRC"

# Determine partition prefix for both source and target
SP=$(partition_prefix "$SRC_DISK")
TP=$(partition_prefix "$TGT_DISK")

echo "=========================================="
echo " Pre-Flight: Structural Validation        "
echo "=========================================="
# Abort if either disk fails the structural check
validate_disk_structure "$SRC_DISK" "$SP" || exit 1
validate_disk_structure "$TGT_DISK" "$TP" || exit 1

# Extract size and model, using xargs to cleanly strip whitespace
SRC_INFO=$(lsblk -n -d -o SIZE,MODEL "$SRC_DISK" | xargs)
TGT_INFO=$(lsblk -n -d -o SIZE,MODEL "$TGT_DISK" | xargs)

# Capture just the model for the GRUB menu
TGT_MODEL=$(lsblk -n -d -o MODEL "$TGT_DISK" | xargs)

echo ""
echo "Backing up offline system from:"
echo "  Source: $SRC_DISK ($SRC_INFO)"
echo "  Target: $TGT_DISK ($TGT_INFO)"
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run mode — destructive commands will be printed, not executed)"
fi
confirm_prompt "Press any key to proceed or Ctrl+C to break"

# Assign partitions
SRC_EFI="${SRC_DISK}${SP}2"
SRC_BOOT="${SRC_DISK}${SP}3"
SRC_ROOT="${SRC_DISK}${SP}4"

TGT_EFI="${TGT_DISK}${TP}2"
TGT_BOOT="${TGT_DISK}${TP}3"
TGT_ROOT="${TGT_DISK}${TP}4"

echo "=========================================="
echo " Phase 1: UUID Extraction                 "
echo "=========================================="
echo "Gathering UUIDs directly from block devices..."
# Reject empty UUIDs so the awk gsub() pass can't silently corrupt the fstab
OLD_UUID_EFI=$(blkid_uuid "$SRC_EFI")
OLD_UUID_BOOT=$(blkid_uuid "$SRC_BOOT")
OLD_UUID_ROOT=$(blkid_uuid "$SRC_ROOT")

NEW_UUID_EFI=$(blkid_uuid "$TGT_EFI")
NEW_UUID_BOOT=$(blkid_uuid "$TGT_BOOT")
NEW_UUID_ROOT=$(blkid_uuid "$TGT_ROOT")

echo "=========================================="
echo " Phase 2: Mounting Filesystems            "
echo "=========================================="
# Mount Target (Read-Write)
sudo mount "$TGT_ROOT" "$MNT"
sudo mkdir -p "$MNT/boot"
sudo mount "$TGT_BOOT" "$MNT/boot"
sudo mkdir -p "$MNT/boot/efi"
sudo mount "$TGT_EFI" "$MNT/boot/efi"

# Mount Source (Read-Only)
sudo mount -r -o noatime "$SRC_ROOT" "$SRC"
sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot"
sudo mount -r "$SRC_EFI" "$SRC/boot/efi"

echo "=========================================="
echo " Phase 3: Synchronization                 "
echo "=========================================="
echo "Rsyncing filesystems: \"$SRC\" => \"$MNT\" This will take a moment..."
run sudo rsync -ahqHAXS --delete --numeric-ids --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/mnt/*","/lost+found"} "$SRC/" "$MNT/"

echo "=========================================="
echo " Phase 4: Filesystem Translation (UUIDs)  "
echo "=========================================="
echo "Translating fstab mappings and sanitizing foreign mounts..."
rewrite_fstab

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

echo "Done. Disk $TGT_DISK is now an exact, updated clone of $SRC_DISK."
