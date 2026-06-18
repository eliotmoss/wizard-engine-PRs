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

### Write-ahead log
- `RegionWal` — in-region single-transaction redo log living in block 1 (`X86_64RegionWal.v3`)
- `LogHeader` layout: `numEntries`, `status` (0=invalid/1=committed), `checksum`
- `LogEntry` layout: `offset` (region-relative), `value`, `width` (1/2/4/8)
- Commit protocol: persist entries → set status=1 → apply to region → fence → clear status
- Recovery: checksum verify → redo entries → fence → clear status durably

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
- `WALCacheTest.v3` — `RegionTransaction` cache read/write, miss fallthrough, commit flow, clean-txn no-op, aligned-access constraint
- `TxnPWRegionTest.v3` — format/mount, alloc/free, coalescing, exhaustion; block-device remount, WAL recovery, corrupt-WAL rejection; `FileMmapRegion`/`PmemMmapRegion` state and lifecycle

---

## In Progress

- Multi-transaction WAL (`X86_64MultiTxnWal.v3`): `WalSuperblock` and `TxnRecordHeader` layouts defined; class body is stubs

---

## Next Steps

### 1. Multi-transaction WAL (`X86_64MultiTxnWal.v3`) — priority
Replace the single-active-transaction `RegionWal` with a circular redo log supporting multiple outstanding transactions and generation-based crash recovery.

Key design points already captured in the layouts:
- Dual-copy superblock (`generation` field) — recovery picks the copy with the higher valid generation
- `logEpoch` — stale records from prior epochs are ignored
- `durableAppliedSeq` — highest txn whose region updates are known durable; recovery replays from here forward

Work items:
- [ ] Circular log append with wrap-around
- [ ] Superblock dual-copy write (write to inactive copy, fence, increment generation)
- [ ] Recovery: read both superblock copies, select winner, scan log from `durableAppliedSeq`, redo uncommitted-but-flushed entries
- [ ] Tests: multi-transaction commit, recovery after crash mid-log, epoch-stale rejection, superblock corruption

### 2. WAL overflow handling
`RegionWal.append` silently drops entries when block 1 is full. Needs to return an error so callers can split the transaction (or trigger a log-full flush).

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
| 2 | `X86_64RegionWal.v3:26-29` | WAL silently drops entries on overflow |
| 3 | `X86_64TxnBackend.v3:58` | Page size hardcoded as 4096 |
| 4 | `X86_64TxnPWRegion.v3:31` | `PWRegionHeader` missing log-chunk offset field |
| 5 | `X86_64TxnPWRegion.v3:771` | Line-mark field not linked in `createChunk()` |
| 6 | `X86_64TxnPWRegion.v3:977` | `ImmixLineSize` hardcoded (should use metadata descriptor) |
| 7 | `TxnBackend.v3:106` | `Backends.getMmap()` declared but not implemented |
