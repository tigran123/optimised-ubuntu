# Optimised version of Ubuntu 26.04 LTS distribution
I have made the following optimisations:

* Formatted the rootfs with `-O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed` which makes use of the latest versions of Linux kernel, forsaking compatibility with the ancient versions which are, imho, no longer relevant.

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

`install.sh` is the single entry point for every flavour of deployment. Besides flashing a whole image/device, it can take a *scattered* source whose partitions live on different disks (`--source-efi` / `--source-boot` / `--source-root`) and write to either a whole device or individual `--target-*` partitions. Each role is independently left in place, migrated (reformatted + copied), or — with `--update` — **synced** onto its existing filesystem with `rsync --delete` (no reformat), so refreshing an already-installed clone is fast instead of a full rebuild. For example, to incrementally sync a system whose `/boot/efi` and `/boot` are on `sda` and whose root is on an NVMe drive onto an already-prepared disk `sdb`:

```
$ ./install.sh \
    --source-efi /dev/sda2 --source-boot /dev/sda3 --source-root /dev/nvme0n1p1 \
    --target-bios-boot /dev/sdb1 --target-efi /dev/sdb2 \
    --target-boot /dev/sdb3 --target-root /dev/sdb4 --update
```

To produce an *impersonal* clone (stripped of personal data), pass `--exclude-from FILE`, which hands the file to `rsync --exclude-from`. List one path per line (see the included `exclude.txt` for the kind of thing I strip — caches, histories, credentials, downloads, etc.):

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda --exclude-from exclude.txt
```

This works with or without `--update`. On an `--update` re-sync it additionally passes `--delete-excluded`, so any listed paths that already exist on the target are *removed* (rsync otherwise protects excluded files from deletion, which would leave stale personal data behind).

Always preview a run with `--dry-run` first; it prints every destructive command instead of executing it. See `./install.sh --help` for the full set of options.
