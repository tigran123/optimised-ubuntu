#!/bin/bash
# install.sh — flash a portable OS image or scattered partitions onto a target.
#
# Three things can be combined freely:
#   * a unified source: a whole block device or a disk-image file (.img);
#   * a scattered source: independent --source-efi/--source-root partitions,
#     plus --source-boot when that system keeps /boot on its own filesystem;
#   * a unified target (--target, auto-partitioned) or independent --target-*
#     partitions.
#
# Per-role rule: each --target-X defaults to its --source-X, so a role whose
# target equals its source is left untouched (in-place), while a role whose
# target differs is migrated (formatted + copied). This makes "move only / to a
# new partition, keeping BIOS Boot and EFI where they are" a first-class
# operation. See --help for examples.
#
# /boot inside / is the default layout, and a separate /boot is EXPLICIT on both
# sides: only --source-boot says a source has one, only --target-boot gives a
# target one. Nothing is inferred from a partition table -- a /boot partition a
# disk happens to carry is left alone unless it is named. The layout is for a
# machine whose BIOS cannot boot from NVMe: BIOS Boot, the ESP and /boot live on
# its SATA disk, / on the (four times faster) NVMe. Either layout converts to
# the other: --no-target-boot folds a source's separate /boot into the target's
# root, --target-boot splits it back out.
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

# dryrun_loop_clashes <loopdev> — true when a dry run's guessed source loop
#   device is one the user named as a target (the whole disk or a partition of
#   it). Reads the caller-set TARGET/TGT_* globals.
dryrun_loop_clashes() {
    local t
    for t in "$TARGET" "$TGT_BIOS" "$TGT_EFI" "$TGT_BOOT" "$TGT_ROOT"; do
        [ -n "$t" ] || continue
        case "$t" in "$1"|"$1"p*) return 0 ;; esac
    done
    return 1
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

