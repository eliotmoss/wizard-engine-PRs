#!/usr/bin/env bash
# Rerun, on sean-tan-PC and at one engine revision, the desktop campaigns the
# thesis cites, with each campaign's original parameters, so that they share
# the revision of the test suites (95e055fa). Normally started, as the user, by
# scripts/desktop-sitting.sh, which sets up the emulated PMEM device and the
# governor as root; it can also be run alone for the steps that need neither.
#
# Usage, on sean-tan-PC, from a clean pwregions checkout:
#   GOV_EXPECT=powersave|performance [DAX_DIR=<dir on a DAX mount>] \
#     bash scripts/desktop-campaigns.sh STEP...
#
# Each step runs one driver in a detached worktree at REV, so the provenance
# each driver writes names REV and a clean tree. Its results directory is
# copied into this checkout's results/ when the step ends; nothing is
# committed. The batch log is $BATCH/batch.log. The worktree is left in place;
# remove it with: git worktree remove --force "$WT".
#
# Block storage on this desktop shares the root filesystem with every other
# process, and its flush latency varies. On 2026-10-27 a 4 KiB fdatasync took
# 1.5 ms at the median through the first 35 minutes of a sitting begun just
# after a reboot, with nothing else running, and came and went for minutes
# more; afterwards it took 0.25 ms. The cause is not identified. So the script
# refuses to start unless the machine is quiet (load, IO pressure, no CI job),
# and probes such an fdatasync before and after every step, refusing to start a
# step while the median stays over PROBE_MAX_US; the batch log records each.
set -uo pipefail

REV=95e055faff802e8c179c608ef775a02c99072c09
SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
REPO=${REPO:-$(cd "$(dirname "$SCRIPT")/.." && pwd)}
WT=${WT:-$HOME/.cache/engine-wt-${REV:0:8}}
BLOCK_DIR=${BLOCK_DIR:-$WT/bin/campaign-block}
DAX_DIR=${DAX_DIR:-}
GOV_EXPECT=${GOV_EXPECT:-powersave}
PROBE_MAX_US=${PROBE_MAX_US:-500}
TAG=sean-tan-PC          # the host tag of every results directory from this desktop
STAMP0=$(date -u +%Y%m%dT%H%M%SZ)
BATCH="$HOME/.cache/campaigns-${REV:0:8}-$STAMP0-$GOV_EXPECT"

die() { echo "desktop-campaigns: $*" >&2; exit 1; }
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

# probe_ok: set p50 and p10 from the probe; while the median is over
# PROBE_MAX_US, log it, wait 30 s and probe again, four probes at most.
probe_ok() {
	local i
	for i in 1 2 3 4; do
		read -r p50 p10 < <(sync_probe "$BLOCK_DIR")
		[ "${p50:-999999}" -le "$PROBE_MAX_US" ] && return 0
		[ -d "$BATCH" ] && echo "$(now) fdatasync-4k median ${p50} us p10 ${p10} us, over $PROBE_MAX_US" >> "$BATCH/batch.log"
		[ "$i" -lt 4 ] && sleep 30
	done
	return 1
}

