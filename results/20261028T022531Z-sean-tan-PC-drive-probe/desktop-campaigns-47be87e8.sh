#!/usr/bin/env bash
# Rerun, on sean-tan-PC, the desktop campaigns the thesis cites, each at its
# ORIGINAL engine revision and with its original parameters, but compiled by
# Magpie's Virgil compiler (Virgil 47be87e8, Aeneas III-11.1968) instead of
# the desktop's own (eb52db97, III-11.1975), so that every result in the thesis
# comes from one compiler. See docs/persistent-backends.md, "Toolchain".
#
# Usage, on sean-tan-PC, from a clean pwregions checkout:
#   GOV_EXPECT=powersave|performance [DAX_DIR=<dir on a DAX mount>] \
#     bash scripts/desktop-campaigns-47be87e8.sh STEP...
# The steps that need the performance governor are started, with the governor
# set, by scripts/desktop-sitting-47be87e8.sh (root).
#
# Each step runs its campaign's driver in a detached worktree at the
# campaign's revision ($HOME/.cache/engine-wt-<rev8>), after deleting that
# worktree's compiled programs so that make rebuilds them with this compiler.
# The results directory is copied into this checkout's results/ with a
# toolchain.txt that names the compiler; nothing is committed. The batch log
# is $BATCH/batch.log. As in scripts/desktop-campaigns.sh, the script refuses
# to start unless the machine is quiet, and probes a 4 KiB fdatasync before
# and after every step, refusing to start a step while its median stays over
# PROBE_MAX_US.
set -uo pipefail

VIRGIL=${VIRGIL:-$HOME/research/virgil-magpie-47be87e8}
VIRGIL_REV=47be87e81a88f94a744119835eaf4877885f54e7
SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
REPO=${REPO:-$(cd "$(dirname "$SCRIPT")/.." && pwd)}
BLOCK_DIR=${BLOCK_DIR:-$HOME/.cache/campaign-block-47be87e8}
DAX_DIR=${DAX_DIR:-}
GOV_EXPECT=${GOV_EXPECT:-powersave}
PROBE_MAX_US=${PROBE_MAX_US:-500}
TAG=sean-tan-PC
STAMP0=$(date -u +%Y%m%dT%H%M%SZ)
BATCH="$HOME/.cache/campaigns-47be87e8-$STAMP0-$GOV_EXPECT"
export PATH="$VIRGIL/bin:$PATH"

die() { echo "desktop-campaigns-47be87e8: $*" >&2; exit 1; }
now() { date -u -Iseconds; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }
load() { cut -d' ' -f1-3 /proc/loadavg; }
iopsi() { awk '/^some/{sub("avg10=","",$2); print $2}' /proc/pressure/io; }

# The median and 10th percentile of 400 4 KiB pwrite+fdatasync pairs, in us.
sync_probe() {
	python3 -I - "$1" <<'EOF'
import os, sys, time
p = os.path.join(sys.argv[1], ".fdatasync-probe")
fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
os.pwrite(fd, b"\0" * (1 << 20), 0); os.fsync(fd)
lat = []
for i in range(400):
    os.pwrite(fd, os.urandom(4096), (i % 256) * 4096)
    t = time.perf_counter_ns(); os.fdatasync(fd); lat.append(time.perf_counter_ns() - t)
os.close(fd); os.unlink(p)
lat.sort()
print(f"{lat[200] // 1000} {lat[40] // 1000}")
EOF
}

probe_ok() {
	local i
	for i in 1 2 3 4 5 6 7 8; do
		read -r p50 p10 < <(sync_probe "$BLOCK_DIR")
		[ "${p50:-999999}" -le "$PROBE_MAX_US" ] && return 0
		[ -d "$BATCH" ] && echo "$(now) fdatasync-4k median ${p50} us p10 ${p10} us, over $PROBE_MAX_US" >> "$BATCH/batch.log"
		[ "$i" -lt 8 ] && sleep 60
	done
	return 1
}

toolchain() {
	echo "---- toolchain (desktop-campaigns-47be87e8.sh)"
	echo "v3c      $(command -v v3c) -> $(readlink -f "$(command -v v3c)")"
	echo "version  $(v3c -version 2>&1 | head -1)"
	echo "virgil   $VIRGIL: HEAD $(git -C "$VIRGIL" rev-parse HEAD), status $( [ -z "$(git -C "$VIRGIL" status --short --untracked-files=no)" ] && echo clean || echo DIRTY)"
	echo "why      Magpie's compiler (Virgil $VIRGIL_REV), rebuilt on this desktop, so that the desktop's results share Magpie's compiler"
	echo "engine   $1 (the original campaign's revision), worktree $2"
	echo "governor $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | tr '\n' ' ')"
	echo "batch    $BATCH"
}

