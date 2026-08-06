# Persistent Region Allocator — Roadmap

Work log for the `pwregions` branch. See `docs/persistent-backends.md` for design detail and `docs/pmem-emulation.md` for the emulated-PMEM development and validation plan.

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
- **No longer wired in** — `PWRegion`/`RegionTransaction` now drive `DualTxnWal` instead. Renamed `RegionWal` → `SingleTxnWal` and retained as a reference implementation for comparison against `MultiTxnWal` and `DualTxnWal` (see `docs/wal-comparison.md`).

### Two-slot redo WAL, phase B (`X86_64DualTxnWal.v3`) — active
- **Piggybacked boundary — one per commit in steady state.** The commit point is now `prepareChangedRange(record) + persistChanges()`: one boundary persists the new record *together with* the previous transaction's applied after-images (one `SFENCE` over all flushed lines on PMEM; one `fdatasync` on file, which subsumes both). The committing transaction's own after-images are applied write-behind afterwards and ride the *next* commit's boundary. `dataDurableSeq` advances to `lastCommittedSeq` at each successful boundary — the induction property (valid record N+1 ⇒ txn N's data durable) made explicit
- Contract: the caller must apply a committed transaction's entries before committing the next one (`RegionTransaction` guarantees this); the boundary only covers already-applied after-images
- `RegionTransaction.commit()` is now `appendToWal → wal.commit (combined boundary) → applyToRegion → clear`; the per-commit `persistAppliedData()` (phase A boundary 2) dropped out. Explicit `RegionTransaction.flush()` added for idle-time durability
- `close()` is the clean-unmount flush: persists the deferred data (`persistAppliedData()`), then scrubs reclaimable slots (only those with `slotSeq ≤ dataDurableSeq` — unrecovered records are never destroyed) so a clean remount recovers `CLEAN`, replay-free. A failed final persist leaves the records intact for the next mount's replay; a failed scrub persist latches recovery-required and any surviving record replays idempotently. `PWRegion.deallocate()` already routes through `wal.close()`
- Fresh-header, commit-record, after-image preparation, recovery, explicit-flush, final-data-close, and slot-scrub persistence failures now latch `DualTxnWal` in a recovery-required state. `applyUpdate()` reports success/failure, and recovery stops before its persistence boundary if an after-image range cannot be prepared. The same instance rejects append, commit, apply, persist, recovery and close persistence work; only a newly constructed instance may inspect and recover the durable image
- Persistence-failure contract chosen 2026-07-30: a boundary-related `commit() == 0` is **unacknowledged**, not a guaranteed abort. Recovery may replay any complete durable record because entries are idempotent after-images. The core fresh-init, commit, apply, recovery, explicit-flush, final-data-close and slot-scrub paths enforce recovery-required state; `RegionTransaction.requiresRecovery()` and `PWRegion.requiresRecovery()` now expose that distinction, failed after-image application propagates through `commit()`, and allocator entry points reject work on a latched mount
- Tests: `DualTxnWalTest.v3` grew to 34 cases — crash after apply/before next commit, back-to-back commits then crash, one-boundary-per-commit + induction property (counting region: 1 `persistChanges`, 0 `persistRange` per commit), explicit-flush durability, commit/apply/recovery/flush/final-data-close/slot-scrub failure requiring reopen, fresh-header fail-before-copy and copy-then-fail outcomes, close-scrubs-for-clean-remount, close-keeps-unrecovered-records, and a shadow durable-memory model with fail-before/copy-then-fail/partial-copy outcomes; the copy-then-fail regressions make indeterminate persistence executable. `RegionTransactionTest.v3`: boundary counts re-pinned (record+data prepares, 1 `persistChanges`/commit), piggybacked-durability and `flush()` tests added
- `docs/wal-comparison.md` extended with a third column for `DualTxnWal` and a "why two slots superseded the ring" section

