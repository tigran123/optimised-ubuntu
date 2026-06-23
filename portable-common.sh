#!/bin/bash
# lib/portable-common.sh — shared helpers for install.sh and backup.sh
#
# Provides:
#   die(), info(), confirm_prompt()
#   partition_prefix()
#   validate_disk_structure()
#   mount_target_and_source()
#   rewrite_fstab()
#   rewrite_grub_distributor()
#   run_chroot_block()
#
# Sourced (not executed) by install.sh and backup.sh. All public functions
# expect the caller to have already set these variables:
#   SRC_DISK, SRC_EFI, SRC_BOOT, SRC_ROOT
#   TGT_DISK, TGT_EFI, TGT_BOOT, TGT_ROOT
#   MNT, SRC
#   OLD_UUID_EFI, OLD_UUID_BOOT, OLD_UUID_ROOT
#   NEW_UUID_EFI, NEW_UUID_BOOT, NEW_UUID_ROOT

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# confirm_prompt <message>
#   Reads a single keystroke; any key accepts. Empty keypress (just Enter) also
#   accepts — the human eye can mistake a blank line for a stray newline.
confirm_prompt() {
    local msg=${1:-Press any key to proceed}
    read -n 1 -s -r -p "$msg (or Ctrl+C to break)..."
    echo ""
}

# -----------------------------------------------------------------------------
# Partition-prefix detection
#
# NVMe and MMCblk devices name partitions with a 'p' separator; traditional
# /dev/sd* devices do not. Detect once and reuse.
# -----------------------------------------------------------------------------
partition_prefix() {
    local disk=$1
    if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
        echo "p"
    else
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# validate_disk_structure <disk> <part_prefix>
#   Returns 0 iff the disk exists, has exactly 4 partitions, and they have
#   the expected GPT type GUIDs (BIOS boot, EFI, Linux, Linux).
# -----------------------------------------------------------------------------
validate_disk_structure() {
    local disk=$1
    local p_prefix=$2

    info "Validating topology of $disk..."

    if [ ! -b "$disk" ]; then
        echo "  [FAIL] $disk is not a valid block device."
        return 1
    fi

    local part_count
    part_count=$(lsblk -n -l -o TYPE "$disk" | grep -cw "part")
    if [ "$part_count" -ne 4 ]; then
        echo "  [FAIL] $disk contains $part_count partitions. Expected exactly 4."
        return 1
    fi

    local exp_bios="21686148-6449-6e6f-744e-656564454649"
    local exp_efi="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    local exp_linux="0fc63daf-8483-4772-8e79-3d69d8477de4"

    local t1 t2 t3 t4
    t1=$(lsblk -n -d -o PARTTYPE "${disk}${p_prefix}1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    t2=$(lsblk -n -d -o PARTTYPE "${disk}${p_prefix}2" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    t3=$(lsblk -n -d -o PARTTYPE "${disk}${p_prefix}3" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    t4=$(lsblk -n -d -o PARTTYPE "${disk}${p_prefix}4" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    if [ "$t1" != "$exp_bios" ]; then
        echo "  [FAIL] Partition 1 is not a BIOS boot partition (Type: $t1)."
        return 1
    fi
    if [ "$t2" != "$exp_efi" ]; then
        echo "  [FAIL] Partition 2 is not an EFI System partition (Type: $t2)."
        return 1
    fi
    if [ "$t3" != "$exp_linux" ]; then
        echo "  [FAIL] Partition 3 is not a Linux filesystem (Type: $t3)."
        return 1
    fi
    if [ "$t4" != "$exp_linux" ]; then
        echo "  [FAIL] Partition 4 is not a Linux filesystem (Type: $t4)."
        return 1
    fi

    echo "  [PASS] Structure is exact."
    return 0
}

# -----------------------------------------------------------------------------
# blkid_uuid <device>
#   Print the UUID of <device>, or die with a clear message if it has none.
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
# mount_target_and_source
#   Mount target RW, source RO under $MNT and $SRC respectively, mirroring
#   the conventional hybrid-system layout (boot + boot/efi as sub-mounts).
# -----------------------------------------------------------------------------
mount_target_and_source() {
    sudo mount "$TGT_ROOT" "$MNT"
    sudo mkdir -p "$MNT/boot"
    sudo mount "$TGT_BOOT" "$MNT/boot"
    sudo mkdir -p "$MNT/boot/efi"
    sudo mount "$TGT_EFI" "$MNT/boot/efi"

    sudo mkdir -p "$SRC"
    sudo mount -r -o noatime "$SRC_ROOT" "$SRC"
    sudo mount -r -o noatime "$SRC_BOOT" "$SRC/boot"
    sudo mount -r "$SRC_EFI" "$SRC/boot/efi"
}

# -----------------------------------------------------------------------------
# rewrite_fstab
#   Translate the three known source UUIDs to the new target UUIDs and
#   disable (comment out) any leftover UUID= or /dev/disk/by-uuid mounts
#   that don't match the target — e.g. swap or foreign drives that would
#   otherwise fail to come up on a different host.
#
#   Also disables bind mounts except the /tmp → /var/tmp exception.
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
    }' "$MNT/etc/fstab" | sudo tee /tmp/fstab_sanitized >/dev/null

    sudo mv /tmp/fstab_sanitized "$MNT/etc/fstab"
    sudo chown root:root "$MNT/etc/fstab"
    sudo chmod 644 "$MNT/etc/fstab"
}

