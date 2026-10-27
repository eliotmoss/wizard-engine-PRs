#!/usr/bin/env bash
# Rerun, on Magpie and at one engine revision, every measurement campaign the
# thesis cites from this host, with each campaign's original parameters, so
# that the timing campaigns, kill loops and controls share the revision of the
# test suites (scripts/magpie-test-suites.sh, 95e055fa).
#
# Usage, on Magpie, from a clean pwregions checkout:
#   bash scripts/magpie-campaigns.sh [STEP...]     (default: every step, in order)
#
# Each step runs one driver in a detached worktree at REV, so the provenance
# each driver writes names REV and a clean tree. Its results directory is
# copied into this checkout's results/ when the step ends; nothing is
# committed. The batch log (batch.log, one line per step with its exit status
# and directory) is in $BATCH. The worktree is left in place for inspection;
# remove it with: git worktree remove --force "$WT".
#
# Which original run each step repeats is in the STEPS table below.
#
# Overrides: DAX_DIR (/mnt/pmem0.0/sean), BLOCK_DIR ($HOME, ext4 on the
# server's disk), SYNC=0 to skip fetching origin (a host that reaches GitHub
# only through a forwarded agent).
set -uo pipefail

REV=95e055faff802e8c179c608ef775a02c99072c09
SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
REPO=${REPO:-$(cd "$(dirname "$SCRIPT")/.." && pwd)}
DAX_DIR=${DAX_DIR:-/mnt/pmem0.0/sean}
BLOCK_DIR=${BLOCK_DIR:-$HOME}
SYNC=${SYNC:-1}
WT="$HOME/wizard-engine-wt-${REV:0:8}"
STAMP0=$(date -u +%Y%m%dT%H%M%SZ)
BATCH="$HOME/campaigns-${REV:0:8}-$STAMP0"
HOST=$(hostname -s)

die() { echo "magpie-campaigns: $*" >&2; exit 1; }
now() { date -u -Iseconds; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }

# ---- Preflight.
cd "$REPO" || die "no $REPO"
[ "$(git rev-parse --abbrev-ref HEAD)" = pwregions ] || die "check out pwregions in $REPO first"
[ -z "$(git status --short --untracked-files=no)" ] || die "$REPO has uncommitted changes to tracked files"
if [ "$SYNC" = 1 ]; then
	git fetch -q origin
	git merge -q --ff-only origin/pwregions || die "pwregions cannot fast-forward to origin/pwregions"
fi
git cat-file -e "$REV^{commit}" || die "revision $REV not found"
command -v v3c-x86-64-linux >/dev/null || command -v v3c >/dev/null || die "no v3c on PATH"
[ -d "$DAX_DIR" ] && [ -w "$DAX_DIR" ] || die "$DAX_DIR is not a writable directory"
findmnt -no OPTIONS -T "$DAX_DIR" | grep -q dax || die "$DAX_DIR is not on a DAX mount"
if [ -e "$WT" ]; then
	[ "$(git -C "$WT" rev-parse HEAD)" = "$REV" ] || die "$WT exists at another revision"
	[ -z "$(git -C "$WT" status --short --untracked-files=no)" ] || die "$WT has tracked changes"
else
	git worktree add -q --detach "$WT" "$REV"
fi
mkdir -p "$BATCH"
cp "$SCRIPT" "$BATCH/"
export PWASM_PMEM_TEST_DIR=$DAX_DIR
echo "$(now) start rev $REV host $HOST wt $WT" | tee -a "$BATCH/batch.log"

# run_step NAME OUTDIR-SUFFIX COMMAND...: run COMMAND in the worktree with its
# output directory set by the caller's environment, then copy the directory.
run_step() {
	local name=$1 out=$2; shift 2
	echo "$(now) begin $name -> $out" | tee -a "$BATCH/batch.log"
	( cd "$WT" && "$@" ) > "$BATCH/$name.log" 2>&1
	local rc=$?
	if [ -d "$out" ]; then
		cp -a "$out" "$REPO/results/"
	fi
	echo "$(now) end $name rc=$rc dir=$(basename "$out")" | tee -a "$BATCH/batch.log"
	return 0
}

