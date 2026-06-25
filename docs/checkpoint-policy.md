# `maybeCheckpoint()` Policy — Design Options

Design discussion for the next `MultiTxnWal` step: replacing the no-op
`maybeCheckpoint()` stub (`return true`) with a real checkpoint policy.

`maybeCheckpoint()` is called by `RegionTransaction.commit()` after `noteApplied(txnSeq)`
and before `clear()`. It decides whether to invoke the (already-implemented)
`checkpoint(targetSeq)`, which persists applied region data, publishes
`durableAppliedSeq` via the superblock, and reclaims now-durable ring records.
Today checkpoints fire *only* lazily inside `reserveRecord`/`appendCommittedRecord`
when the ring is full.

---

## What `checkpoint()` actually costs vs. buys

The per-commit floor cost is **already paid regardless of policy**:
`appendCommittedRecord` does a `persistRange` on the record itself (the commit
point). On the file backend that is an `msync`; on PMEM a flush + fence. So the
WAL does **not** batch record durability — every `commit()` is already
synchronous for its own record.

What `checkpoint()` adds on top:

- `persistChanges()` — `fdatasync` (file, only if dirty) / `storeFence` (PMEM) /
  no-op (volatile) — makes the **applied region data** durable.
- `writeSuperblock()` — another `persistRange` (a second `msync` on file) plus a
  generation bump.
- `reclaimAppliedRecords()` — frees ring space.

So checkpointing is purely about **(a) reclaiming ring space** and **(b) bounding
recovery replay length**, traded against **the region-data sync + superblock
churn**. It does *not* add crash-safety for committed data — recovery already
replays the durable record tail. The cost is strongly backend-asymmetric:

| Backend   | checkpoint cost                              |
|-----------|----------------------------------------------|
| Volatile  | free (reclaim only)                          |
| PMEM      | two store fences (cheap)                     |
| File      | `fdatasync` + superblock `msync` (expensive) |

---

## Cheap signals available in the commit hot path

- **lag** = `appliedSeqVolatile − durableAppliedSeq`. Note `activeRecords.length`
  already equals this (it holds exactly the records with `txnSeq > durableAppliedSeq`).
  O(1).
- **ring occupancy in bytes** = Σ `activeRecords[i].recordLen`. O(active) to sum;
  at a 256 KB block that is up to ~1300 records, so a maintained running
  `activeBytes` counter is preferable to summing on each commit.
- **backend cost class** — `isPersistent()` exists; a richer
  `checkpointCostHint()` would need a new interface method.

Wall-clock / group-commit windows are impractical at this layer (no cheap clock);
a "commits since last checkpoint" counter is the only sane time-substitute, which
collapses into the count policy.

---

## Options

| # | Policy | Fires when | Pros | Cons |
|---|--------|------------|------|------|
| **A** | Never (status quo) | only lazy ring-full in `reserveRecord` | zero per-commit overhead; max batching | recovery replay bounded only by ring size; ring rides near-full; the commit that fills it eats a stall spike |
| **B** | Always | every commit | `durableAppliedSeq` always current; ~empty recovery; trivially correct | adds `fdatasync` + superblock `msync` **per commit** on file — reverts to single-txn WAL economics; superblock generation churns |
| **C** | Count threshold | `lag ≥ N` (i.e. `activeRecords.length ≥ N`) | bounded recovery (≤ N txns); amortizes sync over N commits; trivial & O(1); deterministic to unit-test | N is a magic number; ignores record-size variance (N huge txns ≠ N tiny ones in ring terms) |
| **D** | Occupancy watermark | ring usage ≥ X% of `ringBytes` (e.g. 50–75%) | targets the real constraint directly; pre-empts the lazy ring-full stall; adapts to record size | needs a running `activeBytes` counter; still a magic %; does not cap recovery txn-count directly |
| **E** | Hybrid count-OR-occupancy | `lag ≥ N` **OR** `usage ≥ watermark` | bounds both recovery length and ring pressure; robust to many-small and few-large workloads | two knobs to tune |
| **F** | Backend-aware | thresholds vary by backend cost (volatile→always, PMEM→low, file→high/occupancy-only) | matches the cost asymmetry above | needs a cost signal from `BackendRegion`; more surface area |
| **G** | Adaptive feedback | tighten threshold when `reserveRecord` hits ring-full | self-tuning | premature for current stage; harder to test |

---

## Recommendation

**Option E (hybrid) with the lazy ring-full path kept as a backstop**, and ideally
the thresholds chosen per backend (a light touch of F).

Rationale:

- The occupancy watermark is what actually prevents the ring-full *stall* —
  proactively checkpointing at ~50–60% turns the existing lazy `reserveRecord`
  checkpoint from the primary mechanism into a rare safety net.
- The count cap (`lag ≥ N`) independently bounds **mount/recovery time**, which
  the occupancy trigger alone does not guarantee for a workload of tiny
  transactions.
- When it fires, always checkpoint to `appliedSeqVolatile` (reclaim everything
  once you have decided to pay the sync — there is no reason to checkpoint a
  partial prefix).
- Backend sensitivity matters because the file backend is the only one where this
  is genuinely expensive; on volatile/PMEM a much lower threshold (even
  near-always) is affordable. Cheapest implementation: two `MultiTxnWal`
  constants, optionally overridden via an `isPersistent()` / cost hint.

Implementation footprint is small: add an `activeBytes` running counter
(increment in `appendCommittedRecord`, recompute/decrement in
`reclaimAppliedRecords`), and make `maybeCheckpoint()`:

```
def maybeCheckpoint() -> bool {
        def lag = appliedSeqVolatile - durableAppliedSeq;
        if (lag == 0) return true;                       // nothing to do
        if (lag >= checkpointTxnThreshold) return checkpoint(appliedSeqVolatile);
        if (activeBytes * 100 >= ringBytes * checkpointFillPercent) return checkpoint(appliedSeqVolatile);
        return true;
}
```

---

## Open decisions before implementing

1. **How configurable** — fixed constants in `MultiTxnWalConstants`, or
   backend-aware (volatile/PMEM aggressive, file lazy)?
2. **Failure handling** — `maybeCheckpoint`'s result is currently discarded by
   `RegionTransaction.commit`. A failed checkpoint is not fatal (data is still
   recoverable from the WAL), so should it stay best-effort/silent, or be
   surfaced up? (Ties into Roadmap Next Steps #2, commit-failure propagation.)

Proposed default: fixed constants + best-effort, with a count cap of ~64 and a
50% fill watermark — easy to unit-test.
