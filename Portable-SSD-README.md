Here is the complete, start-to-finish documentation for translating hybrid NVMe+SATA system into a universally bootable, unified portable SSD.

This guide assumes you are booted into a live environment (e.g., MicroSD on `/dev/sdc`).

* **Source Root (`/`):** `/dev/nvme0n1p1`
* **Source Boot (`/boot`):** `/dev/sda3`
* **Source EFI (`/boot/efi`):** `/dev/sda2`
* **Target Portable SSD:** `/dev/sdb`

---

### Phase 1: Target Drive Preparation

We must equip the portable SSD (`/dev/sdb`) with a GPT layout that supports both modern UEFI and legacy CSM (BIOS) booting natively.

**1. Wipe and Partition `/dev/sdb`**

```bash
# Create a fresh GPT partition table
sudo parted -s /dev/sdb mklabel gpt

# Partition 1: BIOS Boot (For CSM fallback, unformatted, 1MB)
sudo parted -s /dev/sdb mkpart primary 1MiB 2MiB
sudo parted -s /dev/sdb set 1 bios_grub on

# Partition 2: EFI System Partition (FAT32, 256MB)
sudo parted -s /dev/sdb mkpart primary fat32 2MiB 258MiB
sudo parted -s /dev/sdb set 2 esp on

# Partition 3: Unified Root (Ext4, taking the rest of the drive)
sudo parted -s /dev/sdb mkpart primary ext4 258MiB 100%

```

There is deliberately **no separate `/boot` partition**. It only ever existed because the root filesystem carried ext4 features GRUB's primitive drivers could not parse; the root is now formatted with the same conservative `-O sparse_super2` as `/boot` used to be, so GRUB reads it directly and `/boot` is simply a directory inside `/`. You can confirm that for a given disk without booting it, using GRUB's own ext2 driver:

```bash
sudo grub-fstest /dev/sdb3 ls /boot/grub/
```

The source machine described above *does* have a separate `/boot`, and the hand-run `rsync` below flattens it into the target's root. `install.sh` does the same job with `--source-boot /dev/sda3 --no-target-boot` — and, given `--target-boot` instead, will split `/boot` back out onto a partition of its own, which is what a machine whose BIOS cannot boot from NVMe needs. Neither layout is inferred: both `--source-boot` and `--target-boot` name a partition explicitly, and where the source has one and the target is described partition by partition, saying which of the two you want is required rather than guessed.

**2. Format the Filesystems**

```bash
# Format ESP
sudo mkfs.fat -F32 -n EFI /dev/sdb2

# Format / (sparse inode table; -N scales with the partition, ~4 MiB per inode)
sudo mkfs.ext4 -vF -m 0 -L root -N 1572864 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 /dev/sdb3

```

`orphan_file` and `metadata_csum_seed` used to be in that `-O` list and were removed on purpose. `orphan_file` sets the *dynamic* `INCOMPAT_ORPHAN_PRESENT` superblock flag whenever the orphan file holds entries and only clears it on a clean unmount, so an unclean shutdown leaves an incompat flag set on the filesystem — recovery after power loss became measurably more destructive. Do not put them back.

---

### Phase 2: Mounting & Data Synchronization

By mounting our split source partitions hierarchically, `rsync` will naturally flatten the architecture, effortlessly translating our separate `/boot` partition into a standard directory inside the portable SSD's unified root.

**1. Mount the Target SSD (`/mnt`)**

```bash
sudo mount /dev/sdb3 /mnt
sudo mkdir -p /mnt/boot/efi
sudo mount /dev/sdb2 /mnt/boot/efi

```

`/mnt/boot` is an ordinary directory on the root filesystem now, so nothing is mounted onto it — the source's separate `/boot` partition simply lands there as files, which is exactly the flattening described above.

**2. Mount the Source Architecture (`/altroot`)**

```bash
sudo mkdir -p /altroot
sudo mount /dev/nvme0n1p1 /altroot
sudo mount /dev/sda3 /altroot/boot
sudo mount /dev/sda2 /altroot/boot/efi

```

**3. Rsync the OS**
Copy everything, preserving attributes and ACLs, while explicitly ignoring live hardware and virtual filesystems:

```bash
sudo rsync -ahvHAXS --numeric-ids --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/media/*","/lost+found"} /altroot/ /mnt/

```

