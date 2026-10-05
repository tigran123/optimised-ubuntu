# Ubuntu 26.04 Public Image — v1.0

A ready-to-boot Ubuntu 26.04 LTS desktop, tuned for speed rather than for
caution. It holds no user accounts and no personal data: you create your own
account the first time it boots. It is a personal project, not an official
Ubuntu release, and is not endorsed by Canonical (Ubuntu is their trademark).

## Disclaimer — read this first

- **No warranty.** The image is provided "as is", without warranty of any kind.
  You use it entirely at your own risk, and the author accepts no liability for
  anything that results: lost data, a machine that will not boot, damaged
  hardware, security breaches or anything else.
- **Writing it erases the target disk.** Everything on the disk you write it to
  is destroyed, partitions included. Double-check which disk you choose.
- **It trades security for speed on purpose** (see
  [Different from stock Ubuntu](#different-from-stock-ubuntu)). Deciding
  whether those trade-offs suit your machine and how you use it is your
  responsibility.
- **Third-party software comes under its own licence.** That includes Google
  Chrome, the NVIDIA driver, VirtualBox, the NordVPN client and
  wolframscript, and by using them you accept those licences.

## What you need

- A 64-bit PC (x86-64). Both UEFI and legacy BIOS work.
- **A disk of at least 24 GiB** (25,769,803,776 bytes): an internal disk, a USB
  stick or a microSD card behind a USB adapter. The image fills the whole disk
  at first boot, so a bigger disk is simply more space.
- **Secure Boot turned off** in the firmware setup, if your machine has it.
  The image's boot loader is not signed.

## Files

| File | |
|---|---|
| `Ubuntu-26-Public-v1.0-*.img.xz` | the image, 7.0 GB compressed (24 GiB written) |
| `Ubuntu-26-Public-v1.0-*.img.xz.sha256` | its checksum |

Check the download before writing it. Compare the hash this prints with the
one in the `.sha256` file:
- **Linux:** `sha256sum -c Ubuntu-26-Public-v1.0-*.img.xz.sha256` checks it for
  you;
- **macOS:** `shasum -a 256 Ubuntu-26-Public-v1.0-*.img.xz`;
- **Windows:** `certutil -hashfile Ubuntu-26-Public-v1.0-<date>.img.xz SHA256`.

## Writing the image

You don't need to decompress it first: every method below reads the `.img.xz`
as it is and decompresses it on the fly as it writes. Whichever you use, the
target is the **whole disk**, not a partition on it.

- **Linux, GNOME Disks:** select the target disk, then ⋮ → *Restore Disk
  Image…* → choose the `.img.xz` → *Start Restoring*.
- **Linux, command line:** find the disk with `lsblk` first.
  ```bash
  xzcat Ubuntu-26-Public-v1.0-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
  ```
- **Windows and macOS:** use [balenaEtcher](https://etcher.balena.io/): *Flash from
  file* → choose the `.img.xz` → *Select target* → *Flash!*
- **Any of the three:** [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
  also works. Choose *Operating System* → *Use custom* → the `.img.xz`, then
  the disk under *Storage*. If it offers to customise the OS, decline: those
  settings are for Raspberry Pi OS.
- **macOS, command line:** this needs `xz` from Homebrew (`brew install xz`).
  Find the disk with `diskutil list`; `/dev/rdiskN` is its raw node, which is
  faster than `/dev/diskN`.
  ```bash
  diskutil unmountDisk /dev/diskN
  xzcat Ubuntu-26-Public-v1.0-*.img.xz | sudo dd of=/dev/rdiskN bs=4m
  ```

## First boot

1. Boot from the disk you wrote, usually through the firmware's boot menu key
   (F12, F11, F8 or Esc, depending on the maker).
2. The boot menu offers three entries:
   - **GUI Portable Image** (the default) is the desktop;
   - **TTY Portable Image** starts a text console without a desktop;
   - **Memory test (memtest86+)** checks the RAM.
3. On the first boot, the system grows to fill the disk on its own; this takes
   seconds. It also generates a new machine ID and new SSH host keys.
4. The setup wizard asks for your language, keyboard, account, privacy
   settings and time zone. The computer's name is set on the account page:
   until then the machine is called `ubuntu`.

### If it does not boot

- **UEFI:** make sure Secure Boot is off.
- **An internal disk that never appears in the boot menu:** some UEFI firmware
  only boots an internal disk that has a boot entry naming it, while USB
  sticks and cards always work. In the firmware setup, add a boot entry that
  points at `\EFI\BOOT\BOOTX64.EFI` on the disk's EFI partition.
  Alternatively, switch the firmware to legacy (CSM) boot, which this image
  also supports.

## Different from stock Ubuntu

Each item below is a deliberate choice, and each can be undone. Changing the
kernel command line means editing the boot menu entry itself. `/etc/default/grub`
and `update-grub` do **not** change this menu: the entry lives on the EFI
partition. For example, to remove `mitigations=off`:

```bash
sudo sh -c "sed -i 's/ mitigations=off//' /boot/efi/boot/grub/entries/*.cfg"
```

Kernel updates through apt need no change to the menu: the entry always boots
the newest kernel installed.

### Security

| What | Why it matters | To undo |
|---|---|---|
| `mitigations=off`: CPU vulnerability mitigations (Spectre, Meltdown and the rest) are off | Faster, but a program you run could read memory it should not see. Only for a machine that runs software you trust. | Remove `mitigations=off` from the kernel command line. |
| `apparmor=0`: AppArmor is off; unprivileged user namespaces are unrestricted, `ptrace` is not limited to child processes, and `dmesg` is readable by all | Fewer layers between a compromised program and the rest of your system. | Remove `apparmor=0`; delete `/etc/sysctl.d/20-apparmor.conf`, `55-kernel-softening.conf` and `60-ptrace.conf`. |
| **An SSH server is running, and the firewall is off** | Anyone on your network can try to log in to your account with its password. | `sudo systemctl disable --now ssh.socket ssh.service`, or `sudo ufw enable` |

Security updates install themselves (unattended-upgrades), as on stock Ubuntu.

### Laptops and power

| What | Effect | To undo |
|---|---|---|
| CPU frequency governor set to *performance* | More heat, shorter battery life | `sudo systemctl disable cpugov.service` |
| `pcie_aspm=off`: PCIe power saving is off | Shorter battery life | Remove `pcie_aspm=off` from the kernel command line. |

### Turned off

- **No swap.** With 8 GB of RAM or less, add a swap file:
  ```bash
  sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab && sudo swapon -a
  ```
- **Printing**, and finding printers on the network. To turn it back on:
  ```bash
  sudo systemctl unmask cups.service cups.socket cups.path cups-browsed.service avahi-daemon.service avahi-daemon.socket
  sudo systemctl enable --now cups.service cups-browsed.service avahi-daemon.service
  ```
- **Other masked services:**
  - mobile-broadband modems (`ModemManager`);
  - location services (`geoclue`);
  - crash reporting (`apport`);
  - the "launch on discrete GPU" menu (`switcheroo-control`).

  Turn any of them back on with `sudo systemctl unmask NAME` and then
  `sudo systemctl enable --now NAME`.
- **No Snap and no App Center:** install software with `apt`.
- **Some kernel modules are blocked:**
  - KVM on AMD processors (QEMU, GNOME Boxes);
  - parallel and serial ports.

  Delete the matching file in `/etc/modprobe.d` and reboot.

### Defaults for new accounts

- **Bash uses vi editing keys.** To get the usual Emacs-style keys, delete
  `~/.inputrc`.
- **Every monitor runs at 100% scaling,** so text looks small on a 4K screen.
  Change it in Settings → Displays → Scale.
- **The terminal is Terminator in the Terminus font** (Ctrl+F9 opens it).
  There are also shell aliases in `~/.bash_aliases`, and night light turns on
  at 18:00.
- **Preinstalled:**
  - Google Chrome is the browser;
  - LibreOffice;
  - VirtualBox;
  - the NVIDIA driver (580), which only loads on a machine with an NVIDIA card.

## Known limitations

- **Every copy of the image carries the same disk and filesystem IDs (UUIDs).**
  Do not connect two copies to the same machine at once, or it may mount the
  wrong one.
- **The menu titles say "Portable Image".** That is cosmetic.