### Two-slot redo WAL, phase A (`X86_64DualTxnWal.v3`) — superseded by phase B above
- `DualTxnWal` — redo log holding at most 2 transactions in two fixed slots after a minimal `DualWalHeader` (64 B: magic/version/headerSize/slotBytes/slotCount/checksum) in the block-1 log chunk; `slotBytes = alignDown((blockSize − 64) / 2, 64)`
- Slot selected by sequence parity (`txnSeq % 2`); records reuse the `TxnRecordHeader`/`TxnCommitTrailer`/`LogEntry` layouts with the `logEpoch` fields reserved (must be 0) and distinct magics (`DWALHEAD`/`DWALTXHD`/`DWALTXCM`) so stale `MultiTxnWal` ring bytes in a reused chunk can never validate
- Phase A commit = write record into slot `txnSeq % 2` → `persistRange` (boundary 1, the commit point) → apply after-images → `persistChanges` (boundary 2). Recovery = validate both slots → replay valid records in ascending `txnSeq` → persist → `nextTxnSeq = max + 1`. No superblocks, epochs, replay floor, or checkpoint policy
- **Open Issue #7 fixed from day one**: `append()` returns `bool` and poisons the pending transaction on an invalid entry, so `commit()` fails instead of committing with a silently missing write. Empty commits write an `entryCount=0` record, so a successful commit always returns a nonzero seq (no failure-sentinel collision)
- **Open Issue #8 fixed from day one**: `recover()` returns `DualWalRecovery` (`CLEAN` / `REPLAYED` / `CORRUPT` / `PERSIST_FAILED`); `PWRegion.mount()` consumes it and traces the bad outcomes
- Failed commit-point persist burns nothing: the seq is not advanced and parity prevents a duplicate-seq record at another location. The active phase-B implementation now forbids same-instance retry after such a persistence failure and requires reopen/recovery
- Overwrite guard: a slot whose record covers not-yet-durable data (boundary-2 failure, or a mount that skipped `recover()`) cannot be overwritten — commit retries the data persist and otherwise fails cleanly through the existing `bool` propagation
- Wired into `RegionTransaction`/`PWRegion` in place of `MultiTxnWal`: `commit()` is `appendToWal → wal.commit → applyToRegion → persistAppliedData → clear`; `noteApplied`/`maybeCheckpoint` dropped out. A boundary-2 failure does not fail the transaction (data remains WAL-recoverable); it emits a `Trace.OUT` diagnostic
- Tests: `DualTxnWalTest.v3` (fresh init, slot alternation, empty-commit seq, commit→crash→recover, clean remount, torn-record rejection, two-slot ascending replay, overwrite + latest-two replay, oversize-commit failure, poisoned-append commit failure, unrecovered-slot overwrite guard, failed-persist reopen requirement, corrupt-header recovery result); `RegionTransactionTest.v3`/`TxnPWRegionTest.v3` re-pointed (slot geometry, boundary-2 persist counts, recovery paths)

### Multi-transaction WAL (`X86_64MultiTxnWal.v3`) — superseded, not wired in
- Circular redo log living in block 1, with a dual-copy superblock at the head of the chunk and the ring immediately after (`ringBase = logChunkAddr + 2 * WalSuperblock.size`, `ringBytes = blockSize - 2 * WalSuperblock.size`)
- Layouts: `WalSuperblock` (64 B, dual copy), `TxnRecordHeader` (64 B), `TxnCommitTrailer` (48 B); records are `ALIGNMENT`(64 B)-aligned, magic/version/size guarded, with an FNV-style checksum over the whole record
- Generation-based superblock selection: `loadSuperblock` picks the valid copy with the higher `generation`; `writeSuperblock` writes the inactive copy, persists, then swaps
- `logEpoch` fences stale records: `validateRecord` rejects records whose epoch ≠ current epoch; recovery bumps the epoch (and writes a fresh superblock) so replayed records cannot be re-applied on a later mount
- `durableAppliedSeq` is the replay floor: recovery scans the ring, selects the contiguous `txnSeq` prefix starting at `durableAppliedSeq + 1` (`selectContiguousPrefix`), redoes it, persists, then publishes the new `durableAppliedSeq`
- Hardened append path: `append()` returns `bool` and poisons the pending transaction on any invalid entry; `commit()` then fails rather than acknowledging an incomplete write set. Successful empty commits write a zero-entry record and receive a nonzero `txnSeq`, leaving 0 as an unambiguous failure sentinel. `reserveRecord` handles wrap-around and triggers a lazy `checkpoint` when the ring is full before retrying
- `backendRegion` is a required constructor dependency (null leaves the WAL unopened); persistence paths use that single contract instead of mixing null-as-no-op guards with unconditional dereferences
- `recover()` returns `MultiWalRecovery` (`CLEAN` / `REPLAYED` / `CORRUPT` / `PERSIST_FAILED`), including failures while publishing gap abandonment or replay durability
- `checkpoint(targetSeq)` persists pending region changes, publishes `durableAppliedSeq` via the superblock, and reclaims now-durable records from `activeRecords`
- `maybeCheckpoint()` implements a hybrid count-OR-occupancy policy (`lag ≥ checkpointTxnThreshold` **OR** `activeBytes ≥ checkpointFillPercent% of ringBytes`) with the lazy ring-full `reserveRecord` checkpoint kept as a backstop. Thresholds are chosen per backend via `BackendRegion.checkpointCost()` (`CheckpointCost.FREE`/`CHEAP`/`EXPENSIVE` → volatile/PMEM/file); an `activeBytes` running counter (maintained in `appendCommittedRecord`/`reclaimAppliedRecords`) drives the occupancy watermark. Best-effort: a failed checkpoint leaves data recoverable from the WAL.
- `RegionTransaction.commit()` / `PWRegion.performCommit()` now return `bool` instead of silently swallowing a WAL commit failure. `allocChunk()` returns `blankChunkHandle` (the existing exhaustion sentinel) and `freeChunk()` returns `false` when the underlying WAL commit fails (record cannot fit even after a checkpoint-and-retry). This is propagation only — no auto-split/retry — and buffered writes are never discarded on failure (the cache stays dirty; data is retained, not lost, consistent with the pre-existing invariant). A failed opportunistic `maybeCheckpoint()` after a successful WAL commit does **not** fail the transaction (see `docs/checkpoint-policy.md`); it only emits a `Trace.OUT` diagnostic.
- `RegionTransaction` rewired onto `MultiTxnWal`: `commit()` is `appendToWal → wal.commit → applyToRegion → noteApplied → maybeCheckpoint → clear`