# -----------------------------------------------------------------------------
# rewrite_grub_distributor
#   Update GRUB_DISTRIBUTOR in /etc/default/grub and /etc/grub.d/09_console
#   to reflect the target disk's model string.
# -----------------------------------------------------------------------------
rewrite_grub_distributor() {
    info "Updating GRUB_DISTRIBUTOR with target model ($TGT_MODEL)..."

    if [ -f "$MNT/etc/default/grub" ]; then
        sudo sed -i -E 's/^(GRUB_DISTRIBUTOR="Desktop ).*( `\( \.)/\1'"$TGT_MODEL"'\2/' "$MNT/etc/default/grub"
    fi

    if [ -f "$MNT/etc/grub.d/09_console" ]; then
        sudo sed -i -E 's/^(GRUB_DISTRIBUTOR="Console ).*( `\( \.)/\1'"$TGT_MODEL"'\2/' "$MNT/etc/grub.d/09_console"
    fi
}

# -----------------------------------------------------------------------------
# run_chroot_block
#   Bind-mount the host's virtual filesystems and chroot into the target to:
#     1. Recreate the universal routing stub (/boot/efi/EFI/BOOT/grub.cfg)
#     2. Install GRUB payloads (BIOS + UEFI removable)
#     3. Regenerate the master menu
#     4. Rebuild initramfs
#
#   The grub-install step is wrapped so that the rm -rf of the vendor
#   ubuntu/ directory only happens on success.
# -----------------------------------------------------------------------------
run_chroot_block() {
    for i in /dev /dev/pts /proc /sys /run; do
        sudo mount --bind "$i" "$MNT$i"
    done

    # Install GRUB payloads into the target disk (passed via TGT_DISK)
    sudo chroot "$MNT" /bin/bash <<EOF
set -e
echo "=> Inside chroot..."

echo "=> Installing GRUB payloads..."
grub-install --target=i386-pc ${TGT_DISK:-$TARGET}
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-uefi-secure-boot
GRUB_RC=\$?

# Recreate the universal routing stub only if grub-install succeeded
if [ "\$GRUB_RC" -eq 0 ]; then
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
    echo "grub-install failed (\$GRUB_RC); leaving /boot/efi/EFI/ubuntu untouched."
fi

echo "=> Regenerating Master Menu..."
update-grub

echo "=> Rebuilding initramfs..."
update-initramfs -u -k all

echo "=> Exiting chroot."
EOF
}