**4. Re-create the swap file**
If the system swaps to a *file* rather than a partition, add it to the exclusions above (`--exclude=/var/swap`) and build a fresh one on the target. The `-S` flag stores the swap file's gigabytes of zeros as holes, and the kernel refuses a swap area that is not fully allocated:

```
swapon: /var/swap: skipping - it appears to have holes.
```

Excluding it also saves copying all those zeros over USB, since `fallocate` costs nothing but metadata:

```bash
sudo rm -f /mnt/var/swap
sudo fallocate -l $(stat -c %s /altroot/var/swap) /mnt/var/swap
sudo chmod 600 /mnt/var/swap
sudo mkswap -L swap /mnt/var/swap

```

---

### Phase 3: Filesystem Translation (`fstab`)

The cloned OS currently expects to find its root on the NVMe drive and its boot on `sda3`. You must update the target's `/etc/fstab` to reflect the new SSD's UUIDs.

**1. Gather the New UUIDs**

```bash
sudo blkid /dev/sdb3  # The Ext4       Root      UUID (also holds /boot)
sudo blkid /dev/sdb2  # The FAT32 EFI  /boot/efi UUID

```

**2. Edit the Target `fstab`**

```bash
sudo vi /mnt/etc/fstab

```

* Update the `/` mount point with the new `sdb3` UUID.
* **Delete or comment out the `/boot` line entirely** — that partition no longer exists, and leaving the entry behind means booting into a failing `mount`.
* Update the `/boot/efi` mount point with the new `sdb2` UUID.

---

### Phase 4: The `chroot` Environment

Bind the "Big Five" virtual filesystems so the chroot environment can interact directly with the hardware block devices.

```bash
for i in /dev /dev/pts /proc /sys /run; do sudo mount --bind $i /mnt$i; done
sudo chroot /mnt

```

---

### Phase 5: Bootloader Architecture & the Menu on the ESP

You are now inside the cloned OS on the portable SSD. We install the payloads for both UEFI and CSM, and put GRUB's boot directory — and with it the menu — on the ESP, where it belongs to the disk rather than to any one root filesystem.

**1. Install the Payloads**

```bash
# 1. Standard MBR payload in the BIOS Boot partition, for legacy CSM
grub-install --target=i386-pc --boot-directory=/boot/efi/boot /dev/sdb

# 2. The un-signed UEFI payload on the fallback path
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --boot-directory=/boot/efi/boot --removable --no-uefi-secure-boot

```

`--boot-directory=/boot/efi/boot` is the whole trick: both payloads get their `$prefix` pointed at `/boot/grub` **on the ESP**, so `/boot/efi/boot/grub` is the real `/boot/grub` for BIOS and UEFI alike. Because the boot directory sits on the ESP itself, `grub-install` embeds a device-relative prefix in the EFI image — so there is no routing stub to write, and an ESP built this way holds `EFI/BOOT/BOOTX64.EFI` and no `EFI/BOOT/grub.cfg`. (Delete a stale one from an older build; nothing reads it.)

**2. Write the Master Menu**

If Canonical's script recreated the `ubuntu` directory, purge it, then write the menu that GRUB will actually read.

```bash
rm -rf /boot/efi/EFI/ubuntu
rm -f  /boot/efi/EFI/BOOT/grub.cfg
mkdir -p /boot/efi/boot/grub/entries
vi /boot/efi/boot/grub/grub.cfg

```

The master holds nothing machine-specific: it sources one file per registered root filesystem, so a disk can carry a rootfs per machine behind this single ESP and each install only ever touches its own entry file.

```text
set timeout=5
set default=0

insmod part_gpt
insmod ext2

if [ -f $prefix/entries/YOUR-ROOT-UUID.cfg ]; then source $prefix/entries/YOUR-ROOT-UUID.cfg; fi

if [ -f $prefix/custom.cfg ]; then source $prefix/custom.cfg; fi

```

Then the entry itself, in `/boot/efi/boot/grub/entries/YOUR-ROOT-UUID.cfg`. The `search` names **whichever filesystem holds `/boot`** — the root partition `/dev/sdb3` on this layout, or a dedicated `/boot` partition on a disk that still has one, in which case the kernel paths lose their `/boot` prefix. The options after `root=UUID=` are this machine's own, out of its `/etc/default/grub`:

