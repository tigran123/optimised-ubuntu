#!/bin/bash
set -euo pipefail

# An example of install.sh in use: this machine's own backup. It runs off
# nvme0n1 and keeps two bootable clones of itself up to date -- one on an
# internal SSD (sdc), one on a portable T7 (sdf) -- each with a mirror of the
# data partition beside it. The device names are this machine's own.
#
# One pipeline per target disk, the two side by side:
#
#     install.sh -> sdc, then data -> sdc4    |    install.sh -> sdf, then data -> sdf6
#
# The data sync onto a disk waits for that disk's install.sh, and not only
# because both write the same SSD: install.sh --remap opens the disk's data
# partition itself -- read-only before the gate, read-write when the swap file
# is missing -- and borrows whatever mount point it finds it on. A sync that
# mounts the same partition meanwhile comes up read-only, or has its mount
# point used after it has moved on to the next disk.

SRC_DATA=/dev/nvme0n1p4

cd "$(dirname "$(readlink -f "$0")")"

# The one password prompt, and kept fresh: both pipelines call sudo for as long
# as they run, and neither can be asked once its output goes to a log.
sudo -v
( while sleep 120; do sudo -n -v || exit; done ) </dev/null >/dev/null 2>&1 &
KEEPALIVE=$!

LOGS=$(mktemp -d /tmp/backup-logs.XXXXXX)
# The data partition as it is on disk, without the binds the running system
# has inside /data/disk3. Not on /data: a mount there hides /data/disk1..4,
# which is where install.sh looks to check what each --remap points at.
RAW=$(mktemp -d /tmp/backup-data.XXXXXX)
DST_SDC=$(mktemp -d /tmp/backup-sdc4.XXXXXX)
DST_SDF=$(mktemp -d /tmp/backup-sdf6.XXXXXX)

# release <mount point> -- unmount it if it is still mounted, waiting out an
#   interrupted rsync whose writes are still being flushed.
release() {
    local m=$1 _i
    for _i in $(seq 1 30); do
        mountpoint -q "$m" || break
        sudo umount "$m" 2>/dev/null && break
        sleep 2
    done
    if mountpoint -q "$m"; then
        echo "Still mounted: $m -- unmount it by hand." >&2
    else
        rmdir "$m" 2>/dev/null || true
    fi
}

cleanup() {
    pkill -P "$KEEPALIVE" 2>/dev/null || true
    kill "$KEEPALIVE" 2>/dev/null || true
    release "$DST_SDC"
    release "$DST_SDF"
    release "$RAW"
}
trap cleanup EXIT

# Ctrl-C alone does not stop a backgrounded install.sh (bash starts background
# jobs with SIGINT ignored), so TERM the whole process group: install.sh
# unmounts its own trees on TERM, and each pipeline exits once its command has.
interrupted() {
    trap '' INT TERM HUP
    echo "Interrupted -- stopping both pipelines and waiting for them to unmount..." >&2
    kill 0
    wait
    exit 130
}
trap interrupted INT TERM HUP

# sync_data <partition> <mount point> -- mirror the data partition onto one target.
sync_data() {
    sudo mount "$1" "$2"
    sudo rsync --delete --exclude=/lost+found --exclude=/swap -ahvHAX "$RAW/" "$2/"
    sudo umount "$2"
}

sudo mount -r -o noatime "$SRC_DATA" "$RAW"

# Internal SSD.
(
    trap 'exit 143' TERM
    ./install.sh --source /dev/nvme0n1 \
                 --target-bios-boot /dev/sdc1 --target-efi /dev/sdc2 --target-root /dev/sdc3  \
                 --remap /data/disk1=/dev/sda1 --remap /data/disk2=/dev/sdb1 --remap /data/disk3=/dev/sdc4 --remap /data/disk4=/dev/sde1 \
                 --update --no-trim --yes
    sync_data /dev/sdc4 "$DST_SDC"
) >"$LOGS/sdc.log" 2>&1 </dev/null &
PID_SDC=$!

# T7.
(
    trap 'exit 143' TERM
    ./install.sh --source /dev/nvme0n1 \
                 --target-bios-boot /dev/sdf1 --target-efi /dev/sdf2 --target-root /dev/sdf3 \
                 --remap /data/disk1=none --remap /data/disk2=none --remap /data/disk3=/dev/sdf6 --remap /data/disk4=none \
                 --update --no-trim --keep-efi --yes
    sync_data /dev/sdf6 "$DST_SDF"
) >"$LOGS/sdf.log" 2>&1 </dev/null &
PID_SDF=$!

echo "Both pipelines are running. Follow them with:"
echo "    tail -f $LOGS/sdc.log $LOGS/sdf.log"

# Report each pipeline as it finishes, whichever is first. A bare "wait" would
# return 0 whatever either of them did.
declare -A RUNNING=([$PID_SDC]=sdc [$PID_SDF]=sdf)
rc=0
while [ ${#RUNNING[@]} -gt 0 ]; do
    pid=""
    if wait -n -p pid "${!RUNNING[@]}"; then
        echo "${RUNNING[$pid]}: done after $((SECONDS / 60)) min."
    else
        rc=1
        [ -n "$pid" ] || { echo "Lost track of the pipelines -- see $LOGS" >&2; break; }
        echo "${RUNNING[$pid]}: FAILED after $((SECONDS / 60)) min -- see $LOGS/${RUNNING[$pid]}.log" >&2
    fi
    unset "RUNNING[$pid]"
done
exit "$rc"
