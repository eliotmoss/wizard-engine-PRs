# Persistent Region Allocator — Roadmap

Work log for the `pwregions` branch. See `docs/persistent-backends.md` for design detail.

---

## Completed

### Storage abstraction layer
- `BackendRegion` / `TxnRegionBackend` abstract interfaces (`src/engine/TxnBackend.v3`)
- `VolatileRegion` / `VolatileBackend` — array-backed, GC-managed
- `FdMmapRegion` base class — owns fd + Mapping, handles destroy/unmap
- `FileMmapRegion` — file-backed mmap; `msync`/`fdatasync` durability
- `PmemMmapRegion` — PMEM mmap with `MAP_SYNC`; cache-line flush + store-fence durability (flush/fence are stubs pending Virgil inline-asm support)
- `RegionFileIO` — `open` (attach to existing), `create` (zero-initialising, `O_TRUNC`), `openBacking` (fresh-or-existing selection), `ensureSize`, `fdatasync`, `close`, `unlink`. Fresh-format intent is threaded to backends via `TxnRegionBackend.create(size, prot, fresh)`.
- `X86_64Backends` factory component

### Write-ahead log (single-transaction, superseded)
- `SingleTxnWal` — in-region single-transaction redo log living in block 1 (`X86_64SingleTxnWal.v3`)
- `LogHeader` layout: `numEntries`, `status` (0=invalid/1=committed), `checksum`
- `LogEntry` layout: `offset` (region-relative), `value`, `width` (1/2/4/8)
- Commit protocol: persist entries → set status=1 → apply to region → fence → clear status
- Recovery: checksum verify → redo entries → fence → clear status durably
- **No longer wired in** — `PWRegion`/`RegionTransaction` now drive `MultiTxnWal` instead. Renamed `RegionWal` → `SingleTxnWal` and retained as a reference implementation for comparison against `MultiTxnWal` (see `docs/wal-comparison.md`).

### Two-slot redo WAL, phase A (`X86_64DualTxnWal.v3`) — active
- `DualTxnWal` — redo log holding at most 2 transactions in two fixed slots after a minimal `DualWalHeader` (64 B: magic/version/headerSize/slotBytes/slotCount/checksum) in the block-1 log chunk; `slotBytes = alignDown((blockSize − 64) / 2, 64)`
- Slot selected by sequence parity (`txnSeq % 2`); records reuse the `TxnRecordHeader`/`TxnCommitTrailer`/`LogEntry` layouts with the `logEpoch` fields reserved (must be 0) and distinct magics (`DWALHEAD`/`DWALTXHD`/`DWALTXCM`) so stale `MultiTxnWal` ring bytes in a reused chunk can never validate
- Phase A commit = write record into slot `txnSeq % 2` → `persistRange` (boundary 1, the commit point) → apply after-images → `persistChanges` (boundary 2). Recovery = validate both slots → replay valid records in ascending `txnSeq` → persist → `nextTxnSeq = max + 1`. No superblocks, epochs, replay floor, or checkpoint policy
- **Open Issue #7 fixed from day one**: `append()` returns `bool` and poisons the pending transaction on an invalid entry, so `commit()` fails instead of committing with a silently missing write. Empty commits write an `entryCount=0` record, so a successful commit always returns a nonzero seq (no failure-sentinel collision)
- **Open Issue #8 fixed from day one**: `recover()` returns `DualWalRecovery` (`CLEAN` / `REPLAYED` / `CORRUPT` / `PERSIST_FAILED`); `PWRegion.mount()` consumes it and traces the bad outcomes
- Failed commit-point persist burns nothing: the seq is not advanced and parity maps the retry onto the same slot, so a duplicate-seq record at another location is structurally impossible (no scrub/rollback protocol)
- Overwrite guard: a slot whose record covers not-yet-durable data (boundary-2 failure, or a mount that skipped `recover()`) cannot be overwritten — commit retries the data persist and otherwise fails cleanly through the existing `bool` propagation
- Wired into `RegionTransaction`/`PWRegion` in place of `MultiTxnWal`: `commit()` is `appendToWal → wal.commit → applyToRegion → persistAppliedData → clear`; `noteApplied`/`maybeCheckpoint` dropped out. A boundary-2 failure does not fail the transaction (data remains WAL-recoverable); it emits a `Trace.OUT` diagnostic
- Tests: `DualTxnWalTest.v3` (fresh init, slot alternation, empty-commit seq, commit→crash→recover, clean remount, torn-record rejection, two-slot ascending replay, overwrite + latest-two replay, oversize-commit failure, poisoned-append commit failure, unrecovered-slot overwrite guard, failed-persist same-slot/same-seq retry, corrupt-header recovery result); `WALCacheTest.v3`/`TxnPWRegionTest.v3` re-pointed (slot geometry, boundary-2 persist counts, recovery paths)