# supports_discard <dev> — true when the device can discard blocks (SSD, SD,
# loop); spinning disks report a zero discard granularity.
supports_discard() {
    local gran
    gran=$(lsblk -bdno DISC-GRAN "$1" 2>/dev/null | xargs) || return 1
    [ -n "$gran" ] && [ "$gran" -gt 0 ]
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
    # Roles that do not exist (e.g. no BIOS Boot partition) arrive as an empty
    # string. Check it here rather than trusting readlink: uutils' readlink
    # resolves "" to the working directory and exits 0, locking the cwd.
    [ -n "${1:-}" ] || return 0
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

# scan_disk_roles <disk> <VAR_PREFIX>
#   Scan a whole disk (or attached loop device) and assign its BIOS Boot, EFI
#   and root partitions into <PREFIX>_BIOS/_EFI/_ROOT by GPT type and filesystem
#   label, rather than assuming fixed partition numbers. This lets a disk
#   carrying an inline swap or data partition — or any other non-canonical
#   ordering — resolve correctly.
#
#   Used for both sides: a unified source, and a unified --target under --update
#   (where the existing layout must be discovered, not imposed, since we neither
#   repartition nor reformat it).
#
#   EFI is the ESP. Root is the Linux-filesystem partition labelled "root" —
#   which this toolkit's own mkfs always writes — or, failing that, a *lone*
#   unlabelled Linux partition. Everything else on the disk is none of our
#   business and is ignored: a data partition, a separate /boot (a role, but a
#   named one -- see --source-boot/--target-boot -- never a discovered one),
#   another distro's rootfs. Ambiguity is never resolved by guessing (an
#   earlier version claimed the first unclaimed Linux partition as
#   /boot, which happily adopted — and then reformatted — a data partition):
#   two or more candidates with no "root" label is a fatal error naming them,
#   and so is more than one partition labelled "root" (a disk carrying a rootfs
#   per machine behind one shared ESP has exactly that layout).
#   Dies likewise if the ESP or root is missing, so an unexpected layout fails
#   here rather than at mount time.
scan_disk_roles() {
    local disk=$1 pfx=$2
    local dev ptype fstype label
    local -a linux_parts=() root_parts=()
    local bios="" efi="" root=""

    # One lsblk for the whole disk, rather than one per partition per column.
    # Default IFS on purpose: lsblk emits no tabs in any output mode (-l pads
    # its columns with spaces), and word splitting collapses that padding. A row
    # whose PARTTYPE is empty shifts its remaining fields left, but that only
    # happens for the whole-disk row (skipped below) and for the non-partition
    # children -l flattens into the list (dm/LVM/crypt), whose FSTYPE can never
    # look like a GUID -- they fall through the case untouched either way.
    while read -r dev ptype fstype label; do
        [ "$dev" = "$disk" ] && continue
        ptype=${ptype,,}
        case "$ptype" in
            "$GUID_BIOS")
                bios="$dev" ;;
            "$GUID_EFI")
                efi="$dev" ;;
            "$GUID_LINUX")
                [ "$fstype" = swap ] && continue   # a Linux-typed swap: not /
                case "$label" in
                    root) root_parts+=("$dev") ;;
                    # A separate /boot. It is a role again, but never a
                    # discovered one: --source-boot/--target-boot name it, so
                    # all this scan owes it is not to mistake it for a root
                    # filesystem or let it make the disk look ambiguous. Unnamed
                    # by the caller, it is left on the disk, unused.
                    boot) ;;
                    *)    linux_parts+=("$dev") ;;
                esac ;;
        esac
    done < <(lsblk -lnpo NAME,PARTTYPE,FSTYPE,LABEL "$disk")

    # One "root" label settles it, and every other Linux partition on the disk
    # is then someone else's (data, an unnamed /boot, a second distro). Only
    # when nothing is labelled does the scan fall back to "there is exactly one
    # candidate, so that is it" — and more than one candidate is an error, not
    # a coin toss: picking wrong here means reformatting the wrong partition.
    #
    # Several partitions labelled 'root' is the same error, and a live layout
    # now that one disk can carry a rootfs per machine behind a shared ESP: an
    # earlier version let the last one win, so a whole-disk --target --update
    # silently synced onto whichever slot lsblk listed last.
    if [ ${#root_parts[@]} -eq 1 ]; then
        root="${root_parts[0]}"
    elif [ ${#root_parts[@]} -gt 1 ]; then
        die "Disk $disk has ${#root_parts[@]} partitions labelled 'root':
  ${root_parts[*]}
A disk carrying one rootfs per machine must be addressed partition by
partition -- name the one you mean with --source-root/--target-root."
    fi
    if [ -z "$root" ]; then
        if [ ${#linux_parts[@]} -eq 1 ]; then
            root="${linux_parts[0]}"
        elif [ ${#linux_parts[@]} -gt 1 ]; then
            die "Disk $disk has ${#linux_parts[@]} candidate Linux partitions and none labelled 'root':
  ${linux_parts[*]}
Name it explicitly with --source-root/--target-root, or label it:
  sudo e2label ${linux_parts[0]} root"
        fi
    fi

    [ -n "$efi" ]  || die "Disk $disk has no EFI System partition."
    [ -n "$root" ] || die "Disk $disk has no Linux root partition."

    printf -v "${pfx}_BIOS" '%s' "$bios"
    printf -v "${pfx}_EFI"  '%s' "$efi"
    printf -v "${pfx}_ROOT" '%s' "$root"
}

# scan_image_roles_dryrun <image>
#   Role partition NUMBERS for a .img in a dry run, where no loop device is
#   attached and lsblk therefore has nothing to scan. parted reads the partition
#   table straight out of the file (no root, no loop needed), so the printed
#   summary reflects the image's real layout instead of a canonical guess.
#   Prints "<efi>:<root>", or nothing if the table could not be read.
#   Limits: without a loop device the filesystems cannot be probed, so a
#   Linux-typed *swap* partition is only recognised when parted names its type,
#   and filesystem LABELS are invisible -- parted's own name field is the GPT
#   partition name ("primary" for everything this toolkit creates), not the
#   ext4 label scan_disk_roles() keys on. Root is therefore the first Linux
#   partition, which is the layout this toolkit produces (BIOS, ESP, root, then
#   any extras). A real run resolves it by label and may disagree; since this
#   only feeds the dry run's printed summary, say so rather than guess silently.
scan_image_roles_dryrun() {
    local img=$1 num fstype flags
    local -a linux_nums=()
    local efi=""

    while IFS=: read -r num _ _ _ fstype _ flags; do
        case "$num" in ''|*[!0-9]*) continue ;; esac
        flags=${flags%;}
        case "$flags" in
            *bios_grub*) continue ;;
            *esp*)       efi="$num"; continue ;;
        esac
        case "$fstype" in linux-swap*) continue ;; esac
        linux_nums+=("$num")
    done < <(parted -sm "$img" unit MiB print 2>/dev/null || true)

    [ -n "$efi" ] || return 0
    [ ${#linux_nums[@]} -ge 1 ] || return 0
    if [ ${#linux_nums[@]} -gt 1 ]; then
        echo "[dry-run] $img has ${#linux_nums[@]} Linux partitions (${linux_nums[*]}) and image labels cannot be read without a loop device: assuming partition ${linux_nums[0]} is root. A real run picks the one labelled 'root'." >&2
    fi
    printf '%s:%s\n' "$efi" "${linux_nums[0]}"
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
# Swap files
# -----------------------------------------------------------------------------
# A swap FILE (as opposed to a swap partition) is never worth copying: it is one
# multi-gigabyte run of zeros, so transferring it ships gigabytes over a slow USB
# link to produce something fallocate re-creates from metadata alone. Under
# --sparse it is worse than pointless -- rsync's -S turns that run of zeros into
# holes and the kernel then refuses the file at boot ("swapon: /var/swap:
# skipping - it appears to have holes"). So it is never transferred at all: it is
# excluded from the rsync and re-created on the target from scratch.

# swapfile_entries <fstab> — print the swap FILE paths listed in an fstab, one
#   per line. Only plain paths qualify: swap partitions (/dev/..., UUID=,
#   LABEL=, PARTUUID=...) and zram devices are somebody else's problem.
swapfile_entries() {
    awk '$1 ~ /^#/ { next }
         $3 == "swap" && $1 ~ /^\// && $1 !~ /^\/dev\// {
             # fstab octal escapes (\040 for a space, ...) would have to be
             # decoded to be usable as a path; such a swap file is vanishingly
             # rare, so say so and skip it rather than mangle it.
             if ($1 ~ /\\/) {
                 print "Warning: swap file " $1 " has an escaped path -- not rebuilt." > "/dev/stderr";
                 next;
             }
             print $1;
         }' "$1"
}

# swapfile_excluded <path> — true when the user's --exclude-from file removes
#   this path from the transfer. Asked of rsync itself with a one-file dry run,
#   so wildcards, "+" include lines and rule ordering are honoured exactly as in
#   the real transfer rather than re-implemented here: the path is excluded
#   exactly when rsync no longer lists it. The destination is a deliberately
#   NON-existent directory -- against the real target, rsync's quick check would
#   skip an unchanged file already sitting there and the empty output would read
#   as "excluded". Nothing is written: --dry-run creates neither. (Limit: a rule
#   excluding a whole parent directory is not detected, since --relative always
#   sends implied dirs; that only matters for an exclude file that guts /var,
#   which could not boot anyway.)
swapfile_excluded() {
    local sf=$1 listed rc=0
    [ -n "$EXCLUDE_FROM" ] || return 1
    listed=$(sudo rsync -n --relative --exclude-from="$EXCLUDE_FROM" \
                 --out-format='%n' "$SRC/./${sf#/}" "$MNT/.swapfile-probe" 2>/dev/null) || rc=$?
    # A failed probe (e.g. the source file is gone) must not read as "excluded".
    [ "$rc" -eq 0 ] || return 1
    [[ $'\n'$listed$'\n' == *$'\n'"${sf#/}"$'\n'* ]] && return 1
    return 0
}

# probe_source_swapfiles — name the swap FILES this run will re-create (or drop)
#   *before* the confirmation gate, so the summary does not say "swap: none"
#   about a disk that is about to get a multi-gigabyte swap file. The source's
#   fstab is the only place that information lives, so read it through a
#   transient read-only mount of SRC_ROOT on SRC -- the same trick
#   probe_target_brand() uses on the target, and for the same reason: the answer
#   is needed before Phase 3 mounts anything for real.
#   Fills SWAP_PREVIEW and sets SWAP_PROBED; scan_swapfiles() still does the
#   authoritative pass later. Best-effort by design: SWAP_PROBED stays 0 when
#   the source cannot be mounted, which in a dry run is the normal case for an
#   image (no loop device is attached, so SRC_ROOT does not exist yet).
probe_source_swapfiles() {
    SWAP_PREVIEW=(); SWAP_PROBED=0
    local sf size state
    [ -b "$SRC_ROOT" ] || return 0
    MOUNTS_DONE=1   # from here on cleanup() must sweep $SRC, interrupts included
    sudo mount -r -o noatime "$SRC_ROOT" "$SRC" 2>/dev/null || return 0
    SWAP_PROBED=1
    if [ -f "$SRC/etc/fstab" ]; then
        while read -r sf; do
            [ -n "$sf" ] || continue
            size=$(sudo stat -c %s "$SRC$sf" 2>/dev/null) || size=""
            if swapfile_excluded "$sf"; then state=drop; else state=keep; fi
            SWAP_PREVIEW+=("$sf ${size:-?} $state")
        done < <(swapfile_entries "$SRC/etc/fstab")
    fi
    # The source root is mounted anyway, and its /etc/default/grub is the file
    # that lands on the target and feeds this system's menu entry: read the boot
    # options now, so the summary can show the command line the disk will boot
    # with (see probe_menu_cmdline, which only mounts anything if this did not).
    MENU_CMDLINE_PREVIEW=$(grub_cmdline_options "$SRC")
    sudo umount "$SRC" || true
}

# scan_swapfiles — read the source's fstab and split its swap files into the
#   ones to rebuild (SWAPFILES) and the ones the --exclude-from file removes
#   (SWAPFILES_DROPPED: an impersonal/minimal disk is meant to have no swap at
#   all, so those are neither copied nor re-created, and rewrite_fstab comments
#   their entries out). SWAP_EXCLUDES keeps every swap file out of the rsync.
#   Reads caller globals (SRC, MNT, EXCLUDE_FROM).
scan_swapfiles() {
    local sf
    local -a found=()
    SWAPFILES=(); SWAPFILES_DROPPED=(); SWAP_EXCLUDES=(); SWAPFILE_TGT_SIZE=()
    [ -f "$SRC/etc/fstab" ] || return 0
    mapfile -t found < <(swapfile_entries "$SRC/etc/fstab")
    for sf in "${found[@]}"; do
        SWAP_EXCLUDES+=("--exclude=$sf")
        if swapfile_excluded "$sf"; then
            info "Swap file $sf is excluded by $EXCLUDE_FROM -- dropped (its fstab entry will be disabled)."
            SWAPFILES_DROPPED+=("$sf")
        else
            info "Swap file $sf will be re-created on the target (not copied)."
            SWAPFILES+=("$sf")
            # Remember the size of the copy already on the target: it is the
            # fallback when the source has no swap file, and --delete-excluded
            # (--update plus --exclude-from) removes it during the transfer.
            if sudo test -f "$MNT$sf"; then
                SWAPFILE_TGT_SIZE[$sf]=$(sudo stat -c %s "$MNT$sf")
            fi
        fi
    done
}

# rebuild_swapfiles — re-create every kept swap file on the freshly synced
#   target: same size as the source's, same label/UUID, 0600 root:root, freshly
#   mkswap'ed. Reads caller globals (SRC, MNT, SWAPFILES) and records what it
#   did in SWAPFILES_REBUILT for verify_install().
rebuild_swapfiles() {
    local sf src_file tgt_file size label uuid
    local -a mkswap_args
    [ ${#SWAPFILES[@]} -gt 0 ] || return 0
    for sf in "${SWAPFILES[@]}"; do
        src_file="$SRC$sf"
        tgt_file="$MNT$sf"

        # rsync -x stays on the root filesystem, so a swap file on a separate
        # mount was never part of this transfer and is not ours to touch.
        if sudo test -e "$src_file" && \
           [ "$(sudo stat -c %d "$src_file")" != "$(sudo stat -c %d "$SRC")" ]; then
            echo "Note: swap file $sf lives outside the root filesystem -- not rebuilt." >&2
            continue
        fi

        # Size: the source's file is the authority; fall back to the size the
        # target's copy had before the sync, and never invent one.
        size=""
        if sudo test -f "$src_file"; then
            size=$(sudo stat -c %s "$src_file")
        else
            size="${SWAPFILE_TGT_SIZE[$sf]:-}"
        fi
        if [ -z "$size" ] || [ "$size" -le 0 ]; then
            echo "Warning: cannot determine the size of swap file $sf (missing on source and target) -- not rebuilt; 'swapon -a' will fail on the target." >&2
            continue
        fi

        # Keep the swap area's identity, so anything referring to it by label
        # or UUID (fstab, resume=) still resolves on the clone.
        label=""; uuid=""
        if sudo test -f "$src_file"; then
            label=$(sudo blkid -p -s LABEL -o value "$src_file" 2>/dev/null || true)
            uuid=$(sudo blkid -p -s UUID -o value "$src_file" 2>/dev/null || true)
        fi
        mkswap_args=(-q)
        [ -n "$label" ] && mkswap_args+=(-L "$label")
        [ -n "$uuid" ]  && mkswap_args+=(-U "$uuid")

        info "Re-creating swap file $sf ($size bytes)..."
        run sudo rm -f "$tgt_file"
        run sudo fallocate -l "$size" "$tgt_file"
        run sudo chown root:root "$tgt_file"
        run sudo chmod 600 "$tgt_file"
        run sudo mkswap "${mkswap_args[@]}" "$tgt_file"
        SWAPFILES_REBUILT+=("$sf")
    done
}

# swapfile_ok <file> — true when a swap file is usable: a regular file with no
#   holes (the condition swapon rejects) carrying a swap signature.
swapfile_ok() {
    local f=$1 size blocks blocksize
    sudo test -f "$f" || return 1
    read -r size blocks blocksize < <(sudo stat -c '%s %b %B' "$f") || return 1
    [ $((blocks * blocksize)) -ge "$size" ] || return 1
    [ "$(sudo blkid -p -s TYPE -o value "$f" 2>/dev/null)" = swap ]
}

# fstab_disabled <path> <fstab> — true when <path>'s entry carries our
#   disabled marker. Compares fields, so a path is matched literally.
fstab_disabled() {
    sudo awk -v p="$1" '
        $1 == "#" && $2 == "[PORTABLE-SYNC-DISABLED]" && $3 == p { found = 1 }
        END { exit !found }' "$2"
}

# fstab_mounts_boot <fstab> — true when the file carries a LIVE /boot entry,
#   i.e. that system keeps /boot on a filesystem of its own. Used to check the
#   source's real layout against --source-boot before anything is copied, to
#   decide whether rewrite_fstab() must insert a /boot entry, and to verify what
#   was written into the target's fstab.
fstab_mounts_boot() {
    sudo awk '$1 !~ /^#/ && $2 == "/boot" { found = 1 } END { exit !found }' "$1"
}

# -----------------------------------------------------------------------------
# Translation Operations
# -----------------------------------------------------------------------------

# target_disks — the disk(s) this install writes to: the parent disks of the
#   target's role partitions, de-duplicated and space separated. The basis of
#   target_disk_uuids(), and what report_fstab_disables() names when it explains
#   that a mount was disabled because its filesystem is on none of them.
target_disks() {
    local d disk
    local -a disks=()
    for d in "$TGT_ROOT" "$TGT_EFI" "$TGT_BOOT"; do
        [ -n "$d" ] || continue
        disk=$(get_parent_disk "$d")
        [ -n "$disk" ] || continue
        case " ${disks[*]-} " in *" $disk "*) continue ;; esac
        disks+=("$disk")
    done
    printf '%s' "${disks[*]-}"
}

# target_disk_uuids — the UUIDs of every filesystem on the disk(s) this install
#   writes to, space-delimited with sentinel spaces at both ends for the awk
#   lookups below. A mount naming one of them is not "foreign" in any sense that
#   matters: it lives on the very disk being installed, so it is present exactly
#   when this system is (a rootfs sharing its disk with a /data partition, the
#   layout a disk carrying one rootfs per machine has). Everything else -- the
#   source machine's other disks above all -- stays disabled, since a clone that
#   boots elsewhere must not block on a device that is not there.
target_disk_uuids() {
    local disk u out=" "
    # Unquoted on purpose: target_disks() returns space-separated device paths,
    # and an empty result must yield no iterations at all.
    for disk in $(target_disks); do
        while read -r u; do
            [ -n "$u" ] || continue
            case "$out" in *" $u "*) continue ;; esac
            out+="$u "
        done < <(lsblk -lno UUID "$disk" 2>/dev/null || true)
    done
    printf '%s' "$out"
}

# report_fstab_disables <records> — say what rewrite_fstab() just commented out:
#   one line per entry, in fstab order, with the reason it went. Five mounts can
#   vanish from a booting system's fstab in a single run -- a /data on the
#   source's own disk and every bind hanging off it -- and the only way to find
#   out used to be to read the file afterwards. A UUID row also names the device
#   that UUID resolves to here, which is what makes the message actionable: it is
#   almost always a partition of the source disk. Nothing is printed when the
#   record file is empty. Reads the caller-set TGT_* globals via target_disks().
report_fstab_disables() {
    local file=$1 kind mp detail dev disks word
    local width=14 n=0 uuid_rows=0
    [ -s "$file" ] || return 0
    while IFS=$'\t' read -r kind mp detail; do
        [ ${#mp} -gt $width ] && width=${#mp}
        n=$((n + 1))
    done < "$file"
    word=entries; [ "$n" -eq 1 ] && word=entry
    disks=$(target_disks)
    info "Disabled in the target's /etc/fstab ($n $word):"
    while IFS=$'\t' read -r kind mp detail; do
        case "$kind" in
            uuid)
                dev=""
                [ -e "/dev/disk/by-uuid/$detail" ] && dev=$(readlink -f "/dev/disk/by-uuid/$detail")
                printf '      %-*s UUID=%s (%s) -- not on %s\n' \
                       "$width" "$mp" "$detail" "${dev:-not attached}" "${disks:-any target disk}"
                uuid_rows=$((uuid_rows + 1))
                ;;
            bind)
                printf '      %-*s bind on %s, disabled above\n' "$width" "$mp" "$detail" ;;
            swapmount)
                printf '      %-*s swap file on %s, disabled above\n' "$width" "$mp" "$detail" ;;
            swapdrop)
                printf '      %-*s swap file dropped by --exclude-from\n' "$width" "$mp" ;;
            boot)
                printf '      %-*s /boot is inside / on this target\n' "$width" "$mp" ;;
        esac
    done < "$file"
    if [ "$uuid_rows" -gt 0 ]; then
        echo "    A disk that boots elsewhere must not block on a device that is not there,"
        echo "    so those are commented out rather than carried over. If this disk will"
        echo "    always see them, uncomment by hand -- naming this disk's own equivalent"
        echo "    filesystem, which does not have the source's UUID."
    fi
}

rewrite_fstab() {
    # drop_swap: swap FILES the --exclude-from file removes from the transfer.
    # Their entries are commented out, so a disk deliberately built without swap
    # does not boot into a failing swapon. Space-delimited, with sentinel spaces
    # at both ends so the awk lookup below matches whole paths only.
    local drop_swap=" "
    if [ ${#SWAPFILES_DROPPED[@]} -gt 0 ]; then
        drop_swap=" $(printf '%s ' "${SWAPFILES_DROPPED[@]}")"
    fi

    # map_boot: translate the /boot UUID only when the source really had a
    # separate /boot. Without one OLD_UUID_BOOT *is* OLD_UUID_ROOT, and the boot
    # substitution would rewrite the root entry to the target's /boot UUID
    # before the root substitution ever saw it.
    local map_boot=0
    [ "$OLD_UUID_BOOT" = "$OLD_UUID_ROOT" ] || map_boot=1

    # has_boot: does the fstab just copied from the source already carry a live
    # /boot entry? When the target has a separate /boot and the source did not,
    # one is inserted below.
    local has_boot=0
    if fstab_mounts_boot "$MNT/etc/fstab"; then has_boot=1; fi

    # keep_uuids: mounts on the target's own disk(s) survive (see
    # target_disk_uuids); the two-pass awk below then keeps the bind mounts that
    # hang off them, and disables the ones whose backing mount it just disabled.
    local keep_uuids
    keep_uuids=$(target_disk_uuids)

    # FSTAB_REPORT: one tab-separated record (kind, mount point, detail) per line
    # the awk disables, rendered by report_fstab_disables() below. Written by
    # root (sudo awk) into a file this shell owns, so reading and removing it
    # needs no privilege of its own; cleanup() sweeps it if the run dies first.
    FSTAB_REPORT=$(mktemp /tmp/install-fstab-report.XXXXXX)

    sudo awk -v old_efi="$OLD_UUID_EFI" -v new_efi="$NEW_UUID_EFI" \
             -v old_root="$OLD_UUID_ROOT" -v new_root="$NEW_UUID_ROOT" \
             -v old_boot="$OLD_UUID_BOOT" -v new_boot="$NEW_UUID_BOOT" \
             -v map_boot="$map_boot" -v sep_boot="$TGT_SEP_BOOT" \
             -v has_boot="$has_boot" -v keep_uuids="$keep_uuids" \
             -v new_swap="${NEW_UUID_SWAP:-}" -v drop_swap="$drop_swap" \
             -v report="$FSTAB_REPORT" '
    # The UUID a line mounts by, or "" when it names none (a device path, a
    # swap file, tmpfs, a bind source).
    function line_uuid(s) {
        if (match(s, /UUID=[0-9A-Za-z-]+/))
            return substr(s, RSTART + 5, RLENGTH - 5);
        if (match(s, /\/dev\/disk\/by-uuid\/[0-9A-Za-z-]+/))
            return substr(s, RSTART + 18, RLENGTH - 18);
        return "";
    }
    function xlate(s) {
        gsub(old_efi, new_efi, s);
        if (map_boot) gsub(old_boot, new_boot, s);
        gsub(old_root, new_root, s);
        return s;
    }
    function uuid_kept(u) {
        if (u == "") return 1;                             # not mounted by UUID
        if (u == new_efi || u == new_boot || u == new_root) return 1;
        return index(keep_uuids, " " u " ") > 0;
    }
    # One record per line this run disables, in file order, for the report the
    # shell prints afterwards. Lines that arrived already tagged are NOT
    # recorded: they are not news, and an --update re-sync of a disk installed
    # this way would otherwise re-announce every one of them on every run.
    function note(kind, mp, detail) {
        printf "%s\t%s\t%s\n", kind, mp, detail >> report;
    }
    # The mount this path sits on: the longest of the mount points pass 1
    # resolved that prefixes it. "/" always matches, so this never comes back
    # empty -- and a path under a mount this run disables resolves to that
    # mount, not to "/", so it goes down with it.
    function nearest_mount(path,   mp, best, bestlen) {
        best = "/"; bestlen = 0;
        for (mp in mp_kept) {
            if (mp == "/" || length(mp) <= bestlen) continue;
            if (path == mp || substr(path, 1, length(mp) + 1) == mp "/")
                { best = mp; bestlen = length(mp) }
        }
        return best;
    }

    # ---- Pass 1: which mounts survive -------------------------------------
    # Read once to decide every device-backed mount, so that pass 2 can judge a
    # bind by the mount its SOURCE sits on. A bind is not a filesystem: it is
    # worth exactly as much as whatever carries the directory it points at.
    NR == FNR {
        if ($0 ~ /^# \[PORTABLE-SYNC-DISABLED\] /) {
            payload = $0;
            while (sub(/^# \[PORTABLE-SYNC-DISABLED\] /, "", payload)) { }
            if (payload ~ /^[[:space:]]*#/) next;
            split(payload, f);
            if (substr(f[2], 1, 1) == "/") was_disabled[f[2]] = 1;
            next;
        }
        if ($0 ~ /^[[:space:]]*#/ || NF < 3) next;
        line = xlate($0);
        split(line, f);
        if (f[4] ~ /(^|,)bind(,|$)/) { binds[++nbind] = f[1] SUBSEP f[2]; next }
        if (!sep_boot && f[2] == "/boot")   keep = 0;
        else if (f[3] == "swap")            keep = (index(drop_swap, " " f[1] " ") == 0);
        else                                keep = uuid_kept(line_uuid(line));
        if (substr(f[2], 1, 1) == "/") mp_kept[f[2]] = keep;
        next;
    }

    # Binds resolve between the passes, in file order -- which is authoritative,
    # since mount -a walks fstab in order and a bind whose source is mounted
    # later would already be broken on the source system. Each resolved bind
    # joins the mount table, so a bind hanging off another bind is judged by the
    # one it rides on.
    FNR == 1 {
        for (mp in was_disabled) if (!(mp in mp_kept)) mp_kept[mp] = 0;
        for (i = 1; i <= nbind; i++) {
            split(binds[i], b, SUBSEP);
            bind_kept[b[2]] = mp_kept[nearest_mount(b[1])];
            mp_kept[b[2]] = bind_kept[b[2]];
        }
    }

    # Lines disabled by a previous run: never re-prefix them (collapse any
    # stacked markers left by older versions), and drop disabled swap entries
    # once a live swap entry is being written below -- otherwise every
    # re-mkswap sync leaves one more dead line behind.
    /^# \[PORTABLE-SYNC-DISABLED\] / {
        payload = $0;
        while (sub(/^# \[PORTABLE-SYNC-DISABLED\] /, "", payload)) { }
        # A comment underneath the marker was never a mount to disable: an
        # older version tagged the stock Ubuntu header because it mentions
        # "UUID=". Give it back, so an fstab already damaged that way heals on
        # the next sync instead of carrying the marker forever.
        if (payload ~ /^[[:space:]]*#/) { print payload; next; }
        split(payload, f);
        if (new_swap != "" && f[3] == "swap") next;
        print "# [PORTABLE-SYNC-DISABLED] " payload;
        next;
    }

    # Comments are prose, not mounts. Ubuntu ships an fstab header that mentions
    # "UUID=", which the foreign-UUID disabler below would otherwise tag on
    # every single sync until the header was buried under markers.
    /^[[:space:]]*#/ { print; next }

    {
        # This disk keeps /boot inside /, so a /boot entry inherited from a
        # source that kept it elsewhere names a filesystem that does not exist
        # here. Disable it before the UUID translation below, which would
        # otherwise rewrite it into a bogus "mount the root filesystem at
        # /boot" line.
        if (!sep_boot && $2 == "/boot") {
            note("boot", $2, "");
            print "# [PORTABLE-SYNC-DISABLED] " $0;
            next;
        }

        gsub(old_efi, new_efi);
        if (map_boot) gsub(old_boot, new_boot);
        gsub(old_root, new_root);

        # This disk has a separate /boot but the source kept /boot inside /, so
        # no entry was inherited: add one directly after the root entry. Never
        # at the end -- mount -a walks fstab in order, and a /boot line after
        # /boot/efi would mount the ESP onto the bare directory and bury it.
        if (sep_boot && !has_boot && !boot_added && $2 == "/") {
            print $0;
            print "/dev/disk/by-uuid/" new_boot "  /boot  ext4  defaults,noatime  0 2";
            boot_added = 1;
            next;
        }

        # A swap file that was deliberately left off this disk: disable its
        # entry rather than leave systemd trying to swapon a missing file.
        if ($3 == "swap" && index(drop_swap, " " $1 " ") > 0) {
            note("swapdrop", $1, "");
            print "# [PORTABLE-SYNC-DISABLED] " $0;
            next;
        }

        # A swap file is worth exactly as much as the filesystem carrying it --
        # the rule binds already follow. When that mount is one this run just
        # disabled, the file is unreachable and swapon -a fails at boot, so the
        # entry goes with it. Only a mount pass 1 actually judged counts: an
        # unrecognised carrier leaves the entry alone rather than guessing.
        if ($3 == "swap" && substr($1, 1, 1) == "/" && $1 !~ /^\/dev\// &&
            $0 !~ /UUID=/) {
            carrier = nearest_mount($1);
            if ((carrier in mp_kept) && !mp_kept[carrier]) {
                note("swapmount", $1, carrier);
                print "# [PORTABLE-SYNC-DISABLED] " $0;
                next;
            }
        }

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
            # A filesystem on the disk this install writes to is kept: it is
            # there exactly when this system is. Anything else -- another disk
            # of the source machine, a foreign swap partition -- is disabled,
            # since a disk that boots elsewhere must not wait for it.
            if (!uuid_kept(line_uuid($0))) {
                note("uuid", $2, line_uuid($0));
                print "# [PORTABLE-SYNC-DISABLED] " $0;
                next;
            }
        }

        if ($4 ~ /(^|,)bind(,|$)/) {
            # Resolved above from the mount its source sits on: /tmp ->
            # /var/tmp rides on / and always survives; /data/tigran ->
            # /home/tigran survives exactly as long as /data does.
            if (bind_kept[$2]) { print $0; next }
            note("bind", $2, nearest_mount($1));
            print "# [PORTABLE-SYNC-DISABLED] " $0;
            next;
        }

        print $0;
    }
    END {
        if (new_swap != "" && !swap_done)
            print "/dev/disk/by-uuid/" new_swap " none swap sw 0 0";
    }' "$MNT/etc/fstab" "$MNT/etc/fstab" | sudo tee "$MNT/etc/fstab.new" >/dev/null

    sudo mv "$MNT/etc/fstab.new" "$MNT/etc/fstab"
    sudo chown root:root "$MNT/etc/fstab"
    sudo chmod 644 "$MNT/etc/fstab"

    report_fstab_disables "$FSTAB_REPORT"
    rm -f "$FSTAB_REPORT"
    FSTAB_REPORT=""
}

# probe_target_brand — read the brand already stamped into GRUB_DISTRIBUTOR of
#   /etc/default/grub on the target root (TGT_ROOT) via a transient read-only
#   mount on MNT, before rsync overwrites the file with the source's copy.
#   Sets TGT_MODEL (empty when the mount fails or the expected
#   "Desktop <brand> `( ." pattern is absent). Runs under --dry-run too, so the
#   summary can show the brand it would keep — one of the two transient
#   read-only mounts a dry run performs (probe_source_swapfiles() is the other). The kernel replays a dirty journal even for an ro mount of a
#   writable device; harmless, as the real mount that follows would do the same.
probe_target_brand() {
    TGT_MODEL=""
    MOUNTS_DONE=1   # from here on cleanup() must sweep $MNT, interrupts included
    if sudo mount -r -o noatime "$TGT_ROOT" "$MNT" 2>/dev/null; then
        TGT_MODEL=$(sed -nE 's/^GRUB_DISTRIBUTOR="Desktop (.*) `\( \..*$/\1/p' \
                        "$MNT/etc/default/grub" 2>/dev/null | head -n 1) || TGT_MODEL=""
        sudo umount "$MNT" || true
    fi
}

# probe_esp_menu — the systems already registered on the target ESP, read
#   *before* the confirmation gate so the summary can say whose entries this run
#   will keep, and so verify_install() can prove afterwards that it kept them.
#   Skipped by the caller when the ESP is about to be formatted (nothing
#   survives that) and silent when it cannot be mounted. The ESP is mounted on
#   MNT, free at this point, exactly as probe_target_brand() borrows it for the
#   target root -- so the grub directory is $MNT/boot/grub here, the ESP's own
#   /boot/grub, not the /boot/efi/boot/grub it becomes once the root is mounted.
#   Fills ESP_MENU_ENTRIES ("<uuid><TAB><title>") and sets ESP_MENU_PROBED.
probe_esp_menu() {
    ESP_MENU_ENTRIES=(); ESP_MENU_PROBED=0
    local row
    [ -b "$TGT_EFI" ] || return 0
    MOUNTS_DONE=1   # from here on cleanup() must sweep $MNT, interrupts included
    sudo mount -r "$TGT_EFI" "$MNT" 2>/dev/null || return 0
    ESP_MENU_PROBED=1
    while IFS= read -r row; do
        [ -n "$row" ] && ESP_MENU_ENTRIES+=("$row")
    done < <(esp_entries "$MNT/boot/grub")
    sudo umount "$MNT" || true
}

# probe_menu_cmdline — the kernel command line the menu entry will carry, for
#   the summary. Same transient read-only mount trick, on whichever root is the
#   authority: the source's /etc/default/grub when its rootfs is being copied
#   (that file lands on the target verbatim), the target's own when the root is
#   in place. Costs nothing when probe_source_swapfiles() already had the source
#   mounted and filled it in.
probe_menu_cmdline() {
    [ -z "$MENU_CMDLINE_PREVIEW" ] || return 0
    local dev="$TGT_ROOT"
    [ "$MIGRATE_ROOT" -eq 0 ] || dev="$SRC_ROOT"
    [ -b "$dev" ] || return 0
    MOUNTS_DONE=1
    sudo mount -r -o noatime "$dev" "$MNT" 2>/dev/null || return 0
    MENU_CMDLINE_PREVIEW=$(grub_cmdline_options "$MNT")
    sudo umount "$MNT" || true
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

# -----------------------------------------------------------------------------
# The standalone ESP: GRUB's boot directory, and the menu every rootfs shares
# -----------------------------------------------------------------------------
# GRUB's boot directory lives on the ESP (/boot/efi/boot/grub, i.e. /boot/grub
# as seen from the ESP's own root), not on any rootfs: grub-install is told
# --boot-directory=/boot/efi/boot for BOTH i386-pc and x86_64-efi, so the BIOS
# core.img and the UEFI image resolve the same prefix and read the same menu.
# That is what lets one disk carry a rootfs per machine -- desktop, laptop, iMac
# -- behind a single ESP: the menu belongs to the disk, not to whichever system
# was installed last.
#
# Its layout:
#
#   /boot/efi/boot/grub/grub.cfg              master menu, regenerated per run
#   /boot/efi/boot/grub/entries/<uuid>.cfg    one file per registered rootfs
#   /boot/efi/boot/grub/custom.cfg            optional, hand-written, sourced last
#   /boot/efi/boot/grub/{x86_64-efi,i386-pc}/ modules, written by grub-install
#
# An install owns exactly one entry file -- the one named after the root
# filesystem it just wrote -- and never edits another system's. The master is
# rebuilt from whatever entry files are present, so registering, re-branding or
# (by deleting a file) retiring a system is a local operation.

# grub_default_value <file> <KEY> — the last KEY="..." (or '...') assignment in
#   an /etc/default/grub-style file. Read, never sourced: it is the target's
#   file, not ours to execute.
grub_default_value() {
    sed -nE "s/^[[:space:]]*$2=\"(.*)\"[[:space:]]*\$/\\1/p;
             s/^[[:space:]]*$2='(.*)'[[:space:]]*\$/\\1/p" "$1" 2>/dev/null | tail -n 1
}

# grub_cmdline_options <mounted-root> — the boot options that system asks for,
#   composed the way update-grub composes them: GRUB_CMDLINE_LINUX then
#   GRUB_CMDLINE_LINUX_DEFAULT, out of that system's own /etc/default/grub, so
#   each rootfs keeps the quirks its machine needs (USB storage, IOMMU, console)
#   instead of inheriting whichever machine the toolkit last ran on. root= is
#   stripped: it is not an option to carry over but a fact about the filesystem
#   this install just wrote, restated by esp_cmdline_from().
grub_cmdline_options() {
    local f=$1/etc/default/grub
    printf '%s %s' "$(grub_default_value "$f" GRUB_CMDLINE_LINUX)" \
                   "$(grub_default_value "$f" GRUB_CMDLINE_LINUX_DEFAULT)" \
        | sed -E 's#(^| )root=[^ ]*##g; s/^ +//; s/ +$//; s/ {2,}/ /g'
}

# esp_cmdline_from <options> — the full command line: the new root UUID, then
#   the options. The fallback covers the pre-confirmation summary, printed
#   before any mkfs has produced a UUID to name.
esp_cmdline_from() {
    printf 'root=UUID=%s%s' "${NEW_UUID_ROOT:-<the new root UUID>}" "${1:+ $1}"
}

# esp_cmdline <mounted-root> — both of the above, for the real write.
esp_cmdline() {
    esp_cmdline_from "$(grub_cmdline_options "$1")"
}

# esp_entries <grubdir> — the systems registered on that ESP, one
#   "<root-uuid><TAB><title>" line each, ordered by title then UUID so the menu
#   has a stable, legible order no matter which system was installed last.
esp_entries() {
    local dir="$1/entries" f uuid title
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.cfg; do
        [ -e "$f" ] || continue
        uuid=${f##*/}; uuid=${uuid%.cfg}
        title=$(sed -nE 's/^menuentry "([^"]*)".*/\1/p' "$f" 2>/dev/null | head -n 1)
        printf '%s\t%s\n' "$uuid" "${title:-$uuid}"
    done | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k1,1
}

# esp_entry_text <title> <cmdline> <kernel-dir> — this system's entry file: the
#   GUI pair the toolkit has always offered, keyed to the filesystem that holds
#   /boot (NEW_UUID_BOOT: the /boot partition on a disk that has one, the root
#   filesystem otherwise), with the kernel path to match.
esp_entry_text() {
    local title=$1 cmdline=$2 kdir=$3
    cat <<EOF
# Written by install.sh -- one file per rootfs registered on this ESP.
# Root filesystem $NEW_UUID_ROOT on $TGT_ROOT; kernel read from $NEW_UUID_BOOT.
# Deleting this file retires the system from the menu; nothing else refers to it.
menuentry "Desktop $title" {
    search --no-floppy --fs-uuid --set=root $NEW_UUID_BOOT
    linux $kdir/vmlinuz $cmdline
    initrd $kdir/initrd.img
}

menuentry "Console $title" {
    search --no-floppy --fs-uuid --set=root $NEW_UUID_BOOT
    linux $kdir/vmlinuz $cmdline systemd.unit=multi-user.target
    initrd $kdir/initrd.img
}
EOF
}

# esp_master_text <grubdir> — the master menu, rebuilt from the entry files
#   present. timeout/default are carried over from the master already there, so
#   a value set by hand survives every later install and the last system
#   installed never silently redefines the menu for the others; 5 and 0 only
#   when writing a master from scratch. Each source is guarded, so an entry file
#   deleted by hand retires that system instead of breaking the menu for all of
#   them.
esp_master_text() {
    local grubdir=$1 timeout="" default="" uuid title
    if [ -f "$grubdir/grub.cfg" ]; then
        timeout=$(sed -nE 's/^[[:space:]]*set[[:space:]]+timeout=(.+)$/\1/p' "$grubdir/grub.cfg" | head -n 1)
        default=$(sed -nE 's/^[[:space:]]*set[[:space:]]+default=(.+)$/\1/p' "$grubdir/grub.cfg" | head -n 1)
    fi
    printf '%s\n' \
        "# Generated by install.sh: the menu shared by every rootfs on this disk." \
        "# Add nothing here -- per-system entries live in entries/<root-uuid>.cfg" \
        "# and this file is rebuilt from them on every install (timeout and" \
        "# default are carried over). Hand-written extras go in custom.cfg." \
        "set timeout=${timeout:-5}" \
        "set default=${default:-0}" \
        "" \
        "insmod part_gpt" \
        "insmod ext2" \
        ""
    while IFS="$(printf '\t')" read -r uuid title; do
        [ -n "$uuid" ] || continue
        printf '# %s\nif [ -f $prefix/entries/%s.cfg ]; then source $prefix/entries/%s.cfg; fi\n' \
            "$title" "$uuid" "$uuid"
    done < <(esp_entries "$grubdir")
    printf '\n%s\n' 'if [ -f $prefix/custom.cfg ]; then source $prefix/custom.cfg; fi'
}

# write_esp_menu — register this system in the shared menu, after
#   run_chroot_block has installed the modules grub-install puts there. Reads
#   caller globals (MNT, TGT_MODEL, TGT_ROOT, TGT_SEP_BOOT, NEW_UUID_ROOT,
#   NEW_UUID_BOOT, MENU_CMDLINE_PREVIEW); prints what it would write under
#   --dry-run, where the ESP is not mounted and the command line can only come
#   from the pre-confirmation probe.
write_esp_menu() {
    local grubdir="$MNT/boot/efi/boot/grub"
    local title=${TGT_MODEL//\"/} kdir="/boot" cmdline master
    [ "$TGT_SEP_BOOT" -eq 0 ] || kdir=""

    if [ "$DRY_RUN" -eq 1 ]; then
        cmdline=$(esp_cmdline_from "${MENU_CMDLINE_PREVIEW:-<options from /etc/default/grub, read at install time>}")
        echo "[dry-run] would write /boot/efi/boot/grub/entries/$NEW_UUID_ROOT.cfg:"
        esp_entry_text "$title" "$cmdline" "$kdir" | sed 's/^/    /'
        echo "[dry-run] would rebuild /boot/efi/boot/grub/grub.cfg over the entries:"
        local row uuid etitle shown=0
        for row in ${ESP_MENU_ENTRIES[@]+"${ESP_MENU_ENTRIES[@]}"}; do
            IFS="$(printf '\t')" read -r uuid etitle <<<"$row"
            [ "$uuid" = "$NEW_UUID_ROOT" ] && continue
            if [ "$uuid" = "${TGT_ROOT_UUID_NOW:-}" ]; then
                echo "    $uuid  $etitle  (retired with the filesystem it names)"
            else
                echo "    $uuid  $etitle  (kept)"
            fi
            shown=1
        done
        echo "    $NEW_UUID_ROOT  GUI $title / TTY $title  (this install)"
        [ "$shown" -eq 1 ] || [ "$ESP_MENU_PROBED" -eq 1 ] || \
            echo "    (the ESP could not be read here, so entries already on it are not listed)"
        return 0
    fi

    cmdline=$(esp_cmdline "$MNT")
    info "Registering \"GUI $title\" in the ESP master menu..."
    sudo mkdir -p "$grubdir/entries"
    esp_entry_text "$title" "$cmdline" "$kdir" | sudo tee "$grubdir/entries/$NEW_UUID_ROOT.cfg" >/dev/null
    # The system this partition held before it was reformatted: its filesystem
    # is gone, so its entry goes with it rather than pointing the menu at a UUID
    # that no longer exists anywhere.
    if [ -n "${TGT_ROOT_UUID_NOW:-}" ] && [ "$TGT_ROOT_UUID_NOW" != "$NEW_UUID_ROOT" ]; then
        sudo rm -f "$grubdir/entries/$TGT_ROOT_UUID_NOW.cfg"
    fi
    # Build the master before truncating it: it carries over its own timeout.
    master=$(esp_master_text "$grubdir")
    printf '%s\n' "$master" | sudo tee "$grubdir/grub.cfg" >/dev/null
}

run_chroot_block() {
    for i in /dev /dev/pts /proc /sys /run; do
        sudo mount --bind "$i" "$MNT$i"
    done

    # INSTALL_GRUB_BIOS / INSTALL_GRUB_EFI default to 1 (full install) for callers
    # that don't set them; install.sh gates BIOS on a BIOS target being given.
    # TGT_GRUB_DISK is resolved by the caller.
    #
    # --boot-directory=/boot/efi/boot puts GRUB's boot directory on the ESP for
    # BOTH firmware paths, so one prefix -- and one menu -- serves BIOS and UEFI
    # and belongs to the disk rather than to this rootfs. Nothing writes a
    # routing stub any more: with the boot directory on the ESP itself,
    # grub-install embeds a device-relative prefix in the image, which is why an
    # ESP built this way holds EFI/BOOT/BOOTX64.EFI and no EFI/BOOT/grub.cfg.
    sudo chroot "$MNT" /bin/bash <<EOF
set -e
echo "=> Inside chroot..."

if [ "${INSTALL_GRUB_BIOS:-1}" = 1 ]; then
    echo "=> Installing legacy BIOS GRUB to $TGT_GRUB_DISK..."
    grub-install --target=i386-pc --boot-directory=/boot/efi/boot "$TGT_GRUB_DISK"
fi

if [ "${INSTALL_GRUB_EFI:-1}" = 1 ]; then
    echo "=> Installing UEFI GRUB (removable)..."
    if grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                    --boot-directory=/boot/efi/boot --removable --no-uefi-secure-boot; then
        rm -rf /boot/efi/EFI/ubuntu
        # A stub left by an older version of this toolkit, when the menu lived
        # on the rootfs. The prefix is embedded now, so nothing reads it.
        rm -f /boot/efi/EFI/BOOT/grub.cfg
    else
        echo "grub-install (EFI) failed; leaving /boot/efi/EFI/ubuntu untouched."
    fi
fi

# The menu GRUB actually reads is the one on the ESP, written by
# write_esp_menu() once this chroot is done. This regenerates the rootfs's own
# /boot/grub/grub.cfg, which nothing boots from any more but which keeps the
# system self-describing (and is what a rescue "configfile" would find).
echo "=> Regenerating the rootfs menu..."
update-grub

echo "=> Rebuilding initramfs..."
update-initramfs -u -k all

echo "=> Exiting chroot."
EOF
}

# verify_install — post-install sanity checks on the still-mounted target tree:
#   fstab and the regenerated grub.cfg must reference the new UUIDs (and no
#   longer the old ones), the ESP must carry GRUB's boot directory with this
#   system registered in the shared menu, and every system that was registered
#   there before must still be. Catches a silently broken configuration while
#   the disk is still on the desk rather than at boot time on another machine.
#   Reads caller globals (MNT, SRC_SEP_BOOT/TGT_SEP_BOOT, ESP_MENU_ENTRIES,
#   INSTALL_GRUB_BIOS, OLD_UUID_*/NEW_UUID_*, SWAP_DEV, NEW_UUID_SWAP).
#   Returns non-zero if any check failed.
verify_install() {
    local fails=0
    vcheck() {
        local desc=$1; shift
        if "$@" >/dev/null 2>&1; then
            echo "  [PASS] $desc"
        else
            echo "  [FAIL] $desc"
            fails=$((fails+1))
        fi
    }
    absent() { ! sudo grep -qF "$1" "$2"; }
    # Same, but blind to commented-out lines: a /boot entry inherited from the
    # source and disabled by rewrite_fstab() legitimately still carries the old
    # UUID.
    absent_active() {
        ! sudo awk -v s="$1" '$0 !~ /^[[:space:]]*#/ && index($0, s) > 0 { found = 1 }
                              END { exit !found }' "$2"
    }
    no_boot_entry() { ! fstab_mounts_boot "$1"; }

    vcheck "fstab mounts / by the new root UUID"       sudo grep -qF "$NEW_UUID_ROOT" "$MNT/etc/fstab"
    if [ "$TGT_SEP_BOOT" -eq 1 ]; then
        vcheck "fstab mounts /boot by the new boot UUID" sudo grep -qF "$NEW_UUID_BOOT" "$MNT/etc/fstab"
    else
        vcheck "fstab has no /boot entry (/boot lives inside /)" no_boot_entry "$MNT/etc/fstab"
    fi
    vcheck "fstab mounts the ESP by the new EFI UUID"  sudo grep -qF "$NEW_UUID_EFI"  "$MNT/etc/fstab"
    if [ -n "$SWAP_DEV" ]; then
        vcheck "fstab swap entry uses the new swap UUID" sudo grep -qF "$NEW_UUID_SWAP" "$MNT/etc/fstab"
    fi
    [ "$OLD_UUID_ROOT" = "$NEW_UUID_ROOT" ] || \
        vcheck "fstab carries no stale root UUID" absent_active "$OLD_UUID_ROOT" "$MNT/etc/fstab"
    [ "$OLD_UUID_EFI" = "$NEW_UUID_EFI" ] || \
        vcheck "fstab carries no stale EFI UUID"  absent_active "$OLD_UUID_EFI"  "$MNT/etc/fstab"
    # Only when the source really had a separate /boot: otherwise OLD_UUID_BOOT
    # *is* OLD_UUID_ROOT, which an in-place root legitimately still carries.
    if [ "$SRC_SEP_BOOT" -eq 1 ] && [ "$OLD_UUID_BOOT" != "$NEW_UUID_BOOT" ]; then
        vcheck "fstab carries no stale boot UUID" absent_active "$OLD_UUID_BOOT" "$MNT/etc/fstab"
    fi

    vcheck "grub.cfg boots by the new root UUID"       sudo grep -qF "$NEW_UUID_ROOT" "$MNT/boot/grub/grub.cfg"
    # update-grub prefixes its menu entries with a search for the filesystem
    # holding /boot. With /boot inside / that is the root UUID, already checked
    # above; a separate /boot is its own filesystem and worth checking.
    if [ "$TGT_SEP_BOOT" -eq 1 ]; then
        vcheck "grub.cfg searches the /boot filesystem" \
            sudo grep -qF "$NEW_UUID_BOOT" "$MNT/boot/grub/grub.cfg"
    fi
    [ "$OLD_UUID_ROOT" = "$NEW_UUID_ROOT" ] || \
        vcheck "grub.cfg carries no stale root UUID" absent "$OLD_UUID_ROOT" "$MNT/boot/grub/grub.cfg"

    vcheck "EFI fallback loader present (EFI/BOOT/BOOTX64.EFI)" \
        sudo test -f "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"

    # The standalone ESP: GRUB's boot directory, the menu it reads, and this
    # system's entry in it. There is no routing stub to check -- with the boot
    # directory on the ESP, grub-install embeds the prefix in the image.
    local espgrub="$MNT/boot/efi/boot/grub"
    local espentry="$espgrub/entries/$NEW_UUID_ROOT.cfg"
    vcheck "EFI GRUB modules on the ESP (boot/grub/x86_64-efi)" \
        sudo test -d "$espgrub/x86_64-efi"
    if [ "${INSTALL_GRUB_BIOS:-0}" -eq 1 ]; then
        vcheck "BIOS GRUB modules on the ESP (boot/grub/i386-pc)" \
            sudo test -d "$espgrub/i386-pc"
    fi
    vcheck "this system is registered in the ESP menu (entries/$NEW_UUID_ROOT.cfg)" \
        sudo test -f "$espentry"
    vcheck "its entry boots the new root UUID" \
        sudo grep -qF "root=UUID=$NEW_UUID_ROOT" "$espentry"
    vcheck "its entry searches the filesystem holding /boot" \
        sudo grep -qF "set=root $NEW_UUID_BOOT" "$espentry"
    vcheck "the ESP master menu sources it" \
        sudo grep -qF "entries/$NEW_UUID_ROOT.cfg" "$espgrub/grub.cfg"
    # Every other system that was on this ESP before the run must still be on
    # it: rebuilding the shared master is the one step that could quietly
    # unregister the machines this install was not about.
    local row uuid etitle
    for row in ${ESP_MENU_ENTRIES[@]+"${ESP_MENU_ENTRIES[@]}"}; do
        IFS="$(printf '\t')" read -r uuid etitle <<<"$row"
        [ -n "$uuid" ] && [ "$uuid" != "$NEW_UUID_ROOT" ] || continue
        # Retired on purpose with the filesystem it named (write_esp_menu).
        [ "$uuid" != "${TGT_ROOT_UUID_NOW:-}" ] || continue
        vcheck "kept the entry for \"$etitle\" ($uuid)" \
            sudo sh -c 'test -f "$1" && grep -qF "$2" "$3"' _ \
                "$espgrub/entries/$uuid.cfg" "entries/$uuid.cfg" "$espgrub/grub.cfg"
    done
    # Proves the /boot content actually landed -- the one thing a layout change
    # (a separate /boot folded into /, or split back out) can silently lose, and
    # the backstop for a source that hides /boot in some way the Phase 3 fstab
    # check cannot see (an unlisted mount, a bind).
    vcheck "a kernel image is present under /boot" \
        sudo sh -c 'ls "$1"/boot/vmlinuz-* >/dev/null 2>&1' _ "$MNT"

    local sf
    for sf in "${SWAPFILES_REBUILT[@]}"; do
        vcheck "swap file $sf is fully allocated and formatted" swapfile_ok "$MNT$sf"
    done
    for sf in "${SWAPFILES_DROPPED[@]}"; do
        vcheck "dropped swap file $sf is absent from the target" \
            sudo test ! -e "$MNT$sf"
        vcheck "dropped swap file $sf is disabled in fstab" \
            fstab_disabled "$sf" "$MNT/etc/fstab"
    done

    if [ "$fails" -gt 0 ]; then
        echo "  $fails verification check(s) FAILED."
        return 1
    fi
    return 0
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
# Empty = derive the root inode count from the partition size; --inodes-root pins it.
INODES_ROOT="${INODES_ROOT:-}"
# Empty = the default 256 MiB ESP; --target-efi-size overrides it (fresh --target only).
TGT_EFI_SIZE="${TGT_EFI_SIZE:-}"
ESP_MIB=256
DRY_RUN=0
UPDATE=0
NO_TRIM=0
# Keep the ESP's filesystem: no mkfs, no new UUID. What a shared ESP needs, and
# nothing else -- its contents are written by grub-install and write_esp_menu on
# every run either way, since the ESP is generated here, never copied.
KEEP_EFI=0
SPARSE=0
ASSUME_YES=0
MNT_AUTO=0
SRC_AUTO=0
LOOP_ATTACHED=0
MOUNTS_DONE=0
CLEANED=0
# "This target keeps /boot inside /", said explicitly (see --no-target-boot).
NO_TGT_BOOT=0

# The systems already registered in the shared ESP menu (probe_esp_menu), the
# boot options this system's entry will carry (probe_menu_cmdline / the source
# swap probe), and the UUIDs verify_install needs before they exist.
ESP_MENU_ENTRIES=()
ESP_MENU_PROBED=0
MENU_CMDLINE_PREVIEW=""
NEW_UUID_ROOT=""

# Swap files listed in the source's fstab: to rebuild, dropped by --exclude-from,
# actually rebuilt (verified later), and the rsync exclusions for all of them.
SWAPFILES=()
SWAPFILES_DROPPED=()
SWAPFILES_REBUILT=()
SWAP_EXCLUDES=()
declare -A SWAPFILE_TGT_SIZE=()
# What the pre-confirmation probe found: "<path> <bytes|?> <keep|drop>" per swap
# file, and whether the probe managed to read the source's fstab at all.
SWAP_PREVIEW=()
SWAP_PROBED=0

# Where rewrite_fstab()'s awk records what it disabled, for the report printed
# right afterwards. Held globally only so cleanup() can remove it when the run
# ends between the mktemp and the rm (an interrupt, or a failing awk under -e).
FSTAB_REPORT=""

# Run with nothing to do: show the help rather than marching into Phase 1 and
# failing on the *default* source path, which says nothing about what went
# wrong. Env-var-only invocations (TARGET=/dev/sdb ./install.sh) still work --
# they are only "no arguments" as far as $# is concerned, so check for a target
# in the environment before deciding the user asked for nothing.
if [ $# -eq 0 ] && [ -z "${TARGET}${TGT_ROOT}${TGT_EFI}${TGT_BIOS}${TGT_BOOT}" ]; then
    set -- --help
fi

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
        --no-target-boot)   NO_TGT_BOOT=1; shift ;;
        --target-root)      TGT_ROOT="$2"; shift 2 ;;
        --target-swap)      TGT_SWAP="$2"; shift 2 ;;
        --keep-efi)         KEEP_EFI=1;    shift ;;

        --mnt)            MNT="$2"; shift 2 ;;
        --src)            SRC="$2"; shift 2 ;;
        --exclude-from)   EXCLUDE_FROM="$2"; shift 2 ;;
        --brand)          BRAND="$2"; shift 2 ;;
        --inodes-root)    INODES_ROOT="$2"; shift 2 ;;
        --target-efi-size) TGT_EFI_SIZE="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --update)         UPDATE=1; shift ;;
        --no-trim)        NO_TRIM=1; shift ;;
        --sparse)         SPARSE=1; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<USAGE
Usage: $0 [source] [target] [options]

Deploys a portable Ubuntu system. Each role (EFI, /boot, /, swap) is either left
in place or migrated: a --target-X defaults to its --source-X, so a role whose
target equals its source is left untouched, and one whose target differs is
formatted and copied.

A separate /boot is EXPLICIT on both sides and never discovered: --source-boot
says the source keeps /boot on a filesystem of its own, --target-boot gives the
target one (an existing partition -- a fresh --target is still partitioned BIOS
Boot + ESP + root). Say nothing and /boot is an ordinary directory inside /,
which is what the images this toolkit distributes carry. Either layout converts
to the other: --no-target-boot folds a source's separate /boot into the target's
root filesystem, --target-boot splits it back out. Where the source has one and
the target is described by individual --target-* partitions, saying which of the
two you want is required rather than guessed. The other roles are found by GPT
type and filesystem label, so any other partition on either disk (data, swap,
an unnamed /boot, another distro) is ignored -- but a disk with several
unlabelled Linux partitions, or several labelled "root", is an error rather than
a guess: name root with --source-root / --target-root, or label it
(e2label PART root). A disk carrying one rootfs per machine behind a shared ESP
is exactly that case, and is always addressed partition by partition.

The ESP is the exception to "migrated": it is never copied from the source.
GRUB is installed onto it with its boot directory there (/boot/efi/boot/grub),
for legacy BIOS and UEFI alike, and this system is registered in the menu that
lives there -- see the notes below.

Source (pick one form):
  --image|--source FILE|DEV   Whole image file or block device
                              (default: Ubuntu26-Portable-16GB.img)
  --source-efi / --source-root PART
                              Scattered source: both required
  --source-boot PART          The source keeps /boot on this partition. Omit
                              when it keeps /boot inside / (an image always
                              does). Needs the scattered form above, so the
                              partition has a name before anything is mounted.
  --source-swap PART          Reuse this swap as-is (NOT reformatted)

Target:
  --target DEV                Whole device: GPT-partition it (BIOS Boot, ESP,
                              root) and format
                              (with --update: treat as already-partitioned and
                              sync onto its existing layout instead)
  --target-bios-boot PART     Provide to (re)install the legacy BIOS bootloader
  --target-efi PART           Defaults to --source-efi  (omit/equal = keep in place)
  --target-boot PART          Give this disk a separate /boot on PART, which must
                              already exist (equal to --source-boot = keep in
                              place). Cannot be combined with a unified --target.
  --no-target-boot            This disk keeps /boot inside /. Needed only when
                              the SOURCE has a separate /boot and the target is
                              named partition by partition -- then one of these
                              two flags must say what becomes of it.
  --target-root PART          Defaults to --source-root (omit/equal = keep in place)
  --target-swap PART          Use this swap, reformatting it (mkswap)
  --keep-efi                  Do not format --target-efi: keep its filesystem and
                              its UUID, and only refresh GRUB and this system's
                              menu entry on it. What a shared ESP needs -- the one
                              a disk carrying a rootfs per machine boots them all
                              from -- since formatting it would drop the other
                              systems' entries and change the UUID their fstabs
                              name. The ESP is never copied from the source in
                              either case; its contents are written here.

Other:
  --update                    Sync onto already-formatted target partitions:
                              skip mkfs and rsync with --delete, refreshing an
                              existing clone in place instead of reformatting it
  --exclude-from FILE         Pass FILE to rsync as --exclude-from, so the listed
                              paths are omitted from the copy (e.g. to produce an
                              impersonal clone). Works with or without --update;
                              under --update the listed paths are also purged from
                              the target (rsync --delete-excluded). A swap file
                              listed here is dropped rather than re-created, and
                              its fstab entry is commented out.
  --brand NAME                Brand the GRUB menu title with NAME instead of the
                              target disk's reported model (useful when the medium
                              sits in a USB card reader, whose model string —
                              e.g. "SD Transcend" — says nothing about the card).
                              Without it, --update keeps the brand already stamped
                              into the target's /etc/default/grub, so a brand
                              chosen at install time survives every sync.
  --target-efi-size SIZE      Size of the ESP on a freshly partitioned --target
                              (default 256M). A bare number is MiB; k/M/G are
                              accepted and must come out whole MiB, since the
                              root partition starts where the ESP ends. Only
                              applies when this run partitions the disk -- not
                              with --update or individual --target-* partitions.
  --inodes-root N             Pass N to the root mkfs.ext4 as -N instead of
                              deriving it from the partition size (~4 MiB per
                              inode, floor 1.5M). A k or M suffix is accepted:
                              1572864, 1536k and 1M all name a count, not a
                              size. An explicit count is used as given -- the
                              1.5M floor is not applied. Only relevant when the
                              root filesystem is actually formatted (not under
                              --update, which keeps the existing one).
  --sparse                    Add -S to the rsync, re-creating each run of nulls
                              in the source as a hole rather than writing it out.
                              Off by default: a hole costs an entry in the file's
                              ext4 extent tree, and a big VM image perforated by
                              thousands of small ones ends up with a tree so wide
                              that fsck.ext4 -f offers to optimize it (and every
                              read of the file walks the extra level). Measured on
                              one 51.8 GiB .vdi: 12,309 holes, 82% of them 64 KiB
                              or smaller, saving 1.01 GiB (2%) between them and
                              costing ~11,900 extents. Worth enabling only for a
                              source holding genuinely, largely sparse files.
  --no-trim                   Skip the closing fstrim of the written filesystems.
                              By default the ESP is trimmed on every run (mkfs.fat
                              has no discard of its own) but the ext4 filesystems
                              only under --update: a fresh mkfs.ext4 has already
                              discarded the whole partition and the rsync that
                              follows only allocates, so nothing is left to
                              reclaim. Trimming keeps flash fast and makes a
                              loop-attached .img sparse (the loop driver turns
                              discards into hole punches on the backing file, so
                              a fallocate'd image only shrinks if this runs).
  --mnt DIR                   Target root mount point  (default: private temp dir)
  --src DIR                   Source root mount point  (default: private temp dir)
  --yes, -y                   Skip the confirmation prompt (for scripted runs)
  --dry-run                   Print destructive commands instead of running them.
                              Two read-only probes still run, so that the summary
                              above the confirmation prompt is accurate rather
                              than guessed: the source's fstab (which swap files
                              would be re-created) and, under --update, the
                              target's current GRUB brand. Both are transient
                              read-only mounts; nothing is written.
  -h, --help                  Show this help

Notes:
  * --source-swap (reuse) and --target-swap (reformat) are mutually exclusive.
    They cover swap PARTITIONS; a swap FILE listed in the source's fstab needs no
    option -- it is never copied (it is a run of zeros that fallocate re-creates
    for free, and under --sparse rsync would leave it full of holes, which swapon
    refuses) and is re-created on the target at the source's size.
  * EFI booting uses the EFI System Partition; the BIOS Boot partition is only
    for legacy boot and is regenerated by grub-install (when --target-bios-boot
    is given) or left intact otherwise.
  * GRUB's boot directory lives on the ESP (/boot/efi/boot/grub), for legacy BIOS
    and UEFI alike, so the menu belongs to the disk rather than to any one rootfs.
    Each install registers itself in entries/<root-uuid>.cfg there and rebuilds
    the master grub.cfg over whatever entry files are present, keeping its
    timeout/default; hand-written extras go in custom.cfg, sourced last. Deleting
    an entry file retires that system from the menu. So one disk can carry a
    rootfs per machine behind a single ESP:
      $0 --source /dev/sde --target-efi /dev/sde2 --keep-efi \\
         --target-bios-boot /dev/sde1 --target-root /dev/sde5 --brand Laptop
  * A separate /boot earns its keep on a machine whose BIOS cannot boot from
    NVMe: BIOS Boot, the ESP and /boot go on a disk that BIOS can read, while /
    -- everything the running system actually reads -- stays on the NVMe.
  * Multiple instances may run concurrently (e.g. flashing several disks from
    one source). Disks are guarded by advisory locks under /run/lock: written
    disks exclusively, source disks shared; a conflicting instance fails fast
    before its confirmation prompt. Run each instance in its own terminal.

Examples:
  # Full deploy of an image onto a fresh disk (3 partitions: BIOS Boot, ESP, /):
  $0 --image Ubuntu26-Portable-16GB.img --target /dev/sda

  # Deploy from the running machine's own disk, whatever else it carries:
  $0 --source /dev/nvme0n1 --target /dev/sda

  # Add a second machine's rootfs to a disk that already boots one: keep the
  # shared ESP (and register this system in the menu on it), format only sde5:
  $0 --image Ubuntu26-Portable-16GB.img --keep-efi \\
     --target-bios-boot /dev/sde1 --target-efi /dev/sde2 \\
     --target-root /dev/sde5 --brand Laptop

  # Migrate ONLY the root filesystem to a new partition, keeping EFI in place:
  $0 --source-efi /dev/sda2 --source-root /dev/sda3 \\
     --target-root /dev/nvme0n1p1

  # Fold a split source (EFI on sda, root on NVMe) onto a 3-partition disk:
  $0 --source-efi /dev/sda2 --source-root /dev/nvme0n1p1 \\
     --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 --target-root /dev/sdb3

  # Build the layout for a BIOS that cannot boot NVMe: BIOS Boot, ESP and /boot
  # on sda (all four partitions must already exist), / on the NVMe:
  $0 --image Ubuntu26-Portable-16GB.img \\
     --target-bios-boot /dev/sda1 --target-efi /dev/sda2 \\
     --target-boot /dev/sda3 --target-root /dev/nvme0n1p1

  # Sync that machine onto a portable disk that also keeps a separate /boot:
  $0 --source-efi /dev/sda2 --source-boot /dev/sda3 \\
     --source-root /dev/nvme0n1p1 \\
     --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \\
     --target-boot /dev/sdb3 --target-root /dev/sdb4 --update

  # ...or onto an ordinary 3-partition disk, folding its /boot into /:
  $0 --source-efi /dev/sda2 --source-boot /dev/sda3 \\
     --source-root /dev/nvme0n1p1 --no-target-boot \\
     --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 --target-root /dev/sdb3

  # Incrementally sync a split-disk source onto an already-formatted disk (no
  # reformat — rsync --delete refreshes the existing clone). Replaces the old
  # backup.sh disk-to-disk clone:
  $0 --source-efi /dev/sda2 --source-root /dev/nvme0n1p1 \\
     --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \\
     --target-root /dev/sdb3 --update

  # Impersonal clone: deploy minus the paths listed in exclude-personal.txt:
  $0 --image Ubuntu26-Portable-16GB.img --target /dev/sda \\
     --exclude-from exclude-personal.txt

Most options also read from the matching environment variable (SOURCE, TARGET,
SRC_ROOT, SRC_BOOT, TGT_ROOT, TGT_BOOT, TGT_SWAP, EXCLUDE_FROM, ...).
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

# --inodes-root is handed to mkfs.ext4 -N, which wants a plain count; accept a
# k/M suffix too, since the useful values are things like 1572864. Resolved here
# so a typo fails before any disk is touched, rather than at mkfs time. 10# keeps
# a leading zero from being read as octal.
if [ -n "$INODES_ROOT" ]; then
    if [[ "$INODES_ROOT" =~ ^([0-9]+)([kKmM]?)$ ]]; then
        n=$((10#${BASH_REMATCH[1]}))
        case "${BASH_REMATCH[2]}" in
            k|K) n=$(( n * 1024 )) ;;
            m|M) n=$(( n * 1024 * 1024 )) ;;
        esac
        [ "$n" -gt 0 ] || die "--inodes-root must be greater than zero."
        INODES_ROOT=$n
    else
        die "--inodes-root must be a positive integer, optionally with a k or M suffix (e.g. 1572864, 1536k, 2M)."
    fi
fi

# --target-efi-size is a SIZE, not a count: a bare number means MiB (the unit the
# GPT layout is expressed in), and k/M/G are KiB/MiB/GiB. It must come out to a
# whole number of MiB, since the root partition starts where the ESP ends and a
# sub-MiB boundary would misalign it. Validated here for the same reason as
# --inodes-root: a typo must not survive until parted has already run.
if [ -n "$TGT_EFI_SIZE" ]; then
    if [[ "$TGT_EFI_SIZE" =~ ^([0-9]+)([kKmMgG]?)$ ]]; then
        n=$((10#${BASH_REMATCH[1]}))
        case "${BASH_REMATCH[2]}" in
            k|K) [ $(( n % 1024 )) -eq 0 ] || \
                     die "--target-efi-size must be a whole number of MiB (got $TGT_EFI_SIZE)."
                 n=$(( n / 1024 )) ;;
            g|G) n=$(( n * 1024 )) ;;
        esac
        [ "$n" -gt 0 ] || die "--target-efi-size must be greater than zero."
        # No hard floor: mkfs.fat -F32 will format even 1 MiB. But the GRUB EFI
        # payload plus the fallback loader need a few MiB, and that failure would
        # not surface until grub-install, long after the disk was partitioned.
        [ "$n" -ge 16 ] || \
            echo "Warning: a ${n} MiB ESP may be too small for the GRUB EFI payload." >&2
        ESP_MIB=$n
    else
        die "--target-efi-size must be a positive integer, optionally with a k, M or G suffix (e.g. 256, 512M, 1G)."
    fi
fi

# Front-load the sudo password prompt before any resources are acquired, so it
# cannot fire mid-rsync (sudo timestamps are per-tty and can expire mid-run).
# A dry run needs it too, for the transient ro mounts the summary is built from:
# the target's existing GRUB brand under --update (without --brand), and the
# source's fstab whenever the source root is a block device we can actually
# mount. An image source in a dry run is the one case that still needs no root
# at all -- no loop device is attached, so there is nothing to read.
if [ "$DRY_RUN" -eq 0 ] || { [ $UPDATE -eq 1 ] && [ -z "$BRAND" ]; } || \
   [ -b "$SOURCE" ] || [ -b "$SRC_ROOT" ]; then
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
    if [ -n "${FSTAB_REPORT:-}" ]; then rm -f "$FSTAB_REPORT"; fi
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

# summary_row <label> <text> — one line of the pre-confirmation summary. The
# 10-column label field is what aligns "EFI:", "/ (root):", "swap:" and the rest;
# pass an empty label for a continuation line under the previous one.
summary_row() { printf '  %-10s%s\n' "$1" "$2"; }

# role_row <label> <migrate-flag> <source-dev> <target-dev> — a summary row for
# one filesystem role. A migrated/synced role names where the data comes FROM as
# well as where it lands, since which source partition feeds which target is the
# thing worth checking before committing to a multi-hour transfer; an in-place
# role has only the one device to name.
role_row() {
    if [ "$2" -eq 1 ]; then
        summary_row "$1" "$(role_state "$2")  $3 -> $4"
    else
        summary_row "$1" "$(role_state "$2")  $4"
    fi
}

# human_size <bytes> — "8.0 GiB" style. Summary output only; nothing parses it.
human_size() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i];
    }'
}

