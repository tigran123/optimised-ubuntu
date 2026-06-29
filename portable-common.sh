#!/bin/bash
# lib/portable-common.sh — shared helpers for install.sh and backup.sh
#
# Provides:
#   die(), info(), confirm_prompt()
#   partition_prefix()
#   validate_partition_type()
#   get_parent_disk()
#   blkid_uuid()
#   mount_target_and_source()
#   rewrite_fstab()
#   rewrite_grub_distributor()
#   run_chroot_block()

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
# Known GPT partition type GUIDs (shared by install.sh and backup.sh)
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

# -----------------------------------------------------------------------------
# UUID & Mount Operations
# -----------------------------------------------------------------------------
blkid_uuid() {
    local dev=$1
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$dev") || \
        die "Could not determine UUID for $dev (unformatted or missing?)"
    [ -n "$uuid" ] || die "Empty UUID for $dev (unformatted?)"
    printf '%s' "$uuid"
}

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
    }' "$MNT/etc/fstab" | sudo tee /tmp/fstab_sanitized >/dev/null

    sudo mv /tmp/fstab_sanitized "$MNT/etc/fstab"
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
