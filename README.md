# Optimised version of Ubuntu 26.04 LTS distribution
I have made the following optimisations:

* Formatted the rootfs with `-O sparse_super2` and a very sparse inode table (~4 MiB per inode), which makes use of the latest versions of Linux kernel, forsaking compatibility with the ancient versions which are, imho, no longer relevant. I did use `orphan_file` for a while and dropped it again: it sets the *dynamic* `INCOMPAT_ORPHAN_PRESENT` superblock flag while orphan entries exist and only clears it on a clean unmount, so an unclean shutdown leaves an incompat flag behind — and recovering from power loss started costing me noticeably more than it used to.

* No separate `/boot` partition. It only ever existed because the rootfs carried features GRUB could not read; now that both are plain `-O sparse_super2`, GRUB reads the rootfs directly and `/boot` is just a directory in `/`. A fresh disk gets three partitions — 1 MiB BIOS Boot, 256 MiB ESP, and the root filesystem. You can check this claim yourself without booting anything, using GRUB's own ext2 driver: `grub-fstest Ubuntu26-16GB.img ls '(loop0,gpt3)/boot/grub/'`.

  One machine here is the exception, and it is not about GRUB being able to *read* the kernel but about the BIOS being able to *reach* it: that BIOS cannot boot from NVMe at all, so its BIOS Boot partition, ESP and `/boot` sit on the SATA SSD (~530 MB/s) while `/` — everything the running system actually touches — lives on the NVMe (~2000 MB/s). `install.sh` supports that layout explicitly, with `--source-boot` / `--target-boot`; see below.

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

`install.sh` is the single entry point for every flavour of deployment. Besides flashing a whole image/device, it can take a *scattered* source whose partitions live on different disks (`--source-efi` / `--source-root`, plus `--source-boot`) and write to either a whole device or individual `--target-*` partitions. Each role is independently left in place, migrated (reformatted + copied), or — with `--update` — **synced** onto its existing filesystem with `rsync --delete` (no reformat), so refreshing an already-installed clone is fast instead of a full rebuild. For example, to incrementally sync a system whose `/boot/efi` is on `sda` and whose root is on an NVMe drive onto an already-prepared disk `sdb`:

```
$ ./install.sh \
    --source-efi /dev/sda2 --source-root /dev/nvme0n1p1 \
    --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \
    --target-root /dev/sdb3 --update
```

`/boot` inside `/` is the default, and a separate `/boot` is **explicit on both sides**: only `--source-boot` says the source has one, only `--target-boot` gives the target one. Nothing is guessed from a partition table — a `/boot` partition a disk happens to carry is left alone unless it is named. The source's own `fstab` is cross-checked against `--source-boot` as soon as the source root is mounted, before anything is copied, so neither mistake gets far.

The two sides are independent, so the same tool builds the layout, refreshes it, or undoes it. To give a machine whose BIOS cannot boot from NVMe its BIOS Boot, ESP and `/boot` on `sda` and its root on the NVMe (all four partitions must already exist — `--target-boot` names one, it never creates one):

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img \
    --target-bios-boot /dev/sda1 --target-efi /dev/sda2 \
    --target-boot /dev/sda3 --target-root /dev/nvme0n1p1
```

and to clone that machine back onto an ordinary three-partition disk, folding `/boot` into the root filesystem on the way:

```
$ ./install.sh \
    --source-efi /dev/sda2 --source-boot /dev/sda3 --source-root /dev/nvme0n1p1 \
    --no-target-boot \
    --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 --target-root /dev/sdb3
```

`--no-target-boot` is the one that says "fold it in". When the source has a separate `/boot` and the target is described partition by partition, one of the two flags is **required**: converting a layout by accident is not something the script will do on a guess.

Roles are found by GPT type and filesystem label, not by partition number, so anything *else* on either disk is none of the script's business. Deploying from a machine whose NVMe carries a big data partition alongside the rootfs needs no special flags:

```
$ ./install.sh --source /dev/nvme0n1 --target /dev/sdb
```

The one case that is an error rather than a guess is a disk whose root is ambiguous — several unlabelled Linux partitions and none labelled `root`, or several *labelled* `root`: the script stops and names the candidates, since picking wrong would mean reformatting the wrong partition. Say which one it is with `--source-root` / `--target-root`, or label it (`sudo e2label /dev/sdX3 root`). `root` is the only label that scan looks for, and `--target-root-label` chooses the one `install.sh` writes — so a rootfs labelled anything else is out of the scan for good, and is named partition by partition from then on.

## One disk, several machines, one menu

GRUB's boot directory goes on the **ESP** — `grub-install --boot-directory=/boot/efi/boot`, for legacy BIOS and UEFI alike — so the boot menu belongs to the disk rather than to any one root filesystem. A disk can therefore carry a rootfs per machine (desktop, laptop, iMac), each holding only its platform-specific state, with `/home`, `/usr/local` and the rest bind-mounted out of a shared data partition, and all of them booting from one shared ESP:

```
/boot/efi/boot/grub/grub.cfg            the master menu, rebuilt on every install
/boot/efi/boot/grub/entries/<uuid>.cfg  one file per rootfs, named by its UUID
/boot/efi/boot/grub/custom.cfg          hand-written extras, sourced last
```

Each install writes **only its own** entry file — a `GUI` / `TTY` pair whose kernel command line is taken from that system's `/etc/default/grub`, so every machine keeps its own quirks — and then rebuilds the master over whatever entry files are present, carrying over the `timeout` and `default` already set there. Deleting an entry file retires that system from the menu; nothing else refers to it.

Adding a second machine's rootfs to a disk that already boots one means keeping the shared ESP, which `--keep-efi` does: its filesystem and UUID are left alone (formatting it would drop the other systems' entries and invalidate the ESP UUID in their `fstab`s), and only the named root partition is formatted and filled:

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --keep-efi \
    --target-bios-boot /dev/sde1 --target-efi /dev/sde2 \
    --target-root /dev/sde5 --brand Laptop --target-root-label laptop
```

