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
│  Write-ahead log    (MultiTxnWal)            │  circular redo log + recovery
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
    create(size: u64, prot: BackendProt) -> BackendRegion
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
- `ensureSize(fd, size)` — `ftruncate` + `fdatasync` to guarantee file extent
- `fdatasync(fd)` — data-only sync (no metadata)
- `close(fd)`, `unlink(path)`

Fresh-format intent reaches the backend through `TxnRegionBackend.create(size, prot, fresh)`: `PWRegion` passes its `forceFormat` flag down, so a fresh format zero-initialises the backing store while a mount attaches to the existing one.

---

## Layer 2 — Write-Ahead Log

**File:** `src/engine/x86-64/X86_64MultiTxnWal.v3`

`MultiTxnWal` is the active WAL: a **circular redo log** supporting multiple outstanding transactions with generation-based crash recovery. It occupies block 1 of a `PWRegion`. `append()` buffers one memory write; `commit()` writes a single contiguous, checksummed transaction record and returns its sequence number; `checkpoint()` publishes how far the region data is durable and reclaims log space; `recover()` replays the committed tail on remount.

> The earlier single-transaction `SingleTxnWal` (`src/engine/x86-64/X86_64SingleTxnWal.v3`, `LogHeader` + `LogEntry[]`, `status` commit flag) is **superseded and no longer wired in**. It is retained as a reference implementation for comparison against `MultiTxnWal` — see `docs/wal-comparison.md`.

### On-disk layout

Block 1 begins with two fixed superblock copies, followed by the record ring:

```
Block 1  (256 KB)
  ┌─────────────────────────────┐  offset 0
  │  WalSuperblock  copy 0 (64B) │
  ├─────────────────────────────┤  offset 64
  │  WalSuperblock  copy 1 (64B) │
  ├─────────────────────────────┤  ringBase = logChunkAddr + 2 * 64
  │  record ring  (ringBytes =  │
  │   blockSize - 2 * 64)       │
  │   TxnRecord[]  (variable,    │
  │   64-byte aligned, may wrap) │
  └─────────────────────────────┘
```

**`WalSuperblock` (64 bytes, two copies)**

| Field | Type | Meaning |
|---|---|---|
| `magic` | u64 | `"WALSUPER"` signature |
| `version` | u32 | format version (1) |
| `superblockSize` | u64 | size of this layout |
| `generation` | u64 | monotonic copy number; recovery picks the higher valid copy |
| `logEpoch` | u64 | current WAL incarnation; records from other epochs are stale |
| `durableAppliedSeq` | u64 | highest txn whose region updates are known durable |
| `reserved` | u64 | must be zero in v1 |
| `checksum` | u64 | checksum over the superblock, excluding this field |

**`TxnRecord`** = `TxnRecordHeader` (64 B) + `LogEntry[]` + `TxnCommitTrailer` (48 B), padded up to a 64-byte (`ALIGNMENT`) boundary. The header (`"WALTXNHD"`) and trailer (`"WALTXNCM"`) carry redundant `recordLen` / `entryCount` / `logEpoch` / `txnSeq`, and the trailer holds an FNV-style `checksum` over the whole record (excluding the checksum field). `LogEntry` is unchanged: `offset` (region-relative), `value`, `width` (1/2/4/8).

### Commit protocol

```
append(offset, value, width)   -- validated, buffered into pendingEntries

commit() -> txnSeq             -- appendCommittedRecord(pendingEntries); clears pending
  1. reserveRecord(len)        -- find a free, contiguous, aligned slot in the ring;
                                  wrap to offset 0 if needed; if full, lazily checkpoint
                                  the applied tail and retry
  2. zero slot; write header, entries, trailer; compute + store record checksum
  3. backendRegion.persistRange(record_range)   -- COMMIT POINT: record durable
  4. push WalActiveRecord; nextTxnSeq++; return txnSeq   (0 on failure)
```

After the WAL record is durable, `RegionTransaction` applies the cached writes to region memory and calls `noteApplied(txnSeq)` (advances `appliedSeqVolatile` in order).

```
checkpoint(targetSeq) -> bool  -- targetSeq must be ≤ appliedSeqVolatile
  1. backendRegion.persistChanges()             -- applied region data durable
  2. writeSuperblock(targetSeq, logEpoch)        -- inactive copy, persist, bump generation, swap
  3. durableAppliedSeq = targetSeq; reclaim now-durable records from activeRecords
```

`fenceAppliedUpdates()` is `checkpoint(appliedSeqVolatile)`.

### Recovery protocol

```
recover() -> bool
  load winning superblock (higher generation among the two valid copies)
  scanCommittedRecords()                 -- stride the ring at 64B, validateRecord each
       validateRecord rejects on: bad magic/version/size, recordLen misalignment,
       trailer mismatch, epoch ≠ current logEpoch, txnSeq ≤ durableAppliedSeq,
       checksum mismatch, or any invalid entry field
  selectContiguousPrefix()               -- contiguous txnSeq run from durableAppliedSeq+1
  if no contiguous prefix:
       if stray valid records exist, bump epoch + rewrite superblock to abandon them
       return false
  for each selected record: redoRecord() ; appliedSeqVolatile = txnSeq
  backendRegion.persistChanges()         -- replayed data durable
  writeSuperblock(maxSeq, logEpoch + 1)  -- publish + bump epoch so replay can't recur
  return true
```

The epoch bump is the key anti-double-replay guard: once recovery republishes at `logEpoch + 1`, every record written under the old epoch fails `validateRecord` on any future mount.