LOOP_DEV=""
UNIFIED_TARGET=0

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------
SCATTERED_SOURCE=0
if [ -n "$SRC_EFI" ] || [ -n "$SRC_BOOT" ] || [ -n "$SRC_ROOT" ]; then
    SCATTERED_SOURCE=1
    # --source-boot names one partition of a scattered source; it cannot stand
    # in for the source itself. That is also what keeps it away from an --image:
    # a partition inside an image file has no name until the loop attach, which
    # happens long after this point.
    if [ -n "$SRC_BOOT" ] && { [ -z "$SRC_EFI" ] || [ -z "$SRC_ROOT" ]; }; then
        die "--source-boot names one partition of a scattered source, so --source-efi and --source-root are needed with it.
(An image keeps /boot inside /, and its partitions have no names until it is attached.)"
    fi
    [ -n "$SRC_EFI" ]  || die "Scattered source needs --source-efi."
    [ -n "$SRC_ROOT" ] || die "Scattered source needs --source-root."
    [ -z "$TARGET" ] || die "Do not combine scattered --source-* with a unified --target."
fi

if [ $NO_TGT_BOOT -eq 1 ] && [ -n "$TGT_BOOT" ]; then
    die "Specify only one of --target-boot (a separate /boot) or --no-target-boot (/boot inside /)."
