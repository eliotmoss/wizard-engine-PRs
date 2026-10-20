# Budget sensitivity of the crash-image explorer (2026-10-20)

Engine: `pwregions` at 129555ed plus `harness.patch` (scratch only, uncommitted,
in `~/.cache/budget-study-wt`). Machine: sean-tan-PC (pc-ubuntu), see
`machine.txt`. Every number below comes from a run whose raw output is under
`raw/`; `catch.csv` has one row per catch-matrix run and `cost.csv` one row per
timed cell.

## What was run

- **Harness** (`test/unittest/x86-64-linux/BudgetStudyTest.v3`). One unit test
  per case, budget and salt, `budget_study:<CASE>_b<budget>_s<salt>`. Each case
  records its scenario by calling the suite test's own tester methods and
  sweeps it as that test does: the same trace, the same cut ranges in the same
  order (the B+-tree's three mark-delimited ranges included), the same
  property, and a stop at the first failing cut (`checkCutRange`). Only the
  budget and the salt vary.
- **Salt.** `PersistentSelectionSeeds.seedAt()` now seeds SplitMix64 with
  `digest ^ cut*0x9E3779B97F4A7C15 ^ salt*0xD1B54A32D192ED03`. At salt 0 the
  XOR term is 0, so salt 0 is the suite's seed exactly. A fixed seed
  (`selectCrashImages()`) is unchanged.
- **Random-stage counter.** For each cut, `search()` records how many of its
  images are extremes (all of them when the cut is enumerated completely), and
  `check()` counts the checked images beyond that number. A sweep "reached the
  random stage" if that count is above 0 anywhere up to its stop. Salts 1–9 were
  run for every (case, budget) cell whose salt-0 run reached it, for the
  ordinary sweeps as well as the planted bugs. Everywhere else the images
  checked do not depend on the seed, and the cell is one run.
- **Budgets.** 1, 2, 4, 8, 12, 16, 32 and 64, as asked. I added 3, 6 and 10,
  which the checksum anchor needs, and 13, 14 and 15, to place the control's
  threshold.
- **Planted bugs** (how each is enabled):
  - M1 `persistent_control:elided_writeback_is_caught`: `ElidedWritebackPmemBackend` while recording (no `CLWB` at all); 1,401 events.
  - M2 `persistent_sieve:unchecked_record_checksum_is_caught`: `DualTxnWalMutants.skipRecordChecksum = true` during the sweep only; 1,456 events.
  - M3 `persistent_btree:elided_node_writeback_is_caught`: the split insert's trace with the `CLWB`s between the second COMPUTE mark and the WRITE mark removed (`withoutWritebacks`, copied into the harness because top-level defs are not visible across files); 4,591 events.
  - M4 `persistent_alloc:early_magic_is_caught`: `PersistentFormatScenario.withEarlyMagic`, swept from the magic's cut to the end, as the test does; 596 events.
  - M5 `APPLY_BEFORE_COMMIT` (ported): `BudgetStudyMutants.applyBeforeCommit` makes `RegionTransaction.commit()` run `applyToRegion()` (store and prepare the after-images) before `wal.commit()`. Set only around the recorded `allocChunk(2)`; 736 events (the ordinary split allocation also has 736, reordered here).
  - M6 `UNLOGGED_LINK_STORE` (ported): `BudgetStudyMutants.unloggedLinkStore` makes `RegionTransaction.writeI64()` (BlockEntry prev, next, listPrev, listNext) store in place through `DualTxnWal.storeUnlogged()`, with no redo entry, no extent and no writeback. Set only around the allocation; 447 events.

  Both ported mutants still fail on the current code. Their traces differ
  from the ordinary one (digests in `catch.csv`), and both validate.
- **Machine time.** The matrix was 1,715 runs, 2.6 CPU-hours, about 8 minutes
  of wall time on 20 cores (12:06–12:14 AEDT). The pinned timing then took
  7 minutes.

## Anchors reproduced (before the matrix; again in it)

Doc line numbers are for 129555ed.

| anchor | doc | reproduced |
|---|---|---|
| control at 64 | THESIS.md:556 "the explorer catches the elided-writeback mutant 708 events into 1,401"; pmem-emulation.md:421-422 "the first failing image is 708 events in, with `free block is on the wrong free list (block 3)`" | cut 708 of 1,401 events, `free block is on the wrong free list (block 3)`, image 15 of 64 at that cut, 41,683 images checked up to and including it |
| 85,055 | THESIS.md:601-602 "the ordinary step's sweep checked 36,605 distinct images over its 1,457 cuts. It now checks 85,055" | the **ordinary** step's sweep at 64 (`O_CONTROL_ORDINARY`, = `persistent_control:ordinary_writeback_holds`) checks 85,055 and passes. The brief pairs 85,055 with the control's catch, but in the doc it is the ordinary step's sweep. The mutant's sweep checks 41,683 up to its catch |
| checksum skip | pmem-crash-model.md:701-704 "the same sweep passed at 2, 3 and 4 images per cut ... it failed at cut 660 at 6 and 8, at cut 385 at 10 and 12, and at cut 289 at 16 and 64"; :696-698 "the ninth the selection takes there" | passes at 2, 3, 4; cut 660 at 6 and 8; cut 385 at 10 and 12 (image 9 of 10, 9 of 12; `used block is linked into a free list (block 2)`); cut 289 at 16 and 64 (salt 0) |
| B+-tree at 4 | persistent-backends.md:2153-2154 "the sweep, at event 4,207 of 4,591, inside the publish's commit, with "the tree could not reopen after recovery"" | cut 4,207 of 4,591, `the tree could not reopen after recovery` |
| early magic at 8 | persistent-backends.md:3585-3588 "must fail both checks at the magic's cut, 339 of 596 ... The sweep's failing image is the third it checks there" | cut 339 of 596, image 3 of 8, `an image carrying the magic was mounted, and memory-order chain does not reach the region marker` |
| sieve ordinary at 4 | THESIS.md:602 "the sieve step's sweep at 4 per cut checks 5,798 against 5,776" | 5,798 images, passes |

The ordinary sweeps also reproduce three further doc counts: the format before
the magic at 8 checks 4,739 (persistent-backends.md:3581, "4,739 checked in
all"); the split allocation at 8 checks 1,360 (pmem-crash-model.md:1618-1619);
and the B+-tree at 4 checks 18,330 for the insert and 11,818 for the update
(persistent-backends.md:2134). The suite's own `persistent_control:*`,
`persistent_sieve:*`, `persistent_btree:*`, `persistent_alloc:*` and
`persistent_explore:*` (48 tests) all pass on the patched binary
(`raw/suite/summary.txt`), so the patch at salt 0 leaves the suite unchanged.

## A. Catch matrix

A cell is "cut N" or "passes" where the selection is fixed (salt 0 checked no
random-stage image). Otherwise it is k/10 seeds caught, followed by the cuts
they caught at.

| bug | 1 | 2 | 4 | 8 | 12 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|---|
| M1 control, elided writeback (suite 64) | passes | passes | 0/10 | 0/10 | 0/10 | 10/10 (cut 708) | 10/10 (cut 708) | 10/10 (cut 708) |
| M2 checksum skip (suite 12) | passes | passes | 0/10 | 10/10 (cut 660) | 10/10 (cut 385) | 10/10 (cut 289, 385, 374) | 10/10 (cut 289, 385, 275, 312, 296, 278, 303) | 10/10 (cut 289, 280, 269, 312, 266, 278, 303, 385, 258) |
| M3 B+-tree, removed node writebacks (suite 4) | cut 4207 | cut 4207 | 10/10 (cut 4207) | 10/10 (cut 4207) | 10/10 (cut 4207) | 10/10 (cut 4207) | 10/10 (cut 4199) | 10/10 (cut 4199) |
| M4 early magic (suite 8) | passes | passes | cut 339 | cut 339 | cut 339 | cut 339 | cut 339 | cut 339 |
| M5 apply before commit (split alloc, suite 8) | passes | cut 4 | cut 4 | cut 4 | cut 4 | cut 4 | cut 4 | cut 4 |
| M6 unlogged link store (split alloc, suite 8) | cut 437 | cut 3 | cut 3 | cut 3 | cut 3 | cut 3 | cut 3 | cut 3 |

Extra budgets:

| bug | 3 | 6 | 10 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|
| M1 | passes | 0/10 | 0/10 | 0/10 | 0/10 | 10/10 (cut 708) |
| M2 | passes | 10/10 (cut 660) | 10/10 (cut 385) | 10/10 (cut 385) | 10/10 (cut 289, 385) | 10/10 (cut 289, 385, 374) |
| M3 | cut 4207 | 10/10 (cut 4207) | 10/10 (cut 4207) | 10/10 (cut 4207) | 10/10 (cut 4207) | 10/10 (cut 4207) |
| M4 | cut 339 | cut 339 | cut 339 | cut 339 | cut 339 | cut 339 |
| M5 | cut 4 | cut 4 | cut 4 | cut 4 | cut 4 | cut 4 |
| M6 | cut 3 | cut 3 | cut 3 | cut 3 | cut 3 | cut 3 |

Salt 0: images checked up to and including the catch, the failing image's
place among the images taken at its cut, or (in parentheses) the whole sweep's
images when it passes:

| bug (salt 0) | 1 | 2 | 4 | 8 | 12 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|---|
| M1 | (1,402) | (2,803) | (5,602) | (11,188) | (16,737) | 11,091; img 15/16 | 21,379; img 15/32 | 41,683; img 15/64 |
| M2 | (1,457) | (2,908) | (5,798) | 5,257; img 5/8 | 4,542; img 9/12 | 4,386; img 14/16 | 7,970; img 14/32 | 14,866; img 14/64 |
| M3 | 4,208; img 1/1 | 8,400; img 1/2 | 16,768; img 1/4 | 33,470; img 1/8 | 50,119; img 1/12 | 66,638; img 1/16 | 132,002; img 25/32 | 262,214; img 25/64 |
| M4 | (258) | (515) | 3; img 3/4 | 3; img 3/8 | 3; img 3/12 | 3; img 3/16 | 3; img 3/32 | 3; img 3/64 |
| M5 | (737) | 8; img 2/2 | 9; img 2/4 | 9; img 2/6 | 9; img 2/6 | 9; img 2/6 | 9; img 2/6 | 9; img 2/6 |
| M6 | 438; img 1/1 | 7; img 2/2 | 8; img 2/4 | 8; img 2/6 | 8; img 2/6 | 8; img 2/6 | 8; img 2/6 | 8; img 2/6 |

Violation messages (every catch, all salts):

- M1, cut 708: `free block is on the wrong free list (block 3)`.
- M2, cut 660: `memory-order forward link is not mirrored (block 3)`. Every other cut (258–385): `used block is linked into a free list (block 2)`.
- M3, cut 4207: `the tree could not reopen after recovery`. Cut 4199: `the tree's value for a key differs from the reference`.
- M4, cut 339: `an image carrying the magic was mounted, and memory-order chain does not reach the region marker`.
- M5, cut 4: `memory-order forward link is not mirrored (block 4)` at 2–4. At 6 and above, where cut 4's six images are enumerated completely in odometer order, the message ends `(block 2)`.
- M6, cut 437 (budget 1): `used block is linked into a free list (block 2)`. Cut 3: `... not mirrored (block 4)` at 2–4, `(block 2)` at 6 and above.

At every bug's smallest catching budget the failing image is an extreme
(`failFrom=extreme` in `catch.csv`), and it is the same under all ten seeds
where seeds apply (M1 at 15: image 15 at cut 708; M2 at 6: image 5 at cut 660).

## False-positive check

Thirteen unmutated sweeps (from twelve suite tests), each at all 14 budgets,
with salts 1–9 wherever salt 0 reached the random stage: 1,334 runs, 0
failures, every one ending `##-ok`.

The sweeps are each planted bug's ordinary twin plus the suite's other
budgeted sweeps: O_SIEVE, O_CONTROL_ORDINARY, O_SIEVE_ALLOC, O_SIEVE_RETIRING,
O_BTREE_INSERT, O_BTREE_UPDATE, O_FORMAT_BEFORE, O_FORMAT_AFTER, O_SPLIT_ALLOC,
O_COALESCING_FREE, O_TWO_ALLOCS, O_ALLOC_RECOVERY_CRASH and
O_FAILED_MOUNT_SWEEP. O_SIEVE, O_CONTROL_ORDINARY, O_SIEVE_ALLOC and M2 record
the same trace (digest 0x0F83F5C39293C142); M1 is that step without its
`CLWB`s. Per-cell counts are in `raw/cells.txt`.

## B. Cost

Median of 3 runs of the sweep alone (timed inside the process around the
sweep; recording excluded), then the images checked. Each run was pinned to
CPU 4 (P-core 2), with its sibling CPU 5 idle (0.01 % busy over the window),
nothing else of mine running, governor powersave, EPP balance_performance.
Every run passed. The min–max of the three runs and the process wall time are
in `cost.csv`.

| scenario | 1 | 2 | 4 | 8 | 12 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|---|
| sieve ordinary step | 0.309 s, 1,457 | 0.372 s, 2,908 | 0.498 s, 5,798 | 0.751 s, 11,546 | 0.992 s, 17,213 | 1.228 s, 22,659 | 2.071 s, 43,627 | 3.703 s, 85,055 |
| B+-tree split insert | 2.492 s, 4,602 | 3.270 s, 9,186 | 4.765 s, 18,330 | 7.828 s, 36,562 | 10.882 s, 54,694 | 13.897 s, 72,584 | 25.845 s, 143,256 | 49.472 s, 283,420 |
| split allocation | 0.134 s, 737 | 0.139 s, 831 | 0.148 s, 1,013 | 0.167 s, 1,360 | 0.185 s, 1,692 | 0.204 s, 2,020 | 0.272 s, 3,284 | 0.402 s, 5,676 |
| format before the magic | 0.071 s, 596 | 0.095 s, 1,190 | 0.142 s, 2,375 | 0.237 s, 4,739 | 0.318 s, 6,793 | 0.395 s, 8,729 | 0.701 s, 16,465 | 1.323 s, 31,877 |

A second pinned set (`raw/cost-extra`, same method, run a minute later) timed
the thresholds that are not on the grid: sieve at 15, 1.170 s and 21,329
images; format at 3, 0.118 s and 1,783 images. It also re-timed two grid
cells, with these results: split allocation at 2, 0.139 s (grid 0.139 s), and
B+-tree at 1, 2.503 s (grid 2.492 s).

## Smallest budget that catches every planted bug on the scenario

| scenario | bugs | smallest measured budget | cost there | suite budget(s) and cost |
|---|---|---|---|---|
| sieve step | M1, M2 | 15 (of the requested budgets, 16) | 1.170 s, 21,329 images (16: 1.228 s, 22,659) | control 64 (3.703 s, 85,055); checksum skip 12; ordinary sweeps 4 (0.498 s, 5,798) |
| B+-tree split insert | M3 | 1 | 2.492 s, 4,602 | 4 (4.765 s, 18,330) |
| split allocation | M5, M6 | 2 | 0.139 s, 831 | 8 (0.167 s, 1,360) |
| format | M4 | 3 | 0.118 s, 1,783 (the format before the magic) | 8 (0.237 s, 4,739) |

The format's planted bug is swept over the mutant's cuts from the magic on (258
cuts), as its test does. The cost row is the ordinary format before its magic,
as asked. These are different cut ranges of related traces.

## Trimmed and deviations

- **Nothing was trimmed.** Every budget, including 32 and 64 for the B+-tree,
  ran salts 1–9 wherever they applied. The extra budgets 3, 6, 10, 13, 14 and
  15 and the extra ordinary sweeps ran on top of the requested ones.
- **Two binaries.** The first salt-0 pass ran on a binary without budgets
  13–15 registered (`raw/superseded-v1`). I re-ran everything on the second
  binary, and every reported number comes from that one. The two agree on
  every shared cell.
- **Images checked, B+-tree.** The harness's B+-tree sweep sums images over
  its three ranges up to the catch. The suite's `checkEveryCut()` returns only
  the failing range's count when its first or second range fails. Cuts and
  messages are unaffected.
- **Extremes count.** `failExtremes` and `maxExtremes` in `catch.csv` count
  the extremes the budget let in, so they are capped at the budget.
- **Governor.** The governor stayed powersave (intel_pstate, HWP, EPP
  balance_performance); changing it needs root. The run held the core
  continuously busy. The suite's anchors are counts and cuts, which do not
  depend on the clock.

## Surprising

1. **The negative control needs 15, not 64, and is missed at 1 to 14.** With
   no `CLWB` at all, the sweep passes at every budget from 1 to 14: at 1 to 3,
   where the selection is fixed, and at 4 to 14 under all ten seeds. From 15 on it is caught at cut 708 by image 15, an extreme. The
   cut has 26 extremes (seen at 32 and 64). *We infer* from 26 = 2 + 12 + 12
   that cut 708 has 12 changeable lines and that image 15 is the first "one
   content below its last, every other line at its last" vector, which is the
   lowest-addressed line's. The harness does not record which line it is.
2. **The checksum skip's documented cut 289 at 16 and 64 belongs to the
   suite's seed.** At 16, 8 of 10 seeds catch at 385 (the extreme, image 9).
   The other 2 catch earlier by random draws: salt 0 at 289 (image 14) and
   salt 9 at 374 (image 15). At 64 the seeds' cuts range from
   258 to 385. All 10 seeds catch from 6 on, and none at 4.
3. **The B+-tree mutant is caught at budget 1**, by the lazy image at cut
   4,207. At 32 and 64 it is caught earlier, at cut 4,199, with a different
   message (`the tree's value for a key differs from the reference`), so the
   test's pinned message holds only below 32. I did not check whether 4,199 is
   inside the test's asserted cut window.
4. **The unlogged link store is caught by the lazy image alone**, at cut 437,
   and from budget 2 on at cut 3.
5. **Cost is close to linear in images checked.** Sieve: 0.31 s at 1,457
   images to 3.70 s at 85,055, about 41 µs per added image. B+-tree: 2.49 s
   to 49.47 s, about 168 µs per added image. Both slopes are arithmetic on
   the table.

## Interpretation (not measurement)

- *We infer* that no suite budget is set at the threshold of its own planted
  bug. Each is above it: the control's 64 is 4.3 times the 15 it needs, the
  checksum skip's 12 is twice 6, the B+-tree's 4 is above 1, and the split
  allocation's and format's 8 are above 2 and 3.
- *We infer* that the sieve's ordinary sweeps, at 4, would catch neither
  planted sieve bug: M1 and M2 both pass at 4 under all ten seeds. This
  holds for these two bugs only.
- Possible budgets, for Sean to decide:
  - sieve controls and ordinary sweeps at 16, which catches both sieve bugs
    under every seed tried. It costs 1.23 s against 0.50 s at 4 and 3.70 s
    at 64. Because 16 is one above the control's threshold, 32 (2.07 s) would
    leave a margin if the extremes' order changes;
  - B+-tree at 4, unchanged (M3 is caught from 1);
  - format and split allocation at 8, unchanged (thresholds 3 and 2, at
    0.24 s and 0.17 s).
- None of this shows that a budget catches bugs other than these six.

## Files

- `harness.patch`: every scratch source change, applying to 129555ed: the harness test file, the salt and counters in `X86_64PersistentExplorer.v3`, and the two mutant flags in `X86_64DualTxnWal.v3` and `X86_64TxnPWRegion.v3`. Verified in a fresh clone; see `machine.txt`.
- `docs-draft.patch`: the draft paragraphs for `docs/pmem-crash-model.md`, after "A recovery that skips the record checksum". It is uncommitted in the scratch worktree's copy of the doc.
- `catch.csv`: one row per run (1,715): case, kind, budget, salt, caught, cut, failing image's place and kind, images checked, cuts, random-stage counts, sweep time, detail, selection note, coverage line, trace digest, CPU.
- `cost.csv`: per timed cell, the median, minimum and maximum sweep time, the process wall time and the images checked.
- `raw/`: every run's output (`anchors/`, `matrix/`, `suite/`, `cost/`, `cost-extra/`, `superseded-v1/`; `matrix/` and `superseded-v1/` are stored as `matrix.tar.xz` and `superseded-v1.tar.xz`, so extract them with `tar -xJf` before running `scripts/aggregate.py`), runner logs with per-run wall time, CPU time and peak RSS, task lists, uptime, binary hashes and `cells.txt` (per-cell aggregate).
- `scripts/`: `run.py` (parallel runner, adapted from the 2026-10-19 study's), `cost.py` (pinned timing), `aggregate.py` (catch.csv) and `tables.py` (tables and cost.csv).