> **TODO:** When a record will not fit even after a checkpoint, `appendCommittedRecord` returns `0` and `RegionTransaction.commit` returns early with the cache still dirty — data is retained but the failure is not surfaced to the caller. `maybeCheckpoint()` is also still a no-op stub, so checkpoints currently happen only lazily under ring pressure.

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
  if !isDirty() → return
  appendToWal()             // iterate addrs → wal.append(offset, value, width)
  txnSeq = wal.commit()     // write one durable WAL record; 0 == failure
  if txnSeq == 0 → return   // leave cache dirty for retry (see Layer 2 TODO)
  applyToRegion()           // write cache values into region bytes
  wal.noteApplied(txnSeq)   // advance appliedSeqVolatile in order
  wal.maybeCheckpoint()     // policy hook (currently a no-op stub)
  clear()                   // reset cache
```

Unlike the old single-transaction flow, `commit()` no longer fences and clears the log per call. The WAL record stays live until a `checkpoint()` (lazy, on ring-full) proves the region data durable and reclaims its space; only the DRAM cache is cleared here.

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

`PWRegion` implements a buddy-style block allocator over the persistent region. All metadata mutations go through `RegionTransaction` so they are WAL-protected.

### Region layout

```
Block 0      PWRegionHeader
Block 1      WAL log chunk
Block 2..N   User data  (allocated / free)
Block N..M   Metadata   (block table, sentinels, descriptors)
```

### `PWRegionHeader` (72 bytes, stored at offset 0)

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
| `blockSize` | u64 | bytes per block (default 256 KB) |

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
  write PWRegionHeader
  create SMALL_FREE and LARGE_FREE sentinels
  allocate block table in metadata area
  link all user blocks in memory order
  insert all user blocks onto LARGE_FREE list
  backendRegion.persistRange(0, full_size)   -- single durable write to initialise

mount(blockSize)
  verify blockSize and numBlocks match header
  restore block table handle
  locate log block (block 1)
  init MultiTxnWal + RegionTransaction
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
      applyToRegion()         -- write values into region bytes
      wal.noteApplied(txnSeq)
      wal.maybeCheckpoint()   -- no-op stub; checkpoint happens lazily on ring-full
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
      load winning superblock (higher generation of the two valid copies)
      scan ring; select contiguous txnSeq prefix from durableAppliedSeq+1
      if a committed prefix exists:
        redo each record into region bytes
        persistChanges()                       -- replayed data durable
        writeSuperblock(maxSeq, logEpoch + 1)   -- publish + bump epoch
        return true
      else:
        if stray valid records exist, bump epoch to abandon them
        return false
```

---

## Testing

| Test file | Location | What it covers |
|---|---|---|
| `TxnPWRegionTest.v3` | `test/unittest/x86-64-linux/` | format/mount, alloc/free, coalescing, WAL recovery, corrupt-WAL detection (via `MultiTxnWal` record checksum), file-backed persistence |
| `WALCacheTest.v3` | `test/unittest/x86-64-linux/` | cache read/write, cache-miss fallthrough, commit flow over `MultiTxnWal`, clean-txn no-op |
| `MultiTxnWalTest.v3` | `test/unittest/x86-64-linux/` | fresh superblock init, newest-generation selection, corrupt-newer-superblock fallback, single-record recovery, record-checksum rejection, invalid-width rejection, contiguous-prefix-only replay, epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, crash-mid-log recovery |

**Coverage gaps:** the `MultiTxnWal` core paths — epoch-stale rejection, wrap-around / log-full→checkpoint→reserve, multi-record recovery, and crash-mid-log recovery — are now tested. The remaining untested behaviour is checkpoint-failure / commit-failure propagation, which is still a known stub (see Open items #2).

Run with:

```bash
test/unit.sh
```

---

## Open items

| # | Location | Description |
|---|---|---|
| 1 | `X86_64TxnBackend.v3:88-93` | `flushCacheLine()` and `storeFence()` need Virgil compiler intrinsics for `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE`. Until then PMEM persistence is not truly durable. |
| 2 | `X86_64MultiTxnWal.v3` | When a record won't fit even after a checkpoint, `commit` returns `0` and `RegionTransaction.commit` returns early with the cache still dirty — failure is not surfaced to the caller. `maybeCheckpoint()` is a no-op stub (checkpoints only fire lazily on ring-full). |
| 3 | `TxnBackend.v3:36` | Consider renaming `TxnRegionBackend` → `RegionManager` to better reflect its role as a factory. |
| 4 | `X86_64TxnBackend.v3:177` | `RegionFileIO.openOrCreate` should be split into `open` and `create`; `create` must initialise bytes to zero. |
| 5 | `X86_64TxnBackend.v3:58` | Page size is hardcoded as `4096`; should be a named constant or queried via `sysconf(_SC_PAGESIZE)`. |
| 6 | `X86_64TxnPWRegion.v3:31` | `PWRegionHeader` should store a pointer/offset to the log chunk to simplify recovery without requiring block 1 to always be the log. |
| 7 | `X86_64TxnPWRegion.v3:771` | Line-mark field is not yet linked during `createChunk()`. |
| 8 | `X86_64TxnPWRegion.v3:977` | `ImmixLineSize` is hardcoded as 256 bytes; should come from the metadata descriptor. |
| 9 | `X86_64TxnPWRegion.v3` | `getHeader()` copies the header into a fresh `Array<byte>` on every call (minor GC pressure). |