`--brand` is worth passing here: without it every slot on the disk is named after the disk's own model, and the menu ends up listing the same title three times. `--target-root-label` is its counterpart on the disk itself: it labels this slot's root filesystem `laptop` rather than the `root` that every slot otherwise carries, so `lsblk` tells them apart at a glance. It does not make the disk scannable — a rootfs labelled anything but `root` is not what a whole-disk scan looks for, and such a disk is addressed partition by partition either way. The summary printed before the confirmation gate names the entry being registered, the command line it will boot with, and every system already registered on that ESP that the run will keep.

### The memory tester

The menu also offers **Memory test (memtest86+)** when the source has Ubuntu's `memtest86+` package installed — a portable disk that boots on arbitrary machines is exactly where a RAM tester earns its keep, since you can plug it into a machine that will not boot at all and still test it. The image (`/boot/mt86+x64`, about 157 KB) is copied onto the ESP at `boot/grub/memtest/`, beside the menu that offers it, and the entry loads it with GRUB's own `linux` command. The same file works under UEFI and legacy BIOS alike, so there is one entry rather than the four Ubuntu's `20_memtest86+` generates — those exist only to choose between the 64- and 32-bit images, and anything that can boot one of these disks is 64-bit.

The entry asks GRUB for a 640x480 framebuffer (`set gfxpayload=640x480,keep`). It needs one at all because under UEFI there is no VGA text mode to fall back on — without a framebuffer memtest86+ prints `No graphics display found` and stops — and it needs a small one because the tester draws a fixed 640x400 panel and never scales it, so on a 2560x1440 screen it would occupy a rectangle in the middle. `keep` is the fallback for firmware with no 640x480 mode. The entry loads GRUB's video driver itself (`insmod all_video`), because the menu around it deliberately loads none. For a while the master set up a graphical terminal for the whole menu, which looked better under UEFI — until a ThinkPad T450s turned up on which it made the menu *invisible*: live and navigable and never drawn on the panel, at every video mode tried, while the same file was fine when the machine was booted BIOS-first. GRUB has no way to tell a framebuffer it wrote from one the screen is actually scanning out, so a disk meant to boot arbitrary machines leaves the display alone and lets the firmware draw the menu. A disk whose firmware is known good can opt back in from `custom.cfg` on its ESP, which is sourced last but still before the menu is drawn.

Like the menu itself, the tester belongs to the **disk**, not to a rootfs: install a second slot from a system that has no `memtest86+` and the entry stays, because the master is rebuilt from what is on the ESP rather than from what the newest source happened to carry.

`GRUB_DISABLE_MEMTEST=true` in a system's `/etc/default/grub` — Ubuntu's own switch — stops *that* system's install from putting the image on the disk. It does not remove one that is already there, for the same reason an install never touches another system's menu entry: one slot must not take a disk-wide feature away from the others. To retire the tester for the whole disk, delete it from the ESP and let the next install rebuild the menu without it:

```
$ sudo rm -rf /boot/efi/boot/grub/memtest
```

If the entry is missing and you want it, `sudo apt install memtest86+` on the source and re-run the install.

The `fstab` of such a system survives the copy: a mount whose UUID is on the disk being installed is kept (a shared `/data` partition is present exactly when the system is), and so are the bind mounts hanging off it. Mounts naming *another* machine's disk are still commented out, along with the binds that depend on them — a clone that boots elsewhere must not block on a device that is not there.

