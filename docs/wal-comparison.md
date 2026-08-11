# WAL comparison — SingleTxnWal vs MultiTxnWal vs DualTxnWal

The `pwregions` branch has three write-ahead log implementations. Only
`DualTxnWal` is wired into `PWRegion` / `RegionTransaction`; the other two are
retained as reference points so the designs can be compared directly.

- `SingleTxnWal` — `src/engine/x86-64/X86_64SingleTxnWal.v3` (superseded, not wired in)
- `MultiTxnWal` — `src/engine/x86-64/X86_64MultiTxnWal.v3` (superseded, not wired in)
- `DualTxnWal` — `src/engine/x86-64/X86_64DualTxnWal.v3` (active; phase B — piggybacked boundary)

All three are in-region redo logs living in block 1 of the mapped region, and all
buffer their actual writes in DRAM via `RegionTransaction`'s write-behind cache;
the WAL only records the redo entries that make a committed transaction durable.
See `docs/persistent-backends.md` for the surrounding storage stack.

## Summary

| Dimension | `SingleTxnWal` | `MultiTxnWal` | `DualTxnWal` |
|---|---|---|---|
| Transaction model | One in-flight transaction at a time; each commit overwrites the log | Circular ring of transaction records; many committed transactions coexist until checkpointed | At most 2 committed transactions in two fixed slots, selected by `txnSeq % 2` parity |
| On-region layout (block 1) | Single `LogHeader` + flat `LogEntry[]` array | Dual-copy `WalSuperblock` at the chunk head, then a ring of records — each `TxnRecordHeader` + `LogEntry[]` + `TxnCommitTrailer`, `ALIGNMENT`(64 B)-aligned | Minimal `DualWalHeader` (64 B), then two fixed slots each holding one record (same `TxnRecordHeader`/`LogEntry[]`/`TxnCommitTrailer` layouts, distinct magics, `logEpoch` reserved-zero) |
| Commit marker | `LogHeader.status` flag (0 = invalid, 1 = committed) | Per-record magic + `txnSeq`, published via the superblock's `durableAppliedSeq` | Per-record magic + `txnSeq`; a record is committed iff it validates — no separate publication step |
| Integrity | One checksum over the whole log (`LogHeader.checksum`) | Per-record FNV-style checksum over each record **and** a checksum over each superblock copy | Per-record FNV-style checksum plus a checksum over the chunk header |
| Recovery | If `status==1` and checksum matches, replay all entries, then clear `status` | Load newest valid superblock, scan the ring, validate records, replay the contiguous `txnSeq` prefix starting at `durableAppliedSeq + 1`, then publish the new `durableAppliedSeq` | Validate both slots, replay the valid records in ascending `txnSeq`, persist, `nextTxnSeq = max + 1`. Entries are idempotent after-images, so no replay floor is needed |
| Staleness handling | `status` flag only — cleared after replay so a later mount won't re-apply | `logEpoch` fences stale records (recovery bumps the epoch); `generation` selects the newer superblock copy | Not needed: re-replaying an already-durable record is harmless, and parity guarantees a retried commit lands on the same slot/seq. Distinct magics fence stale `MultiTxnWal` ring bytes |
| Checkpointing | None — the log is implicitly emptied on `clear()` | `checkpoint(targetSeq)` reclaims ring space + advances `durableAppliedSeq`; `maybeCheckpoint()` runs a hybrid count-OR-occupancy policy with per-backend thresholds (`CheckpointCost.FREE`/`CHEAP`/`EXPENSIVE`) | None: transaction N's data persist piggybacks on commit N+1's boundary; an overwrite guard retries the data persist before a slot covering not-yet-durable data is destroyed |
| Persistence boundaries per commit | 3 (entries+status, post-apply fence, status clear) | ~1 amortized (record persist; superblock persist per checkpoint) | Phase A: 2 (record, then data). Phase B (current): 1 in steady state — `prepareChangedRange(record)` + `persistChanges()` covers the new record and the previous transaction's applied data together (one `SFENCE` on PMEM, one `fdatasync` on file). Unmount/idle uses an explicit `persistAppliedData()` / `close()` |
| Log-full handling | `append()` silently drops the entry when the log is full (correctness hole) | `reserveRecord` wraps around and triggers a lazy checkpoint; `commit()` returns `0` if a record still cannot fit. An invalid `append()` poisons the transaction so `commit()` fails | Per-transaction capacity is fixed at `slotBytes` (~half the chunk); an oversize commit fails cleanly with `0` before touching the slot. An invalid `append()` poisons the transaction so `commit()` fails |
| API results | `commit()` → `void` (persist implied) | `commit()` → `u64`; empty commits write an `entryCount=0` record so success is always nonzero. If both a failed commit point and its compensating record scrub fail, the current instance becomes recovery-required pending reopen. `recover()` → `MultiWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`) | `commit()` → `u64`; nonzero is acknowledged, while a persistence-related `0` is unacknowledged and requires reopen/recovery rather than guaranteeing abort. `recover()` → `DualWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`) |
| Clean-unmount replay | Log cleared after every commit — remount is replay-free | `close()` is empty; even a clean unmount replays the tail | `close()` persists deferred data and scrubs reclaimable slots — clean remounts recover `CLEAN` |
| Wired into `PWRegion` | No (reference only) | No (reference only) | Yes |
| Roadmap-related tests (extended 2026-08-11) | 4 in `SingleTxnWalTest.v3` | 28 in `MultiTxnWalTest.v3` | 38 in `DualTxnWalTest.v3`, plus 81 cache/allocator/backend tests in `RegionTransactionTest.v3` and `TxnPWRegionTest.v3` |

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

