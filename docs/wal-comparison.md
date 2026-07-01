# WAL comparison — SingleTxnWal vs MultiTxnWal

The `pwregions` branch has two write-ahead log implementations. Only `MultiTxnWal`
is wired into `PWRegion` / `RegionTransaction`; `SingleTxnWal` is retained as a
reference point so the two designs can be compared directly.

- `SingleTxnWal` — `src/engine/x86-64/X86_64SingleTxnWal.v3` (superseded, not wired in)
- `MultiTxnWal` — `src/engine/x86-64/X86_64MultiTxnWal.v3` (active)

Both are in-region redo logs living in block 1 of the mapped region, and both
buffer their actual writes in DRAM via `RegionTransaction`'s write-behind cache;
the WAL only records the redo entries that make a committed transaction durable.
See `docs/persistent-backends.md` for the surrounding storage stack.

## Summary

| Dimension | `SingleTxnWal` | `MultiTxnWal` |
|---|---|---|
| Transaction model | One in-flight transaction at a time; each commit overwrites the log | Circular ring of transaction records; many committed transactions coexist until checkpointed |
| On-region layout (block 1) | Single `LogHeader` + flat `LogEntry[]` array | Dual-copy `WalSuperblock` at the chunk head, then a ring of records — each `TxnRecordHeader` + `LogEntry[]` + `TxnCommitTrailer`, `ALIGNMENT`(64 B)-aligned |
| Commit marker | `LogHeader.status` flag (0 = invalid, 1 = committed) | Per-record magic + `txnSeq`, published via the superblock's `durableAppliedSeq` |
| Integrity | One checksum over the whole log (`LogHeader.checksum`) | Per-record FNV-style checksum over each record **and** a checksum over each superblock copy |
| Recovery | If `status==1` and checksum matches, replay all entries, then clear `status` | Load newest valid superblock, scan the ring, validate records, replay the contiguous `txnSeq` prefix starting at `durableAppliedSeq + 1`, then publish the new `durableAppliedSeq` |
| Staleness handling | `status` flag only — cleared after replay so a later mount won't re-apply | `logEpoch` fences stale records (recovery bumps the epoch); `generation` selects the newer superblock copy |
| Checkpointing | None — the log is implicitly emptied on `clear()` | `checkpoint(targetSeq)` reclaims ring space + advances `durableAppliedSeq`; `maybeCheckpoint()` runs a hybrid count-OR-occupancy policy with per-backend thresholds (`CheckpointCost.FREE`/`CHEAP`/`EXPENSIVE`) |
| Ring-full handling | `append()` silently drops the entry when the log is full (correctness hole) | `reserveRecord` wraps around and triggers a lazy checkpoint; `commit()` returns `0` if a record still cannot fit |
| `commit()` signature | `commit()` → `void` (persist implied) | `commit()` → `u64` (returns the assigned `txnSeq`, `0` on failure) |
| Wired into `PWRegion` | No (reference only) | Yes |

## Why the multi-transaction design superseded the single-transaction one

- **Ring reuse.** A single-transaction log must be fully drained before the next
  commit; the ring lets committed records accumulate and be reclaimed lazily, so
  commits don't serialize behind a full log-and-clear cycle.
- **Bounded recovery.** `durableAppliedSeq` gives recovery a precise replay floor
  and the checkpoint policy caps how many records can pile up, bounding
  mount/recovery time instead of leaving it implicit.
- **Epoch fencing.** `logEpoch` guarantees that records from a previous WAL
  incarnation cannot be re-applied on a later mount — a hazard the single flag
  cannot express once multiple records coexist.
- **Per-backend cost.** `maybeCheckpoint()` tunes checkpoint aggressiveness to the
  backend's fence cost (volatile / PMEM / file), amortizing expensive
  `fdatasync`/`msync` while reclaiming eagerly on cheap backends.

## What the single-transaction design is still good for

- **Simplicity / teaching baseline.** No superblock selection, epochs, ring
  wrap-around, or checkpoint policy — the whole commit/recovery protocol fits in
  ~150 lines and is easy to reason about end to end.
- **A control for comparison.** It isolates the cost and complexity that the
  multi-transaction machinery adds, which is why it is kept here rather than
  deleted.