```text
menuentry "GUI Portable SSD" {
    search --no-floppy --fs-uuid --set=root YOUR-BOOT-FILESYSTEM-UUID
    linux /boot/vmlinuz root=UUID=YOUR-ROOT-UUID quiet apparmor=0 mitigations=off
    initrd /boot/initrd.img
}

menuentry "TTY Portable SSD" {
    search --no-floppy --fs-uuid --set=root YOUR-BOOT-FILESYSTEM-UUID
    linux /boot/vmlinuz root=UUID=YOUR-ROOT-UUID quiet apparmor=0 mitigations=off systemd.unit=multi-user.target
    initrd /boot/initrd.img
}

```

`install.sh` writes exactly this, deriving the options from the target's own `/etc/default/grub` and rebuilding the master over whatever entry files are on the ESP. `grub-script-check` will parse either file for you before you reboot.

**3. Enforce the Root UUID Mapping**

`grub-probe` can fail to extract the root filesystem's UUID and fall back to hardcoding a block device path or a PARTUUID — neither of which survives being plugged into a different machine. To guarantee absolute portability across any hardware, pass the root UUID to the kernel explicitly.

```bash
vi /etc/default/grub
```

Locate the `GRUB_CMDLINE_LINUX` variable and append our new `/dev/sdb3` UUID:

```plaintext
GRUB_CMDLINE_LINUX="root=UUID=YOUR-SDB3-UUID"
```

**4. Regenerate the rootfs's own menu**
Nothing boots from `/boot/grub/grub.cfg` any more — the menu on the ESP is what GRUB reads — but this keeps the system self-describing and is what a rescue `configfile` would find. It executes `09_console` (which will also realize it is on a unified drive and prepend `/boot` to the kernel paths) and locks in text-mode colors.

```bash
update-grub

```

**5. Rebuild the Initial RAM Disk (initramfs)**

The cloned OS still contains an initrd holding the fstab mappings and swap UUIDs from your old hardware. You must flush and rebuild the early-boot state so the miniature RAM OS natively understands the portable SSD's new storage topology.

```bash
update-initramfs -u -k all
```

### Phase 6: Teardown & NVRAM Housekeeping

**1. Safely Unmount**

```bash
exit
sudo umount -R /altroot /mnt

```

**2. Clean the Host NVRAM (Optional but Recommended)**
If the live environment's package manager or an accidental script execution dropped Canonical's Secure Boot trap back into the host machine's BIOS, purge it now before rebooting.

```bash
sudo efibootmgr

```

Identify any entry labeled `ubuntu` (e.g., `Boot0000`). Delete it by passing its hex ID:

```bash
sudo efibootmgr -b 0000 -B

```

**3. Create the new EFI entry in NVRAM**


```bash
sudo efibootmgr -c -d /dev/sdb -p 2 -L "HGST 1TB Backup" -l '\EFI\BOOT\BOOTX64.EFI'
```

Breakdown of the Parameters:

* **`-c` (Create):** Tells `efibootmgr` to create a new boot variable.
* **`-d /dev/sdb` (Disk):** Specifies the physical block device containing the bootloader.
* **`-p 2` (Partition):** Points specifically to `/dev/sdb2`, which is your FAT32 EFI System Partition.
* **`-L "HGST 1TB Backup"` (Label):** This is the cosmetic string that will appear in your BIOS/UEFI boot menu. You can name this anything you like.
* **`-l '\EFI\BOOT\BOOTX64.EFI'` (Loader):** The exact path to the GRUB payload relative to the root of the ESP. *Note the use of single quotes and backslashes—UEFI paths strictly require backslashes, and the single quotes prevent the Bash shell from interpreting them as escape characters.*

What Happens Next

When you execute this command, `efibootmgr` will write the new entry to the NVRAM, assign it the next available hex ID (likely `Boot0000` or `Boot0001` based on your output), and automatically push it to the very front of the `BootOrder` list.

### Phase 7: Test it in VirtualBox (Optional)

You can boot this disk directly in VirtualBox by preparing the `.vmdk` file first:

```bash
$ sudo chgrp tigran /dev/sdb # temporarily give access to the raw disk, resets when you unplug the disk
$ VBoxManage createmedium disk --filename Portable.vmdk --format=VMDK --variant RawDisk --property RawDrive=/dev/sdb
```

and then you need to point to this `Portable.vmdk` file in VirtualBox GUI when creating a new virtual machine.

---
The portable SSD is now mathematically complete, universally bootable on both UEFI (Secure Boot disabled) and Legacy BIOS, and mathematically isolated from the hardware quirks of the host machine.
