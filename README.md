# Optimised version of Ubuntu 26.04 LTS distribution
I have made the following optimisations:

* Formatted the rootfs with `-O sparse_super2` and a very sparse inode table (~4 MiB per inode), which makes use of the latest versions of Linux kernel, forsaking compatibility with the ancient versions which are, imho, no longer relevant. I did use `orphan_file` for a while and dropped it again: it sets the *dynamic* `INCOMPAT_ORPHAN_PRESENT` superblock flag while orphan entries exist and only clears it on a clean unmount, so an unclean shutdown leaves an incompat flag behind — and recovering from power loss started costing me noticeably more than it used to.

* No separate `/boot` partition. It only ever existed because the rootfs carried features GRUB could not read; now that both are plain `-O sparse_super2`, GRUB reads the rootfs directly and `/boot` is just a directory in `/`. A fresh disk gets three partitions — 1 MiB BIOS Boot, 256 MiB ESP, and the root filesystem. You can check this claim yourself without booting anything, using GRUB's own ext2 driver: `grub-fstest Ubuntu26-16GB.img ls '(loop0,gpt3)/boot/grub/'`.

* Disabled WiFi, printer and many other services by default (trivially enabled by commands like `sudo systemctl unmask wpa_supplicant ; sudo systemctl enable --now wpa_supplicant`, etc.

* Disabled auto-loading of kernel modules for ancient hardware, like serial port, parallel port, etc. Again, re-enabled by trivial editing of files in `/etc/modprobe.d` and remaking initrd

* Disabled AppArmor, apport, snapd, localsearch and dozens of other useless services that eat CPU cycles and/or spy on your activities under the pretense of "security and convenience".

* Disabled CPU bugfixes `mitigations=off` in the kernel -- use this only if your machine is not running untrusted code. If it does (or if it is exposed to the Internet), then remove `mitigations=off` from `/etc/default/grub` and `/etc/grub.d/09-console` files. Note that you will lose 30% performance by enabling these so-called `mitigations`.

* Enabled lots of things that Ubuntu has disabled by default (see `/etc/sysctl.d/*` files)

* Added console boot entry in menu (boots into `multi-user.target`)

* Console uses Terminus font (change the size with `dpkg-reconfigure console-setup` if necessary)

* Disabled monitor scaling by default and re-enabled bitmap fonts so that Terminus can be used in Terminator (which is the default terminal app). If you have multiple monitors of various very different resolutions, e.g. one FullHD and another 4K, there is still no benefit in scaling, as long you remember that the window will change its dimensions when moved from one monitor to another. This is natural and the solution is simple: configure that particular application for the desired monitor. In any case, if you use some application frequently, you must have an "ideal place" for it in your multi-monitor setup and must configure this specific application (its internal font sizes, etc) for that "ideal placement" anyway. Sacrificing rendering quality for the dubious benefit of auto-scaling a window to each monitor is a _stupid_ idea.

* Enabled `vi` editing mode in bash and added many useful aliases, from my experience on multiple flavours of UNIX since 1990s, i.e. 30+ years of experience of UNIX/Linux kernel development.

* Too many (thousands!) other optimisations to be described here. Not because they are unimportant, but because I didn't get around to documenting them all here. Please wait and re-read this README.md later.

To install the system use `install.sh` script like this:

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda
```

The `.img` file is distributed elsewhere -- too big to upload on GitHub, plus all the standard mp3, etc issues I don't want to have to deal with.

`install.sh` is the single entry point for every flavour of deployment. Besides flashing a whole image/device, it can take a *scattered* source whose partitions live on different disks (`--source-efi` / `--source-root`, plus `--source-boot` if that system has a separate `/boot`) and write to either a whole device or individual `--target-*` partitions. Each role is independently left in place, migrated (reformatted + copied), or — with `--update` — **synced** onto its existing filesystem with `rsync --delete` (no reformat), so refreshing an already-installed clone is fast instead of a full rebuild. For example, to incrementally sync a system whose `/boot/efi` and `/boot` are on `sda` and whose root is on an NVMe drive onto an already-prepared disk `sdb` that also has a separate `/boot`:

```
$ ./install.sh \
    --source-efi /dev/sda2 --source-boot /dev/sda3 --source-root /dev/nvme0n1p1 \
    --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \
    --target-boot /dev/sdb3 --target-root /dev/sdb4 --update
```

A separate `/boot` is optional on **both** sides, and the script converts between the layouts. Omitting `--target-boot` folds the source's `/boot` into the target's root filesystem (its `fstab` entry is commented out); supplying one against a source that has none splits it back out (an `fstab` entry is inserted right after `/`). A whole `--target` disk is partitioned with the new three-partition layout, while `--target ... --update` *detects* what the disk already has, so an older four-partition clone keeps its `/boot` and keeps syncing:

```
$ ./install.sh \
    --source-efi /dev/sda2 --source-boot /dev/sda3 --source-root /dev/nvme0n1p1 \
    --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 --target-root /dev/sdb3
```

To produce an *impersonal* clone (stripped of personal data), pass `--exclude-from FILE`, which hands the file to `rsync --exclude-from`. List one path per line (see the included `exclude.txt` for the kind of thing I strip — caches, histories, credentials, downloads, etc.):

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda --exclude-from exclude.txt
```

This works with or without `--update`. On an `--update` re-sync it additionally passes `--delete-excluded`, so any listed paths that already exist on the target are *removed* (rsync otherwise protects excluded files from deletion, which would leave stale personal data behind).

A **swap file** is never copied. `rsync -S` would turn its gigabytes of zeros into holes on the target, and the kernel then refuses it on the next boot with `swapon: /var/swap: skipping - it appears to have holes`. So every swap file listed in the source's `/etc/fstab` is excluded from the transfer and re-created on the target instead — same size, same label and UUID, `0600 root:root`, freshly `mkswap`ed — which is also much faster than shipping all those zeros over USB. If your `--exclude-from` file lists the swap file (as `exclude.txt` does), it is dropped instead: no swap file is created and its `fstab` entry is commented out, so a minimal boot disk stays swapless and does not boot into a failing `swapon`.

Always preview a run with `--dry-run` first; it prints every destructive command instead of executing it. See `./install.sh --help` for the full set of options.