fi

# A unified --target owns the whole disk; mixing it with per-role --target-*
# partitions would silently ignore one or the other. A separate /boot on the
# target is therefore always spelt out partition by partition: this script
# partitions a fresh disk as BIOS Boot + ESP + root and nothing else.
if [ -n "$TARGET" ]; then
    for v in "$TGT_BIOS" "$TGT_EFI" "$TGT_BOOT" "$TGT_ROOT"; do
        [ -z "$v" ] || die "Do not combine a unified --target with individual --target-* partitions."
    done
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
    if [ -n "$SRC_BOOT" ]; then
        validate_partition_type "$SRC_BOOT" "$GUID_LINUX" "Source Boot" || die "Invalid Source Boot"
    fi
    validate_partition_type "$SRC_ROOT" "$GUID_LINUX" "Source Root" || die "Invalid Source Root"
else
    if [ -b "$SOURCE" ]; then
        echo "Source Mode: Unified Block Device ($SOURCE)"
        scan_disk_roles "$SOURCE" SRC
    elif [ -f "$SOURCE" ]; then
        echo "Source Mode: Flat File Image ($SOURCE)"
        if [ "$DRY_RUN" -eq 1 ]; then
            # No loop device is attached in dry-run, so lsblk has nothing to
            # scan. parted reads the image's partition table out of the file
            # itself, so the summary still shows its real layout.
            # Name the device the real run would actually get rather than
            # assuming loop0: when the TARGET is itself a loop device, a
            # hardcoded loop0 collides with it and the safety check below
            # rejects the run with a bogus "it is also a source partition".
            LOOP_DEV=$(losetup -f 2>/dev/null) || LOOP_DEV=""
            [ -n "$LOOP_DEV" ] || LOOP_DEV="/dev/loop0"
            # A real run attaches the source only once the target is already in
            # use, so losetup can never hand it the target's own loop device. A
            # dry run has no such protection: losetup -f names the target itself
            # whenever that loop is not currently attached, and the "target is
            # also a source partition" check downstream then rejects a conflict
            # that cannot happen for real. Step past whatever the user named.
            loop_tries=0
            while [[ "$LOOP_DEV" =~ ^/dev/loop[0-9]+$ ]] && \
                  dryrun_loop_clashes "$LOOP_DEV" && [ $loop_tries -lt 64 ]; do
                LOOP_DEV="/dev/loop$(( ${LOOP_DEV##*/loop} + 1 ))"
                loop_tries=$((loop_tries + 1))
            done
            echo "[dry-run] sudo losetup -r -P -f --show \"$SOURCE\""
            IFS=: read -r n_efi n_root < <(scan_image_roles_dryrun "$SOURCE") || true
            if [ -z "${n_root:-}" ]; then
                # Unreadable table: fall back to the canonical numbers of the
                # layout this toolkit produces (BIOS Boot, ESP, root).
                echo "Warning: cannot read the partition table of $SOURCE -- assuming the default layout." >&2
                n_efi=2; n_root=3
            fi
            SRC_EFI="${LOOP_DEV}p${n_efi}"
            SRC_ROOT="${LOOP_DEV}p${n_root}"
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
            scan_disk_roles "$LOOP_DEV" SRC
        fi
    else
        die "Source '$SOURCE' is neither a valid block device nor a regular file."
    fi
