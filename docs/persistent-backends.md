# Persistent Backends: Design and Implementation

This document covers the design of the persistent/transactional memory backend system on the `pwregions` branch. The system enables Wizard's garbage collector to use durable storage (PMEM/DAX or file-backed mmap) with crash-consistent allocation via a write-ahead log (WAL).

---

## Overview

The system is organised into four layers that sit between raw storage media and the allocator:

```
┌─────────────────────────────────────────────┐
│  Allocator  (PWRegion / ImmixPWRegion)       │  block allocation + free list management
├─────────────────────────────────────────────┤
│  Transaction cache  (RegionTransaction)      │  write-behind DRAM buffer
├─────────────────────────────────────────────┤
│  Write-ahead log    (DualTxnWal)             │  two-slot redo log + recovery
├─────────────────────────────────────────────┤
│  Backend region     (BackendRegion)          │  storage abstraction: memory / file / PMEM
└─────────────────────────────────────────────┘
```

All interfaces live in `src/engine/TxnBackend.v3`; x86-64 implementations live under `src/engine/x86-64/`.

---

## Layer 1 — Storage Abstraction

**Files:** `src/engine/TxnBackend.v3`, `src/engine/x86-64/X86_64TxnBackend.v3`

### Interfaces

```
BackendRegion (abstract class)
    range: Range<byte>                       // the mapped bytes
    destroy()                                // release storage
    prepareChangedRange(offset, size)        // mark region dirty (write-behind)
    persistChanges()                         // flush all pending dirty ranges
    persistRange(offset, size)               // synchronously flush a specific range (used by WAL)

TxnRegionBackend (abstract class)           // factory for BackendRegion instances
    create(size: u64, prot: BackendProt, fresh: bool) -> BackendRegion
    isPersistent() -> bool
    name() -> string
```

`BackendProt` mirrors Linux `PROT_*` flags: `NONE(0) READ(1) WRITE(2) EXEC(4)`.

### Implementations

