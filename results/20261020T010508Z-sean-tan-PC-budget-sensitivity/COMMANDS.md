# Commands to reproduce (budget-sensitivity study, 2026-10-20)

Everything ran on sean-tan-PC (hostname pc-ubuntu) from an ext4 working
directory (`/tmp` is tmpfs and O_DIRECT fails there). Paths below are the ones
used; `$R` is this directory.

## 1. Scratch worktree and build

```sh
git -C ~/research/wizard-engine-PRs worktree add ~/.cache/budget-study-wt -b budget-study 129555ed
cd ~/.cache/budget-study-wt
git apply $R/harness.patch            # the scratch changes; nothing is committed
PATH=$HOME/research/virgil-titzer/bin:$PATH ./build.sh unittest x86-64-linux
mkdir -p ~/.cache/budget-study-run/bin
cp bin/unittest.x86-64-linux ~/.cache/budget-study-run/bin/unittest-frozen-v2
sha256sum ~/.cache/budget-study-run/bin/unittest-frozen-v2   # 42783700...0a, raw/binaries.sha256
```

The scripts default to that binary (`STUDY_BIN` overrides it). One test is
`budget_study:<CASE>_b<budget>_s<salt>`, for example:

```sh
cd ~/.cache/budget-study-run
taskset -c 4 ./bin/unittest-frozen-v2 'budget_study:M2_CHECKSUM_SKIP_b12_s0'
```

Cases are listed in `enum BudgetCase` in `test/unittest/x86-64-linux/BudgetStudyTest.v3`
(harness.patch); budgets are 1, 2, 3, 4, 6, 8, 10, 12, 13, 14, 15, 16, 32, 64
and salts 0 to 9. Salt 0 is the suite's own per-cut seed.

Copy the scripts into the run directory first:
`mkdir -p ~/.cache/budget-study-run && cp -r $R/scripts ~/.cache/budget-study-run/`.
The task lists `raw/tasks-anchors.txt` and `raw/tasks-salt0.txt` are in this
directory (the salt-0 list is every case at every budget, B+-tree runs and
large budgets first); `raw/tasks-salts1-9.txt` is generated below.

## 2. The suite unchanged at salt 0

```sh
cd ~/.cache/budget-study-run
for p in 'persistent_control:*' 'persistent_sieve:*' 'persistent_btree:*' 'persistent_alloc:*' 'persistent_explore:*'; do
  f=raw/suite/$(echo $p | tr -d ':*').txt
  taskset -c 2 ./bin/unittest-frozen-v2 "$p" > $f 2>&1
  echo "$p exit=$? ok=$(grep -c '^##-ok' $f) fail=$(grep -c '^##-fail' $f)"
done | tee raw/suite/summary.txt
```

## 3. Anchors, then the catch and false-positive matrix

```sh
cd ~/.cache/budget-study-run
python3 scripts/run.py raw/tasks-anchors.txt raw/anchors 0,2,4,6,8,10,12,14
uptime > raw/matrix-uptime-before.txt
python3 scripts/run.py raw/tasks-salt0.txt raw/matrix 0,2,4,6,8,10,12,14,16,17,18,19,20,21,22,23,24,25,26,27
uptime > raw/matrix-uptime-after.txt
python3 scripts/aggregate.py raw/matrix /tmp/bs-catch0v2.csv /tmp/bs-cells0v2.txt
# salts 1-9 for every (case, budget) whose salt-0 run checked a random-stage image:
python3 - <<'PY'
import csv
rows = list(csv.DictReader(open('/tmp/bs-catch0v2.csv')))
cells = [(r['case'], int(r['budget'])) for r in rows if int(r['randomImages']) > 0]
order = sorted(cells, key=lambda cb: (0 if 'BTREE' in cb[0] else 1, -cb[1]))
with open('raw/tasks-salts1-9.txt', 'w') as f:
    for c, b in order:
        for s in range(1, 10):
            f.write('%s_b%d_s%d\n' % (c, b, s))
PY
uptime >> raw/matrix-uptime-before.txt
python3 scripts/run.py raw/tasks-salts1-9.txt raw/matrix 0,2,4,6,8,10,12,14,16,17,18,19,20,21,22,23,24,25,26,27
uptime >> raw/matrix-uptime-after.txt
python3 scripts/aggregate.py raw/matrix catch.csv raw/cells.txt
```

`run.py` writes one file per run (first line the CPU) and a `runner.log` with
each run's wall, user and sys time and peak RSS; it skips a run whose output
already ends in `##-ok`.

## 4. Cost, with nothing else running

```sh
cd ~/.cache/budget-study-run
until awk '{exit !($1 < 1.0)}' /proc/loadavg; do sleep 5; done
mkdir -p raw/cost && python3 scripts/cost.py raw/cost 4 5 3 > raw/cost/progress.txt 2>&1
mkdir -p raw/cost-extra && COST_CELLS=O_SIEVE:15,O_FORMAT_BEFORE:3,O_SPLIT_ALLOC:2,O_BTREE_INSERT:1 \
  python3 scripts/cost.py raw/cost-extra 4 5 3 > raw/cost-extra/progress.txt 2>&1
```

`cost.py <out> <cpu> <sibling> <repeats>` runs each cell under `taskset -c 4`,
one process at a time, repeat by repeat, and records the machine (kernel,
governor, EPP, load) before and after and every CPU's busy fraction over the
window.

## 5. Tables

```sh
cd $R
python3 scripts/tables.py catch.csv raw/cost/cost-runs.csv,raw/cost-extra/cost-runs.csv cost.csv
```

In the committed copy, `raw/matrix/` and `raw/superseded-v1/` are archived as
`raw/matrix.tar.xz` and `raw/superseded-v1.tar.xz`. Run `tar -xJf` on each inside `raw/`
before rerunning `scripts/aggregate.py`.