### Transaction cache
- `RegionTransaction` — write-behind `HashMap<u64, CachedUpdate>` buffering writes in DRAM
- Read path: cache hit returns buffered value; miss falls through to live region memory
- Active phase-B `commit()` pipeline: `appendToWal → wal.commit` (new record + previous data boundary) `→ applyToRegion → clear cache`; `flush()` / `DualTxnWal.close()` provide the idle/unmount boundary for the last applied transaction
- `isDirty()` guard so clean commits are no-ops
- Recovery-required propagation: `RegionTransaction.commit()` retains the dirty cache and returns `false` when `applyUpdate()` fails, clean commits cannot mask a latched WAL, and both `RegionTransaction` and `PWRegion` expose `requiresRecovery()`

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

**Audited 2026-07-31 and extended 2026-08-06:** the four implementation-specific x86-64 Linux test files contain **106 registered tests**. The original 102 passed with no expected failures; the four recovery-propagation regressions added on 2026-08-06 compile in the x86-64 Linux unit target, but were not executable on the current Darwin arm64 host.

- `DualTxnWalTest.v3` — **34 tests** for the active two-slot WAL: format/geometry, fresh-header persistence failures, slot alternation, empty commits, crash recovery against separate live/durable byte images, corrupt/torn records, replay ordering, overwrite guard, oversize/poisoned commits, commit/apply/recovery/flush/final-data-close/slot-scrub recovery-required enforcement, fail-before/copy-then-fail/partial-copy shadow outcomes, the normative unacknowledged-record replay, the phase-B one-boundary induction property, explicit flush, and clean/unrecovered close paths
- `RegionTransactionTest.v3` — **16 tests** for `RegionTransaction` over the active `DualTxnWal`: cache read/write and fallthrough, write-behind apply/clear, phase-B persistence call counts, piggybacked durability, explicit flush, clean no-op, overwrite/alignment behavior, oversize-commit rejection, and commit/apply/flush recovery-required propagation
- `TxnPWRegionTest.v3` — **34 tests** across allocator (`pwregion:`), overflow propagation (`pwregion_overflow:`), injected recovery-required propagation (`pwregion_recovery:`), backend ownership/state (`txn_backend:`), and file-backed remount/recovery (`pwregion_bd:`): format, alloc/free/coalescing/exhaustion, `DualTxnWal` recovery/checksum rejection, mmap/PMEM state and lifecycle, and file-backed persistence
- `MultiTxnWalTest.v3` — **22 tests** for the retained comparison WAL: superblocks, recovery, record validation, failure outcomes, epoch/gap handling, wrap-around/checkpoint reserve, crash-mid-log recovery, failed-persist scrub/rollback, and checkpoint policy
- `SingleTxnWal` has **no dedicated tests**; it remains compiled as a reference implementation only
- The PMEM-labelled test is structural only: `txn_backend:pmem_region_tracks_pending_writeback` wraps an anonymous mapping and bypasses `PmemMmapBackend.create()`, `MAP_SYNC`, filesystem DAX, and `/dev/pmem0`

**Evidence limitation:** the active-WAL crash and failure tests restore live
bytes from a separate durable shadow, so unpersisted bytes disappear; counting
tests still use no-op persistence to pin API boundary counts. This establishes
the WAL protocol under the `BackendRegion` contract, not the correctness of a
backend's syscall or instruction translation. The file-backed tests exercise
real `fdatasync`/`msync` paths and graceful remount, but a remount in the same
kernel can still observe page-cache contents and does not establish abrupt-crash
or power-loss durability. Progressively stronger integration tests remain in
Next Steps #3 and `docs/persistent-backends.md`.

---

## In Progress

