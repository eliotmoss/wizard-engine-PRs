#!/usr/bin/env bash
# A/B of CPU-bound time on Magpie, 2026-10-27: does the sieve compute phase
# (426 us/step at 42edc6ff on 2026-10-14, 482 at 95e055fa today) and the
# B+-tree pmem-none lookup (277 vs 333 ns) move with the revision or the day?
# Interleaved: old, new, old, new, ... on the same DAX dir, pinned node 0.
set -u
export PATH=$HOME/virgil-titzer/bin:$PATH
cd ~/wizard-engine-PRs || exit 1
S=42edc6ff0809969db53509425de97a3d5b3ac952   # 20261014T025706Z-magpie-pwsieve-bench
T=1d7c3276a1af75cd954c765c7bcc5f50635e2ce1   # 20261014T111205Z-magpie-pwbtree-bench
N=95e055faff802e8c179c608ef775a02c99072c09
for r in $S $T; do w=$HOME/wizard-engine-wt-${r:0:8}; [ -e $w ] || git worktree add -q --detach $w $r; done
OUT=$HOME/ab-compute-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p $OUT; echo $OUT
export PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean
for i in 1 2 3; do
  for r in $S $N; do w=$HOME/wizard-engine-wt-${r:0:8}
    echo "$(date -u -Iseconds) sieve ${r:0:8} $i load $(cut -d" " -f1 /proc/loadavg)" >> $OUT/ab.log
    (cd $w && env PWSB_CONFIGS="pmem-auto pmem-none" PWSB_REPS=1 PWSB_OUT=$OUT/sieve-${r:0:8}-$i scripts/pwsieve-bench.sh campaign) > $OUT/sieve-${r:0:8}-$i.log 2>&1
  done
  for r in $T $N; do w=$HOME/wizard-engine-wt-${r:0:8}
    echo "$(date -u -Iseconds) btree ${r:0:8} $i load $(cut -d" " -f1 /proc/loadavg)" >> $OUT/ab.log
    (cd $w && env PWBB_CONFIGS="pmem-none pmem-auto" PWBB_REPS=1 PWBB_OUT=$OUT/btree-${r:0:8}-$i scripts/pwbtree-bench.sh campaign) > $OUT/btree-${r:0:8}-$i.log 2>&1
  done
done
echo "$(date -u -Iseconds) done" >> $OUT/ab.log
