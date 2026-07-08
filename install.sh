#!/bin/bash
# install.sh — flash a portable OS image or scattered partitions onto a target.
#
# Three things can be combined freely:
#   * a unified source: a whole block device or a disk-image file (.img);
#   * a scattered source: independent --source-efi/--source-boot/--source-root
#     partitions;
#   * a unified target (--target, auto-partitioned) or independent --target-*
#     partitions.
#
# Per-role rule: each --target-X defaults to its --source-X, so a role whose
# target equals its source is left untouched (in-place), while a role whose
# target differs is migrated (formatted + copied). This makes "move only / to a
# new partition, keeping BIOS Boot, EFI and /boot where they are" a first-class
# operation. See --help for examples.
#
# With --update, a differing role is *synced* instead of migrated: the target
# filesystem is kept as-is (no mkfs) and rsync runs with --delete, so an
# existing clone is refreshed in place rather than rebuilt from scratch. This
# subsumes the old backup.sh disk-to-disk clone.
set -euo pipefail

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

confirm_prompt() {
    local msg=${1:-Press any key to proceed}
    read -n 1 -s -r -p "$msg (or Ctrl+C to break)..."
    echo ""
}

# -----------------------------------------------------------------------------
# Known GPT partition type GUIDs
# -----------------------------------------------------------------------------
GUID_BIOS="21686148-6449-6e6f-744e-656564454649"
GUID_EFI="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
GUID_LINUX="0fc63daf-8483-4772-8e79-3d69d8477de4"

# -----------------------------------------------------------------------------
# Topology & Validation Helpers
# -----------------------------------------------------------------------------
partition_prefix() {
    local disk=$1
    if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
        echo "p"
    else
        echo ""
    fi
}

get_parent_disk() {
    local part=$1
    local pkname
    pkname=$(lsblk -n -d -o PKNAME "$part" 2>/dev/null || true)
    if [ -n "$pkname" ]; then
        echo "/dev/$pkname"
    else
        echo ""
    fi
}

validate_partition_type() {
    local part=$1
    local exp_type=$2
    local label=$3

    if [ ! -b "$part" ]; then
        echo "  [FAIL] $label partition ($part) is not a valid block device."
        return 1
    fi

    local ptype
    ptype=$(lsblk -n -d -o PARTTYPE "$part" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ "$ptype" != "$exp_type" ]; then
        echo "  [FAIL] $label partition ($part) has type $ptype. Expected $exp_type."
        return 1
    fi
    echo "  [PASS] $label partition ($part) validated."
    return 0
}

# validate_disk_structure <disk> <part_prefix>
#   Confirm a whole disk carries the unified 4-partition GPT layout this toolkit
#   produces: BIOS boot (p1), EFI (p2), Linux /boot (p3), Linux root (p4).
#   Returns non-zero (without exiting) so callers can react.
validate_disk_structure() {
    local disk=$1 p=$2
    info "Validating topology of $disk..."
    if [ ! -b "$disk" ]; then
        echo "  [FAIL] $disk is not a valid block device."
        return 1
    fi
    validate_partition_type "${disk}${p}1" "$GUID_BIOS"  "BIOS boot" || return 1
    validate_partition_type "${disk}${p}2" "$GUID_EFI"   "EFI"       || return 1
    validate_partition_type "${disk}${p}3" "$GUID_LINUX" "Boot"      || return 1
    validate_partition_type "${disk}${p}4" "$GUID_LINUX" "Root"      || return 1
    echo "  [PASS] $disk has the expected BIOS/EFI/boot/root layout."
    return 0
}

# resolve_source_roles <disk>
#   Scan a unified source disk (or attached loop device) and assign its EFI,
#   /boot and root partitions into SRC_EFI/SRC_BOOT/SRC_ROOT by GPT type and
#   filesystem label, rather than assuming fixed partition numbers. This lets a
#   source that carries an inline swap partition (so root is not partition 4) —
#   or any other non-canonical ordering — resolve correctly. EFI is the ESP;
#   /boot and root are the Linux-filesystem partitions, told apart by their
#   "boot"/"root" labels and otherwise by on-disk order. Dies if a role is
#   missing so an unexpected layout fails here rather than at mount time.
resolve_source_roles() {
    local disk=$1
    local dev ptype fstype label
    local -a linux_parts=()
    SRC_EFI=""; SRC_BOOT=""; SRC_ROOT=""

    while read -r dev; do
        [ "$dev" = "$disk" ] && continue
        ptype=$(lsblk -dno PARTTYPE "$dev" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$ptype" in
            "$GUID_EFI")
                SRC_EFI="$dev" ;;
            "$GUID_LINUX")
                fstype=$(lsblk -dno FSTYPE "$dev" 2>/dev/null)
                [ "$fstype" = swap ] && continue   # a Linux-typed swap: not /boot or /
                label=$(lsblk -dno LABEL "$dev" 2>/dev/null)
                case "$label" in
                    boot) SRC_BOOT="$dev" ;;
                    root) SRC_ROOT="$dev" ;;
                    *)    linux_parts+=("$dev") ;;
                esac ;;
        esac
    done < <(lsblk -lnpo NAME "$disk")

    # Any Linux-fs partitions we could not tell apart by label fall back to
    # on-disk order: the first unclaimed one is /boot, the next is root.
    for dev in "${linux_parts[@]}"; do
        if   [ -z "$SRC_BOOT" ]; then SRC_BOOT="$dev"
        elif [ -z "$SRC_ROOT" ]; then SRC_ROOT="$dev"
        fi
    done

    [ -n "$SRC_EFI" ]  || die "Source $disk has no EFI System partition."
    [ -n "$SRC_BOOT" ] || die "Source $disk has no Linux /boot partition."
    [ -n "$SRC_ROOT" ] || die "Source $disk has no Linux root partition."
}

