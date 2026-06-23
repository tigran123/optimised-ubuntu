# Optimised version of Ubuntu 22.04 LTS distribution
I have made the following optimisations:
1. Formatted the rootfs with `-O fast_commit,sparse_super2,orphan_file,inline_data,metadata_csum_seed` which makes use of the latest versions of Linux kernel, forsaking compatibility with the ancient versions which are, imho, no longer relevant.
2. Too many other minor tweaks to be described here.

To install the system use `install.sh` script like this:

```
$ ./install.sh --image Ubuntu26-Portable-16GB.img --target /dev/sda
```

The `.img` file is distributed elsewhere -- too big to uploaded on GitHub, plus all the standard mp3, etc issues I don't want to have to deal with.
