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
| API results | `commit()` → `void` (persist implied) | `commit()` → `u64`; empty commits write an `entryCount=0` record so success is always nonzero. `recover()` → `MultiWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`) | `commit()` → `u64`; empty commits write an `entryCount=0` record so success is always nonzero. `recover()` → `DualWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`) |
| Clean-unmount replay | Log cleared after every commit — remount is replay-free | `close()` is empty; even a clean unmount replays the tail | `close()` persists deferred data and scrubs reclaimable slots — clean remounts recover `CLEAN` |
| Wired into `PWRegion` | No (reference only) | No (reference only) | Yes |

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
- **Failure hazards become structural non-issues.** Parity slot selection means
  a retried commit reuses the same slot and seq, so the duplicate-`txnSeq`
  hazard that required `MultiTxnWal`'s scrub/rollback protocol cannot occur.
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