# -----------------------------------------------------------------------------
# UUID Operations
# -----------------------------------------------------------------------------
blkid_uuid() {
    local dev=$1
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$dev") || \
        die "Could not determine UUID for $dev (unformatted or missing?)"
    [ -n "$uuid" ] || die "Empty UUID for $dev (unformatted?)"
    printf '%s' "$uuid"
}

# -----------------------------------------------------------------------------
# Translation Operations
# -----------------------------------------------------------------------------
rewrite_fstab() {
    sudo awk -v old_efi="$OLD_UUID_EFI" -v new_efi="$NEW_UUID_EFI" \
             -v old_boot="$OLD_UUID_BOOT" -v new_boot="$NEW_UUID_BOOT" \
             -v old_root="$OLD_UUID_ROOT" -v new_root="$NEW_UUID_ROOT" '
    {
        gsub(old_efi, new_efi);
        gsub(old_boot, new_boot);
        gsub(old_root, new_root);

        if ($0 ~ /UUID=/ || $0 ~ /\/dev\/disk\/by-uuid\//) {
            if ($0 !~ new_efi && $0 !~ new_boot && $0 !~ new_root) {
                # Ensure we also ignore foreign swap partitions
                print "# [PORTABLE-SYNC-DISABLED] " $0;
                next;
            }
        }

        if ($4 ~ /(^|,)bind(,|$)/) {
            if ($1 == "/tmp" && $2 == "/var/tmp") {
                print $0;
                next;
            }
            print "# [PORTABLE-SYNC-DISABLED] " $0;
            next;
        }

        print $0;
    }' "$MNT/etc/fstab" | sudo tee "$MNT/etc/fstab.new" >/dev/null

    sudo mv "$MNT/etc/fstab.new" "$MNT/etc/fstab"
    sudo chown root:root "$MNT/etc/fstab"
    sudo chmod 644 "$MNT/etc/fstab"
}

rewrite_grub_distributor() {
    info "Updating GRUB_DISTRIBUTOR with target model ($TGT_MODEL)..."
    if [ -f "$MNT/etc/default/grub" ]; then
        sudo sed -i -E 's/^(GRUB_DISTRIBUTOR="Desktop ).*( `\( \.)/\1'"$TGT_MODEL"'\2/' "$MNT/etc/default/grub"
    fi
    if [ -f "$MNT/etc/grub.d/09_console" ]; then
        sudo sed -i -E 's/^(GRUB_DISTRIBUTOR="Console ).*( `\( \.)/\1'"$TGT_MODEL"'\2/' "$MNT/etc/grub.d/09_console"
    fi
}

run_chroot_block() {
    for i in /dev /dev/pts /proc /sys /run; do
        sudo mount --bind "$i" "$MNT$i"
    done

    # INSTALL_GRUB_BIOS / INSTALL_GRUB_EFI default to 1 (full install) for callers
    # that don't set them; install.sh sets them per-role so EFI/BIOS can be kept
    # intact during a partial (e.g. rootfs-only) migration. TGT_GRUB_DISK and
    # NEW_UUID_BOOT are resolved by the caller.
    sudo chroot "$MNT" /bin/bash <<EOF
set -e
echo "=> Inside chroot..."

if [ "${INSTALL_GRUB_BIOS:-1}" = 1 ]; then
    echo "=> Installing legacy BIOS GRUB to $TGT_GRUB_DISK..."
    grub-install --target=i386-pc "$TGT_GRUB_DISK"
fi

if [ "${INSTALL_GRUB_EFI:-1}" = 1 ]; then
    echo "=> Installing UEFI GRUB (removable)..."
    if grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-uefi-secure-boot; then
        rm -rf /boot/efi/EFI/ubuntu
        mkdir -p /boot/efi/EFI/BOOT

        echo "search --no-floppy --fs-uuid --set=root $NEW_UUID_BOOT" > /boot/efi/EFI/BOOT/grub.cfg
        echo 'if [ -f (\$root)/boot/grub/grub.cfg ]; then' >> /boot/efi/EFI/BOOT/grub.cfg
        echo '    set prefix=(\$root)/boot/grub' >> /boot/efi/EFI/BOOT/grub.cfg
        echo 'else' >> /boot/efi/EFI/BOOT/grub.cfg
        echo '    set prefix=(\$root)/grub' >> /boot/efi/EFI/BOOT/grub.cfg
        echo 'fi' >> /boot/efi/EFI/BOOT/grub.cfg
        echo 'configfile \$prefix/grub.cfg' >> /boot/efi/EFI/BOOT/grub.cfg
    else
        echo "grub-install (EFI) failed; leaving /boot/efi/EFI/ubuntu untouched."
    fi
fi

echo "=> Regenerating Master Menu..."
update-grub

echo "=> Rebuilding initramfs..."
update-initramfs -u -k all

echo "=> Exiting chroot."
EOF
}

