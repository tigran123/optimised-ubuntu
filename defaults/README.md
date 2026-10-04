# Defaults for new accounts

A "vanilla, but better than default Ubuntu" starting point for every account
created on the source system. The friend who creates their own account on the
first boot of a `--public` image gets it, and so does anyone added later. These
files are installed **once, by hand, on the source rootfs**. `install.sh` knows
nothing about them: they live in `/etc` and `/usr/share`, so every image and
clone made from the source carries them anyway.

Existing accounts do not change. `/etc/skel` is copied only when an account is
created, and these dconf values are defaults rather than locks, so any setting a
user has made still wins.

## What goes where

The tree below mirrors `/`: each file goes to the same path without the leading
`defaults/`.

| File | Gives a new account |
|---|---|
| `etc/skel/.bash_aliases` | the aliases `ls l ll md rd j u up ups df r cls dis od m pbcopy pbpaste t`, and `GREP_COLORS` |
| `etc/skel/.dircolors` | the stock `ls` colours, except that directories are bold white instead of bold blue |
| `etc/skel/.inputrc` | vi editing mode in bash and every other readline program |
| `etc/skel/.config/terminator/config` | Terminator in Terminus Bold 14, full screen, with no title bar or scroll bar, 5000 lines of scrollback, and Alt+1…9 to switch tabs |
| `etc/dconf/profile/user` | puts the system database `local` underneath each user's own settings |
| `etc/dconf/db/local.d/00-optimised` | the desktop defaults: wallpaper, blue accent, no animations, dock, night light, Ctrl+F9 for Terminator, and the rest (see the file) |
| `usr/share/backgrounds/Ravnina.jpg` | the wallpaper (3840×2160) |
| `usr/share/gnome-background-properties/optimised-ubuntu-wallpapers.xml` | lists the wallpaper in Settings → Appearance, so it can be chosen again after a change |

You don't need to change the stock `/etc/skel/.bashrc`: it already reads
`~/.bash_aliases`, and takes the `ls` colours from `~/.dircolors`. It is a
dpkg conffile, so leave it alone.

The aliases need `xclip`, `tty-clock` and `binutils`, which the source already
has. Terminator's font comes from the `fonts-terminus-otb` package, not from
a copy in `~/.local/share/fonts`.

## Installing

Boot into the source system and update its checkout, then run:

```bash
sudo apt install fonts-terminus-otb
cd ~/u26/optimised-ubuntu/defaults
find etc usr -type f | while read -r f; do sudo install -D -m 644 "$f" "/$f"; done
sudo dconf update
```

`dconf update` compiles `local.d/` into `/etc/dconf/db/local`, which is what
sessions actually read. Run it again after any edit to `00-optimised`.

To check the compiled database without a new account:

```bash
printf 'system-db:local\n' > /tmp/local-only
DCONF_PROFILE=/tmp/local-only gsettings get org.gnome.desktop.interface accent-color   # 'blue'
```

The full test is a throwaway account: `sudo adduser dtest`, log in as it, look
around, log out, then `sudo deluser --remove-home dtest`.

## Optional settings

`optional/10-personal` holds settings from the source account that suit one
person, one screen or one keyboard rather than everybody:
- text scaling and pointer size
- no screen blanking or suspend
- the gb + ru phonetic layouts
- window and workspace keys
- the Ctrl+Alt launchers
- the Evince view

The steps above do not install it. To adopt some of it, move those blocks
into `00-optimised`, or install the whole file next to it, then run
`sudo dconf update`.

## Undoing

Delete the installed files, and also `/etc/dconf/db/local`: `dconf update`
does not remove a database whose `.d` directory has gone.