- **Design pivot (2026-07-09, decided with supervisor):** a redo log holding **at most 2 transactions** is good enough for our use case — it achieves the persistence-boundary reduction that motivated `MultiTxnWal` at a fraction of the complexity. The two-slot WAL (`DualTxnWal`, Next Steps #1) remains active; the retained `MultiTxnWal` hardening follow-up (Next Steps #2) is complete.
- **Phase A and phase B of `DualTxnWal` are implemented and wired in** (see Completed): phase B reaches one persistence boundary per commit in steady state (piggybacked boundary), with `close()` providing the clean-unmount flush + slot scrub. `MultiTxnWal` is retained alongside `SingleTxnWal` as a comparison implementation.
- Multi-transaction WAL core paths are test-covered (`MultiTxnWalTest.v3`): epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, and crash-mid-log recovery. The `maybeCheckpoint()` policy is implemented (hybrid count-OR-occupancy, per-backend thresholds). Commit-failure propagation is implemented (see Completed).
- A design review of `MultiTxnWal` (2026-07-02) found two durability bugs (epoch double-increment in `recover()`, duplicate `txnSeq` after a failed `persistRange`) plus four API-hardening items. All are fixed and regression-tested; see Next Steps #2 follow-ups.
- The 2026-07-29 test audit found that the happy paths and intended phase-B boundary count are strong, but active-WAL failure/crash semantics, full allocator-transaction recovery, Immix/platform wrappers, and several backend/validation paths remain untested. These are tracked in Next Steps #3.
- **Validation direction (2026-07-30):** the test-only shadow durable-memory backend is implemented for `DualTxnWal`. It separates live bytes from a durable shadow, makes persistence operations copy between them, and restores live bytes from the shadow on simulated crash. The core crash/fault matrix now supplies byte-level evidence for the WAL protocol under the `BackendRegion` contract, including after-image preparation and fresh-header persistence failures; recovery-required state now propagates through the transaction and allocator APIs. An allocator-level shadow factory comes before hardware-specific testing. Syscall integration, abrupt process/VM tests, and physical-media testing supply the progressively stronger outer layers of the correctness argument.
- **PMEM emulation assessment (2026-07-29):** use a QEMU file-backed ACPI NVDIMM as the primary development environment and native x86-64 Linux `memmap=<size>!<start>` as an alternative. In both cases, expose `/dev/pmem0`, create an fsdax filesystem, and give `PmemMmapBackend` a regular file on that mount. Validation is staged as DAX/remount integration, guest crash/restart testing, then real-hardware durability; see `docs/pmem-emulation.md`.

---

## Next Steps

### 1. Two-slot redo WAL (`DualTxnWal`) — done (phases A and B)

**Decision (2026-07-09):** replace `MultiTxnWal` on the commit path with a redo log that holds at most 2 transactions (two fixed slots in the block-1 log chunk). Built in two phases: phase A commits with two persistence boundaries (log, then data); phase B piggybacks the previous transaction's data persist onto the next transaction's log boundary, reaching one boundary per commit in steady state.

**Assessment — why 2 slots is enough:**
- Redo entries are **idempotent absolute after-images** (`offset`/`value`/`width` stores), so re-applying an already-durable record is harmless. Recovery can therefore validate both slots and replay the valid records in ascending `txnSeq` — no `durableAppliedSeq` replay floor is needed, which deletes the dual superblock, generation selection, epoch fencing, checkpoint policy, and all ring bookkeeping (`reserveRecord`/`rangeFree`/`reclaimAppliedRecords`) in one stroke.
- Slot selection by sequence parity (`txnSeq % 2`) makes the duplicate-`txnSeq`-at-different-locations hazard (2026-07-02 review) **structurally impossible**: a retried commit overwrites the same slot, so no ring-head rollback is needed. This does not by itself settle whether a failed, checksummed slot must be durably invalidated before a crash; that outcome is tracked in Next Steps #3.
- In phase B, at any moment at most one transaction's data is not yet durable (the previous one) plus the record being committed — exactly 2 slots. Correctness by induction: if record N+1 is valid on-region, the boundary at its commit completed, so txn N's data is durable; replaying the ≤2 valid records always restores the latest acknowledged state.
- The invariant that makes redo-only logging sufficient carries over unchanged: `RegionTransaction`'s write-behind cache guarantees uncommitted data never reaches the region (apply happens strictly after the log record is durable).
- Boundary count: phase A is 2/commit; phase B is 1/commit in steady state — matching checkpointed `MultiTxnWal` (~1/commit amortized) while also dropping its superblock `persistRange`, and far below `SingleTxnWal`'s 3 (entries+status, post-apply fence, status clear).

**Accepted trade-offs vs `MultiTxnWal`:** per-transaction capacity is ~half the log chunk minus headers (allocator transactions are a handful of metadata words, so this is ample; an oversize commit fails cleanly through the existing `bool` propagation); no burst absorption of many committed-but-uncheckpointed transactions; on PMEM, data lines are flushed every commit instead of every `CHECKPOINT_TXN_CHEAP` commits (cheap fences — acceptable).

**Phase A — two boundaries per commit** — **done (see Completed)**:
commit = write record into slot `txnSeq % 2` → **persist record** (boundary 1, the commit point) → apply after-images to region → **persist data** (boundary 2) → slot reclaimable. Recovery: validate both slots → replay valid records in seq order → persist data → `nextTxnSeq = max(valid seqs) + 1`.
- [x] Implement `X86_64DualTxnWal.v3`: two fixed slots after a minimal chunk header (`DualWalHeader`); reuses the `TxnRecordHeader`/`TxnCommitTrailer` layouts with `logEpoch` reserved-zero and distinct magics; per-record checksum kept
- [x] `append()` contract fixed from day one: returns `bool` **and** poisons the pending transaction so `commit()` fails (Open Issue #7 not inherited); `recover()` returns `DualWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`) and `mount()` consumes it (Open Issue #8 not inherited). Bonus: empty commits write an `entryCount=0` record, eliminating the empty-commit sentinel collision; `backendRegion` is required non-null (one contract, no dead guards)
- [x] Wired into `RegionTransaction`/`PWRegion` in place of `MultiTxnWal` — commit pipeline is `appendToWal → wal.commit → applyToRegion → persistAppliedData → clear`; `noteApplied`/`maybeCheckpoint` dropped out. Added an overwrite guard: a slot covering not-yet-durable data is never destroyed (commit retries the data persist or fails cleanly)
- [x] Tests: the original 13-case phase-A suite covered fresh init, commit→crash→recover, torn-record rejection, two-valid-slots replay order, failed persistence, oversize/poisoned failure, overwrite guard, clean remount and corrupt-header handling; the active phase-B suite replaces retry-after-failure with recovery-required reopen

**Phase B — piggybacked boundary (one per commit steady-state)** — **done (see Completed)**: defer transaction N's data persist; the log-persist boundary at transaction N+1's commit also covers it. Slot N is reclaimable only once a later record is durable.
- File backend: free — `fdatasync` flushes the whole mapping, so txn N+1's commit boundary subsumes txn N's data persist
- PMEM backend: flush txn N's changed lines (already accumulated via `prepareChangedRange`) together with the new record's lines under one `SFENCE`
- [x] Track the pending-data transaction and fold its data persist into the next commit's boundary (commit point is now `prepareChangedRange(record) + persistChanges()`; `dataDurableSeq` advances at each boundary); explicit flush for unmount/idle (`RegionTransaction.flush()`, `DualTxnWal.persistAppliedData()`, `close()`)
- [x] Recovery tests: crash after log persist / before apply (`commit_crash_recover`); crash after apply / before next commit (`apply_then_crash_recover`); back-to-back commits then crash (`back_to_back_commits_then_crash`); induction property verified (`one_boundary_per_commit`: 1 `persistChanges` + 0 `persistRange` per commit, `dataDurableSeq == N` once record N+1 is durable)
- [x] Scrub reclaimed slots on clean `close()` so clean remounts are replay-free — only slots with `slotSeq ≤ dataDurableSeq`; unrecovered records survive close (`close_scrubs_for_clean_remount`, `close_keeps_unrecovered_records`)
- [x] Extended `docs/wal-comparison.md` with a third column for `DualTxnWal` (+ boundary-count row and "why two slots superseded the ring" section)

### 2. Multi-transaction WAL — deprioritized (second priority)
**Deprioritized 2026-07-09** in favor of the two-slot WAL (#1): the superblock/epoch/ring/checkpoint machinery buys burst absorption and bounded replay we don't need for allocator-sized transactions. `DualTxnWal` phase A has landed and replaced it on the commit path; `MultiTxnWal` is now retained alongside `SingleTxnWal` as a comparison implementation (its own unit tests still run). The durability and API-hardening follow-ups below were completed for the retained implementation.

The core `MultiTxnWal` is implemented but no longer wired into `PWRegion` (see Completed). Completed follow-ups:
- [x] `maybeCheckpoint()` implemented as hybrid count-OR-occupancy with the lazy ring-full `reserveRecord` checkpoint kept as a backstop, thresholds chosen per backend via `BackendRegion.checkpointCost()` (`CheckpointCost.FREE`/`CHEAP`/`EXPENSIVE`). Policy brainstormed in `docs/checkpoint-policy.md` (Option E + light F). Covered by `MultiTxnWalTest.v3` (`checkpoint_policy_thresholds`, `maybe_checkpoint_count`, `maybe_checkpoint_occupancy`).
- [x] Test the untested core paths: **epoch-stale rejection** (bump epoch, confirm prior-epoch records are ignored) and **wrap-around / log-full → checkpoint → reserve** (fill a small ring and verify reclaim + wrap). Done in `MultiTxnWalTest.v3` (`epoch_stale_rejected`, `wraparound_checkpoint_reserve`).
- [x] Multi-record recovery test (current recovery test replays a single record; add a multi-transaction commit + crash-mid-log case). Done in `MultiTxnWalTest.v3` (`recovers_multiple_records`, `crash_mid_log_recovery`).
- [x] Commit-failure propagation: `RegionTransaction.commit()`/`PWRegion.performCommit()` return `bool`; `allocChunk()`/`freeChunk()` surface failure via `blankChunkHandle`/`false`. Done — see Completed.
- [x] Repurpose the now-orphaned `RegionWal`: renamed to `SingleTxnWal` (`X86_64SingleTxnWal.v3`) and retained as a reference implementation for comparison against `MultiTxnWal`. Comparison written up in `docs/wal-comparison.md`; still not wired in.

**Design-review follow-ups (2026-07-02):**

Durability bugs (fix first):
- [x] **Epoch double-increment in `recover()`** — both recovery paths called `writeSuperblock(…, logEpoch + 1)` and then bumped `logEpoch` *again* (`writeSuperblock` already assigns `logEpoch = epoch`), so after recovery the in-memory epoch was one ahead of the durable superblock; records committed after a recovery were stamped with the wrong epoch and a crash before the next checkpoint made the remount reject them as stale — **acknowledged commits lost**. The gap-abandonment path also double-bumped `currentGeneration`. Fixed: both redundant bumps removed — `writeSuperblock` alone adopts the new epoch/generation on success. Gap-abandonment publication failures now return `MultiWalRecovery.PERSIST_FAILED`.
- [x] **Duplicate `txnSeq` after failed `persistRange`** — `appendCommittedRecord` wrote a complete, valid-checksum record into the ring (and advanced `headOffset`) *before* the `persistRange` at the commit point; on failure the record bytes could still reach disk via page-cache writeback, and a retried commit wrote a second record with the same `txnSeq` at a different offset — recovery's `selectContiguousPrefix` silently keeps whichever duplicate it scans last and could replay the *failed* attempt. Fixed: on persist failure the record's header magic is scrubbed (scrub persisted best-effort) and `headOffset` is rolled back to the reserved slot, so a retry reuses both the same seq and the same location. The seq is deliberately *not* burned — a skipped seq would gap the committed prefix and make recovery abandon later acknowledged transactions. Regression-tested by `multi_wal:failed_persist_no_duplicate` (verified to fail pre-fix on the head-rollback assertion).
- [x] Add a **recover → commit → crash → recover** test. Done: `multi_wal:commit_after_recovery_survives` (`MultiTxnWalTest.v3`) — verified to fail on the pre-fix code (`expected 2 == 3` on the epoch).

API hardening:
- [x] `append()` now returns `bool` and poisons the pending transaction on any invalid entry; `commit()` fails with 0 and clears the poisoned write set. Covered by `multi_wal:invalid_append_poisons_transaction` and `multi_wal:invalid_width_rejected`.
- [x] `backendRegion` is required: a null backend leaves construction unopened, and operational persistence paths no longer carry contradictory null-as-no-op guards. Covered by `multi_wal:null_backend_rejected`.
- [x] Empty commits write a valid `entryCount=0` record and consume the next nonzero sequence, so 0 is failure-only. Covered by `multi_wal:empty_commit_has_sequence`.
- [x] `recover()` returns `MultiWalRecovery` (`CLEAN` / `REPLAYED` / `CORRUPT` / `PERSIST_FAILED`). `MultiTxnWal` has no `PWRegion` call sites now that it is a comparison implementation; its test callers consume the status, including corrupt-superblock, replay-persist-failure, and gap-abandonment-persist-failure regressions (`multi_wal:corrupt_superblocks_reported`, `multi_wal:recovery_persist_failure_reported`, `multi_wal:gap_abandon_persist_failure_reported`).

Design notes (no action yet, keep in mind):
- Layering: `MultiTxnWal` is log manager + region applier + raw read path in one class; the `readU8`…`readI64` helpers have nothing to do with logging and belong in a shared region-memory helper.
- Recovery scan cost: `scanCommittedRecords` runs a full checksum-validating `validateRecord` at every 64-byte slot and `selectContiguousPrefix` is O(n²) — fine for one 4 KB block, quadratic-ish if `logChunkSize` grows (the new `logChunk` header field makes that likely).
- `reserveRecord` only tries `headOffset` and offset 0; a surviving record ahead of the head forces a full checkpoint even when a fitting hole exists elsewhere. Fine under the current commit-then-apply-immediately usage — an implicit dependency worth documenting.
- `close()` is empty, so even a clean unmount replays the tail on the next mount; a `fenceAppliedUpdates()` call there would make clean remounts replay-free.
- Per-commit constant factors: `zeroBytes` + field stores + `checksumBytes` are three byte-at-a-time passes over each record.

### 3. Test-audit follow-ups — open (2026-07-29)

Priority 0 — active WAL failure/crash semantics:

- [x] Add a test-only `ShadowDurableRegion` for `DualTxnWalTest.v3`. It maintains separate **live** and **durable** byte arrays: direct WAL/data stores change only live bytes; `persistRange()` copies its range to the durable shadow; `prepareChangedRange()` queues ranges for `persistChanges()`; and `crash()` restores live bytes from the durable shadow and clears transient state. Backend self-tests prove that unpersisted bytes disappear and persisted bytes survive.
- [x] Re-run the core phase-B crash matrix against the shadow rather than the former single-array no-op backend: commit boundary→crash→recover, apply→crash→recover, N+1 commit→crash (txn N data already durable, txn N+1 recoverable), replay persistence, explicit flush, close, persisted corruption, and fail-before/partial record outcomes. These tests assert surviving bytes and recovered state, not only `dataDurableSeq` or persistence-call counts.
- [x] Give both shadow persistence operations deterministic one-shot outcomes: fail before copying, copy then report failure (indeterminate outcome), and partial/torn copy.
- [x] Characterize immediate crash/reopen after record preparation failure, fail-before-copy, copy-then-fail, and partial-copy outcomes. The copy-then-fail result informed the chosen contract: `commit()` returns `0`, but recovery is allowed to validate and replay the durable record.
- [x] Cover `DualWalRecovery.PERSIST_FAILED` with the shadow backend: replay-persist failure latches the current instance, retained records recover through a new instance, and the successfully replayed after-image survives a second crash.
- [x] Cover failed explicit `flush()` and failed final-data persist in `close()`: either failure latches recovery-required, retains the durable record, rejects same-instance retry, and recovers the after-image through a new instance.
- [x] Cover failed slot-scrub persistence in `close()`: latch recovery-required, stop before scrubbing the second slot, retain conservative slot metadata, and recover the durable data plus surviving idempotent records through a new instance.
- [x] Complete the remaining `DualTxnWal` fault-injection matrix. `applyUpdate()` and recovery now latch on after-image range-preparation failure without issuing or claiming a later boundary; fresh-header fail-before-copy requires reformat, while copy-then-fail may reopen as a valid clean header. Covered by four shadow regressions.
- [x] Define the persistence-failure contract. A boundary-related `commit() == 0` is **unacknowledged**, not definitely aborted. The mounted region is recovery-required and must not accept retry, another transaction, flush, or clean close; reopen plus successful recovery determines whether the valid record is absent or replayed. Idempotent after-images make either recovery result safe, so durable invalidation is unnecessary.
- [x] Make the copy-then-fail test normative for that contract: `commit()` returns `0`, but crash/reopen recovery may validate and replay the complete durable record.
- [x] Enforce commit-originated recovery-required state in `DualTxnWal`. Record prepare/persist and overwrite-guard persistence failure latch the instance; `requiresRecovery()` distinguishes this from definite validation/capacity rejection; subsequent append/commit/apply/persist/recover/close work is rejected without reaching the backend; a new instance must recover.
- [x] Propagate/query recovery-required state through `RegionTransaction` and `PWRegion`. Both expose `requiresRecovery()`; `RegionTransaction.commit()` propagates failed after-image application without clearing the cache, a clean commit cannot hide an existing latch, and `PWRegion.allocChunk()` / `freeChunk()` reject new work once recovery is required. Ordinary slot-capacity rejection remains distinguishable (`false` with `requiresRecovery() == false`). Covered by three `region_transaction:` fault-injection regressions and `pwregion_recovery:alloc_persist_failure_requires_recovery`.
- [x] Define and test how a failed `prepareChangedRange()` is propagated. `DualTxnWal.applyUpdate()` now returns `bool`, latches recovery-required on backend preparation failure, and makes recovery return `PERSIST_FAILED` before `persistChanges()` or `dataDurableSeq` advancement. `RegionTransaction.commit()` now carries that failure to its caller and retains the dirty cache.

Priority 1 — allocator and backend integration:

- [ ] Add abrupt-process tests for the file backend. Run the writer in a child process, terminate with `_exit`/`SIGKILL` at WAL protocol boundaries without `deallocate()`/`close()`, then reopen and verify in a separate process. Trace or intercept `fdatasync`/`msync` to check ordering and inject errors. This establishes independence from graceful shutdown and exercises the real syscall translation, but must be described as process-crash consistency rather than host power-loss proof.
- [ ] Recover complete multi-entry allocator transactions, not only a manually injected one-byte `BlockEntry.used` update. Cover allocation split/exact-fit and free left/right coalescing at the commit→crash→recover and apply→crash→recover windows, then validate all memory-order and free-list links.
- [ ] Cover `freeChunk()` commit-failure propagation, recovery-required behavior after a failed allocation leaves the shared transaction dirty, and invalid inputs (`allocChunk(0)`, oversized requests, null/double/foreign frees).
- [ ] Add structural/property tests over mixed allocate/free/remount sequences so allocator list invariants are checked directly instead of inferred only from whether a later allocation succeeds.
- [ ] Add metadata/Immix coverage (`MetaDataDesc`, line-mark lookup/reset and persistence policy) and instantiate each `X86_64PW*` / `X86_64ImmixPW*` wrapper.
- [ ] Add backend-format/mount tests for `fresh=true` truncation + zero-fill, missing-file attach fallback, stored block-size/num-block mismatch, and the legacy `PWRegionHeader.logChunk == 0` fallback.

Priority 2 — validation and retained comparisons:

- [ ] Add active commit/recovery coverage for widths 2/4/8 and signed `i16`/`i64`, out-of-region and WAL-overlapping entries, and malformed record header/trailer fields—not only checksum corruption.
- [ ] Add baseline tests for retained `SingleTxnWal` (commit/recover/checksum/boundary count and its known silent-overflow behavior).
- [ ] Extend retained `MultiTxnWal` fault tests to initial superblock-write failure, checkpoint data/superblock failure with records retained, oversize/ring-full failure when nothing is checkpointable, and failure to persist the failed-commit scrub.

### 4. CLWB/SFENCE intrinsics
`MmapRegionUtils.flushCacheLine()` and `storeFence()` are no-op placeholders. PMEM durability is not functional until these emit real `CLWB`/`CLFLUSHOPT` and `SFENCE` instructions. Requires either Virgil inline-asm support or a small native stub.

### 5. PMEM emulation and validation

**Assessment complete (2026-07-29):** QEMU ACPI NVDIMM emulation can provide
the Linux `/dev/pmem0` → fsdax → `MAP_SYNC` path needed by the current
regular-file-oriented `PmemMmapBackend`. It is suitable for functional and
software crash-consistency testing, but an ordinary host backing file cannot
establish host power-loss durability. Native Linux `memmap` reservation
provides the same development interface with more invasive host setup.

- [x] Document QEMU as the primary workflow, Linux `memmap` as the alternative, the fsdax regular-file requirement, unsupported alternatives, and the three validation stages (`docs/pmem-emulation.md`).
- [ ] **Stage 1 — DAX/remount integration:** add an opt-in x86-64 Linux test that uses a caller-supplied file on a prepared fsdax mount; require `PmemMmapBackend.create()`/`MAP_SYNC`, format, allocation, close/remount, and WAL recovery to succeed. Keep it out of the default unit and CI suites.
- [ ] **Stage 2 — guest crash/restart:** automate process termination at WAL boundaries and reopen the same file; add guest reset/QEMU restart experiments with the same NVDIMM backing file. Treat the results as software crash-consistency evidence, not physical durability proof.
- [ ] **Stage 3 — real PMEM durability:** after the CLWB/SFENCE work in #4, repeat the integration and controlled crash/power-interruption campaign on physical PMEM. Only this stage can support a host power-loss durability claim.

### 6. Minor cleanups
- [x] `RegionFileIO.openOrCreate` → split into `open` and `create`; `create` zero-initialises bytes (`O_TRUNC` + `ftruncate` zero-fill). Fresh-format intent threaded through `TxnRegionBackend.create(size, prot, fresh)`; `openBacking(path, fresh)` selects create-vs-open (open falls back to create when the file is missing).
- [x] Add log-chunk offset to `PWRegionHeader` — new `logChunk` field (region-relative byte offset) written by `format()` and read by `mount()`, so recovery locates the log via the header instead of assuming block 1. Header grew 72 → 80 bytes; `mount()` keeps a defensive fallback to block 1 when the field reads as `0`. Covered by `TxnPWRegionTest.v3` (`format_header_fields` asserts the field; the remount/recovery tests exercise the header-driven read path).
- [x] `RegionTransaction.clear()` — no longer reallocates the `HashMap`; empties it in place via `cache.remove()` over the `addrs` key set (both `HashMap.remove` and `Vector.clear` retain their backing storage), reusing the map and vector across commits. Covered by the existing `region_transaction:` and `pwregion:` unit tests (commit→clear cycle, remount/recovery).
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
| 5 | `TxnBackend.v3:132` | `Backends.getMmap()` declared but not implemented |
| 6 | `X86_64TxnPWRegion.v3` | `getHeader()` now copies the header into a fresh `Array<byte>` on every call (minor GC pressure) |
| 7 | `TxnPWRegionTest.v3` | PMEM coverage bypasses `PmemMmapBackend.create()` and `MAP_SYNC`; no fsdax/emulated-device integration test exists yet. |