fi

# Does the source keep /boot on its own filesystem, or inside /? --source-boot
# is the only thing that decides: no partition table is consulted, and the
# source's own fstab is cross-checked once it is mounted (Phase 3).
if [ -n "$SRC_BOOT" ]; then SRC_SEP_BOOT=1; else SRC_SEP_BOOT=0; fi
if [ $SRC_SEP_BOOT -eq 1 ]; then
    echo "Source /boot: separate partition ($SRC_BOOT)"
else
    echo "Source /boot: inside the root filesystem"
fi

# Old UUIDs from the source (translated into the target's fstab/GRUB later).
# Without a separate /boot, OLD_UUID_BOOT *is* the root UUID: every consumer
# wants "the UUID of the filesystem holding /boot", and keeping it non-empty
# also keeps rewrite_fstab's awk substitutions off an empty regex, which would
# match at every character position.
if [ "$DRY_RUN" -eq 1 ]; then
    OLD_UUID_EFI="00000000-0000-0000-0000-000000000001"
    OLD_UUID_ROOT="00000000-0000-0000-0000-000000000003"
    if [ $SRC_SEP_BOOT -eq 1 ]; then
        OLD_UUID_BOOT="00000000-0000-0000-0000-000000000002"
    else
        OLD_UUID_BOOT="$OLD_UUID_ROOT"
    fi
