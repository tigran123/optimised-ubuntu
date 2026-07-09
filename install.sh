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
    if [ "${ASSUME_YES:-0}" -eq 1 ]; then
        echo "$msg -- proceeding (--yes)."
        return 0
    fi
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

# Wait for udev to publish a disk's partition nodes. udevadm settle watches the
# global event queue, which a concurrent instance's partitioning storm can
# stall; poll the one disk we care about instead. Best-effort: on timeout the
# caller's own validation produces the precise error.
wait_for_partitions() {
    local disk=$1 _i
    for _i in $(seq 1 20); do
        if [ -n "$(lsblk -lnpo NAME "$disk" 2>/dev/null | tail -n +2)" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 0
}

# -----------------------------------------------------------------------------
# Cross-instance locking
# -----------------------------------------------------------------------------
# Several instances may run concurrently (e.g. flashing multiple disks from one
# source). Every disk we write gets an exclusive flock, every disk we only read
# a shared one, so instances can share a source but never write the same disk.
# Keys are canonical parent disks, so a partition-level and a whole-disk run of
# the same device collide. Lock files live in /run/lock (tmpfs) and are never
# unlinked: removing a lock file another process holds open reopens the classic
# unlink+flock race. The fds stay open for the life of the process, so locks
# release atomically on any exit, including SIGKILL.
declare -A LOCK_MODE=()

# add_lock <device-or-file> <sh|ex> — register a lock key; ex wins over sh.
add_lock() {
    local key parent
    key=$(readlink -f "$1" 2>/dev/null) || return 0
    [ -n "$key" ] || return 0
    if [ -b "$key" ]; then
        parent=$(get_parent_disk "$key")
        if [ -n "$parent" ]; then key=$parent; fi
    fi
    if [ "${LOCK_MODE[$key]:-}" != "ex" ]; then
        LOCK_MODE[$key]=$2
    fi
}

acquire_locks() {
    local key file fd flag
    local -a keys=()
    [ ${#LOCK_MODE[@]} -gt 0 ] || return 0
    mapfile -t keys < <(printf '%s\n' "${!LOCK_MODE[@]}" | sort)
    for key in "${keys[@]}"; do
        file="/run/lock/portable-install-$(printf '%s' "$key" | tr '/ ' '__').lock"
        if ! exec {fd}>>"$file"; then
            die "Cannot open lock file $file (stale file owned by another user?)"
        fi
        if [ "${LOCK_MODE[$key]}" = "ex" ]; then flag=-x; else flag=-s; fi
        flock -n "$flag" "$fd" || \
            die "Another install.sh instance is using $key (lock: $file)"
    done
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
    # -c /dev/null bypasses the /run/blkid cache, which can hand back a stale
    # UUID right after a concurrent instance re-mkfs'd a device.
    uuid=$(sudo blkid -c /dev/null -s UUID -o value "$dev") || \
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
             -v old_root="$OLD_UUID_ROOT" -v new_root="$NEW_UUID_ROOT" \
             -v new_swap="${NEW_UUID_SWAP:-}" '
    # Lines disabled by a previous run: never re-prefix them (collapse any
    # stacked markers left by older versions), and drop disabled swap entries
    # once a live swap entry is being written below -- otherwise every
    # re-mkswap sync leaves one more dead line behind.
    /^# \[PORTABLE-SYNC-DISABLED\] / {
        payload = $0;
        while (sub(/^# \[PORTABLE-SYNC-DISABLED\] /, "", payload)) { }
        split(payload, f);
        if (new_swap != "" && f[3] == "swap") next;
        print "# [PORTABLE-SYNC-DISABLED] " payload;
        next;
    }
    {
        gsub(old_efi, new_efi);
        gsub(old_boot, new_boot);
        gsub(old_root, new_root);

        # Retarget the existing UUID-based swap entry in place (keeping its
        # position and column spacing) instead of disabling it and appending
        # a duplicate. Only the first is kept: extras fall through and are
        # disabled below. Swap-file entries (no UUID) pass through untouched.
        if (new_swap != "" && !swap_done && $3 == "swap") {
            if (sub(/^UUID=[^ \t]+/, "UUID=" new_swap) ||
                sub(/^\/dev\/disk\/by-uuid\/[^ \t]+/, "/dev/disk/by-uuid/" new_swap)) {
                swap_done = 1;
                print $0;
                next;
            }
        }

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
    }
    END {
        if (new_swap != "" && !swap_done)
            print "/dev/disk/by-uuid/" new_swap " none swap sw 0 0";
    }' "$MNT/etc/fstab" | sudo tee "$MNT/etc/fstab.new" >/dev/null

    sudo mv "$MNT/etc/fstab.new" "$MNT/etc/fstab"
    sudo chown root:root "$MNT/etc/fstab"
    sudo chmod 644 "$MNT/etc/fstab"
}

rewrite_grub_distributor() {
    info "Updating GRUB_DISTRIBUTOR with target model ($TGT_MODEL)..."
    # A --brand value may contain sed-replacement metacharacters (&, /, \).
    local model_esc
    model_esc=$(printf '%s' "$TGT_MODEL" | sed 's/[&/\]/\\&/g')
    if [ -f "$MNT/etc/default/grub" ]; then
        sudo sed -i -E 's/^(GRUB_DISTRIBUTOR="Desktop ).*( `\( \.)/\1'"$model_esc"'\2/' "$MNT/etc/default/grub"
    fi
    if [ -f "$MNT/etc/grub.d/09_console" ]; then
        sudo sed -i -E 's/^(GRUB_DISTRIBUTOR="Console ).*( `\( \.)/\1'"$model_esc"'\2/' "$MNT/etc/grub.d/09_console"
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

# Empty = auto: a private per-instance temp dir, so concurrent runs never
# stack their mounts over each other. --mnt/--src (or the env vars) pin a path.
MNT="${MNT:-}"
SRC="${SRC:-}"
EXCLUDE_FROM="${EXCLUDE_FROM:-}"
BRAND="${BRAND:-}"
DRY_RUN=0
UPDATE=0
ASSUME_YES=0
MNT_AUTO=0
SRC_AUTO=0
LOOP_ATTACHED=0
MOUNTS_DONE=0
CLEANED=0

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
        --brand)          BRAND="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --update)         UPDATE=1; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
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
  --brand NAME                Brand the GRUB menu title with NAME instead of the
                              target disk's reported model (useful when the medium
                              sits in a USB card reader, whose model string —
                              e.g. "SD Transcend" — says nothing about the card)
  --mnt DIR                   Target root mount point  (default: private temp dir)
  --src DIR                   Source root mount point  (default: private temp dir)
  --yes, -y                   Skip the confirmation prompt (for scripted runs)
  --dry-run                   Print destructive commands instead of running them
  -h, --help                  Show this help

Notes:
  * --source-swap (reuse) and --target-swap (reformat) are mutually exclusive.
  * EFI booting uses the EFI System Partition; the BIOS Boot partition is only
    for legacy boot and is regenerated by grub-install (when --target-bios-boot
    is given) or left intact otherwise.
  * Multiple instances may run concurrently (e.g. flashing several disks from
    one source). Disks are guarded by advisory locks under /run/lock: written
    disks exclusively, source disks shared; a conflicting instance fails fast
    before its confirmation prompt. Run each instance in its own terminal.

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

# Front-load the sudo password prompt before any resources are acquired, so it
# cannot fire mid-rsync (sudo timestamps are per-tty and can expire mid-run).
if [ "$DRY_RUN" -eq 0 ]; then
    sudo -v
fi

# Auto mount points: unique per instance.
if [ -z "$MNT" ]; then
    MNT=$(mktemp -d /tmp/install-mnt.XXXXXX)
    MNT_AUTO=1
fi
if [ -z "$SRC" ]; then
    SRC=$(mktemp -d /tmp/install-src.XXXXXX)
    SRC_AUTO=1
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

# Teardown is trap-driven so failures and Ctrl+C release everything too:
# unmount this instance's trees, detach its loop device, remove its temp dirs.
# Flags gate each step to what was actually acquired — in particular the fake
# dry-run LOOP_DEV (/dev/loop0) never sets LOOP_ATTACHED and is never detached,
# and a user-supplied --mnt is never unmounted unless we mounted onto it.

# Recursively unmount one tree, waiting out stragglers that keep it busy.
# A Ctrl+C kills the rsync client at once, but the process writing the data
# can be blocked in uninterruptible sleep (D state) while the kernel flushes
# its dirty pages to a slow target; the pending signal is only honoured when
# that write returns, and until then the tree cannot be unmounted — so retry
# instead of bailing out and leaving the target mounted.
umount_tree() {
    local dir="$1" err waited=0
    while findmnt -n "$dir" >/dev/null 2>&1; do
        if err=$(sudo env LC_ALL=C umount -R -q "$dir" 2>&1); then break; fi
        case "$err" in
        *busy*)
            if [ "$waited" -eq 0 ]; then
                waited=1
                echo "$dir is busy (an interrupted rsync stays until its in-flight writes are flushed) -- waiting to unmount..."
            fi
            sleep 2 ;;
        *)  # Not something waiting can fix — report it and give up on this tree.
            [ -n "$err" ] && echo "$err" >&2
            return 1 ;;
        esac
    done
    return 0
}

cleanup() {
    if [ "$CLEANED" -eq 1 ]; then return 0; fi
    CLEANED=1
    # Once teardown starts it must run to completion: ignore further Ctrl+C
    # (etc.) so an impatient interrupt cannot abort it halfway and leave the
    # target mounted.
    trap '' HUP INT TERM
    if [ "$MOUNTS_DONE" -eq 1 ]; then
        umount_tree "$SRC" || true
        umount_tree "$MNT" || true
    fi
    if [ "$LOOP_ATTACHED" -eq 1 ]; then
        echo "Detaching loop device: $LOOP_DEV"
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    # rmdir, never rm -rf: failing on a still-mounted/busy dir is the safety net.
    if [ "$MNT_AUTO" -eq 1 ]; then rmdir "$MNT" 2>/dev/null || true; fi
    if [ "$SRC_AUTO" -eq 1 ]; then rmdir "$SRC" 2>/dev/null || true; fi
}
trap cleanup EXIT
# Turn fatal signals into a normal exit so the EXIT trap runs (bash does not
# reliably run it when killed by an untrapped signal).
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
            echo "[dry-run] sudo losetup -r -P -f --show \"$SOURCE\""
            SRC_EFI="${LOOP_DEV}p2"
            SRC_BOOT="${LOOP_DEV}p3"
            SRC_ROOT="${LOOP_DEV}p4"
        else
            # Read-only: even an ro ext4 mount writes to the device (journal
            # replay, orphan cleanup), so two instances sharing one image via
            # separate loop devices would corrupt it. With an ro loop the
            # kernel refuses all writes and a dirty image fails loudly instead.
            LOOP_DEV=$(sudo losetup -r -P -f --show "$SOURCE")
            LOOP_ATTACHED=1
            echo "Image mapped to loop device: $LOOP_DEV (read-only)"
            sudo udevadm settle
            wait_for_partitions "$LOOP_DEV"
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
        fstype=$(sudo blkid -c /dev/null -o value -s TYPE "$dev" 2>/dev/null || true)
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
# --brand overrides the probed model (which can be a card reader's name rather
# than the medium's).
if [ $UNIFIED_TARGET -eq 1 ]; then
    BRAND_DISK="$TARGET"
else
    BRAND_DISK=$(get_parent_disk "$TGT_ROOT")
fi
if [ -n "$BRAND" ]; then
    TGT_MODEL="$BRAND"
else
    TGT_MODEL=$(lsblk -n -d -o MODEL "${BRAND_DISK:-}" 2>/dev/null | xargs || true)
    [ -n "$TGT_MODEL" ] || TGT_MODEL="Portable Image"
fi

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

# ---- Cross-instance locks: exclusive on written disks, shared on read ones ----
# ALL target roles are registered, in-place ones included: update-grub and
# update-initramfs write into the mounted /boot even when a role is not
# migrated. A unified fresh target is keyed on the disk itself (its partitions
# may not exist yet). An image source is keyed on the image file.
add_lock "$SRC_EFI"  sh
add_lock "$SRC_BOOT" sh
add_lock "$SRC_ROOT" sh
if [ -n "$SRC_SWAP" ]; then add_lock "$SRC_SWAP" sh; fi
if [ $SCATTERED_SOURCE -eq 0 ] && [ -f "$SOURCE" ]; then add_lock "$SOURCE" sh; fi
if [ $UNIFIED_TARGET -eq 1 ]; then add_lock "$TARGET" ex; fi
add_lock "$TGT_EFI"  ex
add_lock "$TGT_BOOT" ex
add_lock "$TGT_ROOT" ex
if [ -n "$TGT_GRUB_DISK" ]; then add_lock "$TGT_GRUB_DISK" ex; fi
if [ "$DO_MKSWAP" -eq 1 ]; then add_lock "$SWAP_DEV" ex; fi
if [ "$DRY_RUN" -eq 1 ]; then
    for key in "${!LOCK_MODE[@]}"; do
        echo "[dry-run] would flock (${LOCK_MODE[$key]}) $key"
    done
else
    acquire_locks
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
if [ -n "$BRAND" ]; then
    echo "  Menu:     GRUB title branded \"$TGT_MODEL\" (--brand override)"
else
    echo "  Menu:     GRUB title branded \"$TGT_MODEL\" (rootfs on ${BRAND_DISK:-?})"
fi
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
    # Wait for OUR partition nodes rather than the global udev queue, which a
    # concurrent instance can keep busy past the settle timeout.
    run sudo udevadm wait --timeout=30 "$TGT_BIOS" "$TGT_EFI" "$TGT_BOOT" "$TGT_ROOT"
fi

# ---- Format the migrated roles ----
# Skipped entirely under --update, which keeps each target filesystem intact and
# only rsyncs --delete onto it. (--target-swap reformatting is independent: it is
# an explicit opt-in and still honoured below.)
if [ $UPDATE -eq 0 ]; then
    if [ $MIGRATE_EFI -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_EFI"
        if [ "$DRY_RUN" -eq 1 ]; then
            run sudo mkfs.fat -F32 -n EFI "$TGT_EFI"
        else
            sudo mkfs.fat -F32 -n EFI "$TGT_EFI" > /dev/null
        fi
    fi
    if [ $MIGRATE_BOOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_BOOT"
        run sudo mkfs.ext4 -qF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$TGT_BOOT"
    fi
    if [ $MIGRATE_ROOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_ROOT"

        TGT_BYTES=$(lsblk -dbno SIZE "$TGT_ROOT" 2>/dev/null) || TGT_BYTES=""
        if [ -z "$TGT_BYTES" ]; then
            # Only dry-run may proceed without a size (the partition node may
            # not exist yet); a real run must not fabricate the inode count.
            [ "$DRY_RUN" -eq 1 ] || die "Cannot determine size of $TGT_ROOT"
            TGT_BYTES=$((16 * 1024**3))
        fi
        ROOT_BYTES_PER_INODE=$(( 1024**4 / (4 * 1024**2) ))
        CALC_INODES=$(( TGT_BYTES / ROOT_BYTES_PER_INODE ))
        MIN_INODES=$(( 3*1024**2/2 )) # 1.5M inodes minimum
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
    # Refuse to stack over an existing mount — a leftover tree from a crashed
    # run (or a busy --mnt/--src dir) must be cleaned up, not silently shadowed.
    if findmnt -n "$MNT" >/dev/null 2>&1; then die "$MNT is already a mountpoint."; fi
    if findmnt -n "$SRC" >/dev/null 2>&1; then die "$SRC is already a mountpoint."; fi

    # Mount the target tree (the partitions the installed system will use).
    sudo mkdir -p "$MNT"
    MOUNTS_DONE=1
    sudo mount "$TGT_ROOT" "$MNT"
    sudo mkdir -p "$MNT/boot"
    sudo mount "$TGT_BOOT" "$MNT/boot"
    sudo mkdir -p "$MNT/boot/efi"
    sudo mount "$TGT_EFI" "$MNT/boot/efi"

    sudo mkdir -p "$SRC"
    # Source root is the rsync base; -x keeps each rsync on its own filesystem so
    # in-place /boot and /boot/efi are never copied onto themselves.
    sudo mount -r -o noatime "$SRC_ROOT" "$SRC" || \
        die "Cannot mount source root $SRC_ROOT read-only. A dirty (uncleanly unmounted) image cannot replay its journal on a read-only loop -- run e2fsck on it once and retry."

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
    #   --inplace rewrites changed files in place instead of building a hidden
    #     temp copy and renaming: a changed 50 GB VM image would otherwise need
    #     an extra 50 GB free on the target mid-transfer. The trade-off is that
    #     an interrupted transfer leaves such a file half-updated; the next
    #     --update run repairs it. (Combining it with -S needs rsync >= 3.1.3.)
    RSYNC_OPTS=(-ahqHAXS --inplace --numeric-ids -x)
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
        sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot" || \
            die "Cannot mount source /boot $SRC_BOOT read-only (dirty journal? run e2fsck on it once and retry)."
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
    # rewrite_fstab also retargets (or, if absent, appends) the swap entry to
    # NEW_UUID_SWAP when a swap device was given.
    rewrite_fstab

    echo "Enforcing Root UUID mapping in GRUB default..."
    if grep -q '^GRUB_CMDLINE_LINUX=' "$MNT/etc/default/grub"; then
        sudo sed -i -E "s|root=UUID=[a-fA-F0-9-]+|root=UUID=$NEW_UUID_ROOT|g" "$MNT/etc/default/grub"
    fi

    rewrite_grub_distributor
fi

echo "=========================================="
echo " Phase 5: The Headless chroot Environment "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would chroot: update-grub + update-initramfs (grub-install bios=$INSTALL_GRUB_BIOS efi=$INSTALL_GRUB_EFI)"
else
    # os-prober is inert on GRUB >= 2.06 unless explicitly enabled. If the
    # target enables it, concurrent update-grubs probe each other's in-flight
    # disks and can cross-pollute the generated menus.
    if grep -qs '^[[:space:]]*GRUB_DISABLE_OS_PROBER=false' \
            "$MNT/etc/default/grub" "$MNT"/etc/default/grub.d/*.cfg; then
        echo "Warning: os-prober is enabled in the target's GRUB config; avoid concurrent installs (menus may pick up each other's disks)." >&2
    fi
    run_chroot_block
fi

echo "=========================================="
echo " Phase 6: Teardown & Cleanup              "
echo "=========================================="
if [ "$DRY_RUN" -eq 0 ]; then
    echo "[Teardown] Unmounting filesystems and releasing locks..."
fi
cleanup   # also runs from the EXIT trap on any earlier failure

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