# The B+-tree kill loop has no driver: four runs of the program, as in
# results/20261014T110033Z-magpie-pwbtree-kill, with a provenance file.
pwbtree_kill() {
	local out=$1
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
		echo "load     $(cut -d' ' -f1-3 /proc/loadavg)"
		echo "---- parameters"
		echo "args <dir> 50 1 256 4096 <backend> <provider> (max delay 20000 us, capacity 8, key space 600: the defaults)"
		echo "dirs pmem $DAX_DIR; file and direct $BLOCK_DIR"
		echo "unpinned"
	} > "$out/provenance.txt"
	local rc=0 b p d
	for bp in "pmem ordinary" "file ordinary" "direct ordinary" "direct elide-clwb"; do
		set -- $bp; b=$1; p=$2
		[ "$b" = pmem ] && d=$DAX_DIR || d=$BLOCK_DIR
		{ echo "bin/pwbtree.x86-64-linux \"$d\" 50 1 256 4096 $b $p"
		  bin/pwbtree.x86-64-linux "$d" 50 1 256 4096 "$b" "$p"; } > "$out/$b-$p.log" 2>&1 || rc=1
	done
	echo "finished $(now)" >> "$out/provenance.txt"
	return $rc
}

R="$WT/results"
# name | repeats | command (environment set inline)
step() {
	local s; s=$(stamp)
	case $1 in
	pwops)       # results/20261014T121109Z-magpie-pwops-bench
		run_step pwops "$R/$s-$HOST-pwops-bench" env PWOB_BLOCK_DIR="$BLOCK_DIR" \
			PWOB_OUT="$R/$s-$HOST-pwops-bench" scripts/pwops-bench.sh campaign ;;
	pwsieve)     # results/20261014T025706Z-magpie-pwsieve-bench
		run_step pwsieve "$R/$s-$HOST-pwsieve-bench" env PWSB_BLOCK_DIR="$BLOCK_DIR" \
			PWSB_CONFIGS="pmem-auto pmem-clflushopt pmem-none file-dax file-block direct-block file-block-legacy" \
			PWSB_OUT="$R/$s-$HOST-pwsieve-bench" scripts/pwsieve-bench.sh campaign ;;
	pwsieve-ab)  # results/20261013T134636Z-magpie-pwsieve-bench (the fence A/B)
		run_step pwsieve-ab "$R/$s-$HOST-pwsieve-bench-file-ab" env PWSB_BLOCK_DIR="$BLOCK_DIR" \
			PWSB_CONFIGS="file-dax file-dax-legacy file-dax-msync file-block file-block-legacy file-block-msync" \
			PWSB_OUT="$R/$s-$HOST-pwsieve-bench-file-ab" scripts/pwsieve-bench.sh campaign ;;
	pwbtree)     # results/20261014T111205Z-magpie-pwbtree-bench
		run_step pwbtree "$R/$s-$HOST-pwbtree-bench" env PWBB_BLOCK_DIR="$BLOCK_DIR" \
			PWBB_OUT="$R/$s-$HOST-pwbtree-bench" scripts/pwbtree-bench.sh campaign ;;
	pwbtree-kill) # results/20261014T110033Z-magpie-pwbtree-kill
		run_step pwbtree-kill "$R/$s-$HOST-pwbtree-kill" pwbtree_kill "$R/$s-$HOST-pwbtree-kill" ;;
	cost)        # results/20260927T074301Z-magpie and the cost half of 20260918T045605Z-magpie
		run_step cost "$R/$s-$HOST-cost" env PWEXP_BLOCK_DIR="$BLOCK_DIR" \
			PWEXP_OUT="$R/$s-$HOST-cost" scripts/pmem-experiments.sh cost ;;
	cost-node1)  # results/20260918T062908Z-magpie (node 1), against cost's node 0
		run_step cost-node1 "$R/$s-$HOST-cost-node1" env PWEXP_BLOCK_DIR="$BLOCK_DIR" PWEXP_NUMA_NODE=1 \
			PWEXP_OUT="$R/$s-$HOST-cost-node1" scripts/pmem-experiments.sh cost ;;
	regionsize)  # results/20260923T032952Z-magpie-regionsize
		run_step regionsize "$R/$s-$HOST-regionsize" env PWEXP_CONFIGS=file-dax PWEXP_SIZES=8 \
			PWEXP_REGION_BLOCKSIZES="2048 4096 8192 16384" \
			PWEXP_OUT="$R/$s-$HOST-regionsize" scripts/pmem-experiments.sh cost ;;
	bs2048-4096) # results/20260923T043535Z-magpie-bs2048-4096
		run_step bs2048-4096 "$R/$s-$HOST-bs2048-4096" env PWEXP_BLOCK_DIR="$BLOCK_DIR" \
			PWEXP_CONFIGS="pmem-dax file-dax file-block" PWEXP_SIZES="1 8 24" \
			PWEXP_REGION_BLOCKSIZES="2048 4096" \
			PWEXP_OUT="$R/$s-$HOST-bs2048-4096" scripts/pmem-experiments.sh cost ;;
	geometry)    # results/20260923T053541Z-magpie-g256x4096-512x4096, which was pinned to node 1
		run_step geometry "$R/$s-$HOST-g256x4096-512x4096" env PWEXP_BLOCK_DIR="$BLOCK_DIR" PWEXP_NUMA_NODE=1 \
			PWEXP_CONFIGS="pmem-dax file-dax file-block" PWEXP_SIZES="1 8 24" \
			PWEXP_REGION_GEOMETRIES="256x4096 512x4096" \
			PWEXP_OUT="$R/$s-$HOST-g256x4096-512x4096" scripts/pmem-experiments.sh cost ;;
	control)     # results/20260927T074021Z-magpie (and the control half of 20260918T045605Z-magpie)
		run_step control "$R/$s-$HOST-control" env \
			PWEXP_OUT="$R/$s-$HOST-control" scripts/pmem-experiments.sh control ;;
	direct-control) # results/20260927T073911Z-magpie
		run_step direct-control "$R/$s-$HOST-direct-control" env PWEXP_BLOCK_DIR="$BLOCK_DIR" \
			PWEXP_OUT="$R/$s-$HOST-direct-control" scripts/pmem-experiments.sh direct-control ;;
	clwb)        # results/20260928T001505Z-magpie-clwb-eviction (probe and campaign)
		run_step clwb "$R/$s-$HOST-clwb-eviction" env \
			PWCLWB_OUT="$R/$s-$HOST-clwb-eviction" scripts/clwb-eviction.sh all ;;
	clwb-stride) # results/20260928T024904Z-magpie-clwb-eviction (deferred and stride 64)
		run_step clwb-stride "$R/$s-$HOST-clwb-eviction-stride" env \
			PWCLWB_CONFIGS="pmem-auto pmem-deferred pmem-none pmem-auto-s64 pmem-deferred-s64 pmem-none-s64" \
			PWCLWB_OUT="$R/$s-$HOST-clwb-eviction-stride" scripts/clwb-eviction.sh campaign ;;
	*) die "unknown step $1" ;;
	esac
}

ALL="pwsieve pwsieve-ab pwbtree pwbtree-kill cost cost-node1 regionsize bs2048-4096 geometry control direct-control clwb clwb-stride pwops"
[ $# -gt 0 ] || set -- $ALL
for name in "$@"; do step "$name"; done
echo "$(now) done" | tee -a "$BATCH/batch.log"
