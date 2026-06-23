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

# Partition 3: Dedicated /boot (1GB)
sudo parted -s /dev/sdb mkpart primary ext4 258MiB 1282MiB

# Partition 4: Unified Root (Ext4, taking the rest of the drive)
sudo parted -s /dev/sdb mkpart primary ext4 1282MiB 100%

```

**2. Format the Filesystems**

```bash
# Format ESP
sudo mkfs.fat -F32 -n EFI /dev/sdb2

# Format /boot conservatively (GRUB-safe)
sudo mkfs.ext4 -L boot -i 32768 -v -m 0 -E lazy_itable_init=0,lazy_journal_init=0 -O sparse_super2 /dev/sdb3

# Format / hyper-optimized (Kernel 5.x features)
sudo mkfs.ext4 -m 0 -L root -v -i 262144 -E lazy_itable_init=0,lazy_journal_init=0 -O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed /dev/sdb4

```

---

### Phase 2: Mounting & Data Synchronization

By mounting our split source partitions hierarchically, `rsync` will naturally flatten the architecture, effortlessly translating our separate `/boot` partition into a standard directory inside the portable SSD's unified root.

**1. Mount the Target SSD (`/mnt`)**

```bash
sudo mount /dev/sdb4 /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/sdb3 /mnt/boot
sudo mkdir -p /mnt/boot/efi
sudo mount /dev/sdb2 /mnt/boot/efi

```

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

---

### Phase 3: Filesystem Translation (`fstab`)

The cloned OS currently expects to find its root on the NVMe drive and its boot on `sda3`. You must update the target's `/etc/fstab` to reflect the new SSD's UUIDs.

**1. Gather the New UUIDs**

```bash
sudo blkid /dev/sdb4  # The Ext4       Root      UUID
sudo blkid /dev/sdb3  # The Ext4       /boot     UUID
sudo blkid /dev/sdb2  # The FAT32 EFI  /boot/efi UUID

```

**2. Edit the Target `fstab`**

```bash
sudo vi /mnt/etc/fstab

```

* Update the `/` mount point with the new `sdb4` UUID.
* Update the `/boot` mount point with the new `sdb3` UUID.
* Update the `/boot/efi` mount point with the new `sdb2` UUID.

---

### Phase 4: The `chroot` Environment

Bind the "Big Five" virtual filesystems so the chroot environment can interact directly with the hardware block devices.

```bash
for i in /dev /dev/pts /proc /sys /run; do sudo mount --bind $i /mnt$i; done
sudo chroot /mnt

```

---

### Phase 5: Bootloader Architecture & Universal Routing

You are now inside the cloned OS on the portable SSD. We will install the payloads for both UEFI and CSM, and drop the universal routing stub.

**1. Install the Payloads**

```bash
# 1. Install standard MBR payload into the BIOS Boot partition for legacy CSM
grub-install --target=i386-pc /dev/sdb

# 2. Install the mathematically pure, un-signed UEFI payload on the fallback path
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-uefi-secure-boot

```

**2. Create the Universal Routing Stub**
If Canonical's script recreated the `ubuntu` directory, purge it, then write our universal `grub.cfg`.

```bash
rm -rf /boot/efi/EFI/ubuntu
vi /boot/efi/EFI/BOOT/grub.cfg

```

Paste the universal logic, ensuring you insert the **new `/dev/sdb3` UUID**. This script dynamically detects that it is now running on a unified filesystem and adjusts its `$prefix` automatically:

```text
search --no-floppy --fs-uuid --set=root YOUR-SDB3-UUID

if [ -f ($root)/boot/grub/grub.cfg ]; then
    set prefix=($root)/boot/grub
else
    set prefix=($root)/grub
fi

configfile $prefix/grub.cfg

```

**3. Enforce the Root UUID Mapping**

Because the bootloader's primitive drivers cannot parse the hyper-optimized features on our root partition (sdb4), grub-probe will fail to extract its UUID and may hardcode the block device path or fallback to PARTUUID. To guarantee absolute portability across any hardware, you must explicitly pass the root UUID to the kernel.

```bash
vi /etc/default/grub
```

Locate the `GRUB_CMDLINE_LINUX` variable and append our new `/dev/sdb4` UUID:

```plaintext
GRUB_CMDLINE_LINUX="root=UUID=YOUR-SDB4-UUID"
```

**4. Regenerate the Master Menu**
This will execute `09_console` (which will also realize it is on a unified drive and prepend `/boot` to the kernel paths) and lock in text-mode colors.

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
