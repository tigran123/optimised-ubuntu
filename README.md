# Optimised version of Ubuntu 22.04 LTS distribution
I have made the following optimisations:
. Formatted the rootfs with `-O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed` which makes use of the latest versions of Linux kernel, forsaking compatibility with the ancient versions which are, imho, no longer relevant.
. Disabled WiFi, printed and many other services by default (trivially enabled by commands like `sudo systemctl unmask wpa_supplicant ; sudo systemctl enable --now wpa_supplicant`, etc.
. Disabled auto-loading of kernel modules for ancient hardware, like serial port, parallel port, etc. Again, re-enabled by trivial editing of files in `/etc/modprobe.d` and remaking initrd
. Added console boot entry in menu (boots into `multiuser.target`)
. Console uses Terminus font (change the size with `dpkg-reconfigure console-setup` if necessary)
. Disabled monitor scaling by default and re-enabled vector fonts so that Terminus can be used in Terminator (which is the default terminal app). If you have multiple monitors of various very different resolutions, e.g. one FullHD and another 4K, there is still no benefit in scaling, as long you remember that the window will change its dimensions when moved from one monitor to another. This is natural and the solution is simple: configure that particular application for the desire monitor. In any case, if you use some application frequently, you must have an "ideal place" for it in your multi-monitor setup and must configure it for that "ideal placement" anyway. Sacrificing rendering quality for the dubious benefit of auto-scaling a window to each monitor is a _stupid_ idea.
. Too many (thousands of!) other optimisations to be described here. Not because they are unimportant, but because I didn't get around to documenting them all here. Please wait and re-read this README.md later.

To install the system use `install.sh` script like this:

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda
```

The `.img` file is distributed elsewhere -- too big to upload on GitHub, plus all the standard mp3, etc issues I don't want to have to deal with.