| Class | Storage | `prepareChangedRange` | `persistChanges` | `persistRange` |
|---|---|---|---|---|
| `VolatileRegion` | `Array<byte>` (GC'd) | no-op | no-op | no-op |
| `FileMmapRegion` | file + `mmap(MAP_SHARED)` | sets `hasDirtyChanges` | `fdatasync()` if dirty | page-aligned `msync()` |
| `PmemMmapRegion` | file + `mmap(MAP_SHARED_VALIDATE\|MAP_SYNC)` | cache-line flush; sets `hasPendingWriteback` | store fence | flush range + store fence |

`FileMmapRegion` and `PmemMmapRegion` both extend `FdMmapRegion`, which holds the `Mapping` and `fd` and handles `destroy()`.

```
FdMmapRegion  (common mmap logic: bounds check, unmap, close fd)
  ├── FileMmapRegion   (disk durability via msync/fdatasync)
  └── PmemMmapRegion   (PMEM durability via clflush + sfence)
```

**Note:** `MmapRegionUtils.flushCacheLine()` and `storeFence()` are currently stubs — they require Virgil compiler intrinsics for `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE` that are not yet emitted. See [Open items](#open-items).

### Backend factories

| Factory | Creates |
|---|---|
| `VolatileBackend` (singleton via `Backends.getVolatile()`) | `VolatileRegion` |
| `FileMmapBackend` | `FileMmapRegion` |
| `PmemMmapBackend` | `PmemMmapRegion` |

`X86_64Backends` is the platform-level component that dispatches among these three.

### File I/O (`RegionFileIO`)

`RegionFileIO` wraps the raw syscalls needed by the mmap backends:

- `open(path)` — opens an existing file (`O_RDWR`, mode `0644`); returns `-errno` if it does not exist
- `create(path)` — creates/re-creates a fresh file (`O_RDWR | O_CREAT | O_TRUNC`, mode `0644`); `O_TRUNC` plus the `ensureSize` `ftruncate` extension leaves the region zero-initialised
- `openBacking(path, fresh)` — selects `create` for a fresh format, otherwise `open` (falling back to `create` when the file is missing)
- `ensureSize(fd, size)` — `ftruncate` + `fsync` to guarantee file extent
- `fdatasync(fd)` — data-only sync (no metadata)
- `close(fd)`, `unlink(path)`

Fresh-format intent reaches the backend through `TxnRegionBackend.create(size, prot, fresh)`: `PWRegion` passes its `forceFormat` flag down, so a fresh format zero-initialises the backing store while a mount attaches to the existing one.

---

## Layer 2 — Write-Ahead Log

**Active file:** `src/engine/x86-64/X86_64DualTxnWal.v3`

**Comparison files:** `src/engine/x86-64/X86_64MultiTxnWal.v3`, `src/engine/x86-64/X86_64SingleTxnWal.v3`

`DualTxnWal` is the WAL wired into `PWRegion` and `RegionTransaction`. It keeps at most two committed transactions in fixed slots selected by `txnSeq % 2`. Redo entries are absolute, idempotent after-images, so recovery validates both slots and replays them in ascending sequence order without a superblock, epoch, replay floor, ring, or checkpoint policy.

`MultiTxnWal` remains compiled and has dedicated comparison tests, but it is no longer on the allocator commit path. `SingleTxnWal` remains a reference implementation and currently has no dedicated tests. See `docs/wal-comparison.md` for the design comparison and `docs/checkpoint-policy.md` for the retained ring-WAL policy record.

### Active on-region layout

The log chunk begins with a minimal header followed by two equal, 64-byte-aligned slots:

```
Log chunk
  ┌──────────────────────────────┐  offset 0
  │ DualWalHeader           64 B │
  ├──────────────────────────────┤
  │ slot 0: TxnRecord            │  even txnSeq
  ├──────────────────────────────┤
  │ slot 1: TxnRecord            │  odd txnSeq
  └──────────────────────────────┘

slotBytes = alignDown((blockSize - 64) / 2, 64)
```

Each slot contains `TxnRecordHeader` (64 B) + `LogEntry[]` + `TxnCommitTrailer` (48 B), padded to 64-byte alignment. The dual WAL uses distinct header/record/trailer magics so stale `MultiTxnWal` bytes cannot validate. The record header and trailer redundantly encode length, entry count and transaction sequence; `logEpoch` is reserved and must be zero. The trailer checksum covers the complete aligned record except its own checksum field.

### Phase-B commit protocol

```
append(offset, value, width) -> bool
  validate width, region bounds and non-overlap with the WAL chunk
  invalid input poisons the whole pending transaction

commit() -> txnSeq
  1. select slot = nextTxnSeq % 2
  2. if that slot protects data not yet known durable:
       persistAppliedData(); fail if the slot is still unreclaimable
  3. write the complete checksummed record into the slot
  4. prepareChangedRange(record)
  5. persistChanges()                         -- COMMIT POINT
       persists the new record together with the previous transaction's
       already-applied after-images
  6. dataDurableSeq = previous lastCommittedSeq
  7. publish slotSeq/lastCommittedSeq; advance nextTxnSeq
```

The caller then applies the committing transaction's after-images. Their ranges remain pending and ride the next transaction's commit boundary, `RegionTransaction.flush()`, or `DualTxnWal.close()`. Thus steady state uses one persistence boundary per commit. An empty transaction writes a real zero-entry record, so every successful commit has a nonzero sequence and `0` is failure-only.

The phase-B contract requires the caller to apply transaction N before committing N+1. `RegionTransaction.commit()` provides that ordering.

### Recovery and close

```
recover() -> DualWalRecovery
  validate both slots
  if neither is valid: return CLEAN
  replay valid slots in ascending txnSeq order
  persistChanges()
  if persistence fails: return PERSIST_FAILED and retain both records
  dataDurableSeq = maxSeq; nextTxnSeq = maxSeq + 1
  return REPLAYED
```

`CORRUPT` reports an invalid dual-WAL header. Recovery leaves valid records in place; replaying an already-durable after-image again is harmless.

`close()` is the clean-unmount boundary: it persists the last applied transaction and scrubs only slots whose data is known durable. Unrecovered records and records protected by a failed final persist remain available for the next mount.

### Failure-semantics audit note

The 2026-07-29 test audit found an unverified boundary case: after phase-B `prepareChangedRange(record)` or `persistChanges()` fails, the current code returns `0` but leaves a complete checksummed record in the slot. Existing tests retry before reopening; they do not reopen immediately after the failure. The required outcome—an unacknowledged failed commit must not later replay—and the necessary durable invalidation/publication protocol are tracked in `docs/ROADMAP.md` Next Steps #3.

---

## Layer 3 — Transaction Cache

**File:** `src/engine/x86-64/X86_64TxnPWRegion.v3` (class `RegionTransaction`)

`RegionTransaction` buffers writes in a DRAM `HashMap<u64, CachedUpdate>` before committing them to the WAL and then to the region. Reads check the cache first and fall through to the live region bytes on a miss.

```
CachedUpdate(value: u64, size: u8)   #unboxed
```

### Write path

```
writeU8 / writeI16 / writeU64 / writeI64(addr, val)
  cache[addr] = CachedUpdate(val, width)
  addrs.put(addr)           // preserves write order
```

### Commit path

```
commit()
  if !isDirty() → return true
  appendToWal()             // iterate addrs → wal.append(offset, value, width)
  txnSeq = wal.commit()     // write one durable WAL record; 0 == failure
  if txnSeq == 0 → return false  // leave cache dirty for retry/inspection
  applyToRegion()           // write cache values and prepare their ranges
  clear()                   // reuse the cache/map storage
  return true
```

The committing transaction's applied after-images are recoverable from its durable slot, but their direct data persistence is deferred. The next commit's single phase-B boundary persists those pending ranges together with the next record. `flush()` calls `wal.persistAppliedData()` when an idle/unmount boundary is required, and `PWRegion.deallocate()` reaches the same operation through `wal.close()`.

### Read path (cache miss)

```
readU8(addr)
  if cache.has(addr) → return cached value
  // fall through to live region memory
  return Pointer.load<u8>(regionStart + offset)
```

**Constraint:** Only aligned accesses are cached. There is no support for sub-word reads that span a cached boundary.

---

## Layer 4 — Block Allocator

**File:** `src/engine/x86-64/X86_64TxnPWRegion.v3` (class `PWRegion`)

`PWRegion` implements a first-fit block allocator over the persistent region. All metadata mutations go through `RegionTransaction` so they are WAL-protected.

### Region layout

```
Block 0      PWRegionHeader
Block 1      WAL log chunk
Block 2..N   User data  (allocated / free)
Block N..M   Metadata   (block table, sentinels, descriptors)
```

### `PWRegionHeader` (80 bytes, stored at offset 0)

| Field | Type | Meaning |
|---|---|---|
| `blockTable` | u64 | region-relative offset to block table |
| `sentinels` | u64 | offset to sentinel block entries |
| `numBlocks` | u64 | total blocks in region |
| `numBytes` | u64 | total bytes in region |
| `numDescs` | u64 | number of metadata descriptors |
| `metaData` | u64 | offset to metadata area |
| `metaDataDescs` | u64 | offset to descriptor table |
| `magic` | u64 | `0x50_57_41_53_4D` ("PWASM") |
| `blockSize` | u64 | bytes per block (wrapper default 512 KB) |
| `logChunk` | u64 | region-relative offset of the WAL log chunk (block 1 in the current layout) |

### `BlockEntry` (40 bytes)

Each block has one entry in the block table:

| Field | Type | Meaning |
|---|---|---|
| `listNum` | i16 | free-list index (see `ListKind`) |
| `used` | u1 | 1 = allocated |
| `prev` | i64 | previous block in address order |
| `next` | i64 | next block in address order |
| `listPrev` | i64 | previous on same free list |
| `listNext` | i64 | next on same free list |

`ListKind` values: `METADATA(-1)`, `NONE(-2)`, `USED(-3)`, `SMALL_FREE(0)`, `LARGE_FREE(1)`.

### Allocation strategy

- Single-block requests try `SMALL_FREE` first, then fall back to `LARGE_FREE`.
- Multi-block requests search `LARGE_FREE` for a first fit.
- If the found block is larger than needed, it is split; the remainder is re-inserted into the appropriate list.
- Every allocation or free calls `performCommit()` to commit the updated block table entries atomically via the WAL.

### Format vs. mount

```
PWRegion.__new(backend, numBlocks, metaDataDescs, blockSize, forceFormat)
  if forceFormat or no magic → format(blockSize)
  else                       → mount(blockSize)

format(blockSize)
  write PWRegionHeader (incl. logChunk offset)
  create SMALL_FREE and LARGE_FREE sentinels
  allocate block table in metadata area
  link all user blocks in memory order
  insert all user blocks onto LARGE_FREE list
  backendRegion.persistRange(0, full_size)   -- single durable write to initialise

mount(blockSize)
  verify blockSize and numBlocks match header
  restore block table handle
  locate log chunk via header.logChunk       -- fall back to block 1 if unset (0)
  init DualTxnWal + RegionTransaction
  txn.recover()                              -- replay committed WAL if present
```

### Handle types (unboxed)

These are zero-allocation wrappers around raw memory addresses:

- `BlockTableHandle` — indexable view of the block table
- `BlockEntryHandle` — single block entry; `.getCached(txn)` / `.setCached(txn)` for transactional access
- `ChunkHandle` — allocated chunk with `offset` and `limit`
- `LineMarkTableHandle` — line-mark bitmap for Immix GC

---

## Immix GC extension

**File:** `src/engine/x86-64/X86_64TxnPWRegion.v3` (class `ImmixPWRegion`)

`ImmixPWRegion extends PWRegion` adds a line-mark metadata table alongside each allocated chunk. Line size is currently hardcoded at 256 bytes.

- `resetAllLineMarks()` — clears all line marks at the start of a GC cycle.

> **TODO:** Line size should come from the metadata descriptor rather than being hardcoded.
> **TODO:** The line-mark field is not yet linked to the chunk during `createChunk()`.

---

## Platform wrappers

**File:** `src/engine/x86-64/X86_64PWRegion.v3`

Convenience subclasses that wire a backend to `PWRegion` / `ImmixPWRegion`:

| Class | Backend |
|---|---|
| `X86_64PWMemRegion` | `VolatileBackend` |
| `X86_64PWNVRegion` | `PmemMmapBackend` (PMEM/DAX path) |
| `X86_64PWBlockDeviceRegion` | `FileMmapBackend` |
| `X86_64ImmixPWMemRegion` | `VolatileBackend` + Immix metadata |
| `X86_64ImmixPWNVRegion` | `PmemMmapBackend` + Immix metadata |

---

## Data flow summary

### Write (allocation or metadata update)

```
PWRegion.allocChunk(n)
  → BlockEntryHandle.setUsedCached(txn, 1)
    → RegionTransaction.writeU8(addr, val)
      cache[addr] = CachedUpdate(val, 1)
  → performCommit() → txn.commit()
      appendToWal()           -- wal.append per cache entry
      txnSeq = wal.commit()   -- write one durable, checksummed WAL record
                               -- same boundary persists the previous txn's data
      applyToRegion()         -- write values + prepare ranges for next boundary
      cache.clear()
```

### Read (during an open transaction)

```
BlockEntryHandle.getUsedCached(txn)
  → RegionTransaction.readU8(addr)
      if cache.has(addr) → return cached value
      else → Pointer.load<u8>(regionStart + offset)
```

### Crash recovery on remount

```
PWRegion.mount()
  → txn.recover() → wal.recover()
      validate the WAL header; if invalid → return CORRUPT
      validate the two fixed slots
      if neither slot is valid → return CLEAN
      replay valid records in ascending txnSeq order
      persistChanges()                 -- replayed data durable
      return REPLAYED / PERSIST_FAILED
```

---

## Testing

Audited 2026-07-29: the implementation-specific x86-64 Linux suite contains 87 registered tests, all passing in the existing x86-64 Linux test binary. None are expected failures.

| Test file | Tests | What it covers |
|---|---:|---|
| `DualTxnWalTest.v3` | 19 | active two-slot WAL, phase-B boundary count, recovery, overwrite guard, failure retry, flush and close |
| `WALCacheTest.v3` | 13 | transaction cache and active `DualTxnWal` integration, commit/flush propagation and oversize failure |
| `TxnPWRegionTest.v3` | 33 | allocator, overflow propagation, mmap/PMEM backend state, file-backed remount and `DualTxnWal` recovery |
| `MultiTxnWalTest.v3` | 22 | retained ring WAL: superblocks, recovery, epochs, wrap/checkpoint, validation and hardening regressions |

`SingleTxnWal`, Immix metadata behavior, and the platform wrapper classes have no dedicated tests. The highest-priority missing regression is reopen/crash immediately after an active phase-B commit boundary fails, before retry. Full gaps and priorities are maintained in `docs/ROADMAP.md` Next Steps #3.

Run with:

```bash
test/unit.sh
```

---

## Open items

| # | Location | Description |
|---|---|---|
| 1 | `X86_64TxnBackend.v3:88-93` | `flushCacheLine()` and `storeFence()` need Virgil compiler intrinsics for `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE`. Until then PMEM persistence is not truly durable. |
| 2 | `X86_64DualTxnWal.v3:223-224` | A failed phase-B record boundary leaves complete checksummed slot bytes; reopen-before-retry semantics need a regression and may require durable invalidation/publication. |
| 3 | `X86_64DualTxnWal.v3:144-148` | `applyUpdate()` ignores failure from `prepareChangedRange()`, weakening the `dataDurableSeq` claim. |
| 4 | `TxnBackend.v3:55-56` | Consider renaming `TxnRegionBackend` → `RegionManager` to better reflect its role as a factory. |
| 5 | `X86_64TxnBackend.v3:58` | Page size is hardcoded as `4096`; should be a named constant or queried via `sysconf(_SC_PAGESIZE)`. |
| 6 | `X86_64TxnPWRegion.v3` | Line-mark field is not yet linked during `createChunk()`. |
| 7 | `X86_64TxnPWRegion.v3` | `ImmixLineSize` is hardcoded as 256 bytes; should come from the metadata descriptor. |
| 8 | `X86_64TxnPWRegion.v3` | `getHeader()` copies the header into a fresh `Array<byte>` on every call (minor GC pressure). |
