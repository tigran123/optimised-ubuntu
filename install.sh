#!/bin/bash
# install.sh — flash a portable OS image or scattered partitions onto a target.
# Source and target are each either unified (a device or an .img) or scattered
# (--source-*/--target-* partitions); the four combinations all work.
#
# Per-role rule: each --target-X defaults to its --source-X, so a role whose
# target equals its source is left in place and one that differs is migrated
# (mkfs + copy) -- or, under --update, synced (no mkfs, rsync --delete).
# A separate /boot is explicit on both sides, never inferred from a partition
# table. See --help for the options and CLAUDE.md for the reasoning.
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

# Wait for udev to publish a disk's partition nodes. Polls this one disk rather
# than udevadm settle, whose global queue a concurrent instance can stall.
# Best-effort: on timeout the caller's own validation gives the precise error.
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
# Instances may run concurrently (flashing several disks from one source): every
# disk written gets an exclusive flock, every disk only read a shared one. Keys
# are canonical parent disks, so a partition-level and a whole-disk run collide.
# Lock files in /run/lock are never unlinked (unlink+flock is a classic race);
# the fds stay open for the life of the process, so locks release on any exit.
declare -A LOCK_MODE=()
# The fd each key is held on, so acquire_locks() can run again once a later
# decision adds a key (a filesystem an fstab entry is remapped onto). Re-flocking
# a held key would block on ourselves: another fd is another lock holder.
declare -A LOCK_FD=()

# add_lock <device-or-file> <sh|ex> — register a lock key; ex wins over sh.
add_lock() {
    local key parent
    # An absent role arrives as "", which uutils readlink -f resolves to the
    # working directory (exit 0) -- it would lock the cwd. Check it here.
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
        [ -z "${LOCK_FD[$key]:-}" ] || continue    # already held by this run
        file="/run/lock/portable-install-$(printf '%s' "$key" | tr '/ ' '__').lock"
        if ! exec {fd}>>"$file"; then
            die "Cannot open lock file $file (stale file owned by another user?)"
        fi
        if [ "${LOCK_MODE[$key]}" = "ex" ]; then flag=-x; else flag=-s; fi
        flock -n "$flag" "$fd" || \
            die "Another install.sh instance is using $key (lock: $file)"
        LOCK_FD[$key]=$fd
    done
}

# validate_partition_type <part> <gpt-type> <label> — check one named partition
#   and die if it is not what the caller asked for. Every call site wants that,
#   and an unexpected layout must fail here rather than at mount time.
validate_partition_type() {
    local part=$1 exp_type=$2 label=$3 ptype
    [ -b "$part" ] || die "$label partition ($part) is not a valid block device."
    ptype=$(lsblk -n -d -o PARTTYPE "$part" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [ "$ptype" = "$exp_type" ] || \
        die "$label partition ($part) has type ${ptype:-none}, expected $exp_type."
    echo "  [PASS] $label partition ($part) validated."
}

# validate_target_roles — the target partitions this run was given: ESP and root
#   always, BIOS Boot and /boot when named.
validate_target_roles() {
    [ -z "$TGT_BIOS" ] || validate_partition_type "$TGT_BIOS" "$GUID_BIOS" "Target BIOS"
    validate_partition_type "$TGT_EFI" "$GUID_EFI" "Target EFI"
    [ -z "$TGT_BOOT" ] || validate_partition_type "$TGT_BOOT" "$GUID_LINUX" "Target Boot"
    validate_partition_type "$TGT_ROOT" "$GUID_LINUX" "Target Root"
}

# scan_disk_roles <disk> <VAR_PREFIX> — fill <PREFIX>_BIOS/_EFI/_ROOT from a
#   whole disk by GPT type and filesystem label, never by partition number.
#   Used for a unified source and for a unified --target under --update, whose
#   existing layout must be discovered rather than imposed.
#   Root is the Linux partition labelled "root" (what this toolkit's mkfs
#   writes) or, failing that, a *lone* unlabelled one. Everything else on the
#   disk is ignored -- data, swap, another distro, a separate /boot (a named
#   role, never a discovered one). **Ambiguity dies rather than guesses**: two
#   unlabelled candidates, or two labelled "root" (the slot-per-machine disk),
#   are both fatal, as is a missing ESP or root -- an unexpected layout must
#   fail here, not at mount time.
scan_disk_roles() {
    local disk=$1 pfx=$2
    local dev ptype fstype label
    local -a linux_parts=() root_parts=()
    local bios="" efi="" root=""

    # One lsblk for the whole disk. Default IFS on purpose: lsblk pads with
    # spaces, never tabs. An empty PARTTYPE shifts the later fields left, but
    # only on the whole-disk row (skipped) and on dm/LVM/crypt children, whose
    # FSTYPE can never look like a GUID -- both fall through the case anyway.
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
                    # A separate /boot is named by --source-boot/--target-boot,
                    # never discovered: skip it so it neither passes for a root
                    # filesystem nor makes the disk look ambiguous.
                    boot) ;;
                    *)    linux_parts+=("$dev") ;;
                esac ;;
        esac
    done < <(lsblk -lnpo NAME,PARTTYPE,FSTYPE,LABEL "$disk")

    # One "root" label settles it; only an unlabelled disk falls back to "there
    # is exactly one candidate". More than one of either is fatal, never a coin
    # toss -- picking wrong here reformats the wrong partition, and two labelled
    # "root" is the live layout of a slot-per-machine disk.
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

# scan_image_roles_dryrun <image> — role partition NUMBERS for a .img in a dry
#   run, where no loop device is attached: parted reads the table out of the
#   file itself. Prints "<efi>:<root>", or nothing if it cannot be read.
#   Filesystem labels are invisible without a loop (parted's name field is the
#   GPT name, "primary" here), so root is the FIRST Linux partition -- the
#   layout this toolkit produces. A real run resolves it by label and may
#   disagree, so more than one candidate warns rather than guesses silently.
#   This only feeds the dry run's printed summary.
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
# A swap FILE is never copied: it is a multi-gigabyte run of zeros that
# fallocate re-creates from metadata alone, and under --sparse rsync's -S would
# punch it full of holes, which swapon then refuses ("skipping - it appears to
# have holes"). It is excluded from the rsync and re-created on the target.

# swapfile_entries <fstab> — print the swap FILE paths listed in an fstab, one
#   per line. Only plain paths qualify: swap partitions (/dev/..., UUID=,
#   LABEL=, PARTUUID=...) and zram devices are somebody else's problem.
swapfile_entries() {
    awk '$1 ~ /^#/ { next }
         $3 == "swap" && $1 ~ /^\// && $1 !~ /^\/dev\// {
             # An fstab octal escape (\040 etc.) would have to be decoded to
             # be usable: too rare to be worth it, so say so and skip.
             if ($1 ~ /\\/) {
                 print "Warning: swap file " $1 " has an escaped path -- not rebuilt." > "/dev/stderr";
                 next;
             }
             print $1;
         }' "$1"
}

# swapfile_excluded <path> — true when --exclude-from removes this path from the
#   transfer. Asked of rsync itself (a one-file dry run) so wildcards, "+" lines
#   and rule order behave exactly as in the real transfer. The destination is
#   deliberately NON-existent: against the real target rsync's quick check would
#   skip an unchanged file and the empty output would read as "excluded".
#   Limit: a rule excluding a whole parent directory is not detected, --relative
#   always sending implied dirs. That needs an exclude file that guts /var.
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

# probe_source_swapfiles — the swap FILES this run re-creates or drops, read
#   BEFORE the confirmation gate through a transient read-only mount of SRC_ROOT
#   (the same trick probe_target_brand() uses), so the summary cannot say
#   "swap: none" about a disk about to receive a multi-gigabyte swap file.
#   Fills SWAP_PREVIEW ("<fstab path> <bytes|?> keep|drop|offroot <transfer
#   path|carrier>" per file) and SWAP_PROBED; scan_swapfiles() is the
#   authoritative pass later. Best-effort: SWAP_PROBED stays 0 when the source
#   cannot be mounted -- a dry run against an image, which has no loop device.
probe_source_swapfiles() {
    SWAP_PREVIEW=(); SWAP_PROBED=0
    local sf real size state
    [ -b "$SRC_ROOT" ] || return 0
    MOUNTS_DONE=1   # from here on cleanup() must sweep $SRC, interrupts included
    sudo mount -r -o noatime "$SRC_ROOT" "$SRC" 2>/dev/null || return 0
    SWAP_PROBED=1
    # The caches, the --exclude-from audit and -- the reason this comes first --
    # FSTAB_TABLE, which the swap loop below needs to tell /var/swap (in the
    # transfer) from /data/swap (on a partition of its own, and not).
    probe_source_layout
    if [ -f "$SRC/etc/fstab" ]; then
        while read -r sf; do
            [ -n "$sf" ] || continue
            if ! real=$(fstab_realpath "$sf"); then
                SWAP_PREVIEW+=("$sf ? offroot $real")
                continue
            fi
            size=$(sudo stat -c %s "$SRC$real" 2>/dev/null) || size=""
            if swapfile_excluded "$real"; then state=drop; else state=keep; fi
            SWAP_PREVIEW+=("$sf ${size:-?} $state $real")
        done < <(swapfile_entries "$SRC/etc/fstab")
    fi
    # The mount is already here, and this source's /etc/default/grub is what
    # feeds the menu entry: read the boot options now (probe_menu_cmdline only
    # mounts anything if this did not).
    MENU_CMDLINE_PREVIEW=$(grub_cmdline_options "$SRC")
    probe_memtest "$SRC"
    sudo umount "$SRC" || true
}

# scan_swapfiles — split the source's swap files into the ones to rebuild
#   (SWAPFILES) and the ones --exclude-from removes (SWAPFILES_DROPPED: neither
#   copied nor re-created, and their fstab entries are commented out -- an
#   exclude file builds a deliberately swapless disk). SWAP_EXCLUDES keeps every
#   one out of the rsync; SWAPFILE_REAL records where each is in the transfer,
#   which is the fstab path unless a bind moved it. SWAPFILES* keep the *fstab*
#   paths, which is what rewrite_fstab() and the checks match on.
#   Reads caller globals (SRC, MNT, EXCLUDE_FROM).
scan_swapfiles() {
    local sf real
    local -a found=()
    SWAPFILES=(); SWAPFILES_DROPPED=(); SWAP_EXCLUDES=(); SWAPFILE_TGT_SIZE=()
    SWAPFILE_REAL=()
    [ -f "$SRC/etc/fstab" ] || return 0
    FSTAB_TABLE=$(fstab_mount_table "$SRC/etc/fstab")
    mapfile -t found < <(swapfile_entries "$SRC/etc/fstab")
    for sf in "${found[@]}"; do
        # Only the ROOT filesystem is mounted at $SRC, so /data/swap (with /data
        # a partition) is not under it: rsync never sees it, and re-creating it
        # would fallocate gigabytes into the root filesystem under a directory
        # the target mounts /data over at boot -- invisible and never reclaimed.
        # The same walk finds the transfer path of one a bind moved.
        if ! real=$(fstab_realpath "$sf"); then
            if remap_creates_swapfile "$sf"; then
                info "Swap file $sf is on $real, a filesystem of its own -- not in the transfer, but $real was resolved at the gate, so it is created directly on the filesystem chosen for it."
            else
                info "Swap file $sf is on $real, a filesystem of its own -- not in the transfer, left alone."
            fi
            continue
        fi
        SWAPFILE_REAL[$sf]=$real
        SWAP_EXCLUDES+=("--exclude=$real")
        if swapfile_excluded "$real"; then
            info "Swap file $sf is excluded by $EXCLUDE_FROM -- dropped (its fstab entry will be disabled)."
            SWAPFILES_DROPPED+=("$sf")
        else
            info "Swap file $sf will be re-created on the target (not copied)."
            SWAPFILES+=("$sf")
            # Remember the size of the copy already on the target: it is the
            # fallback when the source has no swap file, and --delete-excluded
            # (--update plus --exclude-from) removes it during the transfer.
            if sudo test -f "$MNT$real"; then
                SWAPFILE_TGT_SIZE[$sf]=$(sudo stat -c %s "$MNT$real")
            fi
        fi
    done
}