### Multi-transaction WAL (`X86_64MultiTxnWal.v3`) — superseded, not wired in
- Circular redo log living in block 1, with a dual-copy superblock at the head of the chunk and the ring immediately after (`ringBase = logChunkAddr + 2 * WalSuperblock.size`, `ringBytes = blockSize - 2 * WalSuperblock.size`)
- Layouts: `WalSuperblock` (64 B, dual copy), `TxnRecordHeader` (64 B), `TxnCommitTrailer` (48 B); records are `ALIGNMENT`(64 B)-aligned, magic/version/size guarded, with an FNV-style checksum over the whole record
- Generation-based superblock selection: `loadSuperblock` picks the valid copy with the higher `generation`; `writeSuperblock` writes the inactive copy, persists, then swaps
- `logEpoch` fences stale records: `validateRecord` rejects records whose epoch ≠ current epoch; recovery bumps the epoch (and writes a fresh superblock) so replayed records cannot be re-applied on a later mount
- `durableAppliedSeq` is the replay floor: recovery scans the ring, selects the contiguous `txnSeq` prefix starting at `durableAppliedSeq + 1` (`selectContiguousPrefix`), redoes it, persists, then publishes the new `durableAppliedSeq`
- Append path: `append()` buffers `WalPendingEntry`s; `commit()` writes one contiguous record (`appendCommittedRecord`) and returns its `txnSeq` (0 on failure). `reserveRecord` handles wrap-around and triggers a lazy `checkpoint` when the ring is full before retrying
- `checkpoint(targetSeq)` persists pending region changes, publishes `durableAppliedSeq` via the superblock, and reclaims now-durable records from `activeRecords`
- `maybeCheckpoint()` implements a hybrid count-OR-occupancy policy (`lag ≥ checkpointTxnThreshold` **OR** `activeBytes ≥ checkpointFillPercent% of ringBytes`) with the lazy ring-full `reserveRecord` checkpoint kept as a backstop. Thresholds are chosen per backend via `BackendRegion.checkpointCost()` (`CheckpointCost.FREE`/`CHEAP`/`EXPENSIVE` → volatile/PMEM/file); an `activeBytes` running counter (maintained in `appendCommittedRecord`/`reclaimAppliedRecords`) drives the occupancy watermark. Best-effort: a failed checkpoint leaves data recoverable from the WAL.
- `RegionTransaction.commit()` / `PWRegion.performCommit()` now return `bool` instead of silently swallowing a WAL commit failure. `allocChunk()` returns `blankChunkHandle` (the existing exhaustion sentinel) and `freeChunk()` returns `false` when the underlying WAL commit fails (record cannot fit even after a checkpoint-and-retry). This is propagation only — no auto-split/retry — and buffered writes are never discarded on failure (the cache stays dirty; data is retained, not lost, consistent with the pre-existing invariant). A failed opportunistic `maybeCheckpoint()` after a successful WAL commit does **not** fail the transaction (see `docs/checkpoint-policy.md`); it only emits a `Trace.OUT` diagnostic.
- `RegionTransaction` rewired onto `MultiTxnWal`: `commit()` is `appendToWal → wal.commit → applyToRegion → noteApplied → maybeCheckpoint → clear`

### Transaction cache
- `RegionTransaction` — write-behind `HashMap<u64, CachedUpdate>` buffering writes in DRAM
- Read path: cache hit returns buffered value; miss falls through to live region memory
- `commit()` pipeline: appendToWal → wal.commit → applyToRegion → fence → clear log → clear cache
- `isDirty()` guard so clean commits are no-ops