# Unified parameters
SOURCE="${SOURCE:-Ubuntu26-Portable-16GB.img}"
TARGET="${TARGET:-}"

# Scattered source partitions
SRC_EFI="${SRC_EFI:-}"
SRC_BOOT="${SRC_BOOT:-}"
SRC_ROOT="${SRC_ROOT:-}"
SRC_SWAP="${SRC_SWAP:-}"

# Scattered target partitions
TGT_BIOS="${TGT_BIOS:-}"
TGT_EFI="${TGT_EFI:-}"
TGT_BOOT="${TGT_BOOT:-}"
TGT_ROOT="${TGT_ROOT:-}"
TGT_SWAP="${TGT_SWAP:-}"

MNT="${MNT:-/mnt}"
SRC="${SRC:-/altroot}"
EXCLUDE_FROM="${EXCLUDE_FROM:-}"
DRY_RUN=0
UPDATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image|--source) SOURCE="$2"; shift 2 ;;
        --target)         TARGET="$2"; shift 2 ;;

        --source-efi)     SRC_EFI="$2";  shift 2 ;;
        --source-boot)    SRC_BOOT="$2"; shift 2 ;;
        --source-root)    SRC_ROOT="$2"; shift 2 ;;
        --source-swap)    SRC_SWAP="$2"; shift 2 ;;

        --target-bios-boot) TGT_BIOS="$2"; shift 2 ;;
        --target-efi)       TGT_EFI="$2";  shift 2 ;;
        --target-boot)      TGT_BOOT="$2"; shift 2 ;;
        --target-root)      TGT_ROOT="$2"; shift 2 ;;
        --target-swap)      TGT_SWAP="$2"; shift 2 ;;

        --mnt)            MNT="$2"; shift 2 ;;
        --src)            SRC="$2"; shift 2 ;;
        --exclude-from)   EXCLUDE_FROM="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --update)         UPDATE=1; shift ;;
        -h|--help)
            cat <<USAGE
Usage: $0 [source] [target] [options]

Deploys a portable Ubuntu system. Each role (EFI, /boot, /, swap) is either left
in place or migrated: a --target-X defaults to its --source-X, so a role whose
target equals its source is left untouched, and one whose target differs is
formatted and copied.

Source (pick one form):
  --image|--source FILE|DEV   Whole image file or block device
                              (default: Ubuntu26-Portable-16GB.img)
  --source-efi / --source-boot / --source-root PART
                              Scattered source: supply all three
  --source-swap PART          Reuse this swap as-is (NOT reformatted)

Target:
  --target DEV                Whole device: GPT-partition it and format
                              (with --update: treat as already-partitioned and
                              sync onto its existing filesystems instead)
  --target-bios-boot PART     Provide to (re)install the legacy BIOS bootloader
  --target-efi PART           Defaults to --source-efi  (omit/equal = keep in place)
  --target-boot PART          Defaults to --source-boot (omit/equal = keep in place)
  --target-root PART          Defaults to --source-root (omit/equal = keep in place)
  --target-swap PART          Use this swap, reformatting it (mkswap)

Other:
  --update                    Sync onto already-formatted target partitions:
                              skip mkfs and rsync with --delete, refreshing an
                              existing clone in place instead of reformatting it
  --exclude-from FILE         Pass FILE to rsync as --exclude-from, so the listed
                              paths are omitted from the copy (e.g. to produce an
                              impersonal clone). Works with or without --update;
                              under --update the listed paths are also purged from
                              the target (rsync --delete-excluded).
  --mnt DIR                   Target root mount point  (default: /mnt)
  --src DIR                   Source root mount point  (default: /altroot)
  --dry-run                   Print destructive commands instead of running them
  -h, --help                  Show this help

Notes:
  * --source-swap (reuse) and --target-swap (reformat) are mutually exclusive.
  * EFI booting uses the EFI System Partition; the BIOS Boot partition is only
    for legacy boot and is regenerated by grub-install (when --target-bios-boot
    is given) or left intact otherwise.

Examples:
  # Full deploy of an image onto a fresh disk:
  $0 --image Ubuntu26-Portable-16GB.img --target /dev/sda

  # Migrate ONLY the root filesystem to a new partition, keeping EFI and /boot:
  $0 --source-efi /dev/sda2 --source-boot /dev/sda3 \\
     --source-root /dev/sda4 --target-root /dev/nvme0n1p1

  # Incrementally sync a split-disk source onto an already-formatted disk
  # (no reformat — rsync --delete refreshes the existing clone). Replaces the
  # old backup.sh disk-to-disk clone:
  $0 --source-efi /dev/sda2 --source-boot /dev/sda3 \\
     --source-root /dev/nvme0n1p1 \\
     --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \\
     --target-boot /dev/sdb3 --target-root /dev/sdb4 --update

  # Impersonal clone: deploy minus the personal paths listed in exclude.txt:
  $0 --image Ubuntu26-Portable-16GB.img --target /dev/sda \\
     --exclude-from exclude.txt