## Why the two-slot design superseded the multi-transaction one (2026-07-09)

- **Idempotent after-images make the machinery unnecessary.** Redo entries are
  absolute stores, so recovery can simply replay every valid record in seq
  order. Deleting the replay floor deletes the dual superblock, generation
  selection, epoch fencing, checkpoint policy, and all ring bookkeeping in one
  stroke.
- **Same steady-state boundary count.** Phase B reaches one persistence
  boundary per commit — matching checkpointed `MultiTxnWal` while also dropping
  its superblock `persistRange` — via a simple induction: a valid record N+1
  on-region implies the boundary at its commit completed, so transaction N's
  data is durable. At any moment at most one transaction's data is not yet
  durable plus the record being committed — exactly two slots.
- **The duplicate-location failure hazard becomes a structural non-issue.**
  Parity slot selection means a retried commit reuses the same slot and seq, so
  two copies of the same `txnSeq` cannot occupy different slots. The chosen
  contract nevertheless forbids same-mount retry after a persistence failure:
  the result is unacknowledged and the mount requires reopen/recovery. A
  complete checksummed record left in the slot may then be replayed safely
  because its entries are idempotent after-images.
- **Accepted trade-offs.** Per-transaction capacity is ~half the log chunk
  (ample for allocator-sized transactions; oversize commits fail cleanly); no
  burst absorption of many committed-but-unpersisted transactions; on PMEM,
  data lines are flushed every commit instead of every few commits (cheap
  fences — acceptable).

## What the superseded designs are still good for

- **Simplicity / teaching baseline (`SingleTxnWal`).** No superblock selection,
  epochs, ring wrap-around, or checkpoint policy — the whole commit/recovery
  protocol fits in ~150 lines and is easy to reason about end to end.
- **Burst absorption / bounded replay (`MultiTxnWal`).** Shows what it costs to
  support many outstanding transactions with a bounded replay window — the
  point of comparison that motivated the two-slot simplification.
- **Controls for comparison.** Together they isolate the cost and complexity
  each increment of WAL machinery adds, which is why they are kept here rather
  than deleted.

## Verification status

The implementation-specific x86-64 Linux suite contains 136 tests across five
files, all passing as of the 2026-08-06 extension. Coverage is strongest for normal
phase-B commit/recovery, the intended one-boundary induction property, and the
core shadow-backed crash matrix. The active WAL tests now restore live memory
from a separate durable image before reopening, so unpersisted after-images
genuinely disappear and recovery must reconstruct them from surviving records.
File-backed tests exercise `fdatasync`/`msync`, graceful remount, and abrupt
child-process exit/`SIGKILL` windows, but not VM or host power loss.

The implemented shadow durable-memory backend supplies the innermost layer of
the correctness argument: WAL behavior under the `BackendRegion` persistence
contract. The chosen copy-then-fail contract treats the result as
unacknowledged and makes the mount recovery-required; recovery may replay the
complete record because redo after-images are idempotent. `DualTxnWal` now
latches fresh-header, commit-record, after-image preparation, recovery,
explicit-flush, final-data-close, and slot-scrub persistence failures and
requires a newly constructed instance to inspect or recover durable state.
`RegionTransaction` and `PWRegion` now expose that latch, after-image failures
propagate without clearing the cache, and allocator entry points reject new
work on a recovery-required mount.
Backend syscall/instruction integration, abrupt process/guest recovery, and
physical-media testing provide progressively stronger outer layers. The
complete layer definitions are in `docs/persistent-backends.md`; the
prioritised implementation list is in `docs/ROADMAP.md` Next Steps #3.