else
    OLD_UUID_EFI=$(blkid_uuid "$SRC_EFI")
    OLD_UUID_ROOT=$(blkid_uuid "$SRC_ROOT")
    if [ $SRC_SEP_BOOT -eq 1 ]; then
        OLD_UUID_BOOT=$(blkid_uuid "$SRC_BOOT")
    else
        OLD_UUID_BOOT="$OLD_UUID_ROOT"
    fi
fi

echo "=========================================="
echo " Phase 2: Target Drive Preparation        "
echo "=========================================="
if [ $SCATTERED_SOURCE -eq 1 ]; then
    # Each target defaults to its source => in-place unless overridden.
    TGT_EFI="${TGT_EFI:-$SRC_EFI}"
    TGT_ROOT="${TGT_ROOT:-$SRC_ROOT}"
    # /boot is the one role NOT defaulted from the source. A target that
    # inherited --source-boot in place would leave the clone's fstab mounting
    # /boot from the SOURCE machine's disk -- bootable only while that disk is
    # attached -- so when the source has one, this run has to say what becomes
    # of it. Neither direction is worth guessing: converting the layout by
    # accident is how a machine whose BIOS cannot read NVMe stops booting.
    if [ $SRC_SEP_BOOT -eq 1 ] && [ -z "$TGT_BOOT" ] && [ $NO_TGT_BOOT -eq 0 ]; then
        die "The source keeps /boot on its own filesystem ($SRC_BOOT).
Say what the target should do with it:
  --target-boot PART   give this target its own /boot on PART
  --no-target-boot     fold /boot into the target's root filesystem"
    fi
    echo "Target Mode: Scattered Partitions (per-role migrate / in-place)"
    if [ -n "$TGT_BIOS" ]; then
        validate_partition_type "$TGT_BIOS" "$GUID_BIOS" "Target BIOS" || die "Invalid Target BIOS"
    fi
    validate_partition_type "$TGT_EFI"  "$GUID_EFI"   "Target EFI"  || die "Invalid Target EFI"
    if [ -n "$TGT_BOOT" ]; then
        validate_partition_type "$TGT_BOOT" "$GUID_LINUX" "Target Boot" || die "Invalid Target Boot"
    fi
    validate_partition_type "$TGT_ROOT" "$GUID_LINUX" "Target Root" || die "Invalid Target Root"
else
    # Unified/image source => full deploy. The target is a unified device, or
    # individual --target-* partitions: --target-efi and --target-root are
    # required, --target-bios-boot and --target-boot optional (no --target-boot
    # means /boot goes inside /, which is where the source keeps it anyway --
    # a unified or image source cannot carry --source-boot).
    if [ -n "$TGT_BIOS" ] || [ -n "$TGT_EFI" ] || [ -n "$TGT_BOOT" ] || [ -n "$TGT_ROOT" ]; then
        [ -n "$TGT_EFI" ]  || die "Scattered target needs --target-efi."
        [ -n "$TGT_ROOT" ] || die "Scattered target needs --target-root."
        echo "Target Mode: Scattered Partitions (full deploy)"
        if [ -n "$TGT_BIOS" ]; then
            validate_partition_type "$TGT_BIOS" "$GUID_BIOS" "Target BIOS" || die "Invalid Target BIOS"
        fi
        validate_partition_type "$TGT_EFI"  "$GUID_EFI"   "Target EFI"  || die "Invalid Target EFI"
        if [ -n "$TGT_BOOT" ]; then
            validate_partition_type "$TGT_BOOT" "$GUID_LINUX" "Target Boot" || die "Invalid Target Boot"
        fi
        validate_partition_type "$TGT_ROOT" "$GUID_LINUX" "Target Root" || die "Invalid Target Root"
    else
        [ -n "$TARGET" ] || die "Specify a unified --target DEV, --target-efi/--target-root partitions, or scattered --source-* for partial migration."
        if [ "$DRY_RUN" -eq 0 ] && [ ! -b "$TARGET" ]; then
            die "Target '$TARGET' is not a block device."
        fi
        UNIFIED_TARGET=1
        echo "Target Mode: Unified Block Device ($TARGET)"
        P=$(partition_prefix "$TARGET")
        if [ $UPDATE -eq 1 ] && [ -b "$TARGET" ]; then
            # --update keeps the existing layout (we neither repartition nor
            # format), so discover it rather than impose one -- the ESP and root
            # may sit at any partition number, and anything else on the disk is
            # left alone. A /boot partition included: it is never adopted by the
            # scan, and a unified --target cannot be combined with the
            # --target-boot that would name it, so a disk with a separate /boot
            # is synced by naming its partitions individually.
            info "Reading the existing layout of $TARGET..."
            scan_disk_roles "$TARGET" TGT
        else
            # A fresh disk gets the three-partition layout: BIOS Boot, ESP, and
            # a root filesystem that also holds /boot.
            TGT_BIOS="${TARGET}${P}1"
            TGT_EFI="${TARGET}${P}2"
            TGT_ROOT="${TARGET}${P}3"
        fi
    fi
fi

# --target-efi-size only reaches parted, which only runs for a fresh unified
# --target. Anywhere else the ESP already exists and the value would be silently
# ignored -- say so instead.
if [ -n "$TGT_EFI_SIZE" ] && { [ $UNIFIED_TARGET -eq 0 ] || [ $UPDATE -eq 1 ]; }; then
    die "--target-efi-size only applies when partitioning a fresh --target disk (not with --update or individual --target-* partitions)."
fi

# --keep-efi keeps an ESP that already exists. A fresh unified --target has just
# been repartitioned, so its ESP is an empty partition with no filesystem on it
# at all -- keeping that means a target nothing can boot.
if [ $KEEP_EFI -eq 1 ] && [ $UNIFIED_TARGET -eq 1 ] && [ $UPDATE -eq 0 ]; then
    die "--keep-efi needs an ESP that already exists; a fresh --target disk is repartitioned here and its ESP must be formatted.
Name the partitions instead (--target-efi ... --target-root ...), or add --update to keep the disk's existing filesystems."
fi

# Does the target keep /boot on its own partition, or inside /?
if [ -n "$TGT_BOOT" ]; then TGT_SEP_BOOT=1; else TGT_SEP_BOOT=0; fi

# Per-role migrate (target differs from source) vs in-place (same device).
# Never feed the empty strings of an absent role to same_dev(): uutils' readlink
# resolves "" to the working directory, which would compare equal -- which is
# why MIGRATE_BOOT is only ever computed for a target that has a /boot at all.
if same_dev "$TGT_ROOT" "$SRC_ROOT"; then MIGRATE_ROOT=0; else MIGRATE_ROOT=1; fi

# The ESP is the one role that is never copied: its whole content -- GRUB's boot
# directory, the modules, the shared menu -- is produced here, by grub-install
# and write_esp_menu, on every run. So there is nothing to "migrate", only the
# question of whether its filesystem is created: FORMAT_EFI. A target ESP that
# is already the source's stays as it is, and --keep-efi says so explicitly for
# an ESP that several systems boot from -- reformatting that one would wipe the
# other systems' menu entries and give the ESP a UUID their fstabs do not name.
# (--update formats nothing at all, so it settles this the same way --keep-efi
# does -- and then the entries already on that ESP are worth probing, since the
# run is going to keep them.)
if same_dev "$TGT_EFI" "$SRC_EFI" || [ $KEEP_EFI -eq 1 ] || [ $UPDATE -eq 1 ]; then
    FORMAT_EFI=0
else
    FORMAT_EFI=1
fi

# MIGRATE_BOOT covers the /boot *partition* -- whether one must be formatted and
# given a fresh UUID -- so it is 0 whenever the target has no separate /boot.
MIGRATE_BOOT=0
if [ $TGT_SEP_BOOT -eq 1 ]; then
    if [ $SRC_SEP_BOOT -eq 0 ] || ! same_dev "$TGT_BOOT" "$SRC_BOOT"; then MIGRATE_BOOT=1; fi
fi

# BOOT_PASS: does the /boot content need a transfer of its own? Only when the
# source's /boot filesystem is not already the target's -- i.e. both sides keep
# /boot inside / (the root rsync carries it along), or both use the very same
# /boot partition. Everything else needs a pass: the two separate partitions
# differ, or the layout is being converted in one direction or the other.
BOOT_PASS=1
if [ $SRC_SEP_BOOT -eq 0 ] && [ $TGT_SEP_BOOT -eq 0 ]; then
    BOOT_PASS=0
elif [ $SRC_SEP_BOOT -eq 1 ] && [ $TGT_SEP_BOOT -eq 1 ] && same_dev "$TGT_BOOT" "$SRC_BOOT"; then
    BOOT_PASS=0
fi

# Bootloader install scope: BIOS only when a BIOS target is given. EFI always --
# the ESP carries GRUB's boot directory now, and this system's menu entry has to
# be registered there whatever else the run does, so there is no such thing as a
# migration that leaves the ESP untouched. (run_chroot_block always runs
# update-grub + update-initramfs as well.)
if [ -n "$TGT_BIOS" ]; then INSTALL_GRUB_BIOS=1; else INSTALL_GRUB_BIOS=0; fi
INSTALL_GRUB_EFI=1

if [ $FORMAT_EFI -eq 0 ] && [ $BOOT_PASS -eq 0 ] && [ $MIGRATE_ROOT -eq 0 ] && [ -z "$SWAP_DEV" ]; then
    die "Nothing to do: every role resolves in-place and no swap was given."
fi