Most options also read from the matching environment variable (SOURCE, TARGET,
SRC_ROOT, TGT_ROOT, TGT_SWAP, EXCLUDE_FROM, ...).
USAGE
            exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

# An --exclude-from file is read by rsync on this host (not in the chroot).
# Validate it early and make it absolute so sudo's working directory is moot.
if [ -n "$EXCLUDE_FROM" ]; then
    [ -f "$EXCLUDE_FROM" ] || die "--exclude-from file not found: $EXCLUDE_FROM"
    EXCLUDE_FROM=$(readlink -f "$EXCLUDE_FROM")
fi

# Dry-run wrapper — print the command (properly quoted) or run it.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# True when two paths resolve to the same device/file.
same_dev() { [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ]; }

# Summary label for a role: SYNC when --update keeps the target filesystem and
# rsyncs --delete onto it, MIGRATE when the target is reformatted, in-place when
# target equals source (untouched).
role_state() {
    if [ "$1" -ne 1 ]; then echo "in-place"
    elif [ "$UPDATE" -eq 1 ]; then echo "SYNC    "
    else echo "MIGRATE "; fi
}

LOOP_DEV=""
UNIFIED_TARGET=0

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------
SCATTERED_SOURCE=0
if [ -n "$SRC_EFI" ] || [ -n "$SRC_BOOT" ] || [ -n "$SRC_ROOT" ]; then
    SCATTERED_SOURCE=1
    ns=0
    for v in "$SRC_EFI" "$SRC_BOOT" "$SRC_ROOT"; do
        if [ -n "$v" ]; then ns=$((ns+1)); fi
    done
    [ "$ns" -eq 3 ] || die "Scattered source needs all of --source-efi/--source-boot/--source-root (got $ns/3)."
    [ -z "$TARGET" ] || die "Do not combine scattered --source-* with a unified --target."
fi

# Swap: --source-swap reuses (no mkswap); --target-swap reformats (mkswap); not both.
SWAP_DEV=""
DO_MKSWAP=0
if [ -n "$SRC_SWAP" ] && [ -n "$TGT_SWAP" ]; then
    die "Specify only one of --source-swap (reuse) or --target-swap (reformat), not both."
elif [ -n "$TGT_SWAP" ]; then
    SWAP_DEV="$TGT_SWAP"; DO_MKSWAP=1
elif [ -n "$SRC_SWAP" ]; then
    SWAP_DEV="$SRC_SWAP"; DO_MKSWAP=0
fi

echo "=========================================="
echo " Phase 1: Resolving Source Architecture   "
echo "=========================================="
if [ $SCATTERED_SOURCE -eq 1 ]; then
    echo "Source Mode: Scattered Partitions"
    validate_partition_type "$SRC_EFI"  "$GUID_EFI"   "Source EFI"  || die "Invalid Source EFI"
    validate_partition_type "$SRC_BOOT" "$GUID_LINUX" "Source Boot" || die "Invalid Source Boot"
    validate_partition_type "$SRC_ROOT" "$GUID_LINUX" "Source Root" || die "Invalid Source Root"
else
    if [ -b "$SOURCE" ]; then
        echo "Source Mode: Unified Block Device ($SOURCE)"
        resolve_source_roles "$SOURCE"
    elif [ -f "$SOURCE" ]; then
        echo "Source Mode: Flat File Image ($SOURCE)"
        if [ "$DRY_RUN" -eq 1 ]; then
            # No loop device is attached in dry-run, so fall back to the toolkit's
            # canonical partition numbers just for the printed summary.
            LOOP_DEV="/dev/loop0"
            echo "[dry-run] sudo losetup -P -f --show \"$SOURCE\""
            SRC_EFI="${LOOP_DEV}p2"
            SRC_BOOT="${LOOP_DEV}p3"
            SRC_ROOT="${LOOP_DEV}p4"
        else
            LOOP_DEV=$(sudo losetup -P -f --show "$SOURCE")
            echo "Image mapped to loop device: $LOOP_DEV"
            sudo udevadm settle
            resolve_source_roles "$LOOP_DEV"
        fi
    else
        die "Source '$SOURCE' is neither a valid block device nor a regular file."
    fi
fi

# Old UUIDs from the source (translated into the target's fstab/GRUB later).
if [ "$DRY_RUN" -eq 1 ]; then
    OLD_UUID_EFI="00000000-0000-0000-0000-000000000001"
    OLD_UUID_BOOT="00000000-0000-0000-0000-000000000002"
    OLD_UUID_ROOT="00000000-0000-0000-0000-000000000003"