# rebuild_swapfiles — re-create every kept swap file on the freshly synced
#   target: the source's size, 0600 root:root, plain mkswap (see below).
#   Reads SRC/MNT/SWAPFILES; records SWAPFILES_REBUILT for verify_install().
rebuild_swapfiles() {
    local sf real src_file tgt_file size
    [ ${#SWAPFILES[@]} -gt 0 ] || return 0
    for sf in "${SWAPFILES[@]}"; do
        # Where the file is in the transfer, which is not always where fstab
        # mounts it; scan_swapfiles() already dropped the ones that are not in
        # the transfer at all, by reading the fstab rather than stat'ing.
        real=${SWAPFILE_REAL[$sf]:-$sf}
        src_file="$SRC$real"
        tgt_file="$MNT$real"

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

        # Plain mkswap: the source area's label and UUID are deliberately NOT
        # carried over. A swap FILE is named by its path -- what its fstab entry
        # uses, and what survives the file being remade by hand -- so a label or
        # UUID on one names nothing anybody looks up. Hibernation would want an
        # identity outliving the file; that belongs to a swap PARTITION.
        info "Re-creating swap file $sf ($size bytes)..."
        run sudo rm -f "$tgt_file"
        run sudo fallocate -l "$size" "$tgt_file"
        run sudo chown root:root "$tgt_file"
        run sudo chmod 600 "$tgt_file"
        run sudo mkswap -q "$tgt_file"
        SWAPFILES_REBUILT+=("$sf")
    done
}

# remap_creates_swapfile <fstab path> — true when this run puts that swap file on
#   the filesystem a resolved mount points at (so it is not simply "left alone").
remap_creates_swapfile() {
    local row path
    for row in ${REMAP_SWAP_CREATE[@]+"${REMAP_SWAP_CREATE[@]}"}; do
        IFS=$'\t' read -r path _ <<<"$row"
        [ "$path" = "$1" ] && return 0
    done
    return 1
}

# create_remap_swapfiles — the swap files belonging on a filesystem this run
#   resolved a mount onto, and missing from it. Same recipe as
#   rebuild_swapfiles(), on a filesystem outside the transfer: its fstab entry
#   survives Phase 4 because the carrier does, and a live entry naming a file
#   that is not there boots into a failing swapon -a. Sizes come from
#   probe_remap_choice() and are never invented -- one it could not read is not
#   in this list at all.
create_remap_swapfiles() {
    local row path dev rel size root
    [ ${#REMAP_SWAP_CREATE[@]} -gt 0 ] || return 0
    for row in "${REMAP_SWAP_CREATE[@]}"; do
        IFS=$'\t' read -r path dev rel size <<<"$row"
        if ! remap_open "$dev" rw; then
            echo "Warning: $dev could not be mounted read-write here, so swap file $path was not created; swapon -a will fail on the target." >&2
            continue
        fi
        root=$REMAP_OPEN_PATH
        info "Creating swap file $path on $dev ($size bytes)..."
        run sudo rm -f "$root$rel"
        run sudo fallocate -l "$size" "$root$rel"
        run sudo chown root:root "$root$rel"
        run sudo chmod 600 "$root$rel"
        run sudo mkswap -q "$root$rel"
        if [ "$DRY_RUN" -eq 0 ] && ! swapfile_ok "$root$rel"; then
            echo "Warning: the swap file just created at $path on $dev is not usable (swapon would refuse it)." >&2
        fi
        remap_close rw
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

# fstab_mounts_from <mount point> <spec> <fstab> — true when a LIVE entry mounts
#   that mount point from exactly that spec. What verify_install() asks of a
#   resolved mount: not that the line exists, but that it names the chosen
#   filesystem.
fstab_mounts_from() {
    sudo awk -v mp="$1" -v spec="$2" '
        $1 !~ /^#/ && $2 == mp && $1 == spec { found = 1 } END { exit !found }' "$3"
}

# fstab_live_entry <path> <fstab> — true when a LIVE entry mounts <path>, or, for
#   a swap file (which mounts nowhere), names it as its device.
fstab_live_entry() {
    sudo awk -v p="$1" '
        $1 !~ /^#/ && ($2 == p || ($3 == "swap" && $1 == p)) { found = 1 }
        END { exit !found }' "$2"
}

# fstab_mounts_boot <fstab> — true when the file carries a LIVE /boot entry:
#   that system keeps /boot on a filesystem of its own. Checks the source
#   against --source-boot, tells rewrite_fstab() whether to insert an entry,
#   and verifies what was written.
fstab_mounts_boot() {
    sudo awk '$1 !~ /^#/ && $2 == "/boot" { found = 1 } END { exit !found }' "$1"
}

# -----------------------------------------------------------------------------
# Bind-aware paths
# -----------------------------------------------------------------------------
# The rsync sees the source's root filesystem RAW, with no bind mounts replayed,
# so a path as the running system shows it is not the path the same data has in
# the transfer. On a slot-per-machine disk ~/.cache is a bind of
# /var/local/<...>/cache (copied) while /home/<user> is a bind of the data
# partition, which -x never enters -- so a rule naming
# /home/<user>/.ssh/id_ed25519 silently strips nothing. The helpers below
# translate between the namespaces, with the source's fstab as the authority.

# fstab_mount_table <fstab> — one row per mount point, tab separated:
#   <mountpoint>\t<fs|bind>\t<source>. "/" and swap entries are not emitted, and
#   a trailing slash is stripped (fstab accepts "/home/user/.cache/", which would
#   then match nothing). An octal-escaped path (\040) is announced and skipped
#   rather than emitted as a row that could never match. "rbind" counts as a
#   bind: it puts the data in the same place, and calling it a filesystem would
#   report a rule that DOES match as an out-of-reach no-op. Row order carries no
#   meaning -- fstab_realpath() picks the longest match and follows binds.
fstab_mount_table() {
    sudo awk '
        function trim_slash(p) { sub(/\/+$/, "", p); return p == "" ? "/" : p }
        function escaped(p) {
            if (p !~ /\\/) return 0;
            print "Warning: fstab entry " p " has an escaped path -- not translated." > "/dev/stderr";
            return 1;
        }
        $0 ~ /^[[:space:]]*#/ || NF < 3 { next }
        {
            mp = trim_slash($2); source = trim_slash($1);
            if (substr(mp, 1, 1) != "/" || mp == "/") next;
            if ($4 ~ /(^|,)r?bind(,|$)/) {
                if (escaped($1) || escaped($2)) next;
                nb++; bsrc[nb] = source; bmp[nb] = mp; next;
            }
            if ($3 == "swap" || escaped($2)) next;
            if (!(mp in kind)) order[++n] = mp;
            kind[mp] = "fs"; src[mp] = source;
        }
        END {
            for (i = 1; i <= nb; i++) {
                if (!(bmp[i] in kind)) order[++n] = bmp[i];
                kind[bmp[i]] = "bind"; src[bmp[i]] = bsrc[i];
            }
            for (i = 1; i <= n; i++)
                printf "%s\t%s\t%s\n", order[i], kind[order[i]], src[order[i]];
        }' "$1"
}

# fstab_realpath <path> — translate <path> from the running system's namespace
#   into the path the same data has in the raw root filesystem, following binds.
#   Prints it and returns 0 when the data really is on the root filesystem (so
#   the rsync can see it); returns 1 when it is on another filesystem and prints
#   THAT filesystem's mount point instead -- far more useful, and a caller
#   reading through a command substitution cannot be told through a global.
#   Reads the caller-set FSTAB_TABLE.
fstab_realpath() {
    local path=$1 hops=0 mp kind src
    local best best_kind best_src bestlen rest
    while [ "$hops" -lt 16 ]; do
        best=""; best_kind=""; best_src=""; bestlen=0
        while IFS=$'\t' read -r mp kind src; do
            [ -n "$mp" ] || continue
            [ "${#mp}" -gt "$bestlen" ] || continue
            if [ "$path" = "$mp" ] || [ "${path#"$mp"/}" != "$path" ]; then
                best=$mp; bestlen=${#mp}; best_kind=$kind; best_src=$src
            fi
        done <<<"$FSTAB_TABLE"
        # Nothing but / above it: the path is already a root-filesystem path.
        [ -n "$best" ] || { printf '%s\n' "$path"; return 0; }
        [ "$best_kind" = bind ] || { printf '%s\n' "$best"; return 1; }
        rest=${path#"$best"}
        path="$best_src$rest"
        hops=$((hops + 1))
    done
    return 1    # a bind that points into itself; nothing sane to report
}

# -----------------------------------------------------------------------------
# Regenerable caches
# -----------------------------------------------------------------------------
# ~/.cache/google-chrome is pure derived data: an HTTP cache, a compiled-JS
# cache and a shader cache (948 MB in 21,539 files here) that Chrome rebuilds on
# demand, while the passwords, cookies and extensions live in ~/.config and are
# copied either way. So it is dropped from the transfer by default, and from the
# target when a stale one is there. --keep-cache copies it like anything else.
CACHE_DROP_NAMES=(google-chrome google-chrome-headless)

# cache_drop_paths — the cache directories to drop, as paths in the transfer,
#   one per line. Candidates are named in the RUNNING system's namespace
#   (/root/.cache, every /home/*/.cache, any .cache the fstab mounts) and then
#   put through fstab_realpath, which finds /var/local/<...>/cache behind a
#   bound ~/.cache and drops one that lives on another filesystem entirely.
#   Reads SRC, FSTAB_TABLE, CACHE_DROP_NAMES.
cache_drop_paths() {
    local d cand real name mp kind src
    local -a cands=(/root/.cache)
    for d in "$SRC"/home/*/; do
        [ -d "$d" ] || continue
        d=${d%/}
        cands+=("/home/${d##*/}/.cache")
    done
    while IFS=$'\t' read -r mp kind src; do
        if [ "${mp##*/}" = .cache ]; then cands+=("$mp"); fi
    done <<<"$FSTAB_TABLE"
    for cand in "${cands[@]}"; do
        real=$(fstab_realpath "$cand") || continue
        for name in "${CACHE_DROP_NAMES[@]}"; do
            if sudo test -d "$SRC$real/$name"; then printf '%s\n' "$real/$name"; fi
        done
    done | sort -u
}

# probe_source_layout — what the summary needs from the source's own mount
#   layout, read through the transient mount probe_source_swapfiles() holds: the
#   caches to drop, the --exclude-from rules a bind makes unmatchable, and the
#   mounts that can be resolved instead of disabled. Best-effort like the swap
#   preview -- CACHE_PROBED/EXCLUDE_PROBED stay 0 when the source cannot be read
#   here, and each needs its own flag: an empty audit is also what a clean
#   exclude file looks like, so "not checked" must not print as "nothing found".
#   Fills FSTAB_TABLE, CACHE_PREVIEW, EXCLUDE_AUDIT and the REMAP_* tables;
#   scan_cache_drops() is the authoritative pass.
probe_source_layout() {
    CACHE_PREVIEW=(); CACHE_PROBED=0; EXCLUDE_AUDIT=(); EXCLUDE_PROBED=0
    [ -f "$SRC/etc/fstab" ] || return 0
    FSTAB_TABLE=$(fstab_mount_table "$SRC/etc/fstab") || true
    if [ $KEEP_CACHE -eq 0 ]; then
        mapfile -t CACHE_PREVIEW < <(cache_drop_paths)
        CACHE_PROBED=1
    fi
    if [ -n "$EXCLUDE_FROM" ]; then
        mapfile -t EXCLUDE_AUDIT < <(exclude_rules_unmatchable)
        EXCLUDE_PROBED=1
    fi
    probe_fstab_remap
}

# scan_cache_drops — the authoritative pass, Phase 3, source really mounted (the
#   sibling of scan_swapfiles): fills CACHE_DROPS and CACHE_FILTERS.
#   The rule is "H" (hide), NOT --exclude: an exclude is also a receiver-side
#   PROTECT, so under --update's --delete the stale copy on the target would
#   survive -- the opposite of the point. Hide is sender-side only. (The mirror
#   image of the "- /boot/" + "P /boot/" pair, which wants that protection.)
scan_cache_drops() {
    CACHE_DROPS=(); CACHE_FILTERS=()
    [ $KEEP_CACHE -eq 0 ] || return 0
    [ -f "$SRC/etc/fstab" ] || return 0
    FSTAB_TABLE=$(fstab_mount_table "$SRC/etc/fstab")
    mapfile -t CACHE_DROPS < <(cache_drop_paths)
    cache_filters_for ${CACHE_DROPS[@]+"${CACHE_DROPS[@]}"}
}

# rsync_pattern_escape <path> — quote the wildcards in a literal path. A rule is
#   a pattern, not a name: a directory really called "a[bc]" would otherwise
#   hide "ab" and "ac" -- never probed, and under --update's --delete removed
#   from the target too.
rsync_pattern_escape() {
    local p=$1
    p=${p//\\/\\\\}
    p=${p//\*/\\*}
    p=${p//\?/\\?}
    p=${p//\[/\\[}
    printf '%s\n' "$p"
}

# cache_filters_for <path>... — the rsync rules that drop those caches, into
#   CACHE_FILTERS. Shared by scan_cache_drops() and cache_filters_from_preview()
#   so the dry run's printed command and the real run's cannot drift apart.
cache_filters_for() {
    local p
    CACHE_FILTERS=()
    for p in "$@"; do
        info "Dropping regenerable cache $p (never copied; removed from the target if present)."
        CACHE_FILTERS+=(--filter="H $(rsync_pattern_escape "$p")/")
    done
}

# cache_filters_from_preview — the same rules from the pre-gate probe instead of
#   a mounted source, so the rsync command a dry run prints is the one that runs.
#   CACHE_DROPS stays empty on purpose: only verify_install() reads it, and a dry
#   run never gets there.
cache_filters_from_preview() {
    CACHE_DROPS=(); CACHE_FILTERS=()
    [ $KEEP_CACHE -eq 0 ] || return 0
    if [ "$CACHE_PROBED" -eq 0 ]; then
        echo "[dry-run] ...and the source's mount layout could not be read here either, so the command below omits the --filter='H ...' rule that would drop each regenerable browser cache"
        return 0
    fi
    cache_filters_for ${CACHE_PREVIEW[@]+"${CACHE_PREVIEW[@]}"}
}

# swap_excludes_from_preview — the sibling of cache_filters_from_preview():
#   SWAP_PREVIEW already holds every path scan_swapfiles() would exclude, so a
#   dry run prints the real --exclude= arguments rather than announcing that
#   they are missing.
swap_excludes_from_preview() {
    local entry sf state real
    SWAP_EXCLUDES=()
    if [ "$SWAP_PROBED" -eq 0 ]; then
        echo "[dry-run] ...and the same probe could not name the swap files, so the command below omits one --exclude= per swap file (each is re-created afterwards with fallocate + mkswap${EXCLUDE_FROM:+, or dropped if $EXCLUDE_FROM excludes it})"
        return 0
    fi
    for entry in ${SWAP_PREVIEW[@]+"${SWAP_PREVIEW[@]}"}; do
        read -r sf _ state real <<<"$entry"
        [ -n "$sf" ] || continue
        # Only a swap file the rsync can see gets an --exclude=; every other
        # state is one on a filesystem of its own, whose fourth field is a
        # device, not a transfer path. Listed the right way round on purpose: a
        # state added later must opt IN to being excluded.
        case "$state" in keep|drop) ;; *) continue ;; esac
        SWAP_EXCLUDES+=("--exclude=${real:-$sf}")
    done
}

# exclude_rules_unmatchable — audit an --exclude-from file against the source's
#   mount layout; print the rules that cannot match, tab separated:
#     bind\t<rule>\t<the path that data really has>
#       the rule's data IS in the transfer, under another name. This is the one
#       that matters: a private key or a browser profile the author believes is
#       being stripped from an impersonal clone, and is not.
#     foreign\t<rule>\t<the mount point its data is on>
#       the rule names a path on another filesystem, which -x never copies. Not
#       the same as harmless: a mount the target keeps still carries that data on
#       the booted clone, so the mount point is named rather than counted.
#     unknown\t<rule>\t
#       the wildcard falls above the rule's last component, so there is no
#       literal mount point to translate it against. Neither cleared nor
#       condemned, but said out loud: silence here reads as "checked, and fine".
#   Only anchored rules ("/...") can be judged: an unanchored pattern matches on
#   name alone, tied to no mount point. rsync's file syntax is honoured -- "- "
#   and "+ " (and their underscore forms), and a lone "!", which clears the list
#   so far, so the audit cannot warn about a rule the transfer discarded.
#   Reads EXCLUDE_FROM and FSTAB_TABLE.
exclude_rules_unmatchable() {
    local rule real dir
    local -a rules=()
    local -A have=()
    [ -n "$EXCLUDE_FROM" ] || return 0
    # "|| [ -n "$rule" ]": read fails at EOF on a final line with no newline, and
    # rsync honours that rule -- so dropping it here would leave the one rule the
    # transfer applies as the one rule nobody audited.
    while IFS= read -r rule || [ -n "$rule" ]; do
        rule=${rule%$'\r'}
        # A lone "!" clears the filter list, so everything read so far is gone.
        if [ "$rule" = '!' ]; then rules=(); have=(); continue; fi
        case $rule in
            ''|'#'*|';'*|'+ '*|'+_'*) continue ;;
        esac
        rule=${rule#- }; rule=${rule#-_}
        [ "${rule#/}" != "$rule" ] || continue
        rules+=("$rule"); have[$rule]=1
    done < "$EXCLUDE_FROM"
    for rule in ${rules[@]+"${rules[@]}"}; do
        if real=$(fstab_realpath "$rule"); then
            if [ "$real" = "$rule" ]; then
                # A plain root-filesystem path: nothing to report, unless the
                # wildcard sits in the DIRECTORY portion, where no mount point
                # could have matched literally and the walk proves nothing. A
                # trailing wildcard is fine -- its directory is spelled out.
                dir=${rule%/*}
                case $dir in *[\*\?\[]*) printf 'unknown\t%s\t\n' "$rule" ;; esac
                continue
            fi
            # The file already carries the translated path too, so the pair
            # covers both layouts: an exclude file fixed once stops being
            # announced on every later sync.
            [ -z "${have[$real]:-}" ] || continue
            printf 'bind\t%s\t%s\n' "$rule" "$real"
        else
            # On failure fstab_realpath prints the mount point that stopped it.
            printf 'foreign\t%s\t%s\n' "$rule" "$real"
        fi
    done
}

# report_exclude_audit — render that audit under the summary's "Excludes:" row.
#   The bind rows are the point: a rule whose data IS in the transfer under
#   another name strips nothing, which is how a private key survives on a clone
#   meant to be impersonal. The foreign rows are counted and their filesystems
#   named -- "no-op" would be a promise this cannot make, since a mount the
#   target keeps still carries that data on the booted clone. Says "not checked"
#   when the audit never ran: an empty audit is also what a clean file looks like.
report_exclude_audit() {
    local row kind rule real foreign=0 fs
    local -a hits=() unknown=() fslist=()
    if [ "$EXCLUDE_PROBED" -eq 0 ]; then
        summary_row "" "not checked (the source's fstab could not be read here to audit these rules)"
        return 0
    fi
    for row in ${EXCLUDE_AUDIT[@]+"${EXCLUDE_AUDIT[@]}"}; do
        IFS=$'\t' read -r kind rule real <<<"$row"
        case $kind in
            bind)    hits+=("$rule -> $real") ;;
            unknown) unknown+=("$rule") ;;
            *)       foreign=$((foreign + 1))
                     for fs in ${fslist[@]+"${fslist[@]}"}; do
                         [ "$fs" != "${real:-?}" ] || continue 2
                     done
                     fslist+=("${real:-?}") ;;
        esac
    done
    if [ ${#hits[@]} -gt 0 ]; then
        summary_row "" "WARNING: ${#hits[@]} rule(s) strip nothing -- the source binds their data in from elsewhere:"
        for row in "${hits[@]}"; do summary_row "" "  $row"; done
    fi
    if [ ${#unknown[@]} -gt 0 ]; then
        summary_row "" "WARNING: ${#unknown[@]} rule(s) have a wildcard above their last component, so no bind could be checked:"
        for row in "${unknown[@]}"; do summary_row "" "  $row"; done
    fi
    if [ "$foreign" -gt 0 ]; then
        summary_row "" "$foreign rule(s) name paths on ${fslist[*]}, off the root filesystem: -x never copies them,"
        summary_row "" "  but a mount the target keeps still carries that data on the clone (Phase 4 says which survived)"
    fi
}

# -----------------------------------------------------------------------------
# Mounts resolved at install time
# -----------------------------------------------------------------------------
# rewrite_fstab() comments out every mount whose filesystem is not on a disk
# this run writes to, with its binds and swap files -- right for a clone that
# must not block at boot, and exactly the edit the operator then undoes by hand,
# since the target wants ITS data partition. Which one cannot be derived
# (several disks here are labelled "data"), so it is ASKED before the gate and
# written in Phase 4; no answer means today's behaviour, exactly. Only the
# carrier is chosen -- everything on it follows from pass 1 marking it kept.

# fstab_entries_all <fstab> — every line that is a mount ENTRY, live or
#   commented out, one tab-separated row each:
#     <live|tagged|comment>\t<spec>\t<mount point>\t<type>\t<options>
#   "tagged" is a line this toolkit disabled, "comment" one a human did. The
#   field test is strict -- four fields, a plausible type (or bind), a spec that
#   names a device -- so that prose cannot qualify: Ubuntu's fstab header
#   mentions "UUID=" and must never read as a mount.
fstab_entries_all() {
    sudo awk '
        function known_type(t) {
            return t ~ /^(ext[234]|xfs|btrfs|f2fs|jfs|reiserfs|vfat|exfat|ntfs3?|udf|iso9660|auto|none|swap)$/;
        }
        {
            state = "live"; line = $0;
            if (line ~ /^[[:space:]]*#/) {
                state = (line ~ /^[[:space:]]*#[[:space:]]*\[PORTABLE-SYNC-DISABLED\]/) ? "tagged" : "comment";
                # Strip the marker(s), stacked ones included.
                while (sub(/^[[:space:]]*#[[:space:]]*/, "", line) ||
                       sub(/^\[PORTABLE-SYNC-DISABLED\][[:space:]]+/, "", line)) { }
            }
            n = split(line, f);
            if (n < 4) next;
            if (!known_type(f[3]) && f[4] !~ /(^|,)r?bind(,|$)/) next;
            if (f[1] !~ /^(\/|UUID=|LABEL=|PARTUUID=|PARTLABEL=)/) next;
            # A swap entry mounts nowhere ("none"); everything else has to name
            # an absolute mount point.
            if (f[3] != "swap" && substr(f[2], 1, 1) != "/") next;
            sub(/\/+$/, "", f[2]);
            if (f[2] == "") f[2] = "/";
            printf "%s\t%s\t%s\t%s\t%s\n", state, f[1], f[2], f[3], f[4];
        }' "$1"
}

# spec_uuid <spec> — the filesystem UUID an fstab spec names, or nothing.
spec_uuid() {
    case "$1" in
        UUID=*)              printf '%s' "${1#UUID=}" ;;
        /dev/disk/by-uuid/*) printf '%s' "${1#/dev/disk/by-uuid/}" ;;
    esac
}

# remap_keep_uuids — the UUIDs still there when the target boots, as far as can
#   be known BEFORE Phase 2. A fresh unified --target is repartitioned, so
#   nothing on that disk survives; otherwise the layout is kept and
#   target_disk_uuids() is the answer Phase 4 will reach.
remap_keep_uuids() {
    if [ "$UNIFIED_TARGET" -eq 1 ] && [ "$UPDATE" -eq 0 ]; then printf ' '
    else target_disk_uuids; fi
}

# probe_fstab_remap — the mounts worth asking about, off the transient mount
#   probe_source_swapfiles() holds. A mount qualifies when it is device-backed,
#   is none of this script's own roles, and is either live with a UUID that will
#   not be on the target's disk(s), or commented out in the source's fstab -- by
#   us on an earlier run or by hand, which is how a system already through this
#   migration carries its /data. Its binds and swap files are collected with it
#   (matched on the SOURCE side, which is what sits on the carrier), so one
#   answer covers the group. Fills REMAP_MPS + the REMAP_* tables, REMAP_PROBED.
probe_fstab_remap() {
    REMAP_MPS=(); REMAP_PROBED=0
    REMAP_STATE=(); REMAP_UUID=(); REMAP_LABEL=(); REMAP_SPECWAS=()
    REMAP_BINDS=(); REMAP_SWAPS=()
    [ -f "$SRC/etc/fstab" ] || return 0
    REMAP_PROBED=1

    local -a rows=()
    mapfile -t rows < <(fstab_entries_all "$SRC/etc/fstab")
    [ ${#rows[@]} -gt 0 ] || return 0

    local keep_uuids row state spec mp type opts uuid label rank
    local -A remap_rank=()
    keep_uuids=$(remap_keep_uuids)

    # Carriers first: a bind can only be judged once the mount it rides on is
    # known, and the source's fstab may well list it earlier in the file.
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r state spec mp type opts <<<"$row"
        [ "$type" != swap ] || continue
        case "$opts" in *bind*) continue ;; esac
        case "$mp" in /|/boot|/boot/efi) continue ;; esac
        uuid=$(spec_uuid "$spec")
        if [ "$state" = live ]; then
            # Kept by rewrite_fstab as it stands: on a target disk, or named in a
            # form (LABEL=, a /dev path) that resolves wherever the disk boots.
            [ -n "$uuid" ] || continue
            case "$keep_uuids" in *" $uuid "*) continue ;; esac
        fi
        # Which line IS the entry, when a mount point has several: the live one,
        # else the one this toolkit disabled (it was live when the disk was last
        # synced, and carries the UUID the source really used), else the one a
        # human commented out. The awk applies the same order in Phase 4.
        case "$state" in live) rank=3 ;; tagged) rank=2 ;; *) rank=1 ;; esac
        if [ -n "${REMAP_STATE[$mp]:-}" ]; then
            [ "$rank" -gt "${remap_rank[$mp]}" ] || continue
        else
            REMAP_MPS+=("$mp")
        fi
        remap_rank[$mp]=$rank
        if [ "$state" = live ]; then REMAP_STATE[$mp]=live; else REMAP_STATE[$mp]=disabled; fi
        REMAP_UUID[$mp]=$uuid
        REMAP_SPECWAS[$mp]=$spec
        # The label its candidates must carry: what the filesystem it names
        # wears here (usually attached -- often a partition of the source's own
        # disk), what the entry asks for by name, or the mount point's last
        # component, which is the convention this exists for.
        label=""
        if [ -n "$uuid" ] && [ -e "/dev/disk/by-uuid/$uuid" ]; then
            label=$(lsblk -dno LABEL "/dev/disk/by-uuid/$uuid" 2>/dev/null | xargs || true)
        fi
        case "$spec" in LABEL=*) [ -n "$label" ] || label=${spec#LABEL=} ;; esac
        [ -n "$label" ] || label=${mp##*/}
        REMAP_LABEL[$mp]=$label
    done
    [ ${#REMAP_MPS[@]} -gt 0 ] || return 0

    # ...then what travels with each of them.
    local carrier
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r state spec mp type opts <<<"$row"
        carrier=""
        for carrier in "${REMAP_MPS[@]}"; do
            [ "${spec#"$carrier"/}" != "$spec" ] && break || carrier=""
        done
        [ -n "$carrier" ] || continue
        [ "$state" = live ] || state=disabled
        case "$opts" in
            *bind*) REMAP_BINDS[$carrier]+="$state $mp $spec"$'\n' ;;
            *) if [ "$type" = swap ]; then REMAP_SWAPS[$carrier]+="$state $spec"$'\n'; fi ;;
        esac
    done
}

# remap_block_rows — one row per block device, unit-separated (\037):
#   name<US>type<US>fstype<US>uuid<US>size<US>label<US>mountpoint.
#   lsblk's raw output cannot be read with "read -r a b c" (empty columns
#   collapse and shift every later field), and neither could tabs: tab is IFS
#   *whitespace*, so a run of them is still one delimiter. All but the first two
#   fields are optional, so the separator must be one read treats as a
#   terminator. Pairs mode is the only unambiguous lsblk output; convert it here.
remap_block_rows() {
    lsblk -pPno NAME,TYPE,FSTYPE,UUID,SIZE,LABEL,MOUNTPOINT 2>/dev/null | awk '
        function val(k,   p, s, q) {
            p = index($0, k "=\"");
            if (p == 0) return "";
            s = substr($0, p + length(k) + 2);
            q = index(s, "\"");
            return q ? substr(s, 1, q - 1) : "";
        }
        {
            printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", val("NAME"),
                   val("TYPE"), val("FSTYPE"), val("UUID"), val("SIZE"),
                   val("LABEL"), val("MOUNTPOINT");
        }'
}

# remap_candidates <label> <the source's uuid> — the filesystems that could
#   carry this mount on the target: <device>\t<uuid>\t<fstype>\t<size>\t<note>.
#   Whole-disk filesystems count (the bulk data disks here have no partition
#   table). Ruled out: this run's own roles, anything on a disk it repartitions,
#   an image's loop device, and container types. The candidate on the target's
#   disk comes first -- it travels with the disk, and is the prompt's default.
remap_candidates() {
    local want=$1 srcuuid=${2:-}
    local dev type fstype uuid size label mnt parent note
    local -a first=() rest=()
    local tdisks skip_disk="" roles
    tdisks=" $(target_disks) "
    if [ "$UNIFIED_TARGET" -eq 1 ] && [ "$UPDATE" -eq 0 ]; then
        skip_disk=$(readlink -f "$TARGET" 2>/dev/null || true)
    fi
    # The partitions this run writes to, resolved once. /dev/null stands in for
    # an absent role: uutils readlink resolves "" to the working directory.
    roles=" $(readlink -f "$TGT_ROOT" "$TGT_EFI" "${TGT_BOOT:-/dev/null}" "${TGT_BIOS:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
    while IFS=$'\037' read -r dev type fstype uuid size label mnt; do
        [ -n "$dev" ] && [ -n "$uuid" ] && [ -n "$fstype" ] || continue
        [ "$label" = "$want" ] || continue
        case "$fstype" in
            swap|LVM2_member|crypto_LUKS|linux_raid_member|zfs_member|iso9660|squashfs) continue ;;
        esac
        parent=$(get_parent_disk "$dev")
        # Never offer what this run writes to, wipes, or (an image's loop
        # device) will not have at boot.
        case "$roles" in *" $dev "*) continue ;; esac
        if [ -n "$skip_disk" ] && { [ "$dev" = "$skip_disk" ] || [ "$parent" = "$skip_disk" ]; }; then
            continue
        fi
        if [ -n "${LOOP_DEV:-}" ] && { [ "$dev" = "$LOOP_DEV" ] || [ "$parent" = "$LOOP_DEV" ]; }; then
            continue
        fi
        note=""
        if [ -n "$srcuuid" ] && [ "$uuid" = "$srcuuid" ]; then note="the source's own"; fi
        [ -z "$mnt" ] || note="${note:+$note, }mounted here at $mnt"
        case "$tdisks" in
            *" ${parent:-$dev} "*|*" $dev "*)
                note="${note:+$note, }on ${parent:-$dev}, this run's target disk"
                first+=("$dev"$'\t'"$uuid"$'\t'"$fstype"$'\t'"$size"$'\t'"$note") ;;
            *)  rest+=("$dev"$'\t'"$uuid"$'\t'"$fstype"$'\t'"$size"$'\t'"$note") ;;
        esac
    done < <(remap_block_rows)
    first+=(${rest[@]+"${rest[@]}"})
    [ ${#first[@]} -eq 0 ] || printf '%s\n' "${first[@]}"
}

# remap_open <dev> [rw] — open <dev>, putting a directory where its contents
#   live in REMAP_OPEN_PATH. A global, not a printed value: the rw form goes
#   through run(), whose dry-run output would be captured as the path. Uses the
#   host's own mount point when it has one (the kernel refuses a second mount
#   with different flags), else a transient mount remap_close() -- and cleanup()
#   -- takes down. Someone else's read-only mount is refused for rw, not
#   remounted: it is theirs.
remap_open() {
    local dev=$1 mode=${2:-ro} row mp opts
    REMAP_OPEN_PATH=""
    row=$(findmnt -fnro TARGET,OPTIONS --source "$dev" 2>/dev/null | head -n 1 || true)
    if [ -n "$row" ]; then
        mp=${row%% *}; opts=${row#* }
        if [ "$mode" = rw ]; then
            case ",$opts," in *,rw,*) REMAP_OPEN_PATH=$mp; return 0 ;; esac
            return 1
        fi
        REMAP_OPEN_PATH=$mp
        return 0
    fi
    REMAP_OPEN_MNT=$(mktemp -d /tmp/install-remap.XXXXXX) || { REMAP_OPEN_MNT=""; return 1; }
    if [ "$mode" = rw ]; then
        if run sudo mount -o noatime "$dev" "$REMAP_OPEN_MNT"; then
            REMAP_OPEN_PATH=$REMAP_OPEN_MNT
            return 0
        fi
    elif sudo mount -r -o noatime "$dev" "$REMAP_OPEN_MNT" 2>/dev/null; then
        REMAP_OPEN_PATH=$REMAP_OPEN_MNT
        return 0
    fi
    rmdir "$REMAP_OPEN_MNT" 2>/dev/null || true
    REMAP_OPEN_MNT=""
    return 1
}

remap_close() {
    REMAP_OPEN_PATH=""
    [ -n "$REMAP_OPEN_MNT" ] || return 0
    if [ "${1:-ro}" = rw ]; then run sudo umount "$REMAP_OPEN_MNT"
    else sudo umount "$REMAP_OPEN_MNT" 2>/dev/null || true; fi
    rmdir "$REMAP_OPEN_MNT" 2>/dev/null || true
    REMAP_OPEN_MNT=""
}

# remap_spec_dev <spec> — the device an fstab spec names on this machine, or
#   nothing when it names one that is not here (which is legitimate: the disk is
#   going to boot somewhere else).
remap_spec_dev() {
    local spec=$1 path=""
    case "$spec" in
        /dev/*)      path=$spec ;;
        UUID=*)      path="/dev/disk/by-uuid/${spec#UUID=}" ;;
        LABEL=*)     path="/dev/disk/by-label/${spec#LABEL=}" ;;
        PARTUUID=*)  path="/dev/disk/by-partuuid/${spec#PARTUUID=}" ;;
        PARTLABEL=*) path="/dev/disk/by-partlabel/${spec#PARTLABEL=}" ;;
    esac
    [ -n "$path" ] && [ -b "$path" ] || return 0
    readlink -f "$path"
}

# remap_role_of <dev> — the role this run gives that device, if any. Naming one
#   for another mount point cannot work: the target would carry two fstab
#   entries for one filesystem, and a swap file written there would land on the
#   partition GRUB boots from. For --remap, which names a device outright; the
#   candidate list already rules them out.
remap_role_of() {
    local d parent
    d=$(readlink -f "$1" 2>/dev/null) || return 0
    [ -n "$d" ] || return 0
    [ "$d" != "$(readlink -f "$TGT_ROOT" 2>/dev/null)" ] || { printf 'the root filesystem'; return 0; }
    [ "$d" != "$(readlink -f "$TGT_EFI"  2>/dev/null)" ] || { printf 'the ESP'; return 0; }
    if [ -n "$TGT_BOOT" ] && [ "$d" = "$(readlink -f "$TGT_BOOT" 2>/dev/null)" ]; then
        printf '/boot'; return 0
    fi
    if [ -n "$TGT_BIOS" ] && [ "$d" = "$(readlink -f "$TGT_BIOS" 2>/dev/null)" ]; then
        printf 'the BIOS Boot partition'; return 0
    fi
    # Not a role, but on a disk about to be repartitioned: the filesystem
    # named will not exist when the target boots.
    if [ "$UNIFIED_TARGET" -eq 1 ] && [ "$UPDATE" -eq 0 ]; then
        parent=$(get_parent_disk "$d")
        if [ "$d" = "$(readlink -f "$TARGET" 2>/dev/null)" ] || \
           [ -n "$parent" ] && [ "$parent" = "$(readlink -f "$TARGET" 2>/dev/null)" ]; then
            printf 'a partition of %s, which this run repartitions' "$TARGET"
        fi
    fi
}

# remap_choose <mountpoint> <spec> — record one answer: the spec Phase 4 writes,
#   the device it names here, and every commented-out line that comes back with
#   it. A swap entry mounts nowhere, so it is keyed by its own path, as in the awk.
remap_choose() {
    local mp=$1 spec=$2 st path src
    REMAP_SPEC[$mp]=$spec
    REMAP_DEV[$mp]=$(remap_spec_dev "$spec")
    [ "${REMAP_STATE[$mp]}" = live ] || REMAP_ENABLE+=("$mp")
    while read -r st path src; do
        [ -n "$path" ] || continue
        [ "$st" = live ] || REMAP_ENABLE+=("$path")
    done <<<"${REMAP_BINDS[$mp]:-}"
    while read -r st path; do
        [ -n "$path" ] || continue
        [ "$st" = live ] || REMAP_ENABLE+=("$path")
    done <<<"${REMAP_SWAPS[$mp]:-}"
}

# remap_note <mountpoint> <text> — one more thing the summary should say about
#   a resolved mount, in the order it was found out.
remap_note() { REMAP_NOTES[$1]+="$2"$'\n'; }

# remap_swap_preview_state <fstab path> <state> <detail> [bytes] — rewrite that
#   swap file's row in the preview. probe_source_swapfiles() filed one on /data
#   as "offroot", true of the transfer but not the whole story once /data is
#   resolved: the swap block stays the one place swap is described.
remap_swap_preview_state() {
    local path=$1 state=$2 detail=$3 bytes=${4:-?} i sp sb ss sr
    for i in "${!SWAP_PREVIEW[@]}"; do
        read -r sp sb ss sr <<<"${SWAP_PREVIEW[$i]}"
        [ "$sp" = "$path" ] || continue
        SWAP_PREVIEW[$i]="$path $bytes $state $detail"
    done
}

# probe_remap_choice <mountpoint> — read the chosen filesystem and answer the
#   two questions that decide whether the target boots as expected: are the
#   directories its binds point at there, and is the swap file it carries there?
#   Read-only and best-effort -- one not attached here (a legitimate --remap
#   UUID= for the machine the disk will boot on) is reported as unchecked.
#   A missing swap file is created later at the size of the source's own, read
#   in a second pass since only one filesystem is open at a time. Never invented.
probe_remap_choice() {
    local mp=$1 dev=${REMAP_DEV[$mp]:-} root rel st path src size row avail have
    local -a missing=() need_size=()
    local nbind=0
    if [ -z "$dev" ]; then
        remap_note "$mp" "not attached here, so its contents were not checked"
        return 0
    fi
    if ! remap_open "$dev"; then
        remap_note "$mp" "could not be mounted here, so its contents were not checked"
        return 0
    fi
    root=$REMAP_OPEN_PATH
    while read -r st path src; do
        [ -n "$src" ] || continue
        nbind=$((nbind + 1))
        rel=${src#"$mp"}
        sudo test -e "$root$rel" || missing+=("$src")
    done <<<"${REMAP_BINDS[$mp]:-}"
    if [ "$nbind" -gt 0 ]; then
        if [ ${#missing[@]} -eq 0 ]; then
            remap_note "$mp" "$dev carries all $nbind bind source(s)"
        else
            remap_note "$mp" "WARNING: $dev is missing ${missing[*]} -- those binds will fail at boot"
        fi
    fi
    # What it has to spare: a size read off the source is not one this
    # filesystem can necessarily hold, and fallocate finds that out after the copy.
    avail=$(df -B1 --output=avail "$root" 2>/dev/null | tail -n 1 | xargs || true)
    while read -r st path; do
        [ -n "$path" ] || continue
        rel=${path#"$mp"}
        if sudo test -f "$root$rel" && swapfile_ok "$root$rel"; then
            size=$(sudo stat -c %s "$root$rel")
            remap_note "$mp" "swap file $path is already on $dev ($(human_size "$size"))"
            remap_swap_preview_state "$path" remapkeep "$dev" "$size"
        else
            # An unusable file of that name gives its blocks back when removed,
            # so they count as free space for the check.
            have=$(sudo stat -c %s "$root$rel" 2>/dev/null || echo 0)
            need_size+=("$path"$'\t'"$rel"$'\t'"$have")
        fi
    done <<<"${REMAP_SWAPS[$mp]:-}"
    remap_close

    # The sizes, off the source's own carrier -- the only authority for them.
    local srcdev srcroot
    if [ ${#need_size[@]} -gt 0 ]; then
        srcdev=""
        if [ -n "${REMAP_UUID[$mp]:-}" ] && [ -e "/dev/disk/by-uuid/${REMAP_UUID[$mp]}" ]; then
            srcdev=$(readlink -f "/dev/disk/by-uuid/${REMAP_UUID[$mp]}")
        fi
        srcroot=""
        if [ -n "$srcdev" ] && remap_open "$srcdev"; then srcroot=$REMAP_OPEN_PATH; fi
        for row in "${need_size[@]}"; do
            IFS=$'\t' read -r path rel have <<<"$row"
            size=""
            if [ -n "$srcroot" ] && sudo test -f "$srcroot$rel"; then
                size=$(sudo stat -c %s "$srcroot$rel" 2>/dev/null || true)
            fi
            if [ -z "$size" ] || [ "$size" -le 0 ]; then
                remap_note "$mp" "WARNING: swap file $path is not on $dev and its size cannot be read here -- not created, so swapon -a will fail on the target"
                remap_swap_preview_state "$path" remapnone "$dev"
                continue
            fi
            if [ -n "$avail" ] && [ $((avail + have)) -lt "$size" ]; then
                remap_note "$mp" "WARNING: swap file $path needs $(human_size "$size") and $dev has $(human_size $((avail + have))) free -- not created, so swapon -a will fail on the target"
                remap_swap_preview_state "$path" remapnone "$dev" "$size"
                continue
            fi
            REMAP_SWAP_CREATE+=("$path"$'\t'"$dev"$'\t'"$rel"$'\t'"$size")
            remap_note "$mp" "swap file $path will be created on $dev ($(human_size "$size"))"
            remap_swap_preview_state "$path" remapmake "$dev" "$size"
        done
        remap_close
    fi
}

# ask_fstab_remap — put each remappable mount to the operator, before the gate
#   and so before anything is written. --remap answers without asking; --yes, a
#   non-interactive stdin or no candidate leaves things as they are today, and
#   the summary says which it was. A dry run still asks: the answer is what
#   makes its preview accurate, and nothing here writes.
ask_fstab_remap() {
    [ ${#REMAP_MPS[@]} -gt 0 ] || return 0
    local mp row dev uuid fstype size note ans n default_idx tcount role
    local -a cands=()
    for mp in "${REMAP_MPS[@]}"; do
        if [ -n "${REMAP_ARG[$mp]+set}" ]; then
            if [ "${REMAP_ARG[$mp]}" = none ]; then
                remap_note "$mp" "left as the source has it (--remap $mp=none)"
            else
                # Only --remap can name one of this run's own partitions;
                # remap_candidates() never offers one.
                role=$(remap_role_of "$(remap_spec_dev "${REMAP_ARG[$mp]}")")
                [ -z "$role" ] || \
                    die "--remap $mp=${REMAP_ARG[$mp]} names $role of this very install. Mounting it at $mp as well would give the target two entries for one filesystem (and put anything written there onto the partition this run manages). Name a different filesystem, or --remap $mp=none."
                remap_choose "$mp" "${REMAP_ARG[$mp]}"
                probe_remap_choice "$mp"
            fi
            continue
        fi
        mapfile -t cands < <(remap_candidates "${REMAP_LABEL[$mp]}" "${REMAP_UUID[$mp]:-}")
        if [ ${#cands[@]} -eq 0 ]; then
            remap_note "$mp" "nothing labelled \"${REMAP_LABEL[$mp]}\" is attached here; --remap $mp=UUID=... names one anyway"
            continue
        fi
        if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
            if [ "$ASSUME_YES" -eq 1 ]; then note="--yes"; else note="stdin is not a terminal"; fi
            remap_note "$mp" "not asked ($note); --remap $mp=DEVICE resolves it"
            continue
        fi

        echo
        if [ "${REMAP_STATE[$mp]}" = live ]; then
            info "The source mounts $mp from ${REMAP_SPECWAS[$mp]}, which will not be on this target's disk(s)."
            echo "    Left alone, that entry is commented out on the target$(remap_dependants_phrase "$mp")."
        else
            info "The source has $mp commented out (${REMAP_SPECWAS[$mp]})."
            echo "    Left alone, it stays commented out on the target$(remap_dependants_phrase "$mp")."
        fi
        echo "    Filesystems labelled \"${REMAP_LABEL[$mp]}\" attached now:"
        n=0; tcount=0; default_idx=""
        for row in "${cands[@]}"; do
            IFS=$'\t' read -r dev uuid fstype size note <<<"$row"
            n=$((n + 1))
            printf '      %d) %-16s %8s  %-5s %s%s\n' "$n" "$dev" "$size" "$fstype" "$uuid" "${note:+  ($note)}"
            case "$note" in *"this run's target disk"*) tcount=$((tcount + 1)); default_idx=$n ;; esac
        done
        [ "$tcount" -eq 1 ] || default_idx=""
        echo "      n) leave it as the source has it"
        while true; do
            printf '    Mount %s from [1-%d, n]%s: ' "$mp" "$n" "${default_idx:+ (default $default_idx)}"
            if ! read -r ans; then echo; ans=""; fi
            [ -n "$ans" ] || ans=${default_idx:-n}
            case "$ans" in
                n|N|none)
                    remap_note "$mp" "left as the source has it (answered at the prompt)"
                    break ;;
                ''|*[!0-9]*)
                    echo "    Please answer 1-$n, or n." ;;
                *)
                    if [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
                        IFS=$'\t' read -r dev uuid fstype size note <<<"${cands[$((ans - 1))]}"
                        remap_choose "$mp" "/dev/disk/by-uuid/$uuid"
                        probe_remap_choice "$mp"
                        break
                    fi
                    echo "    Please answer 1-$n, or n." ;;
            esac
        done
    done
    remap_lock_choices
}

# remap_dependants_list <mountpoint> — "binds /Books, /Audio, swap /data/swap",
#   the summary's version of what travels with a mount; empty when nothing does.
remap_dependants_list() {
    local mp=$1 st path src out="" binds=""
    while read -r st path src; do
        if [ -n "$path" ]; then binds="${binds:+$binds, }$path"; fi
    done <<<"${REMAP_BINDS[$mp]:-}"
    [ -z "$binds" ] || out="binds $binds"
    while read -r st path; do
        if [ -n "$path" ]; then out="${out:+$out, }swap $path"; fi
    done <<<"${REMAP_SWAPS[$mp]:-}"
    printf '%s' "$out"
}

# remap_dependants_phrase <mountpoint> — ", along with 3 bind mounts and 1 swap
#   entry", or nothing at all when the mount carries neither.
remap_dependants_phrase() {
    local mp=$1 nb=0 ns=0 line out=""
    while read -r line; do if [ -n "$line" ]; then nb=$((nb + 1)); fi; done <<<"${REMAP_BINDS[$mp]:-}"
    while read -r line; do if [ -n "$line" ]; then ns=$((ns + 1)); fi; done <<<"${REMAP_SWAPS[$mp]:-}"
    if [ "$nb" -eq 1 ]; then out="1 bind mount"
    elif [ "$nb" -gt 1 ]; then out="$nb bind mounts"; fi
    if [ "$ns" -eq 1 ]; then out="${out:+$out and }1 swap entry"
    elif [ "$ns" -gt 1 ]; then out="${out:+$out and }$ns swap entries"; fi
    [ -n "$out" ] || return 0
    printf ', along with %s' "$out"
}

# remap_lock_choices — every disk a resolved mount points at gets a lock like any
#   other disk this run touches: exclusive when a swap file has to be created on
#   it, shared when it is only read. Locks are keyed by parent disk, so a chosen
#   partition of the target's own disk is already covered and is skipped.
remap_lock_choices() {
    local mp dev key before row swapdev
    before=" ${!LOCK_MODE[*]} "
    for mp in "${REMAP_MPS[@]}"; do
        dev=${REMAP_DEV[$mp]:-}
        [ -n "$dev" ] || continue
        key=sh
        for row in ${REMAP_SWAP_CREATE[@]+"${REMAP_SWAP_CREATE[@]}"}; do
            IFS=$'\t' read -r _ swapdev _ _ <<<"$row"
            if [ "$swapdev" = "$dev" ]; then key=ex; fi
        done
        add_lock "$dev" "$key"
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        for key in "${!LOCK_MODE[@]}"; do
            case "$before" in *" $key "*) continue ;; esac
            echo "[dry-run] would flock (${LOCK_MODE[$key]}) $key"
        done
    else
        acquire_locks
    fi
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

# target_disk_uuids — every filesystem UUID on the disk(s) this install writes
#   to, space-delimited with sentinel spaces for the awk lookups below. A mount
#   naming one is present exactly when this system is (a rootfs sharing its disk
#   with /data, the slot-per-machine layout). Everything else stays disabled: a
#   clone that boots elsewhere must not block on a device that is not there.
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

# report_scan <records> <kinds> — measure the rows of those kinds (space
#   separated) in the record file rewrite_fstab()'s awk wrote: sets REPORT_N,
#   REPORT_W (the mount-point column) and REPORT_WORD, and is false when there
#   are none. Shared by the two reports below, which differ only in wording.
report_scan() {
    local file=$1 want=" $2 " kind mp _rest
    REPORT_N=0; REPORT_W=14; REPORT_WORD=entries
    [ -s "$file" ] || return 1
    while IFS=$'\t' read -r kind mp _rest; do
        case "$want" in *" $kind "*) ;; *) continue ;; esac
        [ ${#mp} -le $REPORT_W ] || REPORT_W=${#mp}
        REPORT_N=$((REPORT_N + 1))
    done < "$file"
    [ "$REPORT_N" -ne 1 ] || REPORT_WORD=entry
    [ "$REPORT_N" -gt 0 ]
}

# report_fstab_retargets <records> — printed before report_fstab_disables():
#   the mounts just pointed at a filesystem chosen at the gate, and the
#   commented-out lines revived with them. A mount that was both gets a line for
#   each: they are two different things to have happened to it.
report_fstab_retargets() {
    local file=$1 kind mp detail
    report_scan "$file" "remap enable" || return 0
    info "Resolved in the target's /etc/fstab ($REPORT_N $REPORT_WORD):"
    while IFS=$'\t' read -r kind mp detail; do
        case "$kind" in
            remap)  printf '      %-*s now mounts from %s\n' "$REPORT_W" "$mp" "$detail" ;;
            enable) printf '      %-*s brought back to life%s\n' "$REPORT_W" "$mp" "${detail:+ ($detail)}" ;;
        esac
    done < "$file"
}

# report_fstab_disables <records> — what rewrite_fstab() just commented out, one
#   line per entry in fstab order, with the reason. Five mounts can leave a
#   booting fstab in one run (a /data plus every bind on it), and reading the
#   file afterwards used to be the only way to find out. A UUID row also names
#   the device that UUID resolves to HERE, which is what makes it actionable.
report_fstab_disables() {
    local file=$1 kind mp detail dev disks
    local uuid_rows=0
    report_scan "$file" "uuid bind swapmount swapdrop boot" || return 0
    disks=$(target_disks)
    info "Disabled in the target's /etc/fstab ($REPORT_N $REPORT_WORD):"
    while IFS=$'\t' read -r kind mp detail; do
        case "$kind" in
            uuid)
                dev=""
                [ -e "/dev/disk/by-uuid/$detail" ] && dev=$(readlink -f "/dev/disk/by-uuid/$detail")
                printf '      %-*s UUID=%s (%s) -- not on %s\n' \
                       "$REPORT_W" "$mp" "$detail" "${dev:-not attached}" "${disks:-any target disk}"
                uuid_rows=$((uuid_rows + 1))
                ;;
            bind)
                printf '      %-*s bind on %s, disabled above\n' "$REPORT_W" "$mp" "$detail" ;;
            swapmount)
                printf '      %-*s swap file on %s, disabled above\n' "$REPORT_W" "$mp" "$detail" ;;
            swapdrop)
                printf '      %-*s swap file dropped by --exclude-from\n' "$REPORT_W" "$mp" ;;
            boot)
                printf '      %-*s /boot is inside / on this target\n' "$REPORT_W" "$mp" ;;
        esac
    done < "$file"
    if [ "$uuid_rows" -gt 0 ]; then
        echo "    A disk that boots elsewhere must not block on a device that is not there."
        echo "    If this one will always see them, uncomment by hand (or re-run and answer"
        echo "    the prompt), naming this disk's own equivalent filesystem."
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

    # remap_rows / enable_set: what ask_fstab_remap() resolved. The awk needs
    # only these two -- the spec to write for a mount point, and the lines to
    # revive -- since marking the carrier kept in pass 1 carries its binds and
    # its swap file with it. Swap lines are keyed by their own path.
    # Plain "${!ARR[@]}", never ${!ARR[@]+...}: with a +alternate modifier bash
    # reads "!" as an INDIRECT reference, takes the array's value as a variable
    # name and dies. A declared empty array expands to nothing under set -u.
    local remap_rows="" enable_set=" " remap_mp
    for remap_mp in "${!REMAP_SPEC[@]}"; do
        remap_rows+="$remap_mp"$'\t'"${REMAP_SPEC[$remap_mp]}"$'\n'
    done
    for remap_mp in ${REMAP_ENABLE[@]+"${REMAP_ENABLE[@]}"}; do
        enable_set+="$remap_mp "
    done

    # FSTAB_REPORT: one record (kind, mount point, detail) per line the awk
    # changes, for the reports below. Written by the sudo awk into a file this
    # shell owns; cleanup() sweeps it if the run dies first.
    # In a private directory, NOT straight in /tmp: /tmp is sticky, and
    # fs.protected_regular then refuses even root an O_CREAT open of a file it
    # does not own -- and mawk treats a failed redirection as fatal, which once
    # killed a run in Phase 4 with the copy done and the fstab not translated.
    FSTAB_REPORT_DIR=$(mktemp -d /tmp/install-report.XXXXXX) || FSTAB_REPORT_DIR=""
    if [ -n "$FSTAB_REPORT_DIR" ]; then
        FSTAB_REPORT="$FSTAB_REPORT_DIR/disabled"
        : > "$FSTAB_REPORT"
    else
        FSTAB_REPORT=""
        echo "Warning: no temp dir for the fstab report; entries will still be disabled, just not listed." >&2
    fi

    sudo awk -v old_efi="$OLD_UUID_EFI" -v new_efi="$NEW_UUID_EFI" \
             -v old_root="$OLD_UUID_ROOT" -v new_root="$NEW_UUID_ROOT" \
             -v old_boot="$OLD_UUID_BOOT" -v new_boot="$NEW_UUID_BOOT" \
             -v map_boot="$map_boot" -v sep_boot="$TGT_SEP_BOOT" \
             -v has_boot="$has_boot" -v keep_uuids="$keep_uuids" \
             -v new_swap="${NEW_UUID_SWAP:-}" -v drop_swap="$drop_swap" \
             -v remap="$remap_rows" -v enable="$enable_set" \
             -v report="$FSTAB_REPORT" '
    # The mounts resolved at the gate, as "<mount point>\t<spec>" rows.
    BEGIN {
        nrow = split(remap, row, "\n");
        for (i = 1; i <= nrow; i++) {
            if (row[i] == "") continue;
            t = index(row[i], "\t");
            if (t == 0) continue;
            mp = substr(row[i], 1, t - 1);
            sp = substr(row[i], t + 1);
            remap_plain[mp] = sp;
            # sub() reads "&" as the matched text and "\\" as an escape, so keep
            # a replacement-safe copy of the spec as well as the plain one.
            gsub(/\\/, "\\\\", sp);
            gsub(/&/, "\\\\&", sp);
            remap_spec[mp] = sp;
        }
    }
    # enabled(key) — is this one of the commented-out lines the operator asked
    # for back? Mount point for an ordinary entry, path for a swap file.
    function enabled(k) { return index(enable, " " k " ") > 0 }
    # revive(line, pass) — the live mount line hiding under a comment marker,
    # when this run was told to bring it back; "" for anything else, prose above
    # all. Only the FIRST line per key is revived, so a stale duplicate cannot
    # become a second mount of the same thing; the passes count separately.
    function revive(s, pass,   p, g, k, istag) {
        if (enable == " " || s !~ /^[[:space:]]*#/) return "";
        p = s;
        while (sub(/^[[:space:]]*#[[:space:]]*/, "", p) ||
               sub(/^\[PORTABLE-SYNC-DISABLED\][[:space:]]+/, "", p)) { }
        if (split(p, g) < 4) return "";
        # The test the discovery pass applied when it offered this line: prose
        # can carry four fields too, and must never read as a mount.
        if (g[1] !~ /^(\/|UUID=|LABEL=|PARTUUID=|PARTLABEL=)/) return "";
        if (g[3] !~ /^(ext[234]|xfs|btrfs|f2fs|jfs|reiserfs|vfat|exfat|ntfs3?|udf|iso9660|auto|none|swap)$/ &&
            g[4] !~ /(^|,)r?bind(,|$)/) return "";
        k = (g[3] == "swap") ? g[1] : g[2];
        if (!enabled(k)) return "";
        # With both a line this toolkit disabled and one a human commented out,
        # the tagged one is the entry -- it was live at the last sync, and is
        # what the discovery pass read. Pass 1 finds out there is one; it reads
        # the whole file before pass 2 emits anything.
        istag = (s ~ /\[PORTABLE-SYNC-DISABLED\]/);
        if (pass == 1 && istag) has_tagged[k] = 1;
        if (pass == 2 && has_tagged[k] && !istag) return "";
        if (revived[pass, k]++) return "";
        return p;
    }
    # retarget(line, spec) — point a line at the filesystem chosen for its mount
    # point, leaving everything after the device spec (and its columns) alone.
    function retarget(s, spec,   out) {
        out = s;
        if (!sub(/^[[:space:]]*[^[:space:]]+/, spec, out)) return s;
        return out;
    }
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
    # One record per line this run changes, in file order, for the reports the
    # shell prints afterwards. Lines that arrived already tagged are NOT
    # recorded: an --update re-sync would re-announce them on every run.
    function note(kind, mp, detail) {
        if (report == "") return;   # unreportable: still disable the line
        printf "%s\t%s\t%s\n", kind, mp, detail >> report;
    }
    # The mount a path sits on: the longest mount point pass 1 resolved that
    # prefixes it. "/" always matches, so this never comes back empty -- and a
    # path under a disabled mount resolves to it, and goes down with it.
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
    # Decide every device-backed mount first, so pass 2 can judge a bind by the
    # mount its SOURCE sits on: a bind is worth what carries the directory it
    # points at, no more.
    NR == FNR {
        # A revived line counts as live from here on, so it is not recorded as
        # disabled and the binds riding on it are judged by it.
        line = revive($0, 1);
        if (line == "") {
            if ($0 ~ /^# \[PORTABLE-SYNC-DISABLED\] /) {
                payload = $0;
                while (sub(/^# \[PORTABLE-SYNC-DISABLED\] /, "", payload)) { }
                if (payload ~ /^[[:space:]]*#/) next;
                split(payload, f);
                if (substr(f[2], 1, 1) == "/") was_disabled[f[2]] = 1;
                next;
            }
            if ($0 ~ /^[[:space:]]*#/) next;
            line = $0;
        }
        if (split(line, f) < 3) next;
        line = xlate(line);
        split(line, f);
        if (f[2] in remap_spec) { line = retarget(line, remap_spec[f[2]]); split(line, f) }
        if (f[4] ~ /(^|,)bind(,|$)/) { binds[++nbind] = f[1] SUBSEP f[2]; next }
        if (!sep_boot && f[2] == "/boot")   keep = 0;
        else if (f[3] == "swap")            keep = (index(drop_swap, " " f[1] " ") == 0);
        # Resolved at the gate: kept by decision, whatever UUID it used to name.
        else if (f[2] in remap_spec)        keep = 1;
        else                                keep = uuid_kept(line_uuid(line));
        if (substr(f[2], 1, 1) == "/") mp_kept[f[2]] = keep;
        next;
    }

    # Binds resolve between the passes, in file order -- authoritative, since
    # mount -a walks fstab in order. Each resolved bind joins the mount table,
    # so a bind riding another bind is judged by the one it rides on.
    FNR == 1 {
        for (mp in was_disabled) if (!(mp in mp_kept)) mp_kept[mp] = 0;
        for (i = 1; i <= nbind; i++) {
            split(binds[i], b, SUBSEP);
            bind_kept[b[2]] = mp_kept[nearest_mount(b[1])];
            mp_kept[b[2]] = bind_kept[b[2]];
        }
    }

    # A line brought back at the gate: strip the marker(s) and let the body
    # below judge it as live. $0 is rewritten, so the comment rules under this
    # one no longer match it.
    {
        rev = revive($0, 2);
        if (rev != "") {
            $0 = rev;
            if ($4 ~ /(^|,)bind(,|$)/) note("enable", $2, "bind on " nearest_mount($1));
            else if ($3 == "swap")     note("enable", $1, "swap file on " nearest_mount($1));
            else                       note("enable", $2, "");
        }
    }

    # Lines disabled by a previous run: never re-prefix them (collapse any
    # stacked markers left by older versions), and drop disabled swap entries
    # once a live swap entry is being written below -- otherwise every
    # re-mkswap sync leaves one more dead line behind.
    /^# \[PORTABLE-SYNC-DISABLED\] / {
        payload = $0;
        while (sub(/^# \[PORTABLE-SYNC-DISABLED\] /, "", payload)) { }
        # A comment under the marker was never a mount: an older version
        # tagged the Ubuntu header for mentioning "UUID=". Give it back, so a
        # file damaged that way heals on the next sync.
        if (payload ~ /^[[:space:]]*#/) { print payload; next; }
        split(payload, f);
        if (new_swap != "" && f[3] == "swap") next;
        print "# [PORTABLE-SYNC-DISABLED] " payload;
        next;
    }

    # Comments are prose, not mounts -- and the Ubuntu header mentions "UUID=",
    # which the disabler below would otherwise tag on every sync.
    /^[[:space:]]*#/ { print; next }

    {
        # /boot lives inside / here, so an inherited /boot entry names a
        # filesystem that does not exist. Disable it BEFORE the translation
        # below, which would rewrite it into "mount / at /boot".
        if (!sep_boot && $2 == "/boot") {
            note("boot", $2, "");
            print "# [PORTABLE-SYNC-DISABLED] " $0;
            next;
        }

        gsub(old_efi, new_efi);
        if (map_boot) gsub(old_boot, new_boot);
        gsub(old_root, new_root);

        # Resolved at the gate: point it at the chosen filesystem and keep it.
        # Its binds and swap file need no case here -- pass 1 marked this mount
        # kept, which is all either of them is judged by.
        if ($2 in remap_spec) {
            $0 = retarget($0, remap_spec[$2]);
            note("remap", $2, remap_plain[$2]);
            print $0;
            next;
        }

        # A separate /boot the source did not have: insert its entry right
        # after "/". Never at the end -- mount -a walks fstab in order, and a
        # /boot line after /boot/efi would mount the ESP onto a bare directory.
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

        # A swap file is worth what carries it, the rule binds already follow:
        # under a disabled mount it is unreachable and swapon -a fails at boot.
        # Only a carrier pass 1 judged counts; an unrecognised one is left alone.
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

    report_fstab_retargets "$FSTAB_REPORT"
    report_fstab_disables "$FSTAB_REPORT"
    if [ -n "$FSTAB_REPORT_DIR" ]; then rm -rf "$FSTAB_REPORT_DIR"; fi
    FSTAB_REPORT=""
    FSTAB_REPORT_DIR=""
}

# probe_target_brand — the brand already stamped into the target root's
#   GRUB_DISTRIBUTOR, read through a transient read-only mount on MNT before
#   rsync overwrites the file. Sets TGT_MODEL (empty if the mount fails or the
#   "Desktop <brand> `( ." pattern is absent). Runs under --dry-run too, so the
#   summary can show the brand it would keep.
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
#   before the gate so the summary can say whose entries this run keeps and
#   verify_install() can prove afterwards that it did. Skipped when the ESP is
#   about to be formatted, silent when it cannot be mounted. The ESP goes on MNT
#   (free at this point), so its grub directory is $MNT/boot/grub here, not the
#   /boot/efi/boot/grub it becomes once the root is mounted. Fills
#   ESP_MENU_ENTRIES ("<uuid><TAB><title>"), ESP_MENU_PROBED, and ESP_MEMTEST --
#   which tells "this run adds the tester" from "it is already there".
probe_esp_menu() {
    ESP_MENU_ENTRIES=(); ESP_MENU_PROBED=0; ESP_MEMTEST=0
    local row
    [ -b "$TGT_EFI" ] || return 0
    MOUNTS_DONE=1   # from here on cleanup() must sweep $MNT, interrupts included
    sudo mount -r "$TGT_EFI" "$MNT" 2>/dev/null || return 0
    ESP_MENU_PROBED=1
    [ ! -f "$MNT/boot/grub/memtest/$MEMTEST_IMAGE" ] || ESP_MEMTEST=1
    while IFS= read -r row; do
        [ -n "$row" ] && ESP_MENU_ENTRIES+=("$row")
    done < <(esp_entries "$MNT/boot/grub")
    sudo umount "$MNT" || true
}

# probe_menu_cmdline — the kernel command line the menu entry will carry, for
#   the summary. Same transient mount, on whichever root is the authority: the
#   source's /etc/default/grub when its rootfs is copied (it lands verbatim),
#   the target's own when the root is in place. Free when
#   probe_source_swapfiles() already filled it in.
probe_menu_cmdline() {
    [ -z "$MENU_CMDLINE_PREVIEW" ] || return 0
    local dev="$TGT_ROOT"
    [ "$MIGRATE_ROOT" -eq 0 ] || dev="$SRC_ROOT"
    [ -b "$dev" ] || return 0
    MOUNTS_DONE=1
    sudo mount -r -o noatime "$dev" "$MNT" 2>/dev/null || return 0
    MENU_CMDLINE_PREVIEW=$(grub_cmdline_options "$MNT")
    probe_memtest "$MNT"
    sudo umount "$MNT" || true
}

# probe_memtest <mounted-root> — off an already-mounted root: whether that
#   system carries the tester image, and whether it asks for the entry to be
#   left out. MEMTEST_PROBED stays 0 when no root could be read, so the summary
#   says so rather than promising an entry it never checked.
probe_memtest() {
    MEMTEST_SRC=0; [ ! -f "$1/boot/$MEMTEST_IMAGE" ] || MEMTEST_SRC=1
    MEMTEST_OFF=0
    [ "$(grub_default_value "$1/etc/default/grub" GRUB_DISABLE_MEMTEST)" != true ] || MEMTEST_OFF=1
    MEMTEST_PROBED=1
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
# GRUB's boot directory lives on the ESP (/boot/efi/boot/grub), not on any
# rootfs: grub-install is told --boot-directory=/boot/efi/boot for BOTH i386-pc
# and x86_64-efi, so both resolve one prefix and read one menu. That is what
# lets a disk carry a rootfs per machine behind a single ESP -- the menu belongs
# to the disk, not to whichever system was installed last. Layout:
#
#   /boot/efi/boot/grub/grub.cfg              master menu, regenerated per run
#   /boot/efi/boot/grub/entries/<uuid>.cfg    one file per registered rootfs
#   /boot/efi/boot/grub/memtest/mt86+x64      the memory tester, one per disk
#   /boot/efi/boot/grub/custom.cfg            optional, hand-written, sourced last
#   /boot/efi/boot/grub/{x86_64-efi,i386-pc}/ modules, written by grub-install
#
# An install owns exactly one entry file -- named after the root filesystem it
# just wrote -- and never edits another system's. The master is rebuilt from
# whatever entry files are present, so registering, re-branding or (by deleting
# a file) retiring a system is a local operation.
#
# The memory tester belongs to no rootfs at all, so it lives on the ESP beside
# the menu that offers it. The same x64 image boots through GRUB's "linux"
# command on both firmware paths, so Ubuntu's four-way $grub_platform/cpuid
# block exists only to choose between it and mt86+ia32 -- a choice a toolkit
# deploying amd64 never has to make.
MEMTEST_IMAGE=mt86+x64
MEMTEST_TITLE="Memory test (memtest86+)"

# grub_default_value <file> <KEY> — the last KEY="..." (or '...') assignment in
#   an /etc/default/grub-style file. Read, never sourced: it is the target's
#   file, not ours to execute.
grub_default_value() {
    sed -nE "s/^[[:space:]]*$2=\"(.*)\"[[:space:]]*\$/\\1/p;
             s/^[[:space:]]*$2='(.*)'[[:space:]]*\$/\\1/p" "$1" 2>/dev/null | tail -n 1
}

# grub_cmdline_options <mounted-root> — that system's boot options, composed as
#   update-grub does: GRUB_CMDLINE_LINUX then GRUB_CMDLINE_LINUX_DEFAULT from
#   its OWN /etc/default/grub, so each rootfs keeps the quirks its machine needs.
#   root= is stripped -- not an option to carry over but a fact about the
#   filesystem just written, restated by esp_cmdline_from().
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
#   GUI/TTY pair, keyed to the filesystem holding /boot (NEW_UUID_BOOT -- the
#   /boot partition when there is one, else the root filesystem), with the
#   kernel path to match. No gfxpayload: the menu loads no video driver, so
#   GRUB sets no mode and the firmware hands its own console mode straight
#   through to the kernel -- which is what keeps the early boot visible.
esp_entry_text() {
    local title=$1 cmdline=$2 kdir=$3
    cat <<EOF
# Written by install.sh -- one file per rootfs registered on this ESP.
# Root filesystem $NEW_UUID_ROOT on $TGT_ROOT; kernel read from $NEW_UUID_BOOT.
# Deleting this file retires the system from the menu; nothing else refers to it.
menuentry "GUI $title" {
    search --no-floppy --fs-uuid --set=root $NEW_UUID_BOOT
    linux $kdir/vmlinuz $cmdline
    initrd $kdir/initrd.img
}

menuentry "TTY $title" {
    search --no-floppy --fs-uuid --set=root $NEW_UUID_BOOT
    linux $kdir/vmlinuz $cmdline systemd.unit=multi-user.target
    initrd $kdir/initrd.img
}
EOF
}

# esp_master_text <grubdir> — the master menu, rebuilt from the entry files
#   present. timeout/default are carried over from the master already there (5
#   and 0 only when writing one from scratch), so the last system installed
#   never redefines the menu for the others. Every source line is guarded, so an
#   entry file deleted by hand retires that system instead of breaking the menu.
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
    # Driven by what is on the ESP, not by what this source had: a slot
    # installed from a system without memtest86+ must not drop the disk's entry.
    # $prefix carries its own device, so no search and no ESP UUID are needed.
    if [ -f "$grubdir/memtest/$MEMTEST_IMAGE" ]; then
        printf '%s\n' \
            "" \
            "# The memory tester: shared by the disk, like the menu itself." \
            "if [ -f \$prefix/memtest/$MEMTEST_IMAGE ]; then" \
            "    menuentry \"$MEMTEST_TITLE\" --class memtest {" \
            "        # The only video driver this menu loads, and only when" \
            "        # the tester is chosen. It needs a framebuffer -- under" \
            "        # UEFI there is no VGA text mode to fall back on and it" \
            "        # stops with \"No graphics display found\" without one --" \
            "        # while the menu itself must not touch video at all: a" \
            "        # ThinkPad T450s displays nothing GRUB draws into the" \
            "        # framebuffer efi_gop reports, leaving the menu live," \
            "        # navigable and invisible. all_video resolves to efi_gop" \
            "        # on one path and vbe/vga on the other." \
            "        insmod all_video" \
            "        # memtest86+ draws a fixed 640x400 panel and never scales" \
            "        # it, so ask for the smallest mode that holds it instead of" \
            "        # gfxterm's. \"keep\" is the fallback where 640x480 is not" \
            "        # offered: under UEFI there must be SOME framebuffer." \
            "        set gfxpayload=640x480,keep" \
            "        linux \$prefix/memtest/$MEMTEST_IMAGE" \
            "    }" \
            "fi"
    fi
    printf '\n%s\n' 'if [ -f $prefix/custom.cfg ]; then source $prefix/custom.cfg; fi'
}

# sync_esp_memtest <grubdir> — put the memtest86+ image on the ESP, beside the
#   menu that offers it. It comes from the target's own freshly-synced /boot
#   (mounted at $MNT/boot in either layout), so a source without the package
#   simply gets no entry -- this toolkit ships no binaries.
#   GRUB_DISABLE_MEMTEST=true turns it off, the knob Ubuntu's 20_memtest86+ reads.
#   It ADDS or REFRESHES, never removes: the ESP is shared, so a slot that does
#   not want the tester must not unregister it for the slots that do. Retiring it
#   disk-wide is "rm -rf boot/grub/memtest", as deleting an entry file retires a
#   system.
sync_esp_memtest() {
    local grubdir=$1 img="$MNT/boot/$MEMTEST_IMAGE"
    if [ "$(grub_default_value "$MNT/etc/default/grub" GRUB_DISABLE_MEMTEST)" = true ]; then
        info "GRUB_DISABLE_MEMTEST=true: not installing memtest (any image already on the ESP is left alone)."
        return 0
    fi
    [ -f "$img" ] || return 0
    info "Copying $MEMTEST_IMAGE onto the ESP for the \"$MEMTEST_TITLE\" entry..."
    sudo mkdir -p "$grubdir/memtest"
    # cp, not "install -m": install fchmod()s, and vfat rejects a mode its
    # mount options did not grant. The ESP carries no modes of its own.
    sudo cp "$img" "$grubdir/memtest/$MEMTEST_IMAGE"
}

# write_esp_menu — register this system in the shared menu, after
#   run_chroot_block() has put grub-install's modules there. Reads MNT,
#   TGT_MODEL, TGT_ROOT, TGT_SEP_BOOT, NEW_UUID_ROOT/_BOOT and (under
#   --dry-run, where the ESP is not mounted) MENU_CMDLINE_PREVIEW.
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
        if [ "$MEMTEST_OFF" -eq 1 ]; then
            echo "    (no \"$MEMTEST_TITLE\" entry: GRUB_DISABLE_MEMTEST=true)"
        elif [ "$MEMTEST_SRC" -eq 1 ] || [ "$ESP_MEMTEST" -eq 1 ]; then
            echo "    plus \"$MEMTEST_TITLE\" -> \$prefix/memtest/$MEMTEST_IMAGE"
        fi
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
    # Before the master is built, since the master offers the entry only when the
    # image is really there.
    sync_esp_memtest "$grubdir"
    # Build the master before truncating it: it carries over its own timeout.
    master=$(esp_master_text "$grubdir")
    printf '%s\n' "$master" | sudo tee "$grubdir/grub.cfg" >/dev/null
}

run_chroot_block() {
    for i in /dev /dev/pts /proc /sys /run; do
        sudo mount --bind "$i" "$MNT$i"
    done

    # INSTALL_GRUB_BIOS/_EFI default to 1; install.sh gates BIOS on a BIOS
    # target being given, and the caller resolves TGT_GRUB_DISK.
    # --boot-directory=/boot/efi/boot puts GRUB's boot directory on the ESP for
    # BOTH firmware paths, so one prefix and one menu serve BIOS and UEFI and
    # belong to the disk rather than to this rootfs. No routing stub is needed:
    # grub-install embeds a device-relative prefix, which is why such an ESP
    # holds EFI/BOOT/BOOTX64.EFI and no EFI/BOOT/grub.cfg.
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

# GRUB reads the menu on the ESP, written by write_esp_menu() after this
# chroot. This regenerates the rootfs's own /boot/grub/grub.cfg, which nothing
# boots from but which keeps the system self-describing (and is what a rescue
# "configfile" would find).
echo "=> Regenerating the rootfs menu..."
update-grub

echo "=> Rebuilding initramfs..."
update-initramfs -u -k all

echo "=> Exiting chroot."
EOF
}

# verify_install — post-install checks on the still-mounted target tree: fstab
#   and grub.cfg must name the new UUIDs and not the old, the ESP must carry
#   GRUB's boot directory with this system registered, and every system already
#   registered there must still be. Catches a broken configuration while the
#   disk is on the desk rather than at boot on another machine. Reads MNT,
#   *_SEP_BOOT, ESP_MENU_ENTRIES, INSTALL_GRUB_BIOS, the UUID pairs, SWAP_DEV.
#   Non-zero if any check failed.
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
    # Same, but blind to comments: a /boot entry inherited from the source and
    # disabled by rewrite_fstab() legitimately still carries the old UUID.
    absent_active() {
        ! sudo awk -v s="$1" '$0 !~ /^[[:space:]]*#/ && index($0, s) > 0 { found = 1 }
                              END { exit !found }' "$2"
    }
    no_boot_entry() { ! fstab_mounts_boot "$1"; }
    root_label_is() { [ "$(sudo blkid -c /dev/null -s LABEL -o value "$1")" = "$2" ]; }

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
    # update-grub prefixes its entries with a search for the filesystem holding
    # /boot: the root UUID (checked above) unless /boot is separate.
    if [ "$TGT_SEP_BOOT" -eq 1 ]; then
        vcheck "grub.cfg searches the /boot filesystem" \
            sudo grep -qF "$NEW_UUID_BOOT" "$MNT/boot/grub/grub.cfg"
    fi
    [ "$OLD_UUID_ROOT" = "$NEW_UUID_ROOT" ] || \
        vcheck "grub.cfg carries no stale root UUID" absent "$OLD_UUID_ROOT" "$MNT/boot/grub/grub.cfg"

    vcheck "EFI fallback loader present (EFI/BOOT/BOOTX64.EFI)" \
        sudo test -f "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"

    # The standalone ESP: GRUB's boot directory, its menu, and this system's
    # entry. No routing stub to check -- the prefix is embedded in the image.
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
    # Only when the image is really there: an ESP that never got one is
    # entitled to a menu without the entry.
    if sudo test -f "$espgrub/memtest/$MEMTEST_IMAGE"; then
        vcheck "the ESP menu offers \"$MEMTEST_TITLE\"" \
            sudo grep -qF "memtest/$MEMTEST_IMAGE" "$espgrub/grub.cfg"
    fi
    # Every other system on this ESP must still be registered: rebuilding the
    # shared master is the one step that could quietly unregister the machines
    # this install was not about.
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
    # Proves the /boot content landed: the one thing a layout change can
    # silently lose, and the backstop for a source that hides /boot in some way
    # the Phase 3 fstab check cannot see (an unlisted mount, a bind).
    vcheck "a kernel image is present under /boot" \
        sudo sh -c 'ls "$1"/boot/vmlinuz-* >/dev/null 2>&1' _ "$MNT"
    # Only when a label was asked for: an --update onto a disk this toolkit
    # never labelled is entitled to whatever it carries.
    if [ -n "$TGT_ROOT_LABEL" ]; then
        vcheck "the root filesystem is labelled \"$ROOT_LABEL\"" \
            root_label_is "$TGT_ROOT" "$ROOT_LABEL"
    fi

    # The mounts resolved at the gate: live in the target's fstab, naming the
    # chosen filesystem, with every revived line live too. The one part of the
    # fstab the operator answered a question about.
    local rmp
    for rmp in ${REMAP_MPS[@]+"${REMAP_MPS[@]}"}; do
        [ -n "${REMAP_SPEC[$rmp]:-}" ] || continue
        vcheck "fstab mounts $rmp from ${REMAP_SPEC[$rmp]}" \
            fstab_mounts_from "$rmp" "${REMAP_SPEC[$rmp]}" "$MNT/etc/fstab"
    done
    for rmp in ${REMAP_ENABLE[@]+"${REMAP_ENABLE[@]}"}; do
        vcheck "fstab entry for $rmp is live again" \
            fstab_live_entry "$rmp" "$MNT/etc/fstab"
    done

    local sf
    for sf in "${SWAPFILES_REBUILT[@]}"; do
        vcheck "swap file $sf is fully allocated and formatted" \
            swapfile_ok "$MNT${SWAPFILE_REAL[$sf]:-$sf}"
    done
    for sf in "${SWAPFILES_DROPPED[@]}"; do
        vcheck "dropped swap file $sf is absent from the target" \
            sudo test ! -e "$MNT${SWAPFILE_REAL[$sf]:-$sf}"
        vcheck "dropped swap file $sf is disabled in fstab" \
            fstab_disabled "$sf" "$MNT/etc/fstab"
    done

    # Dropped by hiding, not excluding, so --update's --delete takes the stale
    # copy too. An --exclude would silently leave it in place; prove it did not.
    local cache_path
    for cache_path in ${CACHE_DROPS[@]+"${CACHE_DROPS[@]}"}; do
        vcheck "dropped cache $cache_path is absent from the target" \
            sudo test ! -e "$MNT$cache_path"
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
# Empty = the root filesystem is labelled "root"; --target-root-label overrides
# it. ROOT_LABEL is the resolved label and is never empty -- it reaches
# mkfs.ext4 -L / e2label, which would otherwise clear the label.
TGT_ROOT_LABEL="${TGT_ROOT_LABEL:-}"
ROOT_LABEL=root
DRY_RUN=0
UPDATE=0
NO_TRIM=0
# Keep the ESP's filesystem: no mkfs, no new UUID. What a shared ESP needs; its
# contents are written by grub-install and write_esp_menu on every run anyway.
KEEP_EFI=0
# Copy the regenerable browser caches like any other data instead of dropping
# them (--keep-cache). See CACHE_DROP_NAMES.
KEEP_CACHE=0
SPARSE=0
ASSUME_YES=0
MNT_AUTO=0
SRC_AUTO=0
LOOP_ATTACHED=0
MOUNTS_DONE=0
CLEANED=0
# "This target keeps /boot inside /", said explicitly (see --no-target-boot).
NO_TGT_BOOT=0

# The systems already in the shared ESP menu, the boot options this entry will
# carry, whether the memory tester is on the disk already or comes with this
# run, and the UUIDs verify_install needs before they exist.
ESP_MENU_ENTRIES=()
ESP_MENU_PROBED=0
ESP_MEMTEST=0
MEMTEST_SRC=0
MEMTEST_OFF=0
MEMTEST_PROBED=0
MENU_CMDLINE_PREVIEW=""
NEW_UUID_ROOT=""

# Swap files listed in the source's fstab: to rebuild, dropped by --exclude-from,
# actually rebuilt (verified later), and the rsync exclusions for all of them.
SWAPFILES=()
SWAPFILES_DROPPED=()
SWAPFILES_REBUILT=()
SWAP_EXCLUDES=()
declare -A SWAPFILE_TGT_SIZE=()
declare -A SWAPFILE_REAL=()
# What the pre-confirmation probe found: "<path> <bytes|?> <keep|drop>" per swap
# file, and whether the probe managed to read the source's fstab at all.
SWAP_PREVIEW=()
SWAP_PROBED=0

# The source's mount layout (fstab_mount_table), the caches this run drops (as
# probed, as resolved in Phase 3, and the rsync rules that do it), and the
# --exclude-from rules that cannot match the transfer.
FSTAB_TABLE=""
CACHE_PREVIEW=()
CACHE_PROBED=0
CACHE_DROPS=()
CACHE_FILTERS=()
EXCLUDE_AUDIT=()
EXCLUDE_PROBED=0

# Mounts resolved at install time instead of being disabled: what --remap
# answered, what the operator chose at the gate, what the discovery pass found.
# All keyed by MOUNT POINT, the one field a foreign entry and its replacement
# share. REMAP_PROBED is the "was this checked at all" flag -- an empty
# REMAP_MPS is also what "nothing to ask about" looks like.
REMAP_ARGS=()                 # raw --remap arguments, validated after parsing
declare -A REMAP_ARG=()       #   ...into MOUNTPOINT -> spec, or "none"
declare -A REMAP_SPEC=()      # the fstab spec this run writes for that mount
declare -A REMAP_DEV=()       # the device that spec names here, when attached
declare -A REMAP_STATE=()     # live | disabled, in the SOURCE's own fstab
declare -A REMAP_UUID=()      # the UUID the source's entry named, if any
declare -A REMAP_LABEL=()     # the label its candidates have to carry
declare -A REMAP_SPECWAS=()   # the spec the source's entry carried
declare -A REMAP_BINDS=()     # "<live|disabled> <mount point> <source>" rows
declare -A REMAP_SWAPS=()     # "<live|disabled> <fstab path>" rows, one a line
declare -A REMAP_NOTES=()     # what reading the chosen filesystem found
REMAP_MPS=()                  # the remappable mount points, in fstab order
REMAP_ENABLE=()               # mount points whose commented-out lines come back
# Tab-separated, safe only because all four fields are always set: tab is IFS
# *whitespace*, so a run of tabs is one delimiter and an empty field in the
# middle shifts every later field up one. Anything optional added here must go
# last (cf. remap_block_rows, which uses \037 for exactly this reason).
REMAP_SWAP_CREATE=()          # "<fstab path>\t<dev>\t<path on it>\t<bytes>"
REMAP_PROBED=0
REMAP_OPEN_MNT=""             # a filesystem this run mounted to look inside
REMAP_OPEN_PATH=""            # ...and where its contents are readable

# Where rewrite_fstab()'s awk records what it changed, for the reports printed
# right after. Global only so cleanup() can remove the directory if the run ends
# between the mktemp and the rm.
FSTAB_REPORT=""
FSTAB_REPORT_DIR=""

# Nothing to do: show the help rather than marching into Phase 1 and failing on
# the *default* source path. An env-var-only invocation (TARGET=/dev/sdb
# ./install.sh) is "no arguments" to $#, so check the environment too.
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
        --target-root-label) TGT_ROOT_LABEL="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --update)         UPDATE=1; shift ;;
        --no-trim)        NO_TRIM=1; shift ;;
        --sparse)         SPARSE=1; shift ;;
        --keep-cache)     KEEP_CACHE=1; shift ;;
        --remap)          REMAP_ARGS+=("$2"); shift 2 ;;
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
(e2label PART root). "root" is the only label that scan looks for, and
--target-root-label chooses the one this script writes -- so labelling a rootfs
anything else takes it out of the scan for good. A disk carrying one rootfs per
machine behind a shared ESP is exactly that case, and is always addressed
partition by partition.

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
  --exclude-from FILE         Omit the paths listed in FILE from the copy (e.g.
                              an impersonal clone); under --update they are also
                              purged from the target (--delete-excluded). A swap
                              file listed here is dropped, not re-created, and
                              its fstab entry commented out. Paths are paths in
                              the SOURCE'S ROOT FILESYSTEM, so a rule for a
                              directory the source binds in from elsewhere
                              matches nothing -- the summary says which do.
  --keep-cache                Copy the regenerable browser caches instead of
                              dropping them. By default ~/.cache/google-chrome
                              (and -headless) is neither copied nor left on the
                              target: HTTP, compiled-JS and shader caches only,
                              all rebuilt on demand. The profile that matters
                              lives in ~/.config and is copied either way.
  --remap MOUNT=DEVICE        Point the target's fstab entry for MOUNT (/data,
                              say) at DEVICE instead of commenting it out because
                              the filesystem the source named will not be on this
                              disk. Repeatable. DEVICE is a /dev path (written as
                              its UUID), UUID=..., LABEL=... or "none" (leave it
                              alone). Without this an interactive run ASKS, once
                              per such mount, offering the attached filesystems
                              that carry the label the entry expects and
                              defaulting to the one on the target's own disk;
                              --yes or a non-interactive stdin declines to ask.
                              The binds and swap files riding on that mount come
                              back with it, an entry the source has COMMENTED OUT
                              can be revived the same way, and a swap file the
                              chosen filesystem lacks is created there.
  --brand NAME                Brand the GRUB menu title with NAME instead of the
                              target disk's reported model (useful when the medium
                              sits in a USB card reader, whose model string —
                              e.g. "SD Transcend" — says nothing about the card).
                              Without it, --update keeps the brand already stamped
                              into the target's /etc/default/grub, so a brand
                              chosen at install time survives every sync.
  --target-efi-size SIZE      Size of the ESP on a freshly partitioned --target
                              (default 256M). Bare = MiB; k/M/G must come out
                              whole MiB, since root starts where the ESP ends.
                              Rejected with --update or individual --target-*.
  --inodes-root N             Pass N to the root mkfs.ext4 as -N instead of
                              deriving it from the partition size (~4 MiB per
                              inode, floor 1.5M, which an explicit N skips). A
                              k/M suffix multiplies the COUNT, not a size:
                              1572864, 1536k and 1M are the same. Only when the
                              root filesystem is actually formatted.
  --target-root-label LABEL   Label the target's root filesystem LABEL instead
                              of "root" (mkfs.ext4 -L when formatting, e2label
                              under --update; the UUID is untouched). At most 16
                              bytes, "boot" refused (the disk scan skips
                              boot-labelled partitions), and refused outright for
                              an in-place root -- that filesystem is the
                              source's. "root" is the only label the scan looks
                              for, so a rootfs wearing any other must be named
                              with --source-root/--target-root: that is the
                              point, it is what tells a disk's slots apart.
  --sparse                    Add -S to the rsync, re-creating runs of nulls as
                              holes. Off by default: every hole costs an ext4
                              extent, and one 51.8 GiB .vdi measured here gained
                              12,309 of them to save 1.01 GiB (2%) -- a tree deep
                              enough that fsck offers to optimize it. Worth it
                              only for genuinely, largely sparse sources.
  --no-trim                   Skip the closing fstrim. By default the ESP is
                              trimmed on every run (mkfs.fat has no discard) but
                              the ext4 filesystems only under --update -- a fresh
                              mkfs.ext4 already discarded the partition and the
                              rsync only allocates. Trimming keeps flash fast and
                              makes a loop-attached .img sparse (the loop driver
                              punches holes in the backing file).
  --mnt DIR                   Target root mount point  (default: private temp dir)
  --src DIR                   Source root mount point  (default: private temp dir)
  --yes, -y                   Skip the confirmation prompt (for scripted runs)
  --dry-run                   Print destructive commands instead of running
                              them. Read-only probes still run so the summary is
                              accurate rather than guessed (the source's fstab,
                              the target's current GRUB brand): transient
                              read-only mounts, writing nothing.
  -h, --help                  Show this help

Notes:
  * --source-swap (reuse) and --target-swap (reformat) are mutually exclusive
    and cover swap PARTITIONS. A swap FILE needs no option: it is never copied
    (a run of zeros fallocate re-creates for free, and -S would leave it holed,
    which swapon refuses) and is re-created on the target at the source's size.
  * EFI booting uses the EFI System Partition; the BIOS Boot partition is only
    for legacy boot and is regenerated by grub-install (when --target-bios-boot
    is given) or left intact otherwise.
  * GRUB's boot directory lives on the ESP (/boot/efi/boot/grub) for BIOS and
    UEFI alike, so the menu belongs to the disk, not to any one rootfs. Each
    install registers itself in entries/<root-uuid>.cfg and rebuilds the master
    over whatever entry files are present, keeping its timeout/default;
    hand-written extras go in custom.cfg. Deleting an entry file retires that
    system. So one disk can carry a rootfs per machine behind a single ESP:
      $0 --source /dev/sde --target-efi /dev/sde2 --keep-efi \\
         --target-bios-boot /dev/sde1 --target-root /dev/sde5 --brand Laptop
  * That menu also offers "Memory test (memtest86+)" when the source has the
    package installed: /boot/mt86+x64 is copied to memtest/ on the ESP, so the
    tester belongs to the disk too and survives installs of slots without it.
    One entry covers both firmware paths. GRUB_DISABLE_MEMTEST=true keeps an
    install from adding it but never removes one; retiring it disk-wide is
    "rm -rf /boot/efi/boot/grub/memtest".
  * A separate /boot earns its keep on a machine whose BIOS cannot boot from
    NVMe: BIOS Boot, the ESP and /boot go on a disk that BIOS can read, while /
    -- everything the running system actually reads -- stays on the NVMe.
  * A mount the target cannot resolve -- /data on a partition of the source
    machine, say -- is commented out in its fstab, and its binds and swap files
    go with it. Which filesystem the TARGET should use cannot be derived (several
    disks may share a label), so an interactive run asks before the confirmation
    gate and writes the answer in Phase 4. --remap answers in advance, --yes
    declines to ask; nothing is guessed.
  * Instances may run concurrently (flashing several disks from one source).
    Advisory locks under /run/lock guard each disk -- written exclusively, read
    shared -- so a conflicting instance fails fast, before its prompt.

Examples:
  # Full deploy of an image onto a fresh disk (3 partitions: BIOS Boot, ESP, /):
  $0 --image Ubuntu26-Portable-16GB.img --target /dev/sda

  # Deploy from the running machine's own disk, whatever else it carries:
  $0 --source /dev/nvme0n1 --target /dev/sda

  # Add a second machine's rootfs to a disk that already boots one: keep the
  # shared ESP (and register this system in the menu on it), format only sde5,
  # and label it so this disk's slots can be told apart:
  $0 --image Ubuntu26-Portable-16GB.img --keep-efi \\
     --target-bios-boot /dev/sde1 --target-efi /dev/sde2 \\
     --target-root /dev/sde5 --brand Laptop --target-root-label laptop

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

  # Sync onto a portable disk and point /data at that disk's own data partition,
  # so its binds (and its swap file) come back to life instead of being
  # commented out. Interactively this is the question the run asks anyway:
  $0 --source-efi /dev/sda2 --source-root /dev/nvme0n1p1 \\
     --target-efi /dev/sde2 --target-root /dev/sde5 --update \\
     --yes --remap /data=/dev/sde4

  # Impersonal clone: deploy minus the paths listed in exclude-personal.txt:
  $0 --image Ubuntu26-Portable-16GB.img --target /dev/sda \\
     --exclude-from exclude-personal.txt

Most options also read from the matching environment variable (SOURCE, TARGET,
SRC_ROOT, SRC_BOOT, TGT_ROOT, TGT_BOOT, TGT_ROOT_LABEL, TGT_SWAP, EXCLUDE_FROM,
...).
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

# --inodes-root reaches mkfs.ext4 -N, which wants a plain count; a k/M suffix is
# accepted because the useful values look like 1572864. Resolved here so a typo
# fails before any disk is touched. 10# keeps a leading zero from reading octal.
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

# --target-efi-size is a SIZE, not a count: bare = MiB (the unit the GPT layout
# uses), k/M/G otherwise. It must come out whole MiB, since root starts where
# the ESP ends. Validated here so a typo cannot survive until parted has run.
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
        # No hard floor -- mkfs.fat -F32 formats even 1 MiB -- but the GRUB
        # payload needs a few, and that fails only at grub-install, long after
        # the disk is partitioned.
        [ "$n" -ge 16 ] || \
            echo "Warning: a ${n} MiB ESP may be too small for the GRUB EFI payload." >&2
        ESP_MIB=$n
    else
        die "--target-efi-size must be a positive integer, optionally with a k, M or G suffix (e.g. 256, 512M, 1G)."
    fi
fi

# --target-root-label reaches the superblock (mkfs.ext4 -L, or e2label under
# --update). Checked here because mke2fs silently TRUNCATES a label that does
# not fit, and stamping something the caller did not ask for is worse than
# refusing it. Empty means "not given" and leaves the label "root".
if [ -n "$TGT_ROOT_LABEL" ]; then
    # ext4's s_volume_name is 16 bytes with no room for a terminator, so count
    # bytes: ${#var} counts characters, which differ in a UTF-8 locale.
    label_bytes=$(printf %s "$TGT_ROOT_LABEL" | wc -c)
    [ "$label_bytes" -le 16 ] || \
        die "--target-root-label must fit in 16 bytes (the ext4 label field); \"$TGT_ROOT_LABEL\" needs $label_bytes."
    # scan_disk_roles() skips boot-labelled partitions on purpose, so a root
    # filesystem wearing that label would be invisible to every whole-disk scan.
    [ "$TGT_ROOT_LABEL" != boot ] || \
        die "--target-root-label boot is refused: the disk scan skips boot-labelled partitions, so a root filesystem labelled 'boot' could never be found by one again."
    ROOT_LABEL="$TGT_ROOT_LABEL"
fi

# --remap MOUNTPOINT=DEVICE answers before the run asks. Validated here like the
# options above, and resolved to the spec that will be written so the summary
# and the fstab agree. A /dev path becomes its UUID (lsblk, no privilege
# needed); UUID= and LABEL= are written as given, since they may name a
# filesystem that exists only on the machine the target will boot on.
if [ ${#REMAP_ARGS[@]} -gt 0 ]; then
    for remap_arg in "${REMAP_ARGS[@]}"; do
        case "$remap_arg" in
            *=*) ;;
            *) die "--remap wants MOUNTPOINT=DEVICE (e.g. --remap /data=/dev/sde4), got: $remap_arg" ;;
        esac
        remap_mp=${remap_arg%%=*}
        remap_want=${remap_arg#*=}
        [ "${remap_mp#/}" != "$remap_mp" ] || \
            die "--remap mount point must be absolute (e.g. --remap /data=/dev/sde4), got: $remap_mp"
        remap_mp=${remap_mp%/}   # mount points are compared without one
        [ -n "$remap_mp" ] || die "--remap / is refused: the root filesystem is this run's own role."
        case "$remap_mp" in
            /boot|/boot/efi) die "--remap $remap_mp is refused: this script owns that mount (--target-boot / --target-efi decide it)." ;;
        esac
        [ -z "${REMAP_ARG[$remap_mp]+set}" ] || \
            die "--remap $remap_mp given twice: say once what that mount point should be."
        case "$remap_want" in
            none)   # an explicit "leave it": the prompt skips this mount point
                REMAP_ARG[$remap_mp]=none ;;
            UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
                REMAP_ARG[$remap_mp]="$remap_want" ;;
            /dev/*)
                [ -b "$remap_want" ] || \
                    die "--remap $remap_mp=$remap_want: not a block device on this machine. Name it as UUID=... if it only exists on the machine the target will boot on."
                remap_uuid=$(lsblk -dno UUID "$remap_want" 2>/dev/null | xargs || true)
                [ -n "$remap_uuid" ] || \
                    die "--remap $remap_mp=$remap_want: that device carries no filesystem UUID (unformatted?)."
                REMAP_ARG[$remap_mp]="/dev/disk/by-uuid/$remap_uuid" ;;
            *)
                die "--remap $remap_mp=$remap_want: expected a /dev path, UUID=..., LABEL=... or none." ;;
        esac
    done
fi

# Front-load the sudo prompt before anything is acquired, so it cannot fire
# mid-rsync (timestamps are per-tty and expire). A dry run needs it too, for the
# transient ro mounts the summary is built from; an image source in a dry run is
# the one case that needs no root at all, having no loop device to read.
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

# Teardown is trap-driven, so a failure or Ctrl+C releases everything too.
# Flags gate each step to what was actually acquired -- the fake dry-run
# LOOP_DEV never sets LOOP_ATTACHED, and a user-supplied --mnt is unmounted only
# if we mounted onto it.

# Recursively unmount one tree, waiting out stragglers. Ctrl+C kills the rsync
# client at once, but the writer can sit in uninterruptible sleep while the
# kernel flushes dirty pages to a slow target, and the tree stays busy until
# that returns -- so retry rather than leave the target mounted.
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
    # Once teardown starts it must finish: an impatient second Ctrl+C must not
    # abort it halfway and leave the target mounted.
    trap '' HUP INT TERM
    if [ "$MOUNTS_DONE" -eq 1 ]; then
        umount_tree "$SRC" || true
        umount_tree "$MNT" || true
    fi
    remap_close   # a filesystem opened to look inside, or to write a swap file
    if [ "$LOOP_ATTACHED" -eq 1 ]; then
        echo "Detaching loop device: $LOOP_DEV"
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    # rmdir, never rm -rf: failing on a still-mounted/busy dir is the safety net.
    if [ "$MNT_AUTO" -eq 1 ]; then rmdir "$MNT" 2>/dev/null || true; fi
    if [ "$SRC_AUTO" -eq 1 ]; then rmdir "$SRC" 2>/dev/null || true; fi
    if [ -n "${FSTAB_REPORT_DIR:-}" ]; then rm -rf "$FSTAB_REPORT_DIR"; fi
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
# one role. A migrated/synced one names where the data comes FROM as well as
# where it lands, the thing worth checking before a multi-hour transfer; an
# in-place role has only the one device.
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
    # --source-boot names one partition of a scattered source, never the source
    # itself -- which is also what keeps it away from an --image, whose
    # partitions have no names until the loop attach far below.
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
# would silently ignore one or the other. A separate /boot is therefore always
# spelt out partition by partition: a fresh disk gets BIOS Boot + ESP + root.
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
    validate_partition_type "$SRC_EFI" "$GUID_EFI" "Source EFI"
    [ -z "$SRC_BOOT" ] || validate_partition_type "$SRC_BOOT" "$GUID_LINUX" "Source Boot"
    validate_partition_type "$SRC_ROOT" "$GUID_LINUX" "Source Root"
else
    if [ -b "$SOURCE" ]; then
        echo "Source Mode: Unified Block Device ($SOURCE)"
        scan_disk_roles "$SOURCE" SRC
    elif [ -f "$SOURCE" ]; then
        echo "Source Mode: Flat File Image ($SOURCE)"
        if [ "$DRY_RUN" -eq 1 ]; then
            # No loop is attached in a dry run, so parted reads the image's
            # table out of the file itself and the summary still shows its real
            # layout. Name the device the real run would get rather than
            # assuming loop0, which could BE the target.
            LOOP_DEV=$(losetup -f 2>/dev/null) || LOOP_DEV=""
            [ -n "$LOOP_DEV" ] || LOOP_DEV="/dev/loop0"
            # A real run attaches the source after the target is in use, so
            # losetup can never hand it the target's own loop. A dry run has no
            # such protection, and the "target is also a source partition" check
            # would then reject a conflict that cannot happen: step past it.
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
            # Read-only: even an ro ext4 MOUNT writes (journal replay, orphan
            # cleanup), so two instances sharing one image through separate
            # loops would corrupt it. An ro loop refuses every write, and a
            # dirty image then fails loudly instead.
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

# Does the source keep /boot on its own filesystem? --source-boot alone decides;
# no partition table is consulted, and the source's fstab cross-checks it once
# mounted (Phase 3).
if [ -n "$SRC_BOOT" ]; then SRC_SEP_BOOT=1; else SRC_SEP_BOOT=0; fi
if [ $SRC_SEP_BOOT -eq 1 ]; then
    echo "Source /boot: separate partition ($SRC_BOOT)"
else
    echo "Source /boot: inside the root filesystem"
fi

# Old UUIDs from the source, translated into the target's fstab/GRUB later.
# Without a separate /boot, OLD_UUID_BOOT *is* the root UUID: every consumer
# wants "the UUID of the filesystem holding /boot", and an empty one would make
# the awk substitutions match at every character position.
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
    # /boot is the one role NOT defaulted from the source: inheriting it would
    # leave the clone mounting /boot from the SOURCE machine's disk. Neither
    # direction is worth guessing -- converting the layout by accident is how a
    # machine whose BIOS cannot read NVMe stops booting.
    if [ $SRC_SEP_BOOT -eq 1 ] && [ -z "$TGT_BOOT" ] && [ $NO_TGT_BOOT -eq 0 ]; then
        die "The source keeps /boot on its own filesystem ($SRC_BOOT).
Say what the target should do with it:
  --target-boot PART   give this target its own /boot on PART
  --no-target-boot     fold /boot into the target's root filesystem"
    fi
    echo "Target Mode: Scattered Partitions (per-role migrate / in-place)"
    validate_target_roles
else
    # Unified/image source => full deploy, onto a unified device or individual
    # --target-* partitions (--target-efi and --target-root required, the other
    # two optional). No --target-boot means /boot inside /, which is where such
    # a source keeps it anyway.
    if [ -n "$TGT_BIOS" ] || [ -n "$TGT_EFI" ] || [ -n "$TGT_BOOT" ] || [ -n "$TGT_ROOT" ]; then
        [ -n "$TGT_EFI" ]  || die "Scattered target needs --target-efi."
        [ -n "$TGT_ROOT" ] || die "Scattered target needs --target-root."
        echo "Target Mode: Scattered Partitions (full deploy)"
        validate_target_roles
    else
        [ -n "$TARGET" ] || die "Specify a unified --target DEV, --target-efi/--target-root partitions, or scattered --source-* for partial migration."
        if [ "$DRY_RUN" -eq 0 ] && [ ! -b "$TARGET" ]; then
            die "Target '$TARGET' is not a block device."
        fi
        UNIFIED_TARGET=1
        echo "Target Mode: Unified Block Device ($TARGET)"
        P=$(partition_prefix "$TARGET")
        if [ $UPDATE -eq 1 ] && [ -b "$TARGET" ]; then
            # --update keeps the existing layout, so discover it rather than
            # impose one: the ESP and root may sit at any partition number and
            # everything else is left alone -- a separate /boot included, which
            # the scan never adopts, so such a disk is synced by naming its
            # partitions individually.
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
# --target. Anywhere else the ESP exists already: say so rather than ignore it.
if [ -n "$TGT_EFI_SIZE" ] && { [ $UNIFIED_TARGET -eq 0 ] || [ $UPDATE -eq 1 ]; }; then
    die "--target-efi-size only applies when partitioning a fresh --target disk (not with --update or individual --target-* partitions)."
fi

# --keep-efi keeps an ESP that already exists. A fresh unified --target has just
# been repartitioned, so its ESP holds no filesystem to keep.
if [ $KEEP_EFI -eq 1 ] && [ $UNIFIED_TARGET -eq 1 ] && [ $UPDATE -eq 0 ]; then
    die "--keep-efi needs an ESP that already exists; a fresh --target disk is repartitioned here and its ESP must be formatted.
Name the partitions instead (--target-efi ... --target-root ...), or add --update to keep the disk's existing filesystems."
fi

# Does the target keep /boot on its own partition, or inside /?
if [ -n "$TGT_BOOT" ]; then TGT_SEP_BOOT=1; else TGT_SEP_BOOT=0; fi

# Per-role migrate (target differs from source) vs in-place (same device).
# Never feed an absent role's "" to same_dev(): uutils readlink resolves it to
# the working directory, and two of those compare equal -- which is why
# MIGRATE_BOOT is computed only for a target that has a /boot.
if same_dev "$TGT_ROOT" "$SRC_ROOT"; then MIGRATE_ROOT=0; else MIGRATE_ROOT=1; fi

# The ESP is never copied: everything on it -- GRUB's boot directory, the
# modules, the shared menu -- is produced here on every run. So there is nothing
# to migrate, only FORMAT_EFI: whether its filesystem is created. One that is
# already the source's stays as it is, and --keep-efi says so for a shared ESP,
# where a reformat would wipe the other systems' entries and change the UUID
# their fstabs name.
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

# BOOT_PASS: does /boot need a transfer of its own? No only when its filesystem
# is already the target's -- /boot inside / on both sides (the root rsync
# carries it), or the same /boot partition on both. A layout conversion in
# either direction, or two different partitions, needs a pass.
BOOT_PASS=1
if [ $SRC_SEP_BOOT -eq 0 ] && [ $TGT_SEP_BOOT -eq 0 ]; then
    BOOT_PASS=0
elif [ $SRC_SEP_BOOT -eq 1 ] && [ $TGT_SEP_BOOT -eq 1 ] && same_dev "$TGT_BOOT" "$SRC_BOOT"; then
    BOOT_PASS=0
fi

# Bootloader scope: BIOS only when a BIOS target is given; EFI always, since the
# ESP carries GRUB's boot directory and this system's entry has to be registered
# there whatever else the run does. (run_chroot_block also always runs
# update-grub + update-initramfs.)
if [ -n "$TGT_BIOS" ]; then INSTALL_GRUB_BIOS=1; else INSTALL_GRUB_BIOS=0; fi
INSTALL_GRUB_EFI=1

if [ $FORMAT_EFI -eq 0 ] && [ $BOOT_PASS -eq 0 ] && [ $MIGRATE_ROOT -eq 0 ] && [ -z "$SWAP_DEV" ]; then
    die "Nothing to do: every role resolves in-place and no swap was given."
fi

# An in-place root is the source's own filesystem, so relabelling it would
# rename the disk being copied FROM. Refuse rather than ignore, as above.
if [ -n "$TGT_ROOT_LABEL" ] && [ $MIGRATE_ROOT -eq 0 ]; then
    die "--target-root-label needs a root filesystem this run writes, but --target-root ($TGT_ROOT) is the source's own and is left in place."
fi

# An ESP this run does not format must already hold FAT, or Phase 3 fails on
# the mount with the target half-written. --keep-efi, --update and an in-place
# ESP are the same bet.
if [ $FORMAT_EFI -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    fstype=$(sudo blkid -c /dev/null -o value -s TYPE "$TGT_EFI" 2>/dev/null || true)
    if [ -z "$fstype" ]; then
        die "EFI target $TGT_EFI has no recognizable filesystem (unformatted?); drop --keep-efi to create one."
    elif [ "$fstype" != vfat ]; then
        die "EFI target $TGT_EFI has filesystem '$fstype', expected 'vfat'."
    fi
fi

# Under --update nothing is mkfs'd, so catch an unformatted or wrong-type
# target now rather than at a cryptic mount error later.
if [ $UPDATE -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    check_update_fs() {   # <dev> <label> <migrate-flag>
        local fstype
        [ "$3" -eq 1 ] || return 0
        fstype=$(sudo blkid -c /dev/null -o value -s TYPE "$1" 2>/dev/null || true)
        [ -n "$fstype" ] || \
            die "--update: $2 target $1 has no recognizable filesystem (unformatted?)."
        [ "$fstype" = ext4 ] || \
            die "--update: $2 target $1 has filesystem '$fstype', expected 'ext4'."
    }
    check_update_fs "$TGT_BOOT" Boot "$MIGRATE_BOOT"
    check_update_fs "$TGT_ROOT" Root "$MIGRATE_ROOT"
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

# Safety: refuse targets in use. A second mount of a mounted filesystem
# succeeds (it shares the superblock), so the sync would write into one in
# active use -- a disk a desktop session auto-mounted, say. Every target role is
# mounted RW, in-place ones included, so all must be unmounted first.
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
# update-initramfs write into the mounted /boot either way. A fresh unified
# target is keyed on the disk (its partitions may not exist yet), an image
# source on the file.
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
# The menu is branded after the disk the rootfs lives on. --brand wins; failing
# that, --update keeps the brand already in the target's /etc/default/grub, so
# one chosen at install time survives every sync; failing that, the disk's model
# -- which can be a card reader's name, hence --brand. After the locks: the
# probe mounts the target root and must not race a concurrent mkfs.
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
    # Often the first real media access (blkid is answered from cache), so a
    # spun-down disk pauses here -- say what we are waiting for.
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
# The source's fstab first: it names the swap files, the caches and the mounts
# to resolve, none of which the summary can guess. Only when the root filesystem
# is really transferred -- an in-place root touches no swap file at all.
if [ $MIGRATE_ROOT -eq 1 ]; then probe_source_swapfiles; fi
# ...then the boot options, if that probe did not already have the source
# mounted, and the systems on the ESP (nothing to read if it is reformatted).
probe_menu_cmdline
if [ $FORMAT_EFI -eq 0 ]; then probe_esp_menu; fi
# What the target partition holds NOW: this system when the filesystem is kept,
# a stranger when it is about to be reformatted -- in which case
# write_esp_menu() retires its menu entry with it rather than advertise a UUID
# that no longer exists.
TGT_ROOT_UUID_NOW=$(sudo blkid -c /dev/null -s UUID -o value "$TGT_ROOT" 2>/dev/null || true)
# ...and the label it wears now, so the summary can say what --target-root-label
# changes it FROM, and so an e2label that would change nothing is skipped.
TGT_ROOT_LABEL_NOW=$(sudo blkid -c /dev/null -s LABEL -o value "$TGT_ROOT" 2>/dev/null || true)

# Everything is known, so put the mounts that would otherwise be commented out
# to the operator: before the summary, which shows the answers, and before the
# gate, which approves them with the rest of the run.
ask_fstab_remap
for remap_mp in "${!REMAP_ARG[@]}"; do
    if [ "$REMAP_PROBED" -eq 1 ] && [ -z "${REMAP_STATE[$remap_mp]:-}" ]; then
        echo "Warning: --remap $remap_mp names a mount point the source's fstab does not carry (or one it already resolves) -- nothing to do for it." >&2
    fi
done

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
    read -r swap_path swap_bytes swap_state swap_real <<<"$swap_entry"
    if [ "$swap_bytes" = "?" ]; then swap_size="size unknown"; else swap_size=$(human_size "$swap_bytes"); fi
    swap_label
    case $swap_state in
        # On a filesystem of its own: neither copied nor re-created. Said out
        # loud because its fstab entry may still go in Phase 4 with its carrier,
        # and a swapless boot is worth knowing about before the gate.
        offroot) echo "LEAVE     file $swap_path is on $swap_real, a filesystem of its own -- not in the transfer" ;;
        drop)    echo "DROP      file $swap_path (excluded by $EXCLUDE_FROM; its fstab entry is disabled)" ;;
        # The carrier was resolved at the gate, so the file is this run's
        # business after all (see the fstab: block below).
        remapkeep) echo "present   file $swap_path is already on $swap_real ($swap_size; nothing to do)" ;;
        remapmake) echo "CREATE    file $swap_path on $swap_real ($swap_size, fallocate + mkswap)" ;;
        remapnone) echo "MISSING   file $swap_path is not created on $swap_real -- swapon -a will fail on the target (the fstab: block below says why)" ;;
        *)       if [ "$swap_real" != "$swap_path" ]; then
                     echo "re-create file $swap_path, which the transfer carries at $swap_real ($swap_size, never copied)"
                 else
                     echo "re-create file $swap_path ($swap_size, never copied)"
                 fi ;;
    esac
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
# fstab: the mounts resolved at install time instead of being left commented out
# -- the carrier, what comes back with it, and what reading the chosen
# filesystem found. A mount left alone says why: "nothing was asked" and
# "nothing to ask about" must not look the same.
if [ $MIGRATE_ROOT -eq 1 ]; then
    if [ "$REMAP_PROBED" -eq 0 ]; then
        summary_row "fstab:" "not checked (the source's fstab could not be read here to look for mounts it cannot resolve)"
        if [ ${#REMAP_ARG[@]} -gt 0 ]; then
            summary_row "" "so --remap is not shown above either; a real run reads the fstab and applies it"
        fi
    elif [ ${#REMAP_MPS[@]} -gt 0 ]; then
        remap_shown=0
        for remap_mp in "${REMAP_MPS[@]}"; do
            if [ $remap_shown -eq 0 ]; then remap_shown=1; remap_lbl="fstab:"; else remap_lbl=""; fi
            remap_with=$(remap_dependants_list "$remap_mp")
            if [ -n "${REMAP_SPEC[$remap_mp]:-}" ]; then
                if [ "${REMAP_STATE[$remap_mp]}" = live ]; then
                    remap_verb="RETARGET"; remap_kept="kept with it"
                else
                    remap_verb="ENABLE  "; remap_kept="live again with it"
                fi
                summary_row "$remap_lbl" "$remap_verb  $remap_mp -> ${REMAP_DEV[$remap_mp]:-${REMAP_SPEC[$remap_mp]}}"
                summary_row "" "  written as ${REMAP_SPEC[$remap_mp]}"
                [ -z "$remap_with" ] || summary_row "" "  $remap_kept: $remap_with"
            elif [ "${REMAP_STATE[$remap_mp]}" = live ]; then
                summary_row "$remap_lbl" "DISABLE   $remap_mp is commented out on the target${remap_with:+, along with $remap_with}"
            else
                summary_row "$remap_lbl" "leave     $remap_mp commented out${remap_with:+, along with $remap_with}"
            fi
            while read -r remap_note_line; do
                [ -n "$remap_note_line" ] || continue
                summary_row "" "  $remap_note_line"
            done <<<"${REMAP_NOTES[$remap_mp]:-}"
        done
    fi
fi
# Cache: the browser caches dropped from the transfer -- and from the target,
# the rule being sender-side only. Named in full, because the transfer sees a
# path in the source's ROOT filesystem, not the ~/.cache a running system shows.
if [ $MIGRATE_ROOT -eq 1 ]; then
    if [ $KEEP_CACHE -eq 1 ]; then
        summary_row "Cache:" "kept (--keep-cache): browser caches are copied like anything else"
    elif [ "$CACHE_PROBED" -eq 0 ]; then
        summary_row "Cache:" "not checked (the source's fstab could not be read here to locate its caches)"
    elif [ ${#CACHE_PREVIEW[@]} -eq 0 ]; then
        summary_row "Cache:" "nothing to drop (no browser cache in the source's root filesystem)"
    else
        cache_shown=0
        for cache_path in "${CACHE_PREVIEW[@]}"; do
            if [ $cache_shown -eq 0 ]; then cache_shown=1; summary_row "Cache:" "DROP $cache_path"
            else summary_row "" "DROP $cache_path"; fi
        done
        summary_row "" "(regenerable; never copied, and removed from the target if present)"
    fi
fi
echo "  Menu:     GRUB title branded \"$TGT_MODEL\" ($BRAND_ORIGIN)"
# The entry this run registers, the systems already there that it keeps, and the
# command line it will boot: the three things a shared ESP must not be guessed at.
summary_row "" "entry \"GUI $TGT_MODEL\" / \"TTY $TGT_MODEL\" in the ESP menu"
summary_row "" "boots $(esp_cmdline_from "${MENU_CMDLINE_PREVIEW:-<options from /etc/default/grub, read at install time>}")"
# The tester belongs to the disk, not this rootfs, so what happens to it depends
# on the source AND on what the ESP already carries.
if [ "$MEMTEST_PROBED" -eq 0 ]; then
    summary_row "" "memtest: not checked (no root could be read here to look for /boot/$MEMTEST_IMAGE)"
elif [ "$MEMTEST_OFF" -eq 1 ] && [ "$ESP_MEMTEST" -eq 1 ]; then
    summary_row "" "GRUB_DISABLE_MEMTEST=true, but the image already on the ESP is left alone -- so \"$MEMTEST_TITLE\" stays in the menu"
elif [ "$MEMTEST_OFF" -eq 1 ]; then
    summary_row "" "no \"$MEMTEST_TITLE\" (GRUB_DISABLE_MEMTEST=true)"
elif [ "$MEMTEST_SRC" -eq 1 ]; then
    summary_row "" "plus \"$MEMTEST_TITLE\" ($MEMTEST_IMAGE, copied to the ESP)"
elif [ "$ESP_MEMTEST" -eq 1 ]; then
    summary_row "" "plus \"$MEMTEST_TITLE\", already on the ESP (this source has no image to refresh it with)"
else
    summary_row "" "no \"$MEMTEST_TITLE\": the source has no /boot/$MEMTEST_IMAGE (apt install memtest86+ to get one)"
fi
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
if [ -n "$TGT_ROOT_LABEL" ]; then
    if [ $UPDATE -eq 0 ]; then
        summary_row "Label:" "root mkfs -L $ROOT_LABEL (--target-root-label override)"
    elif [ "$TGT_ROOT_LABEL_NOW" = "$ROOT_LABEL" ]; then
        summary_row "Label:" "root filesystem already labelled \"$ROOT_LABEL\" (--target-root-label: nothing to do)"
    else
        summary_row "Label:" "relabel the root filesystem \"${TGT_ROOT_LABEL_NOW:-<none>}\" -> \"$ROOT_LABEL\" (e2label; --update keeps the filesystem)"
    fi
    # The consequence a reader must not have to work out: this rootfs has left
    # the set a whole-disk scan can resolve.
    [ "$ROOT_LABEL" = root ] || summary_row "" \
        "not \"root\", so a whole-disk --source/--target will no longer find it: name this partition with --source-root/--target-root"
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
    report_exclude_audit
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
    # No /boot partition: root and a /boot get the same ext4 feature set and
    # GRUB reads both, so one buys nothing on a disk that boots its own root.
    # A target that needs one names existing partitions (--target-boot).
    run sudo parted -s "$TARGET" mkpart primary ext4 "${ESP_END}MiB" 100%
    # Wait for OUR nodes, not the global udev queue a concurrent instance can
    # keep busy past the settle timeout.
    run sudo udevadm wait --timeout=30 "$TGT_BIOS" "$TGT_EFI" "$TGT_ROOT"
fi

# ---- Format the migrated roles ----
# Skipped under --update, which keeps each filesystem and rsyncs --delete onto
# it -- all but the root LABEL, the one piece of metadata --target-root-label
# still stamps on a kept filesystem. (--target-swap is an explicit opt-in and is
# still honoured below.)
if [ $UPDATE -eq 0 ]; then
    if [ $FORMAT_EFI -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_EFI"
        run sudo mkfs.fat -F32 -n EFI "$TGT_EFI"
    fi
    if [ $MIGRATE_BOOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_BOOT"
        # A /boot holds a few dozen large files, so its inode table wants to
        # be dense (-i 32768) where the rootfs wants the opposite;
        # sparse_super2 because GRUB's own drivers must read it.
        run sudo mkfs.ext4 -vF -L boot -i 32768 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$TGT_BOOT"
    fi
    if [ $MIGRATE_ROOT -eq 1 ]; then
        run sudo wipefs -q -a "$TGT_ROOT"

        if [ -n "$INODES_ROOT" ]; then
            # Pinned by the caller: taken at face value, no floor imposed.
            TARGET_INODES="$INODES_ROOT"
            info "Root inode count pinned by --inodes-root: $TARGET_INODES"
        else
            TGT_BYTES=$(lsblk -dbno SIZE "$TGT_ROOT" 2>/dev/null) || TGT_BYTES=""
            if [ -z "$TGT_BYTES" ]; then
                # Only a dry run may proceed without a size (the node may not
                # exist yet); a real run must not fabricate an inode count.
                [ "$DRY_RUN" -eq 1 ] || die "Cannot determine size of $TGT_ROOT"
                TGT_BYTES=$((16 * 1024**3))
            fi
            ROOT_BYTES_PER_INODE=$(( 1024**4 / (4 * 1024**2) ))
            CALC_INODES=$(( TGT_BYTES / ROOT_BYTES_PER_INODE ))
            MIN_INODES=$(( 1024**2 )) # 1M inodes minimum
            TARGET_INODES=$(( CALC_INODES < MIN_INODES ? MIN_INODES : CALC_INODES ))
        fi

        run sudo mkfs.ext4 -vF -m 0 -L "$ROOT_LABEL" -N "$TARGET_INODES" -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 "$TGT_ROOT"
    fi
elif [ -n "$TGT_ROOT_LABEL" ] && [ "$TGT_ROOT_LABEL_NOW" != "$ROOT_LABEL" ]; then
    # No mkfs under --update, so this is where a kept root filesystem gets its
    # label. Here rather than Phase 3 because the partition is not mounted yet;
    # e2label leaves the UUID alone, so nothing verified later is affected.
    info "Relabelling $TGT_ROOT: \"${TGT_ROOT_LABEL_NOW:-<none>}\" -> \"$ROOT_LABEL\""
    run sudo e2label "$TGT_ROOT" "$ROOT_LABEL"
fi
if [ "$DO_MKSWAP" -eq 1 ]; then
    run sudo wipefs -q -a "$SWAP_DEV"
    run sudo mkswap -q "$SWAP_DEV"
fi

# ---- New UUIDs: fresh for migrated roles, unchanged for in-place ----
# NEW_UUID_BOOT is "the UUID of the filesystem holding /boot", so without a
# separate partition it is the root UUID -- exactly what the ESP menu entry must
# search for to find the kernel.
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
    # Refuse to stack over an existing mount: a leftover tree from a crashed
    # run must be cleaned up, not silently shadowed.
    if findmnt -n "$MNT" >/dev/null 2>&1; then die "$MNT is already a mountpoint."; fi
    if findmnt -n "$SRC" >/dev/null 2>&1; then die "$SRC is already a mountpoint."; fi
fi

# Every command below goes through run(), so a dry run prints the exact mount
# and rsync command lines: the assembled option set is the thing worth reviewing
# before a multi-hour transfer.

# Mount the target tree (the partitions the installed system will use).
run sudo mkdir -p "$MNT"
# Only a real run has trees to tear down; a dry run mounts nothing, so cleanup()
# must not go unmounting $MNT/$SRC afterwards.
if [ "$DRY_RUN" -eq 0 ]; then MOUNTS_DONE=1; fi
run sudo mount "$TGT_ROOT" "$MNT"
# Without a separate /boot, $MNT/boot is just a directory -- but $MNT/boot/efi
# must be created on whichever filesystem ends up carrying it, so the /boot
# mount goes between the two mkdirs.
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
# copied; its own fstab is the authority, whatever the partition table says.
# Wrong in either direction transfers nothing useful: an unnamed separate /boot
# leaves the target with no kernel, and a --source-boot the source does not use
# would be mounted over the real /boot and ship an empty one. The fstab is on
# the root filesystem, so this runs before $SRC_BOOT is mounted -- and only a
# real run has a mounted source to read.
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
# $SRC is the bare mount point of the source root. Only the /boot pass needs it
# -- the ESP is generated on the target, never read from the source -- and an
# in-place /boot never gets a pass, so this is always a real read-only mount.
if [ $SRC_SEP_BOOT -eq 1 ] && [ $BOOT_PASS -eq 1 ]; then
    run sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot" || \
        die "Cannot mount source /boot $SRC_BOOT read-only (dirty journal? run e2fsck on it once and retry)."
fi

# Base rsync options.
#   --inplace rewrites changed files in place instead of building a temp copy
#     and renaming: a changed 50 GB VM image would otherwise need 50 GB free
#     mid-transfer. An interrupted transfer leaves such a file half-updated;
#     the next --update repairs it. (-S with --inplace needs rsync >= 3.1.3.)
#   --delete only under --update, which refreshes an existing clone; a plain
#     migrate writes onto a freshly-formatted target.
#   --exclude-from applies to every transfer, anchored to each transfer root,
#     so the personal "/..." paths only match during the root rsync;
#     --delete-excluded joins it under --update so those paths are PURGED from
#     the target rather than protected from --delete.
#   -S is deliberately absent -- see --sparse. Every hole costs an ext4 extent:
#     one 51.8 GiB .vdi measured here bought back 1.01 GiB (2%) for ~11,900
#     extents, deepening the tree by a level. Writing the nulls out costs a few
#     percent more I/O and reads back faster.
RSYNC_OPTS=(-ahHAX --inplace --numeric-ids -x --verbose)
if [ $SPARSE -eq 1 ]; then RSYNC_OPTS+=(-S); fi
if [ $UPDATE -eq 1 ]; then
    RSYNC_OPTS+=(--delete)
    if [ -n "$EXCLUDE_FROM" ]; then RSYNC_OPTS+=(--delete-excluded); fi
fi
if [ -n "$EXCLUDE_FROM" ]; then RSYNC_OPTS+=(--exclude-from="$EXCLUDE_FROM"); fi

# Keep the root transfer off /boot whenever /boot is a filesystem of its own on
# either side -- one that gets a pass below, or an in-place one. Two rules, not
# one: "- /boot/" hides it from the sender, and the receiver-side "P /boot/" is
# what stops --delete emptying the target's /boot (a plain exclude would not:
# --delete-excluded demotes unqualified rules to sender-side only). With /boot
# inside / on both sides it simply rides along with the root transfer.
BOOT_FILTERS=()
if [ $TGT_SEP_BOOT -eq 1 ] || [ $BOOT_PASS -eq 1 ]; then
    BOOT_FILTERS=(--filter='- /boot/' --filter='P /boot/')
fi

if [ $MIGRATE_ROOT -eq 1 ]; then
    # Swap files are never transferred, only re-created afterwards. A dry run
    # mounts nothing here, but the pre-gate probe did, so the printed command
    # still carries the real swap and cache arguments.
    if [ "$DRY_RUN" -eq 0 ]; then
        scan_swapfiles
        scan_cache_drops
    else
        swap_excludes_from_preview
        cache_filters_from_preview
    fi
    echo "Rsyncing root filesystem..."
    # -x keeps the sender out of the target's mounted ESP at $MNT/boot/efi and
    # stops --delete recursing into it; BOOT_FILTERS does the same for a /boot
    # that is a filesystem of its own. CACHE_FILTERS come FIRST: rule order
    # decides, and a "+" line in an --exclude-from file must not re-include a
    # cache. --keep-cache is the one way to keep them, and it empties the array.
    run sudo rsync "${CACHE_FILTERS[@]}" "${RSYNC_OPTS[@]}" "${BOOT_FILTERS[@]}" \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/mnt/*","/lost+found"} \
        "${SWAP_EXCLUDES[@]}" \
        "$SRC/" "$MNT/"
    # Reads the sizes/labels of files under $SRC, so likewise real runs only.
    if [ "$DRY_RUN" -eq 0 ]; then rebuild_swapfiles; fi
    # ...and the swap files belonging on a filesystem resolved at the gate,
    # whose sizes the probe already read -- so this runs in a dry run too.
    create_remap_swapfiles
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
# No EFI pass: the ESP is not copied. Everything on it is written by Phase 5 and
# write_esp_menu, from this system's own GRUB. Copying the source's would drag
# over its master menu, whose entries name the SOURCE disk's root filesystems,
# burying the entries of the other systems that boot from a shared ESP.

echo "=========================================="
echo " Phase 4: Filesystem Translation (UUIDs)  "
echo "=========================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would rewrite fstab + GRUB root UUID and (re)brand the GRUB menu as \"$TGT_MODEL\""
    for remap_mp in "${!REMAP_SPEC[@]}"; do
        echo "[dry-run] would point $remap_mp at ${REMAP_SPEC[$remap_mp]} in the target's fstab"
    done
    if [ ${#REMAP_ENABLE[@]} -gt 0 ]; then
        echo "[dry-run] would bring ${#REMAP_ENABLE[@]} commented-out fstab line(s) back to life: ${REMAP_ENABLE[*]}"
    fi
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
    # os-prober is inert on GRUB >= 2.06 unless enabled. Where the target
    # enables it, concurrent update-grubs probe each other's in-flight disks.
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
# Discard unused blocks: keeps flash fast and lets a loop-attached .img shrink
# (the loop driver turns discards into hole punches on the backing file, which
# is why a fallocate'd image only becomes sparse if this runs). Skipped where
# the medium cannot discard, and --no-trim suppresses it outright.
#
# The ext4 roles are trimmed only under --update: otherwise they were just
# mkfs.ext4'd, which discards the whole partition (its "discard" option is the
# default), and the rsync that follows only allocates -- nothing returns to
# free. Under --update, rsync --delete really does free blocks and this is the
# only thing reclaiming them. The ESP is the exception in the other direction:
# mkfs.fat has no discard, so a fresh ESP is released only here.
if [ $NO_TRIM -eq 1 ]; then
    echo "Skipping fstrim on the written filesystems (--no-trim)."
else
    # Every run, not just a formatting one: a kept ESP has just had its menu
    # and modules rewritten, so blocks come free either way.
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

# GRUB reads two filesystems at boot: the ESP, for the menu and its modules, and
# whichever holds /boot, for the kernel. Ask GRUB's own drivers now that both
# are unmounted and consistent. Advisory: a failure means the disk will not
# boot, but nothing on it is wrong to fix.
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
    # The path the entry loads, symlink and all. Fall back to its directory, so
    # a driver that will not follow the symlink is not read as a broken disk.
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
