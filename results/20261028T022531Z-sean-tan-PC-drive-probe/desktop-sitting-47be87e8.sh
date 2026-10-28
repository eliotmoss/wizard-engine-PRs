#!/usr/bin/env bash
# Stage 2 of the desktop rerun with Magpie's Virgil compiler (47be87e8,
# Aeneas III-11.1968; scripts/desktop-campaigns-47be87e8.sh): the steps that
# need root. Run once, as root, after stage 1 has finished and with nothing
# else heavy running:
#
#   sudo env PWROOT_USER=sean-tan bash scripts/desktop-sitting-47be87e8.sh
#
# As root it only: checks the DAX mount that the 2026-10-27 sitting made;
# sets every CPU's governor to performance for the four performance campaigns
# and back to powersave (also on exit); and runs the root checks of
# 2026-10-21, each from a worktree at its original revision, exactly as their
# own usage lines say. Every program is built, and every campaign runs, as
# PWROOT_USER with Magpie's compiler first on PATH. Results are copied into
# this checkout's results/ with a toolchain.txt; nothing is committed.
set -euo pipefail

die() { echo "desktop-sitting-47be87e8: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root: sudo env PWROOT_USER=<user> bash $0"
U=${PWROOT_USER:?set PWROOT_USER to the user who owns the checkout}
UH=$(getent passwd "$U" | cut -d: -f6)
[ -n "$UH" ] || die "no user $U"
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
VIRGIL=$UH/research/virgil-magpie-47be87e8
LOG=$UH/.cache/desktop-sitting-47be87e8-$(date -u +%Y%m%dT%H%M%SZ).log
now() { date -u -Iseconds; }
say() { echo "$(now) $*" | tee -a "$LOG"; chown "$U": "$LOG"; }
asuser() { runuser -u "$U" -- env HOME="$UH" PATH="$VIRGIL/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

asuser "$VIRGIL/bin/v3c" -version 2>&1 | head -1 | grep -q 'III-11.1968' || die "$VIRGIL/bin/v3c is not III-11.1968"
findmnt -no OPTIONS /mnt/pmem0 | grep -q dax=always || die "/mnt/pmem0 is not mounted with dax=always (run scripts/desktop-sitting.sh's setup first)"
[ -d /mnt/pmem0/clwb ] && [ "$(stat -c %U /mnt/pmem0/clwb)" = "$U" ] || die "/mnt/pmem0/clwb is missing or not owned by $U"

setgov() { local g; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" > "$g"; done; }
trap 'setgov powersave' EXIT

# ---- 1. The four campaigns that ran under the performance governor.
say "governor performance"
setgov performance
sleep 5
asuser env GOV_EXPECT=performance DAX_DIR=/mnt/pmem0/clwb \
	bash "$REPO/scripts/desktop-campaigns-47be87e8.sh" pwsieve clwb-cpus2 pwsieve-ab-perf pwsieve-ab-perf20 \
	|| say "performance campaigns: exit $? (see the batch log)"
setgov powersave
say "governor powersave"
sleep 5

# ---- 2. The root checks of 2026-10-21, each at its original revision.
# wt REV: the worktree at REV, made as the user; prog PROG: build it there.
wt() {
	local rev; rev=$(asuser git -C "$REPO" rev-parse "$1^{commit}")
	W=$UH/.cache/engine-wt-${rev:0:8}
	[ -e "$W" ] || asuser git -C "$REPO" worktree add -q --detach "$W" "$rev"
	[ "$(asuser git -C "$W" rev-parse HEAD)" = "$rev" ] || die "$W is not at $rev"
	REV=$rev
}
build() {
	asuser bash -c "cd '$W' && rm -f bin/$1.x86-64-linux bin/Build-*.v3 && make bin/$1.x86-64-linux" >> "$LOG" 2>&1 \
		|| die "could not build $1 in $W"
}
# Copy the results directories a check made into this checkout, with a
# toolchain.txt.
collect() {
	local before=$1 d
	for d in $(comm -13 <(echo "$before") <(ls "$W/results" | sort)); do
		[ -d "$W/results/$d" ] || continue
		{
			echo "---- toolchain (desktop-sitting-47be87e8.sh)"
			echo "v3c      $VIRGIL/bin/v3c ($(asuser "$VIRGIL/bin/v3c" -version 2>&1 | head -1))"
			echo "virgil   $VIRGIL: HEAD $(asuser git -C "$VIRGIL" rev-parse HEAD)"
			echo "why      Magpie's compiler, rebuilt on this desktop, so that the desktop's results share Magpie's compiler"
			echo "engine   $REV (the original check's revision), worktree $W"
		} > "$W/results/$d/toolchain.txt"
		chown "$U": "$W/results/$d/toolchain.txt"
		asuser cp -a "$W/results/$d" "$REPO/results/"
		say "  -> results/$d"
	done
}
run_check() {
	local name=$1 before; shift
	before=$(ls "$W/results" 2>/dev/null | sort)
	say "begin $name rev ${REV:0:8}"
	( cd "$W" && "$@" ) >> "$LOG" 2>&1 && say "end $name ok" || say "end $name exit $?"
	collect "$before"
}

# results/20261021T040954Z-sean-tan-PC-desktop-root-checks
wt dd0c1cc5; build pwbench
run_check desktop-root-checks env PWROOT_USER="$U" bash "$W/scripts/desktop-root-checks.sh"
# results/20261021T041120Z-sean-tan-PC-desktop-stable-writes
build pwsievebench
run_check desktop-stable-writes env PWROOT_USER="$U" bash "$W/scripts/desktop-stable-writes.sh"
# results/20261021T100005Z-sean-tan-PC-fsyncfail-rzHcHs (ext4 and XFS; it repeats
# 20261021T095453Z-...-nNagao, which had ext4 only)
wt af6f9680; build pwreboot
run_check fsyncfail-af6f9680 env PWROOT_USER="$U" bash "$W/scripts/desktop-fsyncfail-check.sh" run --yes-inject-io-errors
# results/20261021T105823Z-sean-tan-PC-fsyncfail-Px6IUW
wt bd23bd4f; build pwreboot
run_check fsyncfail-bd23bd4f env PWROOT_USER="$U" bash "$W/scripts/desktop-fsyncfail-check.sh" run --yes-inject-io-errors

say "done; log $LOG"