cd "$REPO" || die "no $REPO"
[ $# -gt 0 ] || die "name the steps to run (see step() below)"
[ "$(git rev-parse --abbrev-ref HEAD)" = pwregions ] || die "check out pwregions in $REPO first"
[ -z "$(git status --short --untracked-files=no)" ] || die "$REPO has uncommitted changes to tracked files"
[ "$(git -C "$VIRGIL" rev-parse HEAD)" = "$VIRGIL_REV" ] || die "$VIRGIL is not at $VIRGIL_REV"
v3c -version 2>&1 | head -1 | grep -q 'III-11.1968' || die "v3c on PATH is not III-11.1968: $(command -v v3c)"
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
	[ "$(cat "$g")" = "$GOV_EXPECT" ] || die "$g is $(cat "$g"), not $GOV_EXPECT"
done
if [ -n "$DAX_DIR" ]; then
	[ -d "$DAX_DIR" ] && [ -w "$DAX_DIR" ] || die "$DAX_DIR is not a writable directory"
	findmnt -no OPTIONS -T "$DAX_DIR" | grep -q dax || die "$DAX_DIR is not on a DAX mount"
fi
pgrep -f Runner.Worker >/dev/null && die "a GitHub Actions job is running"
l1=$(cut -d' ' -f1 /proc/loadavg)
awk -v l="$l1" 'BEGIN{exit !(l < 2.5)}' || die "load $(load) is too high for a sitting; top: $(ps -eo comm --sort=-pcpu | sed -n 2,5p | tr '\n' ' ')"
awk -v p="$(iopsi)" 'BEGIN{exit !(p < 5)}' || die "IO pressure avg10 $(iopsi) % is too high for a sitting"
mkdir -p "$BATCH" "$BLOCK_DIR"
probe_ok || die "4 KiB fdatasync median ${p50} us (p10 ${p10}) in $BLOCK_DIR, over $PROBE_MAX_US: the disk is busy"
cp "$SCRIPT" "$BATCH/"
echo "$(now) start host $(hostname -s) compiler $(v3c -version 2>&1 | head -1) governor $GOV_EXPECT load $(load) io-psi $(iopsi) fdatasync-4k median ${p50} us p10 ${p10} us" | tee -a "$BATCH/batch.log"

# A clean detached worktree at REV with no compiled programs, so that every
# program is rebuilt by this compiler.
WT=
use_rev() {
	local rev; rev=$(git rev-parse "$1^{commit}") || die "no revision $1"
	WT=$HOME/.cache/engine-wt-${rev:0:8}
	if [ -e "$WT" ]; then
		[ "$(git -C "$WT" rev-parse HEAD)" = "$rev" ] || die "$WT exists at another revision"
		[ -z "$(git -C "$WT" status --short --untracked-files=no)" ] || die "$WT has tracked changes"
	else
		git worktree add -q --detach "$WT" "$rev" || die "worktree $WT"
	fi
	rm -f "$WT"/bin/*.x86-64-linux "$WT"/bin/Build-*.v3
	REV=$rev
}

run_step() {
	local name=$1 out=$2; shift 2
	probe_ok || die "4 KiB fdatasync median ${p50} us (p10 ${p10}) in $BLOCK_DIR, over $PROBE_MAX_US: stopping before $name"
	echo "$(now) begin $name rev ${REV:0:8} -> $(basename "$out") load $(load) io-psi $(iopsi) fdatasync-4k median ${p50} us p10 ${p10} us" | tee -a "$BATCH/batch.log"
	local before; before=$(ls "$WT/results" 2>/dev/null | sort)
	( cd "$WT" && "$@" ) > "$BATCH/$name.log" 2>&1
	local rc=$?
	# The driver may ignore the output override at an old revision: take any
	# new directory under the worktree's results/.
	local d new=()
	[ -d "$out" ] && new+=("$out")
	for d in $(comm -13 <(echo "$before") <(ls "$WT/results" 2>/dev/null | sort)); do
		[ "$WT/results/$d" = "$out" ] || new+=("$WT/results/$d")
	done
	for d in "${new[@]}"; do
		toolchain "$REV" "$WT" > "$d/toolchain.txt"
		cp -a "$d" "$REPO/results/"
	done
	read -r p50 p10 < <(sync_probe "$BLOCK_DIR")
	echo "$(now) end $name rc=$rc dirs=$(for d in "${new[@]}"; do basename "$d"; done | tr '\n' ' ')load $(load) io-psi $(iopsi) fdatasync-4k median ${p50} us p10 ${p10} us" | tee -a "$BATCH/batch.log"
	return 0
}

# The B+-tree kill loop has no driver: four runs of the program, as in
# results/20261014T042933Z-sean-tan-PC-pwbtree-kill, with a provenance file.
pwbtree_kill() {
	local out=$1 rc=0 bp b p
	mkdir -p "$out"
	./build.sh pwbtree x86-64-linux > "$out/build.log" 2>&1 || return 1
	{
		echo "---- revision"
		echo "commit $(git rev-parse HEAD)"
		echo "dirty  $(git diff --quiet && git diff --cached --quiet && echo no || echo YES) (tracked files)"
		echo "---- host"
		echo "hostname $(hostname)"
		echo "kernel   $(uname -srmo)"
		echo "started  $(now)"
		echo "load     $(load)"
		echo "governor $GOV_EXPECT"
		echo "---- directory"
		echo "block    $BLOCK_DIR"
		findmnt -no SOURCE,FSTYPE,OPTIONS -T "$BLOCK_DIR"
		echo "---- parameters"
		echo "args $BLOCK_DIR 50 1 256 4096 <backend> <provider> (max delay 20000 us, capacity 8, key space 600: the defaults)"
		echo "unpinned"
	} > "$out/provenance.txt"
	for bp in "direct ordinary" "direct elide-clwb" "file ordinary" "file elide-clwb"; do
		set -- $bp; b=$1; p=$2
		{ echo "bin/pwbtree.x86-64-linux \"$BLOCK_DIR\" 50 1 256 4096 $b $p"
		  bin/pwbtree.x86-64-linux "$BLOCK_DIR" 50 1 256 4096 "$b" "$p"; } > "$out/$b-$p.log" 2>&1 || rc=1
	done
	echo "finished $(now)" >> "$out/provenance.txt"
	return $rc
}

# The unit suite, as in results/20261027T104232Z-sean-tan-PC-unit-suite.
unit_suite() {
	local out=$1
	mkdir -p "$out"
	{
		echo "---- revision"; echo "commit $(git rev-parse HEAD)"
		echo "dirty  $(git diff --quiet && git diff --cached --quiet && echo no || echo YES) (tracked files)"
		echo "---- host"; echo "hostname $(hostname)"; echo "kernel   $(uname -srmo)"
		echo "cmdline  $(cat /proc/cmdline)"; echo "load     $(load)"
		echo "cwd      $(pwd) on $(findmnt -no SOURCE,FSTYPE -T .)"
		echo "---- build"; echo "started  $(now)"
		echo "command  env SHELLOPTS=xtrace make bin/unittest.x86-64-linux   (trace in build.log)"
	} > "$out/provenance.txt"
	env SHELLOPTS=xtrace make bin/unittest.x86-64-linux > "$out/build.log" 2>&1
	echo "finished $(now) (exit $?)" >> "$out/provenance.txt"
	{ echo "---- run"; echo "started  $(now)"
	  echo "command  /usr/bin/time -v env TEST_TARGET=x86-64-linux test/unit.sh   (cwd: the worktree root; WIZENG_OPTS unset)"; } >> "$out/provenance.txt"
	/usr/bin/time -v -o "$out/time.txt" env TEST_TARGET=x86-64-linux test/unit.sh > "$out/unit.log" 2>&1
	local rc=$?
	echo "finished $(now) (exit $rc)" >> "$out/provenance.txt"
	{ echo "registered $(grep -c '^##+' "$out/unit.log")"; echo "passed     $(grep -c '^##-ok' "$out/unit.log")"
	  echo "failed     $(grep -c '^##-fail' "$out/unit.log")"; } > "$out/counts.txt"
	return $rc
}

need_dax() { [ -n "$DAX_DIR" ] || die "step $1 needs DAX_DIR"; export PWASM_PMEM_TEST_DIR=$DAX_DIR; }
need_gov() { [ "$GOV_EXPECT" = "$2" ] || die "step $1 runs under $2, not $GOV_EXPECT"; }

step() {
	local s o R; s=$(stamp)
	case $1 in
	# ---- powersave, block storage only
	pwbtree)      # results/20261014T041846Z-sean-tan-PC-pwbtree-bench-cpus2-powersave
		need_gov "$1" powersave; use_rev 73f5aed2; R=$WT/results; o="$R/$s-$TAG-pwbtree-bench-cpus2-powersave"
		run_step "$1" "$o" env PWBB_CPUS=2 PWBB_CONFIGS="file-block direct-block" \
			PWBB_BLOCK_DIR="$BLOCK_DIR" PWBB_OUT="$o" scripts/pwbtree-bench.sh campaign ;;
	pwsieve-ab)   # results/20261013T124441Z-sean-tan-PC-pwsieve-bench-cpus2-powersave-file-ab
		need_gov "$1" powersave; use_rev c1dfd14f; R=$WT/results; o="$R/$s-$TAG-pwsieve-bench-cpus2-powersave-file-ab"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CONFIGS="file-block file-block-legacy file-block-msync" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	pwbtree-kill) # results/20261014T042933Z-sean-tan-PC-pwbtree-kill
		need_gov "$1" powersave; use_rev 62300c6c; R=$WT/results; o="$R/$s-$TAG-pwbtree-kill"
		run_step "$1" "$o" pwbtree_kill "$o" ;;
	direct-control) # results/20260927T081826Z-sean-tan-PC
		need_gov "$1" powersave; use_rev 4e5a346f; R=$WT/results; o="$R/$s-$TAG-direct-control"
		run_step "$1" "$o" env PWEXP_BLOCK_DIR="$HOME" PWEXP_NUMA_NODE=none \
			PWEXP_OUT="$o" scripts/pmem-experiments.sh direct-control ;;
	direct-cost)  # the file and direct-file cost runs of results/20260927T083305Z-sean-tan-PC-direct-nvme;
	              # 4e5a346f's cost mode has no config filter, so it also runs pmem-dax and file-dax
		need_gov "$1" powersave; need_dax "$1"; use_rev 4e5a346f; R=$WT/results; o="$R/$s-$TAG-direct-nvme"
		run_step "$1" "$o" env PWEXP_BLOCK_DIR="$HOME" PWEXP_NUMA_NODE=none \
			PWEXP_OUT="$o" scripts/pmem-experiments.sh cost ;;
	unit-suite)   # results/20261027T104232Z-sean-tan-PC-unit-suite
		need_gov "$1" powersave; use_rev 5e3f6219; R=$WT/results; o="$R/$s-$TAG-unit-suite"
		run_step "$1" "$o" unit_suite "$o" ;;
	# ---- powersave, with the emulated PMEM device
	pwsieve-clock) # results/20260929T025351Z-sean-tan-PC-pwsieve-bench-cpus2-clock-powersave
		need_gov "$1" powersave; need_dax "$1"; use_rev 519859ed; R=$WT/results; o="$R/$s-$TAG-pwsieve-bench-cpus2-clock-powersave"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CLOCK=1 \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	# ---- performance (scripts/desktop-sitting-47be87e8.sh sets the governor)
	pwsieve)      # results/20260928T100258Z-sean-tan-PC-pwsieve-bench-cpus2 (performance)
		need_gov "$1" performance; need_dax "$1"; use_rev ef11daf9; R=$WT/results; o="$R/$s-$TAG-pwsieve-bench-cpus2"
		run_step "$1" "$o" env PWSB_CPUS=2 \
			PWSB_CONFIGS="pmem-auto pmem-clflushopt pmem-none file-dax file-block direct-block" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	clwb-cpus2)   # results/20260928T075258Z-sean-tan-PC-clwb-eviction-cpus2 (performance)
		need_gov "$1" performance; need_dax "$1"; use_rev 8ba684ff; R=$WT/results; o="$R/$s-$TAG-clwb-eviction-cpus2"
		run_step "$1" "$o" env PWCLWB_CPUS=2 \
			PWCLWB_CONFIGS="pmem-auto pmem-auto-entry pmem-clflushopt pmem-clflushopt-entry pmem-none file-dax" \
			PWCLWB_OUT="$o" scripts/clwb-eviction.sh all ;;
	pwsieve-ab-perf) # results/20261015T052543Z-sean-tan-PC-pwsieve-bench-cpus2-performance-file-ab
		need_gov "$1" performance; use_rev b358dbf0; R=$WT/results; o="$R/$s-$TAG-pwsieve-bench-cpus2-performance-file-ab"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CONFIGS="file-block file-block-legacy direct-block" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	pwsieve-ab-perf20) # results/20261015T111803Z-sean-tan-PC-pwsieve-bench-cpus20-performance-file-ab
		need_gov "$1" performance; use_rev a39d024f; R=$WT/results; o="$R/$s-$TAG-pwsieve-bench-cpus20-performance-file-ab"
		run_step "$1" "$o" env PWSB_CPUS=20 PWSB_REPS=15 PWSB_CONFIGS="file-block file-block-legacy direct-block" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	*) die "unknown step $1" ;;
	esac
}

for name in "$@"; do step "$name"; done
echo "$(now) done" | tee -a "$BATCH/batch.log"