else
    OLD_UUID_EFI=$(blkid_uuid "$SRC_EFI")
    OLD_UUID_BOOT=$(blkid_uuid "$SRC_BOOT")
    OLD_UUID_ROOT=$(blkid_uuid "$SRC_ROOT")
fi

echo "=========================================="
echo " Phase 2: Target Drive Preparation        "
echo "=========================================="
if [ $SCATTERED_SOURCE -eq 1 ]; then
    # Each target defaults to its source => in-place unless overridden.
    TGT_EFI="${TGT_EFI:-$SRC_EFI}"
    TGT_BOOT="${TGT_BOOT:-$SRC_BOOT}"
    TGT_ROOT="${TGT_ROOT:-$SRC_ROOT}"
    echo "Target Mode: Scattered Partitions (per-role migrate / in-place)"
    if [ -n "$TGT_BIOS" ]; then
        validate_partition_type "$TGT_BIOS" "$GUID_BIOS" "Target BIOS" || die "Invalid Target BIOS"
    fi
    validate_partition_type "$TGT_EFI"  "$GUID_EFI"   "Target EFI"  || die "Invalid Target EFI"
    validate_partition_type "$TGT_BOOT" "$GUID_LINUX" "Target Boot" || die "Invalid Target Boot"
    validate_partition_type "$TGT_ROOT" "$GUID_LINUX" "Target Root" || die "Invalid Target Root"
else
    # Unified/image source => full deploy. Target is unified or all four --target-*.
    nt=0
    for v in "$TGT_BIOS" "$TGT_EFI" "$TGT_BOOT" "$TGT_ROOT"; do
        if [ -n "$v" ]; then nt=$((nt+1)); fi
    done
    if [ "$nt" -gt 0 ] && [ "$nt" -lt 4 ]; then
        die "Scattered target needs all four of --target-bios-boot/--target-efi/--target-boot/--target-root (got $nt/4)."
    fi
    if [ "$nt" -eq 4 ]; then
        echo "Target Mode: Scattered Partitions (full deploy)"
        validate_partition_type "$TGT_BIOS" "$GUID_BIOS"  "Target BIOS" || die "Invalid Target BIOS"
        validate_partition_type "$TGT_EFI"  "$GUID_EFI"   "Target EFI"  || die "Invalid Target EFI"
        validate_partition_type "$TGT_BOOT" "$GUID_LINUX" "Target Boot" || die "Invalid Target Boot"
        validate_partition_type "$TGT_ROOT" "$GUID_LINUX" "Target Root" || die "Invalid Target Root"
    else
        [ -n "$TARGET" ] || die "Specify a unified --target DEV, all four --target-* partitions, or scattered --source-* for partial migration."
        if [ "$DRY_RUN" -eq 0 ] && [ ! -b "$TARGET" ]; then
            die "Target '$TARGET' is not a block device."
        fi
        UNIFIED_TARGET=1
        echo "Target Mode: Unified Block Device ($TARGET)"
        P=$(partition_prefix "$TARGET")
        TGT_BIOS="${TARGET}${P}1"
        TGT_EFI="${TARGET}${P}2"
        TGT_BOOT="${TARGET}${P}3"
        TGT_ROOT="${TARGET}${P}4"
        # --update trusts the existing layout (we won't repartition or format
        # it), so the disk must already carry our BIOS/EFI/boot/root layout.
        if [ $UPDATE -eq 1 ]; then
            validate_disk_structure "$TARGET" "$P" || \
                die "Target $TARGET lacks the expected BIOS/EFI/boot/root layout (required for --update)."
        fi
    fi
fi

# Per-role migrate (target differs from source) vs in-place (same device).
if same_dev "$TGT_EFI"  "$SRC_EFI";  then MIGRATE_EFI=0;  else MIGRATE_EFI=1;  fi
if same_dev "$TGT_BOOT" "$SRC_BOOT"; then MIGRATE_BOOT=0; else MIGRATE_BOOT=1; fi
if same_dev "$TGT_ROOT" "$SRC_ROOT"; then MIGRATE_ROOT=0; else MIGRATE_ROOT=1; fi

# Bootloader install scope: BIOS only when a BIOS target is given, EFI when the
# ESP is fresh. (run_chroot_block always runs update-grub + update-initramfs.)
if [ -n "$TGT_BIOS" ]; then INSTALL_GRUB_BIOS=1; else INSTALL_GRUB_BIOS=0; fi
INSTALL_GRUB_EFI=$MIGRATE_EFI

if [ $MIGRATE_EFI -eq 0 ] && [ $MIGRATE_BOOT -eq 0 ] && [ $MIGRATE_ROOT -eq 0 ] && [ -z "$SWAP_DEV" ]; then
    die "Nothing to do: every role resolves in-place and no swap was given."
fi

