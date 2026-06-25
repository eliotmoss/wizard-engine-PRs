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
- `RegionFileIO` — `openOrCreate`, `ensureSize`, `fdatasync`, `close`, `unlink`
- `X86_64Backends` factory component

### Write-ahead log (single-transaction, superseded)
- `RegionWal` — in-region single-transaction redo log living in block 1 (`X86_64RegionWal.v3`)
- `LogHeader` layout: `numEntries`, `status` (0=invalid/1=committed), `checksum`
- `LogEntry` layout: `offset` (region-relative), `value`, `width` (1/2/4/8)
- Commit protocol: persist entries → set status=1 → apply to region → fence → clear status
- Recovery: checksum verify → redo entries → fence → clear status durably
- **No longer wired in** — `PWRegion`/`RegionTransaction` now drive `MultiTxnWal` instead. `RegionWal` is currently orphaned (kept for reference; see Next Steps cleanup).

### Multi-transaction WAL (`X86_64MultiTxnWal.v3`)
- Circular redo log living in block 1, with a dual-copy superblock at the head of the chunk and the ring immediately after (`ringBase = logChunkAddr + 2 * WalSuperblock.size`, `ringBytes = blockSize - 2 * WalSuperblock.size`)
- Layouts: `WalSuperblock` (64 B, dual copy), `TxnRecordHeader` (64 B), `TxnCommitTrailer` (48 B); records are `ALIGNMENT`(64 B)-aligned, magic/version/size guarded, with an FNV-style checksum over the whole record
- Generation-based superblock selection: `loadSuperblock` picks the valid copy with the higher `generation`; `writeSuperblock` writes the inactive copy, persists, then swaps
- `logEpoch` fences stale records: `validateRecord` rejects records whose epoch ≠ current epoch; recovery bumps the epoch (and writes a fresh superblock) so replayed records cannot be re-applied on a later mount
- `durableAppliedSeq` is the replay floor: recovery scans the ring, selects the contiguous `txnSeq` prefix starting at `durableAppliedSeq + 1` (`selectContiguousPrefix`), redoes it, persists, then publishes the new `durableAppliedSeq`
- Append path: `append()` buffers `WalPendingEntry`s; `commit()` writes one contiguous record (`appendCommittedRecord`) and returns its `txnSeq` (0 on failure). `reserveRecord` handles wrap-around and triggers a lazy `checkpoint` when the ring is full before retrying
- `checkpoint(targetSeq)` persists pending region changes, publishes `durableAppliedSeq` via the superblock, and reclaims now-durable records from `activeRecords`
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
- `WALCacheTest.v3` — `RegionTransaction` cache read/write, miss fallthrough, commit flow (now over `MultiTxnWal`: durable record written, only cache cleared on commit), clean-txn no-op, aligned-access constraint
- `TxnPWRegionTest.v3` — format/mount, alloc/free, coalescing, exhaustion; block-device remount, WAL recovery, corrupt-WAL rejection (now via `MultiTxnWal` record checksum); `FileMmapRegion`/`PmemMmapRegion` state and lifecycle
- `MultiTxnWalTest.v3` — fresh superblock init, newest-generation superblock selection, corrupt-newer-superblock fallback, single-record recovery, record-checksum rejection, invalid-width rejection, contiguous-prefix-only replay, epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, crash-mid-log recovery

---

## In Progress

- Multi-transaction WAL core paths are now test-covered (`MultiTxnWalTest.v3`): epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, and crash-mid-log recovery. Remaining `MultiTxnWal` work is the `maybeCheckpoint()` policy and commit-failure propagation (Next Steps #1–2).

---

## Next Steps

### 1. Multi-transaction WAL — finish off
The core `MultiTxnWal` is implemented and wired in (see Completed). Remaining work:
- [ ] `maybeCheckpoint()` is a no-op stub (`return true`) — checkpointing currently happens only lazily when the ring fills in `reserveRecord`. Decide on a per-commit / threshold checkpoint policy so `durableAppliedSeq` advances without log pressure.
- [x] Test the untested core paths: **epoch-stale rejection** (bump epoch, confirm prior-epoch records are ignored) and **wrap-around / log-full → checkpoint → reserve** (fill a small ring and verify reclaim + wrap). Done in `MultiTxnWalTest.v3` (`epoch_stale_rejected`, `wraparound_checkpoint_reserve`).
- [x] Multi-record recovery test (current recovery test replays a single record; add a multi-transaction commit + crash-mid-log case). Done in `MultiTxnWalTest.v3` (`recovers_multiple_records`, `crash_mid_log_recovery`).
- [ ] Remove or repurpose the now-orphaned `RegionWal` (`X86_64RegionWal.v3`).

### 2. WAL overflow / commit-failure propagation
`appendCommittedRecord` returns `0` when a record will not fit even after a checkpoint, and `RegionTransaction.commit` returns early leaving the cache dirty (data is retained, not lost, but the failure is not surfaced to the allocator). Propagate an error so callers can split the transaction or trigger a log-full flush. (The legacy `RegionWal.append` silently dropped entries; the multi-txn path no longer loses data but is still silent.)

### 3. CLWB/SFENCE intrinsics
`MmapRegionUtils.flushCacheLine()` and `storeFence()` are no-op placeholders. PMEM durability is not functional until these emit real `CLWB`/`CLFLUSHOPT` and `SFENCE` instructions. Requires either Virgil inline-asm support or a small native stub.

### 4. Minor cleanups
- `RegionFileIO.openOrCreate` → split into `open` and `create`; `create` must zero-initialise bytes
- Add log-chunk offset to `PWRegionHeader` (avoids assuming block 1 is always the log)
- `RegionTransaction.clear()` — avoid allocating a new `HashMap` on every commit
- Link line-mark field in `createChunk()` (`ImmixPWRegion`)
- `ImmixLineSize` should come from the metadata descriptor, not be hardcoded

---

## Open Issues

| # | File | Description |
|---|------|-------------|
| 1 | `X86_64TxnBackend.v3:88-100` | `flushCacheLine`/`storeFence` are stubs — PMEM not truly durable |
| 2 | `X86_64MultiTxnWal.v3` | Commit failure (record won't fit even after checkpoint) returns `0` and is not surfaced to the allocator; `maybeCheckpoint()` is a no-op stub |
| 3 | `X86_64TxnBackend.v3:58` | Page size hardcoded as 4096 |
| 4 | `X86_64TxnPWRegion.v3:31` | `PWRegionHeader` missing log-chunk offset field — `mount` still assumes block 1 is the log |
| 5 | `X86_64TxnPWRegion.v3:771` | Line-mark field not linked in `createChunk()` |
| 6 | `X86_64TxnPWRegion.v3:977` | `ImmixLineSize` hardcoded (should use metadata descriptor) |
| 7 | `TxnBackend.v3:106` | `Backends.getMmap()` declared but not implemented |
| 8 | `X86_64TxnPWRegion.v3` | `getHeader()` now copies the header into a fresh `Array<byte>` on every call (minor GC pressure) |
| 9 | `X86_64RegionWal.v3` | `RegionWal` is orphaned — no longer wired in after the `MultiTxnWal` switch |
