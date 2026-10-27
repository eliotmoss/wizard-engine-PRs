#!/usr/bin/env bash
# A/B of block-storage boundaries on Magpie, 2026-10-27: are /home boundaries
# 7-12 % slower at 95e055fa than at the October revisions because of the
# revision or the day? Interleaved old, new, ..., on /home, pinned node 0.
set -u
export PATH=$HOME/virgil-titzer/bin:$PATH
cd ~/wizard-engine-PRs || exit 1
C=9f8dead1505c24a0893615a1b088aa025a06c9c5   # 20260927T074301Z-magpie (cost)
T=1d7c3276a1af75cd954c765c7bcc5f50635e2ce1   # 20261014T111205Z-magpie-pwbtree-bench
N=95e055faff802e8c179c608ef775a02c99072c09
for r in $C $T; do w=$HOME/wizard-engine-wt-${r:0:8}; [ -e $w ] || git worktree add -q --detach $w $r; done
OUT=$HOME/ab-block-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p $OUT; echo $OUT
export PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean
for i in 1 2 3; do
  for r in $C $N; do w=$HOME/wizard-engine-wt-${r:0:8}
    echo "$(date -u -Iseconds) cost ${r:0:8} $i load $(cut -d" " -f1 /proc/loadavg)" >> $OUT/ab.log
    (cd $w && env PWEXP_BLOCK_DIR=$HOME PWEXP_SIZES=8 PWEXP_REPS=1 PWEXP_OUT=$OUT/cost-${r:0:8}-$i scripts/pmem-experiments.sh cost) > $OUT/cost-${r:0:8}-$i.log 2>&1
  done
  for r in $T $N; do w=$HOME/wizard-engine-wt-${r:0:8}
    echo "$(date -u -Iseconds) btree ${r:0:8} $i load $(cut -d" " -f1 /proc/loadavg)" >> $OUT/ab.log
    (cd $w && env PWBB_BLOCK_DIR=$HOME PWBB_CONFIGS=file-block PWBB_REPS=1 PWBB_OUT=$OUT/btree-${r:0:8}-$i scripts/pwbtree-bench.sh campaign) > $OUT/btree-${r:0:8}-$i.log 2>&1
  done
done
echo "$(date -u -Iseconds) done" >> $OUT/ab.log
echo ALL-DONE
