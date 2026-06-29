# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small toolkit of Bash scripts for deploying a custom, performance-optimized Ubuntu 26.04 LTS system onto portable storage (SSD / image file). The produced disk boots on **both** UEFI and legacy BIOS machines from a single GPT layout. There is no application code — the deliverable is the scripts plus the methodology documented in `README.md` and `Portable-SSD-README.md`.

## Running the scripts

There is no build, test, lint, or CI setup — scripts are run directly and require `sudo` (they shell out to `parted`, `mkfs`, `losetup`, `chroot`, `grub-install`, etc.). Always preview destructive runs with `--dry-run`, which prints every wrapped command instead of executing it.

- **`install.sh`** — flash a portable image/device onto a target. Source can be a unified block device, a `.img` file (auto-attached via `losetup -P`), or four scattered source partitions; target can be a unified device (it partitions + formats) or scattered partitions.
  ```bash
  ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda
  ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda --dry-run
  ```
- **`backup.sh`** — clone an already-running/offline hybrid system (e.g. NVMe + SATA split) disk-to-disk onto a pre-partitioned target. `--src-disk` and `--tgt-disk` are mandatory (no defaults, by design, so a bare run can't nuke `/dev/sda`); they may also come from `SRC_DISK`/`TGT_DISK` env vars. Mounts source read-only and rsyncs with `--delete`.
  ```bash
  ./backup.sh --src-disk /dev/nvme0n1 --tgt-disk /dev/sdb --dry-run
  ```
- **`init-disk.sh`** — standalone reference snippet that GPT-partitions and formats one disk. Values are hardcoded (`TARGET=/dev/sde`); edit the variable before running. Not sourced by anything else.

Verifying a change: there's no test harness, so validate by running the relevant script against a throwaway `.img` (create one with `truncate`/`dd`, attach with `losetup -P`) under `--dry-run` first, then for real against a loop device or scratch disk.

## Architecture

Two entry points (`install.sh`, `backup.sh`) source one shared library (`portable-common.sh`) via `. "$SCRIPT_DIR/portable-common.sh"`. Both set `set -euo pipefail` and define their own local `run()` dry-run wrapper (it quotes args with `%q`); `portable-common.sh` itself sets no shell options and defines no `run()`.

Both entry points implement the same pipeline; `install.sh` does the extra partition/format/loop-device work, `backup.sh` assumes the target is already partitioned:

1. **Resolve source/target topology** — unified device, image (loop), or scattered partitions. Partition types are checked against GPT type GUIDs (`GUID_BIOS`/`GUID_EFI`/`GUID_LINUX`, defined in `portable-common.sh`) via `validate_partition_type()`; `backup.sh` checks a whole disk's 4-partition layout via `validate_disk_structure()`.
2. **Prepare target** (`install.sh` only) — `parted` GPT layout + `mkfs`.
3. **Mount** — `mount_target_and_source()` mounts target RW (`/mnt`, `/mnt/boot`, `/mnt/boot/efi`) and source RO (`/altroot`, …), then `rsync -ahqHAXS --numeric-ids` with the live-filesystem exclusions.
4. **Translate identifiers** — `rewrite_fstab()` rewrites old→new UUIDs and comments out foreign swap / bind mounts (tagged `# [PORTABLE-SYNC-DISABLED]`, keeping only the `/tmp → /var/tmp` bind); `rewrite_grub_distributor()` stamps the target disk model into the GRUB menu branding.
5. **Chroot + bootloader** — `run_chroot_block()` bind-mounts `/dev /dev/pts /proc /sys /run`, installs GRUB for **both** `i386-pc` (BIOS) and `x86_64-efi --removable` (UEFI), writes a universal `/boot/efi/EFI/BOOT/grub.cfg` routing stub keyed to `NEW_UUID_BOOT`, then `update-grub` + `update-initramfs -u -k all`.
6. **Teardown** — recursive unmount, detach loop device if one was used.

### Conventions to follow when editing

- **Shared logic lives in `portable-common.sh`.** When the library reads a variable (e.g. `TGT_ROOT`, `MNT`, `SRC`, `OLD_UUID_*`/`NEW_UUID_*`, `TGT_MODEL`, `TGT_GRUB_DISK`, `NEW_UUID_BOOT`), the entry point must set it before the call — these functions rely on caller-set globals rather than taking all inputs as parameters.
- **Naming:** `SRC_*` = source partitions, `TGT_*` = target partitions, `OLD_UUID_*`/`NEW_UUID_*` = pre/post-format UUID pairs, `MNT`=`/mnt`, `SRC`=`/altroot`.
- Use `die()` for fatal errors, `info()` (`==> …`) for progress, and route destructive commands through `run()` so `--dry-run` keeps working.
- Partition-suffix differences are handled by `partition_prefix()` (returns `p` for `nvme`/`mmcblk`/`loop`, empty otherwise) — use it rather than hardcoding `sda1` vs `nvme0n1p1`.

### Filesystem optimization (intentional, don't "fix")

The root ext4 is created with aggressive features (`fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed`) and a very high bytes-per-inode ratio (~4 MiB/inode), which requires a modern (5.x+) kernel. `/boot` deliberately uses only the GRUB-safe `sparse_super2` and a conservative inode density so the bootloader can still read it.

### `run_chroot_block` bootloader gating

`run_chroot_block` reads `INSTALL_GRUB_BIOS`/`INSTALL_GRUB_EFI` (default `1` if unset) to decide whether to run each `grub-install`, and always runs `update-grub` + `update-initramfs`. `install.sh` sets them per-role so a partial (e.g. rootfs-only) migration can leave the EFI/BIOS bootloaders byte-intact; `backup.sh` sets both to `1` (full clone). It also expands `$TGT_GRUB_DISK` unconditionally in the chroot heredoc, so any caller must set that variable even when not reinstalling BIOS GRUB.