# Under --update the target filesystems must already exist and be the right
# type — we won't mkfs, so catch unformatted or wrong-type partitions now
# rather than failing with a cryptic mount error later.
if [ $UPDATE -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    for entry in "$TGT_EFI:EFI:vfat:$MIGRATE_EFI" \
                 "$TGT_BOOT:Boot:ext4:$MIGRATE_BOOT" \
                 "$TGT_ROOT:Root:ext4:$MIGRATE_ROOT"; do
        dev="${entry%%:*}"
        rest="${entry#*:}"
        label="${rest%%:*}"
        rest="${rest#*:}"
        expected="${rest%%:*}"
        migrate="${rest##*:}"
        [ "$migrate" -eq 1 ] || continue
        fstype=$(sudo blkid -o value -s TYPE "$dev" 2>/dev/null || true)
        if [ -z "$fstype" ]; then
            die "--update: $label target $dev has no recognizable filesystem (unformatted?)."
        elif [ "$fstype" != "$expected" ]; then
            die "--update: $label target $dev has filesystem '$fstype', expected '$expected'."
        fi
    done
fi

# Disk to install the legacy BIOS bootloader onto. Only meaningful when a BIOS
# target was given; otherwise empty (grub-install --target=i386-pc is skipped).
if [ $INSTALL_GRUB_BIOS -eq 1 ]; then
    if [ $UNIFIED_TARGET -eq 1 ]; then
        TGT_GRUB_DISK="$TARGET"
    else
        TGT_GRUB_DISK=$(get_parent_disk "$TGT_BIOS")
        [ -n "$TGT_GRUB_DISK" ] || die "Could not resolve parent disk for BIOS partition $TGT_BIOS"
    fi
else
    TGT_GRUB_DISK=""
fi

# Disk whose model brands the GRUB menu = where the rootfs (the OS) lives.
if [ $UNIFIED_TARGET -eq 1 ]; then
    BRAND_DISK="$TARGET"
else
    BRAND_DISK=$(get_parent_disk "$TGT_ROOT")
fi
TGT_MODEL=$(lsblk -n -d -o MODEL "${BRAND_DISK:-}" 2>/dev/null | xargs || true)
[ -n "$TGT_MODEL" ] || TGT_MODEL="Portable Image"

# Safety: a partition we are about to format must not also be a source we read.
migrated_targets=()
if [ $MIGRATE_EFI  -eq 1 ]; then migrated_targets+=("$TGT_EFI");  fi
if [ $MIGRATE_BOOT -eq 1 ]; then migrated_targets+=("$TGT_BOOT"); fi
if [ $MIGRATE_ROOT -eq 1 ]; then migrated_targets+=("$TGT_ROOT"); fi
if [ "$DO_MKSWAP"  -eq 1 ]; then migrated_targets+=("$SWAP_DEV"); fi
source_devs=("$SRC_EFI" "$SRC_BOOT" "$SRC_ROOT")
if [ -n "$SRC_SWAP" ]; then source_devs+=("$SRC_SWAP"); fi
if [ ${#migrated_targets[@]} -gt 0 ]; then
    for t in "${migrated_targets[@]}"; do
        for s in "${source_devs[@]}"; do
            if same_dev "$t" "$s"; then
                die "Refusing to write to $t: it is also a source partition."
            fi
        done
    done
fi

# ---- Summary + single confirmation gate (before anything destructive) ----
echo
echo "About to install:"
if [ $SCATTERED_SOURCE -eq 1 ]; then
    echo "  Source:   scattered  (efi=$SRC_EFI boot=$SRC_BOOT root=$SRC_ROOT)"
else
    echo "  Source:   $SOURCE${LOOP_DEV:+  (loop $LOOP_DEV)}"
fi
echo "  EFI:      $(role_state $MIGRATE_EFI)  $TGT_EFI"
echo "  /boot:    $(role_state $MIGRATE_BOOT)  $TGT_BOOT"
echo "  / (root): $(role_state $MIGRATE_ROOT)  $TGT_ROOT"
if [ -n "$SWAP_DEV" ]; then
    if [ "$DO_MKSWAP" -eq 1 ]; then echo "  swap:     reformat  $SWAP_DEV"; else echo "  swap:     reuse     $SWAP_DEV"; fi
else
    echo "  swap:     none"
fi
echo "  Menu:     GRUB title branded \"$TGT_MODEL\" (rootfs on ${BRAND_DISK:-?})"
if [ $INSTALL_GRUB_BIOS -eq 1 ] && [ $INSTALL_GRUB_EFI -eq 1 ]; then
    echo "  Bootldr:  reinstall legacy BIOS -> $TGT_GRUB_DISK, and UEFI (removable)"
elif [ $INSTALL_GRUB_BIOS -eq 1 ]; then
    echo "  Bootldr:  reinstall legacy BIOS -> $TGT_GRUB_DISK (UEFI left intact)"
elif [ $INSTALL_GRUB_EFI -eq 1 ]; then
    echo "  Bootldr:  reinstall UEFI (removable) (legacy BIOS left intact)"
else
    echo "  Bootldr:  kept as-is — only update-grub + update-initramfs run"
fi
echo "  Mounts:   target=$MNT  source=$SRC"
if [ -n "$EXCLUDE_FROM" ]; then
    if [ $UPDATE -eq 1 ]; then
        echo "  Excludes: --exclude-from=$EXCLUDE_FROM (listed paths purged from target via --delete-excluded)"
    else
        echo "  Excludes: --exclude-from=$EXCLUDE_FROM (listed paths not copied)"
    fi
fi
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (dry-run mode — destructive commands will be printed, not executed)"
fi
echo
if [ $UPDATE -eq 1 ]; then
    confirm_prompt "Proceed? This will OVERWRITE files on the target partitions (rsync --delete, no reformat)"
else
    confirm_prompt "Proceed? This will ERASE the migrated target partitions"
fi

# ---- Partition a unified target (only now, after confirmation) ----
# Skipped under --update: the disk is already partitioned and we keep it.
if [ $UNIFIED_TARGET -eq 1 ] && [ $UPDATE -eq 0 ]; then
    run sudo parted -s "$TARGET" mklabel gpt
    run sudo parted -s "$TARGET" mkpart primary 1MiB 2MiB
    run sudo parted -s "$TARGET" set 1 bios_grub on
    run sudo parted -s "$TARGET" mkpart primary fat32 2MiB 258MiB
    run sudo parted -s "$TARGET" set 2 esp on
    run sudo parted -s "$TARGET" mkpart primary ext4 258MiB 770MiB
    run sudo parted -s "$TARGET" mkpart primary ext4 770MiB 100%
    run sudo udevadm settle
fi

# ---- Format the migrated roles ----
# Skipped entirely under --update, which keeps each target filesystem intact and
# only rsyncs --delete onto it. (--target-swap reformatting is independent: it is
# an explicit opt-in and still honoured below.)
if [ $UPDATE -eq 0 ]; then
    if [ $MIGRATE_EFI -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_EFI"
        run sudo mkfs.fat -F32 -n EFI "$TGT_EFI" > /dev/null
    fi
    if [ $MIGRATE_BOOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_BOOT"
        run sudo mkfs.ext4 -qF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$TGT_BOOT"
    fi
    if [ $MIGRATE_ROOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_ROOT"

        TGT_BYTES=$(sudo blockdev --getsize64 "$TGT_ROOT")
        ROOT_BYTES_PER_INODE=$(( 1024**4 / (4 * 1024**2) ))
        CALC_INODES=$(( TGT_BYTES / ROOT_BYTES_PER_INODE ))
        MIN_INODES=$(( 1024**2 ))
        TARGET_INODES=$(( CALC_INODES < MIN_INODES ? MIN_INODES : CALC_INODES ))

        run sudo mkfs.ext4 -qF -m 0 -L root -N "$TARGET_INODES" -E lazy_itable_init=0,lazy_journal_init=0 -O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed "$TGT_ROOT"
    fi
fi
if [ "$DO_MKSWAP" -eq 1 ]; then
    run sudo wipefs -q -a "$SWAP_DEV"
    run sudo mkswap -q "$SWAP_DEV"
fi

# ---- New UUIDs: fresh for migrated roles, unchanged for in-place ----
if [ "$DRY_RUN" -eq 0 ]; then
    if [ $MIGRATE_EFI  -eq 1 ]; then NEW_UUID_EFI=$(blkid_uuid "$TGT_EFI");   else NEW_UUID_EFI="$OLD_UUID_EFI";   fi
    if [ $MIGRATE_BOOT -eq 1 ]; then NEW_UUID_BOOT=$(blkid_uuid "$TGT_BOOT"); else NEW_UUID_BOOT="$OLD_UUID_BOOT"; fi
    if [ $MIGRATE_ROOT -eq 1 ]; then NEW_UUID_ROOT=$(blkid_uuid "$TGT_ROOT"); else NEW_UUID_ROOT="$OLD_UUID_ROOT"; fi
    if [ -n "$SWAP_DEV" ]; then NEW_UUID_SWAP=$(blkid_uuid "$SWAP_DEV"); fi
else
    if [ $MIGRATE_EFI  -eq 1 ]; then NEW_UUID_EFI="dry-run-new-efi";   else NEW_UUID_EFI="$OLD_UUID_EFI";   fi
    if [ $MIGRATE_BOOT -eq 1 ]; then NEW_UUID_BOOT="dry-run-new-boot"; else NEW_UUID_BOOT="$OLD_UUID_BOOT"; fi
    if [ $MIGRATE_ROOT -eq 1 ]; then NEW_UUID_ROOT="dry-run-new-root"; else NEW_UUID_ROOT="$OLD_UUID_ROOT"; fi
    if [ -n "$SWAP_DEV" ]; then NEW_UUID_SWAP="dry-run-new-swap"; fi
fi

echo "=========================================="
echo " Phase 3: Mounting & Data Synchronization "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    if [ $UPDATE -eq 1 ]; then
        echo "[dry-run] would mount the target tree and rsync --delete the differing filesystems (no mkfs)"
    else
        echo "[dry-run] would mount the target tree and rsync the migrated filesystems"
    fi
else
    # Mount the target tree (the partitions the installed system will use).
    sudo mount "$TGT_ROOT" "$MNT"
    sudo mkdir -p "$MNT/boot"
    sudo mount "$TGT_BOOT" "$MNT/boot"
    sudo mkdir -p "$MNT/boot/efi"
    sudo mount "$TGT_EFI" "$MNT/boot/efi"

    sudo mkdir -p "$SRC"
    # Source root is the rsync base; -x keeps each rsync on its own filesystem so
    # in-place /boot and /boot/efi are never copied onto themselves.
    sudo mount -r -o noatime "$SRC_ROOT" "$SRC"

    # Base rsync options.
    #   --delete (mirror the source, removing stale target files) is added only
    #     under --update, where we refresh an existing clone in place; a plain
    #     migrate writes onto a freshly-formatted target, so nothing to delete.
    #   --exclude-from (e.g. an impersonal clone) applies to every transfer; its
    #     paths are anchored to each transfer root, so the personal "/..." paths
    #     in the file only match during the root rsync.
    #   --delete-excluded is added when both apply, so a re-sync also PURGES any
    #     excluded paths already on the target — rsync otherwise protects
    #     excluded files from --delete, which would leave personal data behind.
    RSYNC_OPTS=(-ahqHAXS --numeric-ids -x)
    if [ $UPDATE -eq 1 ]; then
        RSYNC_OPTS+=(--delete)
        if [ -n "$EXCLUDE_FROM" ]; then RSYNC_OPTS+=(--delete-excluded); fi
    fi
    if [ -n "$EXCLUDE_FROM" ]; then RSYNC_OPTS+=(--exclude-from="$EXCLUDE_FROM"); fi

    if [ $MIGRATE_ROOT -eq 1 ]; then
        echo "Rsyncing root filesystem..."
        sudo rsync "${RSYNC_OPTS[@]}" \
            --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/mnt/*","/lost+found"} \
            "$SRC/" "$MNT/"
    fi
    if [ $MIGRATE_BOOT -eq 1 ]; then
        sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot"
        echo "Rsyncing /boot filesystem..."
        sudo rsync "${RSYNC_OPTS[@]}" "$SRC/boot/" "$MNT/boot/"
    fi
    if [ $MIGRATE_EFI -eq 1 ]; then
        sudo mount -r "$SRC_EFI" "$SRC/boot/efi"
        echo "Rsyncing EFI filesystem..."
        sudo rsync "${RSYNC_OPTS[@]}" "$SRC/boot/efi/" "$MNT/boot/efi/"
    fi
fi

echo "=========================================="
echo " Phase 4: Filesystem Translation (UUIDs)  "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would rewrite fstab + GRUB root UUID and (re)brand the GRUB menu"
else
    rewrite_fstab

    echo "Enforcing Root UUID mapping in GRUB default..."
    if grep -q '^GRUB_CMDLINE_LINUX=' "$MNT/etc/default/grub"; then
        sudo sed -i -E "s|root=UUID=[a-fA-F0-9-]+|root=UUID=$NEW_UUID_ROOT|g" "$MNT/etc/default/grub"
    fi

    if [ -n "$SWAP_DEV" ]; then
        echo "Adding swap entry to fstab ($SWAP_DEV)..."
        echo "/dev/disk/by-uuid/$NEW_UUID_SWAP none swap sw 0 0" | sudo tee -a "$MNT/etc/fstab" >/dev/null
    fi

    rewrite_grub_distributor
fi

echo "=========================================="
echo " Phase 5: The Headless chroot Environment "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would chroot: update-grub + update-initramfs (grub-install bios=$INSTALL_GRUB_BIOS efi=$INSTALL_GRUB_EFI)"
else
    run_chroot_block
fi

echo "=========================================="
echo " Phase 6: Teardown & Cleanup              "
echo "=========================================="
if [ "$DRY_RUN" -eq 0 ]; then
    echo "[Teardown] Unmounting filesystems and releasing locks..."
    sudo umount -R -q "$SRC" "$MNT" 2>/dev/null || true

    if [ -n "${LOOP_DEV:-}" ]; then
        echo "Detaching loop device: $LOOP_DEV"
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
fi

if [ $UNIFIED_TARGET -eq 1 ]; then
    if [ $UPDATE -eq 1 ]; then
        echo "Done. Disk $TARGET synced (existing filesystems refreshed) and bootable."
    else
        echo "Done. Disk $TARGET is fully prepared and bootable."
    fi
else
    roles=""
    if [ $MIGRATE_ROOT -eq 1 ]; then roles="$roles /"; fi
    if [ $MIGRATE_BOOT -eq 1 ]; then roles="$roles /boot"; fi
    if [ $MIGRATE_EFI  -eq 1 ]; then roles="$roles EFI"; fi
    if [ -n "$SWAP_DEV" ]; then roles="$roles swap"; fi
    verb="Migrated"; [ $UPDATE -eq 1 ] && verb="Synced"
    if [ $INSTALL_GRUB_BIOS -eq 1 ] || [ $INSTALL_GRUB_EFI -eq 1 ]; then
        echo "Done. $verb:${roles:- (none)}. Bootloader reinstalled (bios=$INSTALL_GRUB_BIOS efi=$INSTALL_GRUB_EFI)."
    else
        echo "Done. $verb:${roles:- (none)}. Existing bootloader kept; GRUB menu + initramfs regenerated."
    fi
fi