cd "$REPO" || die "no $REPO"
[ $# -gt 0 ] || die "name the steps to run (see step() below)"
[ "$(git rev-parse --abbrev-ref HEAD)" = pwregions ] || die "check out pwregions in $REPO first"
[ -z "$(git status --short --untracked-files=no)" ] || die "$REPO has uncommitted changes to tracked files"
git cat-file -e "$REV^{commit}" || die "revision $REV not found"
command -v v3c-x86-64-linux >/dev/null || command -v v3c >/dev/null || die "no v3c on PATH"
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
	[ "$(cat "$g")" = "$GOV_EXPECT" ] || die "$g is $(cat "$g"), not $GOV_EXPECT"
done
if [ -n "$DAX_DIR" ]; then
	[ -d "$DAX_DIR" ] && [ -w "$DAX_DIR" ] || die "$DAX_DIR is not a writable directory"
	findmnt -no OPTIONS -T "$DAX_DIR" | grep -q dax || die "$DAX_DIR is not on a DAX mount"
fi
pgrep -f Runner.Worker >/dev/null && die "a GitHub Actions job is running"
l1=$(cut -d' ' -f1 /proc/loadavg)
awk -v l="$l1" 'BEGIN{exit !(l < 1.5)}' || die "load $(load) is too high for a sitting; top: $(ps -eo comm --sort=-pcpu | sed -n 2,5p | tr '\n' ' ')"
awk -v p="$(iopsi)" 'BEGIN{exit !(p < 5)}' || die "IO pressure avg10 $(iopsi) % is too high for a sitting"
if [ -e "$WT" ]; then
	[ "$(git -C "$WT" rev-parse HEAD)" = "$REV" ] || die "$WT exists at another revision"
	[ -z "$(git -C "$WT" status --short --untracked-files=no)" ] || die "$WT has tracked changes"
else
	git worktree add -q --detach "$WT" "$REV"
fi
mkdir -p "$BATCH" "$BLOCK_DIR"
probe_ok || die "4 KiB fdatasync median ${p50} us (p10 ${p10}) in $BLOCK_DIR, over $PROBE_MAX_US: the disk is busy"
cp "$SCRIPT" "$BATCH/"
echo "$(now) start rev $REV host $(hostname -s) wt $WT governor $GOV_EXPECT load $(load) io-psi $(iopsi) fdatasync-4k median ${p50} us p10 ${p10} us" | tee -a "$BATCH/batch.log"

run_step() {
	local name=$1 out=$2; shift 2
	probe_ok || die "4 KiB fdatasync median ${p50} us (p10 ${p10}) in $BLOCK_DIR, over $PROBE_MAX_US: stopping before $name"
	echo "$(now) begin $name -> $out load $(load) io-psi $(iopsi) fdatasync-4k median ${p50} us p10 ${p10} us" | tee -a "$BATCH/batch.log"
	( cd "$WT" && "$@" ) > "$BATCH/$name.log" 2>&1
	local rc=$?
	[ -d "$out" ] && cp -a "$out" "$REPO/results/"
	read -r p50 p10 < <(sync_probe "$BLOCK_DIR")
	echo "$(now) end $name rc=$rc dir=$(basename "$out") load $(load) io-psi $(iopsi) fdatasync-4k median ${p50} us p10 ${p10} us" | tee -a "$BATCH/batch.log"
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

need_dax() { [ -n "$DAX_DIR" ] || die "step $1 needs DAX_DIR"; export PWASM_PMEM_TEST_DIR=$DAX_DIR; }
need_gov() { [ "$GOV_EXPECT" = "$2" ] || die "step $1 runs under $2, not $GOV_EXPECT"; }

R="$WT/results"
step() {
	local s o; s=$(stamp)
	case $1 in
	# ---- powersave, block storage only
	pwbtree)      # results/20261014T041846Z-sean-tan-PC-pwbtree-bench-cpus2-powersave
		need_gov "$1" powersave; o="$R/$s-$TAG-pwbtree-bench-cpus2-powersave"
		run_step "$1" "$o" env PWBB_CPUS=2 PWBB_CONFIGS="file-block direct-block" \
			PWBB_BLOCK_DIR="$BLOCK_DIR" PWBB_OUT="$o" scripts/pwbtree-bench.sh campaign ;;
	pwsieve-ab)   # results/20261013T124441Z-sean-tan-PC-pwsieve-bench-cpus2-powersave-file-ab
		need_gov "$1" powersave; o="$R/$s-$TAG-pwsieve-bench-cpus2-powersave-file-ab"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CONFIGS="file-block file-block-legacy file-block-msync" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	pwbtree-kill) # results/20261014T042933Z-sean-tan-PC-pwbtree-kill
		need_gov "$1" powersave; o="$R/$s-$TAG-pwbtree-kill"
		run_step "$1" "$o" pwbtree_kill "$o" ;;
	direct-control) # results/20260927T081826Z-sean-tan-PC
		need_gov "$1" powersave; o="$R/$s-$TAG-direct-control"
		run_step "$1" "$o" env PWEXP_BLOCK_DIR="$HOME" PWEXP_NUMA_NODE=none \
			PWEXP_OUT="$o" scripts/pmem-experiments.sh direct-control ;;
	direct-cost)  # the file and direct-file cost runs of results/20260927T083305Z-sean-tan-PC-direct-nvme
		need_gov "$1" powersave; o="$R/$s-$TAG-direct-nvme"
		run_step "$1" "$o" env PWEXP_BLOCK_DIR="$HOME" PWEXP_NUMA_NODE=none \
			PWEXP_CONFIGS="file-block direct-block" PWEXP_OUT="$o" scripts/pmem-experiments.sh cost ;;
	# ---- powersave, with the emulated PMEM device (DRAM reserved by memmap=)
	pwsieve)      # results/20260928T100258Z-sean-tan-PC-pwsieve-bench-cpus2
		need_gov "$1" powersave; need_dax "$1"; o="$R/$s-$TAG-pwsieve-bench-cpus2"
		run_step "$1" "$o" env PWSB_CPUS=2 \
			PWSB_CONFIGS="pmem-auto pmem-clflushopt pmem-none file-dax file-block direct-block" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	pwsieve-clock) # results/20260929T025351Z-sean-tan-PC-pwsieve-bench-cpus2-clock-powersave
		need_gov "$1" powersave; need_dax "$1"; o="$R/$s-$TAG-pwsieve-bench-cpus2-clock-powersave"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CLOCK=1 \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	clwb-cpus2)   # results/20260928T075258Z-sean-tan-PC-clwb-eviction-cpus2, without the removed -entry placement
		need_gov "$1" powersave; need_dax "$1"; o="$R/$s-$TAG-clwb-eviction-cpus2"
		run_step "$1" "$o" env PWCLWB_CPUS=2 PWCLWB_CONFIGS="pmem-auto pmem-clflushopt pmem-none file-dax" \
			PWCLWB_OUT="$o" scripts/clwb-eviction.sh all ;;
	clwb-cpus20)  # results/20260928T075906Z-sean-tan-PC-clwb-eviction-cpus20, without the removed -entry placement
		need_gov "$1" powersave; need_dax "$1"; o="$R/$s-$TAG-clwb-eviction-cpus20"
		run_step "$1" "$o" env PWCLWB_CPUS=20 PWCLWB_REPS=15 \
			PWCLWB_CONFIGS="pmem-auto pmem-clflushopt pmem-none file-dax" \
			PWCLWB_OUT="$o" scripts/clwb-eviction.sh all ;;
	# ---- performance
	pwsieve-clock-perf) # results/20260929T031445Z-sean-tan-PC-pwsieve-bench-cpus2-clock-performance
		need_gov "$1" performance; need_dax "$1"; o="$R/$s-$TAG-pwsieve-bench-cpus2-clock-performance"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CLOCK=1 \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	pwsieve-ab-perf) # results/20261015T052543Z-sean-tan-PC-pwsieve-bench-cpus2-performance-file-ab
		need_gov "$1" performance; o="$R/$s-$TAG-pwsieve-bench-cpus2-performance-file-ab"
		run_step "$1" "$o" env PWSB_CPUS=2 PWSB_CONFIGS="file-block file-block-legacy direct-block" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	pwsieve-ab-perf20) # results/20261015T111803Z-sean-tan-PC-pwsieve-bench-cpus20-performance-file-ab
		need_gov "$1" performance; o="$R/$s-$TAG-pwsieve-bench-cpus20-performance-file-ab"
		run_step "$1" "$o" env PWSB_CPUS=20 PWSB_REPS=15 PWSB_CONFIGS="file-block file-block-legacy direct-block" \
			PWSB_BLOCK_DIR="$BLOCK_DIR" PWSB_OUT="$o" scripts/pwsieve-bench.sh campaign ;;
	*) die "unknown step $1" ;;
	esac
}

for name in "$@"; do step "$name"; done
echo "$(now) done" | tee -a "$BATCH/batch.log"