### Block allocator
- On-region layouts: `PWRegionHeader`, `BlockEntry`, `ChunkHeader`, `MetaDataDesc`, `LineMark`, `LogHeader`, `LogEntry`
- Unboxed handle types: `BlockTableHandle`, `BlockEntryHandle`, `ChunkHandle`, `LineMarkTableHandle`
- `PWRegion.format()` — writes header, sentinels, block table, free lists; single `persistRange` flush
- `PWRegion.mount()` — validates blockSize/numBlocks, restores handles, runs WAL recovery
- `allocChunk(n)` — SMALL_FREE fast path, LARGE_FREE first-fit with splitting
- `freeChunk(chunk)` — left + right coalescing, re-insertion into correct free list
- Each alloc/free calls `performCommit()` — one WAL transaction per allocator operation
- `ImmixPWRegion` — extends `PWRegion` with line-mark metadata table and `resetAllLineMarks()`

### Platform wrappers
- `X86_64PWMemRegion`, `X86_64PWNVRegion`, `X86_64PWBlockDeviceRegion`
- `X86_64ImmixPWMemRegion`, `X86_64ImmixPWNVRegion`

### Tests
- `WALCacheTest.v3` — `RegionTransaction` cache read/write, miss fallthrough, commit flow (now over `MultiTxnWal`: durable record written, only cache cleared on commit), clean-txn no-op, aligned-access constraint, commit-failure propagation (oversized transaction overflows the ring, `commit()` returns `false`, cache stays dirty, WAL remains usable for subsequent transactions)
- `TxnPWRegionTest.v3` — format/mount, alloc/free, coalescing, exhaustion; block-device remount, WAL recovery, corrupt-WAL rejection (now via `MultiTxnWal` record checksum); `FileMmapRegion`/`PmemMmapRegion` state and lifecycle; small-ring WAL-overflow commit-failure propagation through `allocChunk`
- `MultiTxnWalTest.v3` — fresh superblock init, newest-generation superblock selection, corrupt-newer-superblock fallback, single-record recovery, record-checksum rejection, invalid-width rejection, contiguous-prefix-only replay, epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, crash-mid-log recovery, per-backend checkpoint-policy thresholds, `maybeCheckpoint` count-cap and occupancy-watermark paths

---

## In Progress

