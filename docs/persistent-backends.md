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
│  Write-ahead log    (RegionWal)              │  redo log + recovery
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

- `openOrCreate(path)` — opens or creates a file (`O_RDWR | O_CREAT`, mode `0644`)
- `ensureSize(fd, size)` — `ftruncate` + `fdatasync` to guarantee file extent
- `fdatasync(fd)` — data-only sync (no metadata)
- `close(fd)`, `unlink(path)`

> **TODO:** Opening an existing file vs. creating a new one should be two separate methods. A newly created file needs to be explicitly initialised with zero bytes before the first mount.

---

## Layer 2 — Write-Ahead Log

**File:** `src/engine/x86-64/X86_64RegionWal.v3`

`RegionWal` manages a fixed-size redo log that occupies block 1 of a `PWRegion`. Each call to `append()` records one memory write; `commit()` makes the entire batch durable; `clear()` resets the log; `recover()` replays a committed log on remount.

### On-disk layout

```
Block 1  (256 KB)
  ┌─────────────────────────────┐  offset 0
  │  LogHeader  (32 bytes)      │
  │    numEntries : u32         │  +0
  │    status     : u8          │  +4   (0 = invalid, 1 = committed)
  │    checksum   : u64         │  +8
  └─────────────────────────────┘
  ┌─────────────────────────────┐  offset 32
  │  LogEntry[]                 │  one per buffered write
  │    offset : u64             │  +0   (relative to region start)
  │    value  : u64             │  +8
  │    width  : u8              │  +16  (1, 2, 4, or 8)
  └─────────────────────────────┘
```

### Commit protocol

```
append(offset, value, width)   -- called per write while txn is open
  store entry at currentEntryIndex; increment index

commit()
  1. header.numEntries = currentEntryIndex
  2. header.checksum  = computed checksum over entries
  3. backendRegion.persistRange(entries_range)   -- entries durable
  4. header.status = 1
  5. backendRegion.persistRange(header_range)    -- header durable (commit point)

clear()
  1. zero header fields
  2. backendRegion.persistRange(header_range)    -- invalidate log durably
  3. currentEntryIndex = 0
```

### Recovery protocol

```
recover() -> bool
  if header.status != 1  → return false  (no committed txn)
  if checksum mismatch:
    clear status durably
    return false
  for each entry:
    applyUpdate(offset, value, width)    -- write into region bytes
  fenceAppliedUpdates()                  -- backendRegion.persistChanges()
  clear status durably
  return true
```

> **TODO:** If `maxEntries` is exceeded during `append()`, entries are silently dropped. This should return an error so callers can split the transaction.

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
  wal.commit()              // make log durable
  applyToRegion()           // write cache values into region bytes
  wal.fenceAppliedUpdates() // fence applied writes
  wal.clear()               // invalidate log
  clear()                   // reset cache
```

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
  init RegionWal + RegionTransaction
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
      wal.commit()            -- make entries + header durable
      applyToRegion()         -- write values into region bytes
      wal.fenceAppliedUpdates()
      wal.clear()
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
      if status == 1 and checksum OK:
        apply all log entries to region bytes
        fence
        clear log header durably
        return true
      else:
        clear log header durably if status was set
        return false
```

---

## Testing

| Test file | Location | What it covers |
|---|---|---|
| `TxnPWRegionTest.v3` | `test/unittest/x86-64-linux/` | format/mount, alloc/free, coalescing, WAL recovery, corrupt-WAL detection, file-backed persistence |
| `WALCacheTest.v3` | `test/unittest/x86-64-linux/` | cache read/write, cache-miss fallthrough, commit flow, clean-txn no-op |

Run with:

```bash
test/unit.sh
```

---

## Open items

| # | Location | Description |
|---|---|---|
| 1 | `X86_64TxnBackend.v3:88-93` | `flushCacheLine()` and `storeFence()` need Virgil compiler intrinsics for `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE`. Until then PMEM persistence is not truly durable. |
| 2 | `X86_64RegionWal.v3:26-29` | WAL silently drops entries when the log chunk is full. Should return an error so the caller can split the transaction. |
| 3 | `TxnBackend.v3:36` | Consider renaming `TxnRegionBackend` → `RegionManager` to better reflect its role as a factory. |
| 4 | `X86_64TxnBackend.v3:177` | `RegionFileIO.openOrCreate` should be split into `open` and `create`; `create` must initialise bytes to zero. |
| 5 | `X86_64TxnBackend.v3:58` | Page size is hardcoded as `4096`; should be a named constant or queried via `sysconf(_SC_PAGESIZE)`. |
| 6 | `X86_64TxnPWRegion.v3:31` | `PWRegionHeader` should store a pointer/offset to the log chunk to simplify recovery without requiring block 1 to always be the log. |
| 7 | `X86_64TxnPWRegion.v3:771` | Line-mark field is not yet linked during `createChunk()`. |
| 8 | `X86_64TxnPWRegion.v3:977` | `ImmixLineSize` is hardcoded as 256 bytes; should come from the metadata descriptor. |