# An ESP this run does not format is one it trusts: it must already hold a FAT
# filesystem, or Phase 3 fails on the mount with the target half-written. Not
# just under --update -- --keep-efi and an in-place ESP are the same bet.
if [ $FORMAT_EFI -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    fstype=$(sudo blkid -c /dev/null -o value -s TYPE "$TGT_EFI" 2>/dev/null || true)
    if [ -z "$fstype" ]; then
        die "EFI target $TGT_EFI has no recognizable filesystem (unformatted?); drop --keep-efi to create one."
    elif [ "$fstype" != vfat ]; then
        die "EFI target $TGT_EFI has filesystem '$fstype', expected 'vfat'."
    fi
fi

# Under --update the target filesystems must already exist and be the right
# type — we won't mkfs, so catch unformatted or wrong-type partitions now
# rather than failing with a cryptic mount error later.
if [ $UPDATE -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    for entry in "$TGT_BOOT:Boot:ext4:$MIGRATE_BOOT" \
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

# Safety: a partition we are about to format must not also be a source we read.
migrated_targets=()
if [ $FORMAT_EFI   -eq 1 ]; then migrated_targets+=("$TGT_EFI");  fi
if [ $MIGRATE_BOOT -eq 1 ]; then migrated_targets+=("$TGT_BOOT"); fi
if [ $MIGRATE_ROOT -eq 1 ]; then migrated_targets+=("$TGT_ROOT"); fi
if [ "$DO_MKSWAP"  -eq 1 ]; then migrated_targets+=("$SWAP_DEV"); fi
source_devs=("$SRC_EFI" "$SRC_ROOT")
if [ -n "$SRC_BOOT" ]; then source_devs+=("$SRC_BOOT"); fi
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

# Safety: refuse targets that are in use. Mounting an already-mounted
# filesystem a second time succeeds (it shares the superblock), so the sync
# would write into a filesystem in active use — e.g. one auto-mounted by a
# desktop session when the disk was plugged in. Every target role gets mounted
# RW (even in-place ones), so all of them must be unmounted first.
if [ $UNIFIED_TARGET -eq 1 ]; then
    busy_devs=("$TARGET")   # whole disk: lsblk reports every partition's use
else
    busy_devs=("$TGT_EFI" "$TGT_ROOT")
    if [ -n "$TGT_BOOT" ]; then busy_devs+=("$TGT_BOOT"); fi
    if [ "$DO_MKSWAP" -eq 1 ]; then busy_devs+=("$SWAP_DEV"); fi
fi
for t in "${busy_devs[@]}"; do
    # MOUNTPOINTS shows filesystem mounts and active swap ([SWAP]) alike.
    in_use=$(lsblk -no MOUNTPOINTS "$t" 2>/dev/null | grep -v '^$' | head -n 1 || true)
    [ -z "$in_use" ] || die "Target $t is in use ($in_use) -- unmount/swapoff it first."
done

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

# ---- GRUB menu brand ----
# Disk whose model brands the GRUB menu = where the rootfs (the OS) lives.
# --brand always wins. Under --update the brand already stamped into the
# target's /etc/default/grub is kept (probed now, so the summary can show it),
# so a brand chosen at install time survives every subsequent sync. Only
# otherwise is the model probed from the disk — which can be a card reader's
# name rather than the medium's, hence --brand. Resolved after the locks: the
# probe mounts the target root, which must not race a concurrent mkfs.
if [ $UNIFIED_TARGET -eq 1 ]; then
    BRAND_DISK="$TARGET"
else
    BRAND_DISK=$(get_parent_disk "$TGT_ROOT")
fi
TGT_MODEL=""
if [ -n "$BRAND" ]; then
    TGT_MODEL="$BRAND"
    BRAND_ORIGIN="--brand override"
elif [ $UPDATE -eq 1 ]; then
    # Often the run's first real media access (earlier blkid probes are usually
    # answered from the page cache), so a spun-down or slow target disk makes
    # this pause noticeably — say what we are waiting for.
    info "Reading current GRUB brand off $TGT_ROOT (may need to spin the disk up)..."
    probe_target_brand
    BRAND_ORIGIN="kept from target's GRUB_DISTRIBUTOR"
fi
if [ -z "$TGT_MODEL" ]; then
    TGT_MODEL=$(lsblk -n -d -o MODEL "${BRAND_DISK:-}" 2>/dev/null | xargs || true)
    [ -n "$TGT_MODEL" ] || TGT_MODEL="Portable Image"
    BRAND_ORIGIN="rootfs on ${BRAND_DISK:-?}"
fi

# ---- Summary + single confirmation gate (before anything destructive) ----
# Read the source's fstab first: a swap file listed there is re-created on the
# target, and the summary should say so rather than report "swap: none". Only
# when the root filesystem is actually transferred, though -- rebuild_swapfiles()
# runs with the root rsync, so an in-place root touches no swap file at all.
if [ $MIGRATE_ROOT -eq 1 ]; then probe_source_swapfiles; fi
# ...then the boot options for the menu entry, if that probe did not already
# have the source mounted, and the systems already registered on the ESP (which
# a run that formats it cannot keep, so there is nothing to read).
probe_menu_cmdline
if [ $FORMAT_EFI -eq 0 ]; then probe_esp_menu; fi
# The root filesystem the target partition holds *now*: the system this slot
# used to boot. It is this system when the filesystem is kept (--update or an
# in-place root) and a stranger when it is about to be reformatted -- in which
# case write_esp_menu() retires its menu entry along with it, rather than leave
# the menu advertising a UUID that no longer exists.
TGT_ROOT_UUID_NOW=$(sudo blkid -c /dev/null -s UUID -o value "$TGT_ROOT" 2>/dev/null || true)

echo
echo "About to install:"
if [ $SCATTERED_SOURCE -eq 1 ]; then
    summary_row "Source:" "scattered partitions (see the roles below)"
else
    summary_row "Source:" "$SOURCE${LOOP_DEV:+  (loop $LOOP_DEV)}"
fi
# The ESP is never a copy of the source's, so it gets a row of its own rather
# than a role_row: the only question is whether its filesystem survives the run.
if [ $FORMAT_EFI -eq 1 ]; then
    summary_row "EFI:" "FORMAT    $TGT_EFI  (fresh FAT32, then GRUB + the menu written onto it)"
else
    summary_row "EFI:" "KEEP      $TGT_EFI  (filesystem and UUID untouched; GRUB + the menu refreshed)"
fi
if [ $TGT_SEP_BOOT -eq 1 ]; then
    role_row "/boot:" "$MIGRATE_BOOT" "${SRC_BOOT:-inside / on $SRC_ROOT}" "$TGT_BOOT"
elif [ $SRC_SEP_BOOT -eq 1 ]; then
    summary_row "/boot:" "FLATTEN   $SRC_BOOT -> the root filesystem (no separate partition)"
else
    summary_row "/boot:" "in the root filesystem"
fi
role_row "/ (root):" "$MIGRATE_ROOT" "$SRC_ROOT" "$TGT_ROOT"

# swap: a partition (--source-swap/--target-swap) and any number of swap FILES
# inherited from the source's fstab are independent, so both can appear. Only
# the first row carries the label.
swap_shown=0
swap_label() {
    if [ "$swap_shown" -eq 0 ]; then swap_shown=1; printf '  %-10s' "swap:"
    else printf '  %-10s' ""; fi
}
if [ -n "$SWAP_DEV" ]; then
    swap_label
    if [ "$DO_MKSWAP" -eq 1 ]; then echo "reformat  $SWAP_DEV"; else echo "reuse     $SWAP_DEV"; fi
fi
for swap_entry in "${SWAP_PREVIEW[@]}"; do
    read -r swap_path swap_bytes swap_state <<<"$swap_entry"
    if [ "$swap_bytes" = "?" ]; then swap_size="size unknown"; else swap_size=$(human_size "$swap_bytes"); fi
    swap_label
    if [ "$swap_state" = drop ]; then
        echo "DROP      file $swap_path (excluded by $EXCLUDE_FROM; its fstab entry is disabled)"
    else
        echo "re-create file $swap_path ($swap_size, never copied)"
    fi
done
if [ "$swap_shown" -eq 0 ]; then
    if [ $MIGRATE_ROOT -eq 0 ]; then
        summary_row "swap:" "none (the root filesystem is in-place, so no swap file is touched)"
    elif [ "$SWAP_PROBED" -eq 1 ]; then
        summary_row "swap:" "none (the source's fstab lists no swap file)"
    else
        summary_row "swap:" "none given (the source's fstab could not be read here to check for a swap file)"
    fi
fi
echo "  Menu:     GRUB title branded \"$TGT_MODEL\" ($BRAND_ORIGIN)"
# The entry this run registers in the menu on the ESP, the systems already
# registered there that it will keep, and the command line it will boot with --
# the three things a shared-ESP disk must not be guessed about.
summary_row "" "entry \"GUI $TGT_MODEL\" / \"TTY $TGT_MODEL\" in the ESP menu"
summary_row "" "boots $(esp_cmdline_from "${MENU_CMDLINE_PREVIEW:-<options from /etc/default/grub, read at install time>}")"
esp_menu_kept=0
for esp_row in ${ESP_MENU_ENTRIES[@]+"${ESP_MENU_ENTRIES[@]}"}; do
    IFS="$(printf '\t')" read -r esp_uuid esp_title <<<"$esp_row"
    if [ "$esp_uuid" = "${TGT_ROOT_UUID_NOW:-}" ]; then
        # The entry of whatever this partition holds now: re-branded in place
        # when the filesystem is kept, retired with it when it is reformatted.
        if [ $MIGRATE_ROOT -eq 1 ] && [ $UPDATE -eq 0 ]; then
            summary_row "" "replaces \"$esp_title\" ($esp_uuid), the system this partition holds now"
            esp_menu_kept=1
        fi
        continue
    fi
    summary_row "" "keeps \"$esp_title\" ($esp_uuid), already registered there"
    esp_menu_kept=1
    if [ "$esp_title" = "GUI $TGT_MODEL" ] || [ "$esp_title" = "TTY $TGT_MODEL" ]; then
        echo "Warning: the ESP already lists \"$esp_title\" for a different root filesystem ($esp_uuid); pass --brand NAME to tell the two apart in the menu." >&2
    fi
done
if [ $FORMAT_EFI -eq 1 ] && [ $UNIFIED_TARGET -eq 0 ]; then
    summary_row "" "any entries already on that ESP go with its filesystem (--keep-efi keeps both)"
elif [ "$esp_menu_kept" -eq 0 ] && [ "$ESP_MENU_PROBED" -eq 0 ] && [ $FORMAT_EFI -eq 0 ]; then
    summary_row "" "(the ESP could not be read here, so entries already on it are not listed)"
fi
if [ $INSTALL_GRUB_BIOS -eq 1 ]; then
    echo "  Bootldr:  reinstall legacy BIOS -> $TGT_GRUB_DISK, and UEFI (removable)"
else
    echo "  Bootldr:  reinstall UEFI (removable) (no --target-bios-boot, so legacy BIOS is left intact)"
fi
echo "            GRUB boot directory + menu on the ESP (--boot-directory=/boot/efi/boot)"
echo "  Mounts:   target=$MNT  source=$SRC"
if [ $UNIFIED_TARGET -eq 1 ] && [ $UPDATE -eq 0 ]; then
    echo "  Layout:   ${ESP_MIB} MiB ESP, root to 100%${TGT_EFI_SIZE:+  (--target-efi-size)}"
fi
if [ -n "$INODES_ROOT" ] && [ $MIGRATE_ROOT -eq 1 ] && [ $UPDATE -eq 0 ]; then
    echo "  Inodes:   root mkfs -N $INODES_ROOT (--inodes-root override)"
fi
if [ $NO_TRIM -eq 1 ]; then
    echo "  Trim:     skipped (--no-trim)"
fi
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
    ESP_END=$(( 2 + ESP_MIB ))   # the ESP starts at 2 MiB, after the BIOS Boot
    run sudo parted -s "$TARGET" mkpart primary fat32 2MiB "${ESP_END}MiB"
    run sudo parted -s "$TARGET" set 2 esp on
    # No /boot partition: root and a /boot are formatted with the same ext4
    # feature set and GRUB reads both, so one would buy nothing on a disk that
    # boots its own root. A target that needs a separate /boot -- because the
    # BIOS cannot reach the disk holding / at all -- names existing partitions
    # (--target-boot) instead of having this layout imposed on it.
    run sudo parted -s "$TARGET" mkpart primary ext4 "${ESP_END}MiB" 100%
    # Wait for OUR partition nodes rather than the global udev queue, which a
    # concurrent instance can keep busy past the settle timeout.
    run sudo udevadm wait --timeout=30 "$TGT_BIOS" "$TGT_EFI" "$TGT_ROOT"
fi

# ---- Format the migrated roles ----
# Skipped entirely under --update, which keeps each target filesystem intact and
# only rsyncs --delete onto it. (--target-swap reformatting is independent: it is
# an explicit opt-in and still honoured below.)
if [ $UPDATE -eq 0 ]; then
    if [ $FORMAT_EFI -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_EFI"
        run sudo mkfs.fat -F32 -n EFI "$TGT_EFI"
    fi
    if [ $MIGRATE_BOOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_BOOT"
        # A /boot holds a few dozen large files, so its inode table wants to be
        # dense (-i 32768) where the rootfs wants the opposite. sparse_super2 for
        # the same reason the rootfs has it: GRUB's own drivers must read this.
        run sudo mkfs.ext4 -vF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$TGT_BOOT"
    fi
    if [ $MIGRATE_ROOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_ROOT"

        if [ -n "$INODES_ROOT" ]; then
            # Pinned by the caller: no probing, and no minimum imposed either --
            # an explicit count is taken at face value.
            TARGET_INODES="$INODES_ROOT"
            info "Root inode count pinned by --inodes-root: $TARGET_INODES"
        else
            TGT_BYTES=$(lsblk -dbno SIZE "$TGT_ROOT" 2>/dev/null) || TGT_BYTES=""
            if [ -z "$TGT_BYTES" ]; then
                # Only dry-run may proceed without a size (the partition node may
                # not exist yet); a real run must not fabricate the inode count.
                [ "$DRY_RUN" -eq 1 ] || die "Cannot determine size of $TGT_ROOT"
                TGT_BYTES=$((16 * 1024**3))
            fi
            ROOT_BYTES_PER_INODE=$(( 1024**4 / (4 * 1024**2) ))
            CALC_INODES=$(( TGT_BYTES / ROOT_BYTES_PER_INODE ))
            MIN_INODES=$(( 1024**2 )) # 1M inodes minimum
            TARGET_INODES=$(( CALC_INODES < MIN_INODES ? MIN_INODES : CALC_INODES ))
        fi

        run sudo mkfs.ext4 -vF -m 0 -L root -N "$TARGET_INODES" -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$TGT_ROOT"
    fi
fi
if [ "$DO_MKSWAP" -eq 1 ]; then
    run sudo wipefs -q -a "$SWAP_DEV"
    run sudo mkswap -q "$SWAP_DEV"
fi

# ---- New UUIDs: fresh for migrated roles, unchanged for in-place ----
# NEW_UUID_BOOT is "the UUID of the filesystem that holds /boot", so without a
# separate /boot partition it is the root UUID -- which is exactly what the menu
# entry on the ESP must search for to find the kernel, and what update-grub puts
# in the search line of the rootfs menu it regenerates.
if [ "$DRY_RUN" -eq 0 ]; then
    NEW_UUID_EFI=$(blkid_uuid "$TGT_EFI")
    if [ $MIGRATE_ROOT -eq 1 ]; then NEW_UUID_ROOT=$(blkid_uuid "$TGT_ROOT"); else NEW_UUID_ROOT="$OLD_UUID_ROOT"; fi
    if [ $TGT_SEP_BOOT -eq 0 ];  then NEW_UUID_BOOT="$NEW_UUID_ROOT"
    elif [ $MIGRATE_BOOT -eq 1 ]; then NEW_UUID_BOOT=$(blkid_uuid "$TGT_BOOT")
    else                              NEW_UUID_BOOT="$OLD_UUID_BOOT"; fi
    if [ -n "$SWAP_DEV" ]; then NEW_UUID_SWAP=$(blkid_uuid "$SWAP_DEV"); fi
else
    if [ $FORMAT_EFI   -eq 1 ]; then NEW_UUID_EFI="dry-run-new-efi";   else NEW_UUID_EFI="$OLD_UUID_EFI";   fi
    if [ $MIGRATE_ROOT -eq 1 ]; then NEW_UUID_ROOT="dry-run-new-root"; else NEW_UUID_ROOT="$OLD_UUID_ROOT"; fi
    if [ $TGT_SEP_BOOT -eq 0 ];  then NEW_UUID_BOOT="$NEW_UUID_ROOT"
    elif [ $MIGRATE_BOOT -eq 1 ]; then NEW_UUID_BOOT="dry-run-new-boot"
    else                              NEW_UUID_BOOT="$OLD_UUID_BOOT"; fi
    if [ -n "$SWAP_DEV" ]; then NEW_UUID_SWAP="dry-run-new-swap"; fi
fi

echo "=========================================="
echo " Phase 3: Mounting & Data Synchronization "
echo "=========================================="
if [ "$DRY_RUN" -eq 0 ]; then
    # Refuse to stack over an existing mount — a leftover tree from a crashed
    # run (or a busy --mnt/--src dir) must be cleaned up, not silently shadowed.
    if findmnt -n "$MNT" >/dev/null 2>&1; then die "$MNT is already a mountpoint."; fi
    if findmnt -n "$SRC" >/dev/null 2>&1; then die "$SRC is already a mountpoint."; fi
fi

# Every command below goes through run(), so a dry run prints the exact mount
# and rsync command lines rather than a summary of them: the rsync option set is
# the thing worth reviewing before committing to a multi-hour transfer.

# Mount the target tree (the partitions the installed system will use).
run sudo mkdir -p "$MNT"
# Only a real run has trees to tear down; a dry run mounts nothing, so cleanup()
# must not go unmounting $MNT/$SRC afterwards.
if [ "$DRY_RUN" -eq 0 ]; then MOUNTS_DONE=1; fi
run sudo mount "$TGT_ROOT" "$MNT"
# Without a separate /boot partition, $MNT/boot is simply a directory on the
# root filesystem -- but $MNT/boot/efi has to be created on whichever of the two
# filesystems ends up carrying it, so the /boot mount goes between the mkdirs.
run sudo mkdir -p "$MNT/boot"
if [ $TGT_SEP_BOOT -eq 1 ]; then
    run sudo mount "$TGT_BOOT" "$MNT/boot"
fi
run sudo mkdir -p "$MNT/boot/efi"
run sudo mount "$TGT_EFI" "$MNT/boot/efi"

run sudo mkdir -p "$SRC"
# Source root is the rsync base; -x keeps each rsync on its own filesystem so
# an in-place /boot or /boot/efi is never copied onto itself.
run sudo mount -r -o noatime "$SRC_ROOT" "$SRC" || \
    die "Cannot mount source root $SRC_ROOT read-only. A dirty (uncleanly unmounted) image cannot replay its journal on a read-only loop -- run e2fsck on it once and retry."

# Cross-check the source's real layout against --source-boot before anything is
# copied. Its own fstab is the authority, whatever the partition tables look
# like, and getting this wrong in either direction transfers nothing useful: an
# unnamed separate /boot means the root rsync copies an empty mount point and the
# target ends up with no kernel, while a --source-boot the source does not
# actually use would be mounted over the real /boot and ship an empty one. The
# fstab lives on the root filesystem, so this runs before $SRC_BOOT is mounted --
# and only a real run has a mounted source to read it from.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] the source is not mounted, so its fstab cannot be read here: a real run also checks that it does (or does not) mount /boot, matching --source-boot"
elif fstab_mounts_boot "$SRC/etc/fstab"; then
    [ $SRC_SEP_BOOT -eq 1 ] || \
        die "Source $SRC_ROOT keeps /boot on a separate filesystem (its fstab has a /boot entry).
Name that partition with --source-boot PART, so its contents are transferred,
or fold /boot into the source's root filesystem and drop the fstab entry."
elif [ $SRC_SEP_BOOT -eq 1 ]; then
    die "--source-boot $SRC_BOOT was given, but the source's fstab has no /boot entry:
$SRC_ROOT keeps /boot inside its own root filesystem. Mounting $SRC_BOOT over it
would hide the real /boot and copy an empty one. Drop --source-boot."
fi

# The layout is agreed, so complete the source tree: without this, /boot under
# $SRC is the bare mount point directory of the source root. Only the /boot pass
# needs it now -- the ESP is generated on the target, never read from the source.
if [ $SRC_SEP_BOOT -eq 1 ] && [ $BOOT_PASS -eq 1 ]; then
    if [ $BOOT_PASS -eq 0 ]; then
        # In-place /boot: this very filesystem is already mounted read-write
        # at $MNT/boot, so a second, read-only mount of it is at best redundant
        # and at worst refused outright (one superblock cannot be both). Bind
        # the mount we already have -- the same filesystem by definition, and
        # all that is wanted from it here is the /boot/efi mount point.
        run sudo mount --bind "$MNT/boot" "$SRC/boot"
    else
        run sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot" || \
            die "Cannot mount source /boot $SRC_BOOT read-only (dirty journal? run e2fsck on it once and retry)."
    fi
fi

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
#     --update run repairs it.
#   --verbose (show the files as they are rsync'ed)
#   -S is deliberately NOT here; see --sparse, which adds it back. Every hole
#     rsync punches is one more entry in the file's ext4 extent tree, and a
#     large VM image is perforated by thousands of tiny ones: measured on a
#     51.8 GiB .vdi, 12,309 holes (82% of them <= 64 KiB) bought back 1.01 GiB
#     -- 2% of the file -- for ~11,900 extra extents, which pushed the tree from
#     one level to two and made every fsck.ext4 -f offer to optimize it. Writing
#     the nulls out costs a couple of percent more I/O and reads back faster.
#     (Combining -S with --inplace needs rsync >= 3.1.3.)
RSYNC_OPTS=(-ahHAX --inplace --numeric-ids -x --verbose)
if [ $SPARSE -eq 1 ]; then RSYNC_OPTS+=(-S); fi
if [ $UPDATE -eq 1 ]; then
    RSYNC_OPTS+=(--delete)
    if [ -n "$EXCLUDE_FROM" ]; then RSYNC_OPTS+=(--delete-excluded); fi
fi
if [ -n "$EXCLUDE_FROM" ]; then RSYNC_OPTS+=(--exclude-from="$EXCLUDE_FROM"); fi

# Keep the root transfer off /boot whenever /boot is a filesystem of its own on
# either side -- whether it gets a pass below (BOOT_PASS) or is left alone
# in place (TGT_SEP_BOOT with the same partition on both sides). Two rules, not
# one: "- /boot/" hides it from the sender, and the explicit receiver-side
# "P /boot/" is what stops --delete from emptying the target's /boot. A plain
# exclude would not do -- --delete-excluded (added when --update and
# --exclude-from are combined) demotes unqualified rules to sender-side only.
# With /boot inside / on both sides there is nothing to keep out: it is an
# ordinary directory that rides along with the root transfer.
BOOT_FILTERS=()
if [ $TGT_SEP_BOOT -eq 1 ] || [ $BOOT_PASS -eq 1 ]; then
    BOOT_FILTERS=(--filter='- /boot/' --filter='P /boot/')
fi

if [ $MIGRATE_ROOT -eq 1 ]; then
    # Swap files are never transferred (gigabytes of zeros, and under --sparse
    # rsync would punch them full of holes); they are re-created afterwards.
    # A dry run has not mounted the source, so its fstab -- and with it the
    # swap file paths -- cannot be read: say so, since their --exclude=
    # arguments are then the one part missing from the command printed below.
    if [ "$DRY_RUN" -eq 0 ]; then
        scan_swapfiles
    else
        echo "[dry-run] ...and the command below therefore omits one --exclude= per swap file listed there (each is re-created afterwards with fallocate + mkswap${EXCLUDE_FROM:+, or dropped if $EXCLUDE_FROM excludes it})"
    fi
    echo "Rsyncing root filesystem..."
    # $MNT/boot/efi is the target's mounted ESP, which the EFI pass below owns:
    # -x keeps the sender out of it and, just as importantly, stops --delete
    # recursing into it on the receiving side. BOOT_FILTERS does the same for
    # /boot when that is a filesystem of its own rather than a directory here.
    run sudo rsync "${RSYNC_OPTS[@]}" "${BOOT_FILTERS[@]}" \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/mnt/*","/lost+found"} \
        "${SWAP_EXCLUDES[@]}" \
        "$SRC/" "$MNT/"
    # Reads the sizes/labels of files under $SRC, so likewise real runs only.
    if [ "$DRY_RUN" -eq 0 ]; then rebuild_swapfiles; fi
fi
if [ $BOOT_PASS -eq 1 ]; then
    # The source side is a mount of its own /boot partition (made above), or --
    # when the source keeps /boot inside / -- already a directory under $SRC.
    echo "Rsyncing /boot..."
    # /boot/efi is the target's mounted ESP, which the EFI pass below owns: keep
    # this transfer out of it, and out of --delete's reach, since $MNT/boot may
    # be an ordinary directory rather than a mount point that -x would shield.
    run sudo rsync "${RSYNC_OPTS[@]}" --filter='- /efi/' --filter='P /efi/' \
        "$SRC/boot/" "$MNT/boot/"
fi
# No EFI pass: the ESP is not copied. Everything on it -- GRUB's boot directory,
# the modules, the shared menu -- is written by Phase 5 (grub-install) and
# write_esp_menu, from this system's own GRUB. Copying the source's ESP instead
# would drag over its master menu, whose entries name the source disk's root
# filesystems, and on a shared ESP would bury the entries of the other systems
# that boot from it.

echo "=========================================="
echo " Phase 4: Filesystem Translation (UUIDs)  "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would rewrite fstab + GRUB root UUID and (re)brand the GRUB menu as \"$TGT_MODEL\""
    echo "[dry-run] cannot list the fstab entries it would disable: that needs the target's own fstab, which is only readable once mounted"
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
    echo "[dry-run] would chroot: grub-install --boot-directory=/boot/efi/boot (bios=$INSTALL_GRUB_BIOS efi=$INSTALL_GRUB_EFI), update-grub + update-initramfs"
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
# Register this system in the menu on the ESP -- after the chroot, which is what
# puts GRUB's boot directory there. Prints what it would write in a dry run.
write_esp_menu

echo "=========================================="
echo " Phase 6: Post-install Verification       "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would verify the UUID translation in fstab/grub.cfg, and the ESP menu (this system registered, the others kept)"
else
    verify_install || die "Verification failed -- the target may not boot; inspect it before relying on it."
fi

echo "=========================================="
echo " Phase 7: Teardown & Cleanup              "
echo "=========================================="
# Discard unused blocks on the filesystems we wrote: keeps flash media fast and
# lets a loop-attached .img target shrink, since the loop driver turns discards
# into FALLOC_FL_PUNCH_HOLE on the backing file (which is why a fallocate'd image
# only becomes sparse if this runs). Skipped when the medium cannot discard
# (spinning disks), so a dry run only shows trims that would actually happen; a
# failure on discard-capable media is reported but never aborts the teardown.
# --no-trim suppresses it outright, for a medium where the trim is slow, pointless
# or unwanted (e.g. a target whose free space should stay written).
#
# The ext4 roles are trimmed only under --update. Without it they were just
# mkfs.ext4'd, and mke2fs discards the whole partition at format time (its
# "discard" extended option is the default); the rsync that follows only ever
# allocates blocks, so no block transitions back to free and the closing fstrim
# would merely re-discard ranges the mkfs already discarded. Under --update the
# existing filesystem is kept and rsync --delete really does free blocks, so the
# trim is the only thing that reclaims them. The ESP is the exception in the
# other direction: mkfs.fat has no discard of its own, so a freshly formatted
# 256 MiB ESP holding a few MiB of bootloader is only ever released here -- which
# on a loop-backed .img is the difference between a sparse and a solid ESP.
if [ $NO_TRIM -eq 1 ]; then
    echo "Skipping fstrim on the written filesystems (--no-trim)."
else
    # The ESP is trimmed on every run, not just a formatting one: mkfs.fat has no
    # discard of its own, and a kept ESP has just had its menu and modules
    # rewritten, so blocks come free either way.
    if supports_discard "$TGT_EFI"; then run sudo fstrim -v "$MNT/boot/efi" || true; fi
    if [ $UPDATE -eq 1 ]; then
        if [ $MIGRATE_ROOT -eq 1 ] && supports_discard "$TGT_ROOT"; then run sudo fstrim -v "$MNT" || true; fi
        if [ $MIGRATE_BOOT -eq 1 ] && supports_discard "$TGT_BOOT"; then run sudo fstrim -v "$MNT/boot" || true; fi
    elif [ $MIGRATE_ROOT -eq 1 ] && [ $MIGRATE_BOOT -eq 1 ]; then
        echo "Skipping fstrim on the freshly formatted root and /boot filesystems (mkfs.ext4 already discarded them)."
    elif [ $MIGRATE_ROOT -eq 1 ]; then
        echo "Skipping fstrim on the freshly formatted root filesystem (mkfs.ext4 already discarded it)."
    elif [ $MIGRATE_BOOT -eq 1 ]; then
        echo "Skipping fstrim on the freshly formatted /boot filesystem (mkfs.ext4 already discarded it)."
    fi
fi
if [ "$DRY_RUN" -eq 0 ]; then
    echo "[Teardown] Unmounting filesystems and releasing locks..."
fi
cleanup   # also runs from the EXIT trap on any earlier failure

# GRUB reads two filesystems at boot: the ESP, for the menu and the modules
# under its boot directory, and then whichever filesystem holds /boot, for the
# kernel the menu points at -- the root filesystem on a disk that keeps /boot
# inside / (which is why the rootfs is formatted with nothing GRUB cannot
# parse), or the /boot partition on one that has its own. Ask GRUB's own drivers,
# now that both are unmounted and consistent -- advisory, since a failure here
# means the disk will not boot but nothing on it is wrong to fix.
if [ "$DRY_RUN" -eq 0 ] && command -v grub-fstest >/dev/null 2>&1; then
    if sudo grub-fstest "$TGT_EFI" ls /boot/grub/grub.cfg >/dev/null 2>&1; then
        echo "  [PASS] GRUB can read its menu at /boot/grub/grub.cfg on the ESP $TGT_EFI."
    else
        echo "Warning: GRUB's own FAT driver cannot read /boot/grub/grub.cfg on the ESP $TGT_EFI -- this disk is unlikely to boot." >&2
    fi
    if [ $TGT_SEP_BOOT -eq 1 ]; then
        BOOT_FS="$TGT_BOOT"; BOOT_KERNEL="/vmlinuz"
    else
        BOOT_FS="$TGT_ROOT"; BOOT_KERNEL="/boot/vmlinuz"
    fi
    # The path the menu entry actually loads, symlink and all -- the thing the
    # ext2 driver has to resolve. Fall back to the directory it lives in, so a
    # driver that will not follow the symlink is not reported as a broken disk.
    if sudo grub-fstest "$BOOT_FS" ls "$BOOT_KERNEL" >/dev/null 2>&1; then
        echo "  [PASS] GRUB can read the kernel at $BOOT_KERNEL on $BOOT_FS."
    elif sudo grub-fstest "$BOOT_FS" ls "${BOOT_KERNEL%/*}/" >/dev/null 2>&1; then
        echo "  [PASS] GRUB can read ${BOOT_KERNEL%/*}/ on $BOOT_FS (it would not resolve the $BOOT_KERNEL symlink here)."
    else
        echo "Warning: GRUB's own ext2 driver cannot read $BOOT_KERNEL on $BOOT_FS -- this disk is unlikely to boot." >&2
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
    if [ $BOOT_PASS    -eq 1 ]; then roles="$roles /boot"; fi
    if [ $FORMAT_EFI   -eq 1 ]; then roles="$roles EFI"; fi
    if [ -n "$SWAP_DEV" ]; then roles="$roles swap"; fi
    verb="Migrated"; [ $UPDATE -eq 1 ] && verb="Synced"
    if [ $INSTALL_GRUB_BIOS -eq 1 ] || [ $INSTALL_GRUB_EFI -eq 1 ]; then
        echo "Done. $verb:${roles:- (none)}. Bootloader reinstalled (bios=$INSTALL_GRUB_BIOS efi=$INSTALL_GRUB_EFI)."
    else
        echo "Done. $verb:${roles:- (none)}. Existing bootloader kept; GRUB menu + initramfs regenerated."
    fi
fi