- **Design pivot (2026-07-09, decided with supervisor):** a redo log holding **at most 2 transactions** is good enough for our use case — it achieves the persistence-boundary reduction that motivated `MultiTxnWal` at a fraction of the complexity. The two-slot WAL (`DualTxnWal`, Next Steps #1) is now the priority; finishing `MultiTxnWal` hardening is second priority (Next Steps #2).
- **Phase A of `DualTxnWal` is implemented and wired in** (see Completed): two persistence boundaries per commit, replacing `MultiTxnWal` on the commit path. `MultiTxnWal` is retained alongside `SingleTxnWal` as a comparison implementation. Next: phase B (piggybacked boundary, one per commit steady-state).
- Multi-transaction WAL core paths are test-covered (`MultiTxnWalTest.v3`): epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, and crash-mid-log recovery. The `maybeCheckpoint()` policy is implemented (hybrid count-OR-occupancy, per-backend thresholds). Commit-failure propagation is implemented (see Completed).
- A design review of `MultiTxnWal` (2026-07-02) found two durability bugs (epoch double-increment in `recover()`, duplicate `txnSeq` after a failed `persistRange`) plus several API-hardening items — see Next Steps #2 follow-ups and Open Issues #7–8. Both durability bugs are fixed (regression-tested by `multi_wal:commit_after_recovery_survives` and `multi_wal:failed_persist_no_duplicate`).

---

## Next Steps

### 1. Two-slot redo WAL (`DualTxnWal`) — current priority

**Decision (2026-07-09):** replace `MultiTxnWal` on the commit path with a redo log that holds at most 2 transactions (two fixed slots in the block-1 log chunk). Built in two phases: phase A commits with two persistence boundaries (log, then data); phase B piggybacks the previous transaction's data persist onto the next transaction's log boundary, reaching one boundary per commit in steady state.

**Assessment — why 2 slots is enough:**
- Redo entries are **idempotent absolute after-images** (`offset`/`value`/`width` stores), so re-applying an already-durable record is harmless. Recovery can therefore validate both slots and replay the valid records in ascending `txnSeq` — no `durableAppliedSeq` replay floor is needed, which deletes the dual superblock, generation selection, epoch fencing, checkpoint policy, and all ring bookkeeping (`reserveRecord`/`rangeFree`/`reclaimAppliedRecords`) in one stroke.
- Slot selection by sequence parity (`txnSeq % 2`) makes the duplicate-`txnSeq`-after-failed-`persistRange` hazard (2026-07-02 review) **structurally impossible**: a retried commit overwrites the same slot, so no magic-scrub / head-rollback protocol is needed.
- In phase B, at any moment at most one transaction's data is not yet durable (the previous one) plus the record being committed — exactly 2 slots. Correctness by induction: if record N+1 is valid on-region, the boundary at its commit completed, so txn N's data is durable; replaying the ≤2 valid records always restores the latest acknowledged state.
- The invariant that makes redo-only logging sufficient carries over unchanged: `RegionTransaction`'s write-behind cache guarantees uncommitted data never reaches the region (apply happens strictly after the log record is durable).
- Boundary count: phase A is 2/commit; phase B is 1/commit in steady state — matching checkpointed `MultiTxnWal` (~1/commit amortized) while also dropping its superblock `persistRange`, and far below `SingleTxnWal`'s 3 (entries+status, post-apply fence, status clear).

**Accepted trade-offs vs `MultiTxnWal`:** per-transaction capacity is ~half the log chunk minus headers (allocator transactions are a handful of metadata words, so this is ample; an oversize commit fails cleanly through the existing `bool` propagation); no burst absorption of many committed-but-uncheckpointed transactions; on PMEM, data lines are flushed every commit instead of every `CHECKPOINT_TXN_CHEAP` commits (cheap fences — acceptable).

**Phase A — two boundaries per commit** — **done (see Completed)**:
commit = write record into slot `txnSeq % 2` → **persist record** (boundary 1, the commit point) → apply after-images to region → **persist data** (boundary 2) → slot reclaimable. Recovery: validate both slots → replay valid records in seq order → persist data → `nextTxnSeq = max(valid seqs) + 1`.
- [x] Implement `X86_64DualTxnWal.v3`: two fixed slots after a minimal chunk header (`DualWalHeader`); reuses the `TxnRecordHeader`/`TxnCommitTrailer` layouts with `logEpoch` reserved-zero and distinct magics; per-record checksum kept
- [x] `append()` contract fixed from day one: returns `bool` **and** poisons the pending transaction so `commit()` fails (Open Issue #7 not inherited); `recover()` returns `DualWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`) and `mount()` consumes it (Open Issue #8 not inherited). Bonus: empty commits write an `entryCount=0` record, eliminating the empty-commit sentinel collision; `backendRegion` is required non-null (one contract, no dead guards)
- [x] Wired into `RegionTransaction`/`PWRegion` in place of `MultiTxnWal` — commit pipeline is `appendToWal → wal.commit → applyToRegion → persistAppliedData → clear`; `noteApplied`/`maybeCheckpoint` dropped out. Added an overwrite guard: a slot covering not-yet-durable data is never destroyed (commit retries the data persist or fails cleanly)
- [x] Tests: `DualTxnWalTest.v3` (13 cases — fresh init, commit→crash→recover, torn-record rejection, two-valid-slots replay order, retry-after-failed-persist reuses the same slot/seq, oversize-commit failure, poisoned-append failure, unrecovered-slot overwrite guard, clean remount, corrupt-header result); `WALCacheTest`/`TxnPWRegionTest` recovery paths re-pointed

**Phase B — piggybacked boundary (one per commit steady-state):** defer transaction N's data persist; the log-persist boundary at transaction N+1's commit also covers it. Slot N is reclaimable only once a later record is durable.
- File backend: free — `fdatasync`/`msync` flush the whole mapping, so txn N+1's boundary 1 subsumes txn N's data persist
- PMEM backend: flush txn N's changed lines (already accumulated via `prepareChangedRange`) together with the new record's lines under one `SFENCE`
- [ ] Track the pending-data transaction and fold its data persist into the next commit's boundary; explicit `fenceAppliedUpdates()`-style flush for unmount/idle
- [ ] Recovery tests: crash after log persist / before apply; crash after apply / before next commit; back-to-back commits then crash; verify the induction property (valid record N+1 ⇒ txn N data durable)
- [ ] Optional: scrub reclaimed slots on clean `close()` so clean remounts are replay-free (design note inherited from `MultiTxnWal`)
- [ ] Extend `docs/wal-comparison.md` with a third column for `DualTxnWal`

### 2. Multi-transaction WAL — deprioritized (second priority)
**Deprioritized 2026-07-09** in favor of the two-slot WAL (#1): the superblock/epoch/ring/checkpoint machinery buys burst absorption and bounded replay we don't need for allocator-sized transactions. `DualTxnWal` phase A has landed and replaced it on the commit path; `MultiTxnWal` is now retained alongside `SingleTxnWal` as a comparison implementation (its own unit tests still run). The unchecked items below are paused unless they block the comparison write-up.

The core `MultiTxnWal` is implemented and wired in (see Completed). Remaining work:
- [x] `maybeCheckpoint()` implemented as hybrid count-OR-occupancy with the lazy ring-full `reserveRecord` checkpoint kept as a backstop, thresholds chosen per backend via `BackendRegion.checkpointCost()` (`CheckpointCost.FREE`/`CHEAP`/`EXPENSIVE`). Policy brainstormed in `docs/checkpoint-policy.md` (Option E + light F). Covered by `MultiTxnWalTest.v3` (`checkpoint_policy_thresholds`, `maybe_checkpoint_count`, `maybe_checkpoint_occupancy`).
- [x] Test the untested core paths: **epoch-stale rejection** (bump epoch, confirm prior-epoch records are ignored) and **wrap-around / log-full → checkpoint → reserve** (fill a small ring and verify reclaim + wrap). Done in `MultiTxnWalTest.v3` (`epoch_stale_rejected`, `wraparound_checkpoint_reserve`).
- [x] Multi-record recovery test (current recovery test replays a single record; add a multi-transaction commit + crash-mid-log case). Done in `MultiTxnWalTest.v3` (`recovers_multiple_records`, `crash_mid_log_recovery`).
- [x] Commit-failure propagation: `RegionTransaction.commit()`/`PWRegion.performCommit()` return `bool`; `allocChunk()`/`freeChunk()` surface failure via `blankChunkHandle`/`false`. Done — see Completed.
- [x] Repurpose the now-orphaned `RegionWal`: renamed to `SingleTxnWal` (`X86_64SingleTxnWal.v3`) and retained as a reference implementation for comparison against `MultiTxnWal`. Comparison written up in `docs/wal-comparison.md`; still not wired in.

**Design-review follow-ups (2026-07-02):**

Durability bugs (fix first):
- [x] **Epoch double-increment in `recover()`** — both recovery paths called `writeSuperblock(…, logEpoch + 1)` and then bumped `logEpoch` *again* (`writeSuperblock` already assigns `logEpoch = epoch`), so after recovery the in-memory epoch was one ahead of the durable superblock; records committed after a recovery were stamped with the wrong epoch and a crash before the next checkpoint made the remount reject them as stale — **acknowledged commits lost**. The gap-abandonment path also double-bumped `currentGeneration`. Fixed: both redundant bumps removed — `writeSuperblock` alone adopts the new epoch/generation on success. Note the gap path still ignores `writeSuperblock`'s return (best-effort abandonment; folded into the `recover()` return-value item below).
- [x] **Duplicate `txnSeq` after failed `persistRange`** — `appendCommittedRecord` wrote a complete, valid-checksum record into the ring (and advanced `headOffset`) *before* the `persistRange` at the commit point; on failure the record bytes could still reach disk via page-cache writeback, and a retried commit wrote a second record with the same `txnSeq` at a different offset — recovery's `selectContiguousPrefix` silently keeps whichever duplicate it scans last and could replay the *failed* attempt. Fixed: on persist failure the record's header magic is scrubbed (scrub persisted best-effort) and `headOffset` is rolled back to the reserved slot, so a retry reuses both the same seq and the same location. The seq is deliberately *not* burned — a skipped seq would gap the committed prefix and make recovery abandon later acknowledged transactions. Regression-tested by `multi_wal:failed_persist_no_duplicate` (verified to fail pre-fix on the head-rollback assertion).
- [x] Add a **recover → commit → crash → recover** test. Done: `multi_wal:commit_after_recovery_survives` (`MultiTxnWalTest.v3`) — verified to fail on the pre-fix code (`expected 2 == 3` on the epoch).

API hardening:
- [ ] `append()` silently drops entries failing `validEntryFields` (returns void); the revalidation loop in `appendCommittedRecord` can't see the dropped entry, so a transaction can commit *successfully* while missing a write. `append` should return `bool` or poison the pending transaction so `commit()` fails.
- [ ] `validEntryFields` dereferences `backendRegion.range` without the null guard every other method uses — either the guards are dead code or this is a crash path; pick one contract.
- [ ] Empty-commit sentinel collision: `appendCommittedRecord` returns `durableAppliedSeq` for an empty commit, which is 0 on a fresh region — indistinguishable from the failure sentinel. Unreachable today only because `RegionTransaction.commit()` guards with `isDirty()`.
- [ ] `recover()`'s `bool` conflates clean-nothing-to-replay, corrupt superblocks, and persist-failure-mid-recovery — and both `PWRegion` call sites discard the result, so a mid-recovery persist failure is invisible to `mount()`.

Design notes (no action yet, keep in mind):
- Layering: `MultiTxnWal` is log manager + region applier + raw read path in one class; the `readU8`…`readI64` helpers have nothing to do with logging and belong in a shared region-memory helper.
- Recovery scan cost: `scanCommittedRecords` runs a full checksum-validating `validateRecord` at every 64-byte slot and `selectContiguousPrefix` is O(n²) — fine for one 4 KB block, quadratic-ish if `logChunkSize` grows (the new `logChunk` header field makes that likely).
- `reserveRecord` only tries `headOffset` and offset 0; a surviving record ahead of the head forces a full checkpoint even when a fitting hole exists elsewhere. Fine under the current commit-then-apply-immediately usage — an implicit dependency worth documenting.
- `close()` is empty, so even a clean unmount replays the tail on the next mount; a `fenceAppliedUpdates()` call there would make clean remounts replay-free.
- Per-commit constant factors: `zeroBytes` + field stores + `checksumBytes` are three byte-at-a-time passes over each record.

### 3. CLWB/SFENCE intrinsics
`MmapRegionUtils.flushCacheLine()` and `storeFence()` are no-op placeholders. PMEM durability is not functional until these emit real `CLWB`/`CLFLUSHOPT` and `SFENCE` instructions. Requires either Virgil inline-asm support or a small native stub.

### 4. Minor cleanups
- [x] `RegionFileIO.openOrCreate` → split into `open` and `create`; `create` zero-initialises bytes (`O_TRUNC` + `ftruncate` zero-fill). Fresh-format intent threaded through `TxnRegionBackend.create(size, prot, fresh)`; `openBacking(path, fresh)` selects create-vs-open (open falls back to create when the file is missing).
- [x] Add log-chunk offset to `PWRegionHeader` — new `logChunk` field (region-relative byte offset) written by `format()` and read by `mount()`, so recovery locates the log via the header instead of assuming block 1. Header grew 72 → 80 bytes; `mount()` keeps a defensive fallback to block 1 when the field reads as `0`. Covered by `TxnPWRegionTest.v3` (`format_header_fields` asserts the field; the remount/recovery tests exercise the header-driven read path).
- [x] `RegionTransaction.clear()` — no longer reallocates the `HashMap`; empties it in place via `cache.remove()` over the `addrs` key set (both `HashMap.remove` and `Vector.clear` retain their backing storage), reusing the map and vector across commits. Covered by the existing `wal_cache:` and `pwregion:` unit tests (commit→clear cycle, remount/recovery).
- Link line-mark field in `createChunk()` (`ImmixPWRegion`)
- `ImmixLineSize` should come from the metadata descriptor, not be hardcoded

---

## Open Issues

| # | File | Description |
|---|------|-------------|
| 1 | `X86_64TxnBackend.v3:88-100` | `flushCacheLine`/`storeFence` are stubs — PMEM not truly durable |
| 2 | `X86_64TxnBackend.v3:58` | Page size hardcoded as 4096 |
| 3 | `X86_64TxnPWRegion.v3` | Line-mark field not linked in `createChunk()` |
| 4 | `X86_64TxnPWRegion.v3` | `ImmixLineSize` hardcoded (should use metadata descriptor) |
| 5 | `TxnBackend.v3:106` | `Backends.getMmap()` declared but not implemented |
| 6 | `X86_64TxnPWRegion.v3` | `getHeader()` now copies the header into a fresh `Array<byte>` on every call (minor GC pressure) |
| 7 | `X86_64MultiTxnWal.v3` | `append()` silently drops invalid entries — a transaction can commit successfully while missing a write. Deprioritized with `MultiTxnWal` (now a comparison implementation, not wired in); `DualTxnWal` fixed this contract from day one (`append() -> bool` + transaction poisoning) |
| 8 | `X86_64MultiTxnWal.v3` | `recover()` return value conflates clean/corrupt/persist-failure, and both `PWRegion` call sites ignore it. Deprioritized with `MultiTxnWal` (not wired in); `DualTxnWal` defines `DualWalRecovery` and `mount()` consumes it |
