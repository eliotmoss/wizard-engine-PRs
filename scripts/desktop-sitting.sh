#!/usr/bin/env bash
# One quiet sitting on sean-tan-PC: every desktop campaign the thesis cites, at
# engine 95e055fa (scripts/desktop-campaigns.sh), with the emulated PMEM device
# and both governors. Run as root, once, after a boot with memmap=1G!8G and
# with nothing else running (no agent sessions, servers or CI jobs):
#
#   sudo env PWROOT_USER=sean-tan bash scripts/desktop-sitting.sh
#
# As root it only: checks that /dev/pmem0 is the 1 GiB of DRAM reserved at
# 8 GiB; makes an ext4 filesystem on it and mounts it with dax=always at
# /mnt/pmem0 (unless already mounted there), with /mnt/pmem0/clwb owned by the
# user; and sets every CPU's governor, powersave for the first half and
# performance for the second, restoring powersave on exit. Every campaign runs
# as PWROOT_USER. The reserved DRAM holds nothing else, so mkfs loses nothing.
set -euo pipefail

die() { echo "desktop-sitting: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root: sudo env PWROOT_USER=<user> bash $0"
U=${PWROOT_USER:?set PWROOT_USER to the user who owns the checkout}
UH=$(getent passwd "$U" | cut -d: -f6)
[ -n "$UH" ] || die "no user $U"
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
MNT=/mnt/pmem0
DAX=$MNT/clwb

# ---- The device must be the reservation, and nothing else.
grep -Eq '^\s*200000000-23fffffff : Persistent Memory \(legacy\)' /proc/iomem \
	|| die "no 'Persistent Memory (legacy)' at 200000000-23fffffff in /proc/iomem: is memmap=1G!8G on the kernel command line? ($(cat /proc/cmdline))"
[ -b /dev/pmem0 ] || die "no /dev/pmem0"
[ "$(cat /sys/block/pmem0/size)" = 2097152 ] || die "/dev/pmem0 is not 1 GiB"
cur=$(findmnt -no TARGET /dev/pmem0 || true)
if [ -z "$cur" ]; then
	mkfs.ext4 -q -F -b 4096 /dev/pmem0
	mkdir -p "$MNT"
	mount -o dax=always /dev/pmem0 "$MNT"
elif [ "$cur" != "$MNT" ]; then
	die "/dev/pmem0 is mounted at $cur, not $MNT"
fi
findmnt -no OPTIONS "$MNT" | grep -q dax=always || die "$MNT is not mounted with dax=always"
mkdir -p "$DAX" && chown "$U": "$DAX"

# The fdatasync probe is recorded, not a gate, here: with nothing else running,
# a slow probe describes the drive, and the sitting should still run.
PROBE_MAX_US=${PROBE_MAX_US:-1000000}

setgov() { for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" > "$g"; done; }
trap 'setgov powersave; echo "desktop-sitting: governor restored to powersave"' EXIT

as_user() {
	runuser -u "$U" -- env HOME="$UH" USER="$U" LOGNAME="$U" \
		PATH="$UH/research/virgil-titzer/bin:/usr/local/bin:/usr/bin:/bin" \
		DAX_DIR="$DAX" GOV_EXPECT="$1" PROBE_MAX_US="$PROBE_MAX_US" \
		bash "$REPO/scripts/desktop-campaigns.sh" "${@:2}"
}

setgov powersave
as_user powersave pwbtree pwsieve-ab pwbtree-kill direct-control direct-cost \
	pwsieve pwsieve-clock clwb-cpus2 clwb-cpus20
# Let the first half's own load and IO pressure decay below the quiet checks.
sleep 90
setgov performance
sleep 5
as_user performance pwsieve-clock-perf pwsieve-ab-perf pwsieve-ab-perf20
echo "desktop-sitting: done; results copied into $REPO/results (uncommitted)"