To produce an *impersonal* clone (stripped of personal data), pass `--exclude-from FILE`, which hands the file to `rsync --exclude-from`. List one path per line (see the included `exclude-personal.txt` for the kind of thing I strip — caches, histories, credentials, downloads, etc.):

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda --exclude-from exclude-personal.txt
```

This works with or without `--update`. On an `--update` re-sync it additionally passes `--delete-excluded`, so any listed paths that already exist on the target are *removed* (rsync otherwise protects excluded files from deletion, which would leave stale personal data behind).

Write those paths as the **source's root filesystem** sees them, not as the running system does. rsync is handed that filesystem raw — mounted read-only, with none of its bind mounts replayed — so on a disk whose slots share one `/data`, a rule for `/home/tigran/.ssh/id_ed25519` matches nothing at all: `/home/tigran` is a bind of `/data/tigran`, and what the transfer actually carries is `/var/local/tigran-state/ssh/id_ed25519`, bound in from the root filesystem. That is a quiet way to ship a private key on a clone meant to be impersonal, so `install.sh` translates every rule through the source's own `fstab` and names the ones that cannot match, before the confirmation gate:

```
  Excludes: --exclude-from=exclude-personal.txt (listed paths purged from target via --delete-excluded)
            WARNING: 2 rule(s) strip nothing -- the source binds their data in from elsewhere:
              /home/tigran/.ssh/id_ed25519* -> /var/local/tigran-state/ssh/id_ed25519*
              /home/tigran/.config/google-chrome/ -> /var/local/tigran-state/config/google-chrome/
            64 rule(s) name paths on /data, off the root filesystem: -x never copies them,
              but a mount the target keeps still carries that data on the clone (Phase 4 says which survived)
```

Adding the translated path silences the warning for that rule; keep the home-relative one beside it and the file still works against a source with an ordinary home directory. (`exclude-personal.txt` carries both.)

The second line is worth reading rather than skipping. "Off the root filesystem" means the transfer never carries that data — but it does *not* mean the clone will not have it. On a slot-per-machine disk the personal home lives on the shared `/data`, which is on the disk being installed, so `fstab` keeps both it and the `/home/tigran` bind that hangs off it (the Phase 4 report says which mounts survived): the rules cost nothing, and the booted clone reads the same home directory through the same bind. What makes a clone impersonal there is stripping the paths on the **root** filesystem — the ones the first warning is about.

Two more things the audit can say. A rule whose wildcard falls *above* its last component (`/home/*/.ssh/known_hosts*`) cannot be matched against a mount point at all, so it is listed as unchecked rather than passed silently; a trailing wildcard is fine, since the directory it lives in is spelled out. And when the source cannot be read at the point the summary is printed — a `--dry-run` against an image, which has no loop device attached — the block says `not checked` instead of nothing, because an empty audit is also what a clean file looks like.

A **swap file** is never copied. `rsync -S` would turn its gigabytes of zeros into holes on the target, and the kernel then refuses it on the next boot with `swapon: /var/swap: skipping - it appears to have holes`. So every swap file listed in the source's `/etc/fstab` **that is on the root filesystem** is excluded from the transfer and re-created on the target instead — same size, same label and UUID, `0600 root:root`, freshly `mkswap`ed — which is also much faster than shipping all those zeros over USB. If your `--exclude-from` file lists the swap file (as `exclude-personal.txt` does), it is dropped instead: no swap file is created and its `fstab` entry is commented out, so a minimal boot disk stays swapless and does not boot into a failing `swapon`.

A swap file on a **different** filesystem is left alone entirely — `/data/swap`, where `/data` is a partition of its own. rsync is handed only the root filesystem, so such a file is not in the transfer, there is nothing to exclude, and re-creating it would mean allocating those gigabytes inside the *root* filesystem, under the empty directory the target mounts `/data` over at boot: space that is then invisible, unusable and never reclaimed. The summary says so before the gate:

```
  swap:     LEAVE     file /data/swap is on /data, a filesystem of its own -- not in the transfer
```

Whether the clone then has swap at all depends on `/data` itself: if that partition is on the disk being installed, `fstab` keeps the mount and the swap entry with it; if it is not, both are commented out and the clone boots swapless. Either way the file belongs to whoever owns that filesystem, not to this run.

A **browser cache** is dropped by default. `~/.cache/google-chrome` holds nothing but `Default/Cache` (the HTTP cache), `Default/Code Cache` (compiled JavaScript) and a GPU shader cache — 948 MB in 21,539 files here, all of which Chrome rebuilds on demand. Passwords, cookies, bookmarks and extensions live in `~/.config/google-chrome`, which is copied like anything else, so nothing is lost by leaving the cache behind. It is found the same way as everything else about the source's layout — through its `fstab`, so a bound `~/.cache` is followed to the path the transfer really carries — and it is dropped with an rsync `H` (hide) rule rather than an `--exclude`, because an exclude also *protects* the receiver's copy: on an `--update` re-sync the stale cache already on the target is deleted too. `--keep-cache` copies them instead.

Always preview a run with `--dry-run` first; it prints every destructive command instead of executing it. See `./install.sh --help` for the full set of options.
