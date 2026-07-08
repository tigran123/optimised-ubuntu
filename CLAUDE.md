# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small toolkit of Bash scripts for deploying a custom, performance-optimized Ubuntu 26.04 LTS system onto portable storage (SSD / image file). The produced disk boots on **both** UEFI and legacy BIOS machines from a single GPT layout. There is no application code — the deliverable is the scripts plus the methodology documented in `README.md` and `Portable-SSD-README.md`.

## Running the scripts

There is no build, test, lint, or CI setup — scripts are run directly and require `sudo` (they shell out to `parted`, `mkfs`, `losetup`, `chroot`, `grub-install`, etc.). Always preview destructive runs with `--dry-run`, which prints every wrapped command instead of executing it.

- **`install.sh`** — the single, universal entry point. Source can be a unified block device, a `.img` file (auto-attached via `losetup -P`), or scattered source partitions (`--source-efi/-boot/-root`, which may live on different disks); target can be a unified device (it partitions + formats) or scattered partitions. Each role is left in place (target == source), migrated (target differs → reformat + full copy), or — under `--update` — synced (target differs → keep the existing filesystem, `rsync --delete` onto it). `--update` subsumes the old disk-to-disk clone (`backup.sh`, removed): it refreshes an already-installed clone incrementally instead of rebuilding it. `--exclude-from FILE` passes `rsync --exclude-from`, omitting listed paths from the copy (e.g. an impersonal clone); combined with `--update` it also adds `--delete-excluded`, so those paths are purged from the target rather than protected. `--brand NAME` overrides the GRUB menu branding, which otherwise uses the reported model of the disk holding the target rootfs (useful when that reports a USB card reader's name instead of the card's).
  ```bash
  ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda
  ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda --dry-run
  # Incrementally sync a split-disk source (sda EFI/boot + nvme root) onto sdb:
  ./install.sh --source-efi /dev/sda2 --source-boot /dev/sda3 \
               --source-root /dev/nvme0n1p1 \
               --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \
               --target-boot /dev/sdb3 --target-root /dev/sdb4 --update
  # Impersonal clone — deploy minus the paths listed in exclude.txt:
  ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda \
               --exclude-from exclude.txt
  ```

Verifying a change: there's no test harness, so validate by running the script against a throwaway `.img` (create one with `truncate`/`dd`, attach with `losetup -P`) under `--dry-run` first, then for real against a loop device or scratch disk.

## Architecture

`install.sh` is a single self-contained script (the former `portable-common.sh` library was folded into it, and the `init-disk.sh`/`backup.sh` helpers were removed). It sets `set -euo pipefail` and defines the `run()` dry-run wrapper (it quotes args with `%q`).

The pipeline:

1. **Resolve source/target topology** — unified device, image (loop), or scattered partitions. Per-role partition types are checked against GPT type GUIDs (`GUID_BIOS`/`GUID_EFI`/`GUID_LINUX`, defined near the top of the script) via `validate_partition_type()`; a unified `--target` combined with `--update` is checked whole-disk via `validate_disk_structure()` (the layout must already exist, since `--update` won't recreate it).
2. **Prepare target** — `parted` GPT layout + `mkfs`, skipped per-role for in-place roles and skipped entirely under `--update` (which keeps the existing filesystems and `rsync --delete`s onto them).
3. **Mount + sync** — mounts target RW (`$MNT`, `$MNT/boot`, `$MNT/boot/efi`) and source RO (`$SRC`, …), then a per-role `rsync -ahqHAXS --numeric-ids -x` (one rsync per migrated/synced filesystem) with the live-filesystem exclusions on root. The shared `RSYNC_OPTS` array gains `--delete` only under `--update`, `--exclude-from=FILE` when `--exclude-from` is given, and `--delete-excluded` when both apply (so excluded paths are purged from, not protected on, the target). Because `--exclude-from` paths are anchored to each transfer root, the personal `/…` paths in the file only match during the root rsync.
4. **Translate identifiers** — `rewrite_fstab()` rewrites old→new UUIDs and comments out foreign swap / bind mounts (tagged `# [PORTABLE-SYNC-DISABLED]`, keeping only the `/tmp → /var/tmp` bind); `rewrite_grub_distributor()` stamps the target disk model (or the `--brand` override) into the GRUB menu branding.
5. **Chroot + bootloader** — `run_chroot_block()` bind-mounts `/dev /dev/pts /proc /sys /run`, installs GRUB for **both** `i386-pc` (BIOS) and `x86_64-efi --removable` (UEFI), writes a universal `/boot/efi/EFI/BOOT/grub.cfg` routing stub keyed to `NEW_UUID_BOOT`, then `update-grub` + `update-initramfs -u -k all`.
6. **Teardown** — recursive unmount, detach loop device if one was used.

### Conventions to follow when editing

- **Helper functions read caller-set globals** rather than taking all inputs as parameters (e.g. `rewrite_fstab()`, `rewrite_grub_distributor()`, and `run_chroot_block()` read `TGT_ROOT`, `MNT`, `SRC`, `OLD_UUID_*`/`NEW_UUID_*`, `TGT_MODEL`, `TGT_GRUB_DISK`, `NEW_UUID_BOOT`) — set the variables before the call.
- **Naming:** `SRC_*` = source partitions, `TGT_*` = target partitions, `OLD_UUID_*`/`NEW_UUID_*` = pre/post-format UUID pairs, `MNT`/`SRC` = target/source root mount points (private per-instance temp dirs by default; `--mnt`/`--src` pin them).
- Use `die()` for fatal errors, `info()` (`==> …`) for progress, and route destructive commands through `run()` so `--dry-run` keeps working.
- Partition-suffix differences are handled by `partition_prefix()` (returns `p` for `nvme`/`mmcblk`/`loop`, empty otherwise) — use it rather than hardcoding `sda1` vs `nvme0n1p1`.

### Filesystem optimization (intentional, don't "fix")

The root ext4 is created with aggressive features (`fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed`) and a very high bytes-per-inode ratio (~4 MiB/inode), which requires a modern (5.x+) kernel. `/boot` deliberately uses only the GRUB-safe `sparse_super2` and a conservative inode density so the bootloader can still read it.

### `run_chroot_block` bootloader gating

`run_chroot_block` reads `INSTALL_GRUB_BIOS`/`INSTALL_GRUB_EFI` (default `1` if unset) to decide whether to run each `grub-install`, and always runs `update-grub` + `update-initramfs`. `install.sh` sets them per-role (`INSTALL_GRUB_BIOS=1` only when a BIOS target is given; `INSTALL_GRUB_EFI=$MIGRATE_EFI`) so a partial (e.g. rootfs-only) migration can leave the EFI/BIOS bootloaders byte-intact, while a full clone or whole-disk sync reinstalls both. It also expands `$TGT_GRUB_DISK` unconditionally in the chroot heredoc, so any caller must set that variable even when not reinstalling BIOS GRUB.
