# Persistent Backends: Design and Implementation

This document covers the design of the persistent/transactional memory backend system on the `pwregions` branch. The system enables Wizard's garbage collector to use durable storage (PMEM/DAX or file-backed mmap) with crash-consistent allocation via a write-ahead log (WAL). See [PMEM Emulation](pmem-emulation.md) for the supported emulated-PMEM development environment and validation limits, and [PMEM Crash Model](pmem-crash-model.md) for the proposed store/`CLWB`/`SFENCE` trace explorer.

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

### Supported PMEM path

`PmemMmapBackend` expects a **regular file on an fsdax filesystem**, not a raw
device path:

```text
/dev/pmem0 → ext4/XFS mounted with DAX → /mnt/pmem/wizard-region
                                           └─ PmemMmapBackend path
```

This follows from both sides of the contract. Linux supports `MAP_SYNC` only
for DAX files, while `PmemMmapBackend` uses the regular-file operations
`open`, `lseek`, and `ftruncate` before mapping. A raw fsdax block device does
not itself provide filesystem DAX, and `/dev/daxX.Y` has fixed-size,
alignment-sensitive character-device semantics that do not fit
`RegionFileIO.ensureSize()`.

For machines without physical PMEM, the recommended development setup is a
QEMU-emulated NVDIMM exposed as `/dev/pmem0` inside an x86-64 Linux guest,
then formatted and mounted as fsdax. Native Linux `memmap=<size>!<start>` RAM
reservation is an alternative. Both validate the DAX programming interface;
neither proves survival of host power loss. See `docs/pmem-emulation.md` for
setup, safety constraints, and the staged validation plan.

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
  if persistence fails: latch recovery-required, return PERSIST_FAILED, and retain both records
  dataDurableSeq = maxSeq; nextTxnSeq = maxSeq + 1
  return REPLAYED
```

`CORRUPT` reports an invalid dual-WAL header. Recovery leaves valid records in place; replaying an already-durable after-image again is harmless.

`close()` is the clean-unmount boundary: it persists the last applied transaction and scrubs only slots whose data is known durable. Unrecovered records and records protected by a failed final persist remain available for the next mount.

### Persistence-failure contract

The project adopts a **recovery-required** contract for phase-B persistence
failures:

- A nonzero `commit()` result is **acknowledged**. The persistence boundary
  reported success and the returned value is the transaction sequence.
- If `prepareChangedRange(record)` or `persistChanges()` reports failure after
  the complete record has been constructed, `commit()` returns `0`, but this
  means **unacknowledged**, not aborted. Any complete valid record that reached
  durable storage may be replayed.
- If preparing an acknowledged transaction's applied after-image fails,
  `applyUpdate()` returns `false` and latches recovery-required. Recovery uses
  the same rule: it returns `PERSIST_FAILED` without issuing `persistChanges()`
  or advancing `dataDurableSeq`.
- If either ordered write during fresh-header initialization fails, the new WAL
  remains closed and recovery-required. Fail-before-copy can require a fresh
  reformat; copy-then-fail may leave a complete header that a new instance
  validates as clean.
- After an unacknowledged result, the mounted region must not accept another
  normal transaction, retry, flush, or clean close. It is in a
  **recovery-required** state. The process must abandon that mount, reopen the
  region, and run recovery; only successful recovery establishes the durable
  state from which work may continue.
- `recover() == CLEAN` resolves the attempted transaction as absent.
  `recover() == REPLAYED` may include it. `CORRUPT` or `PERSIST_FAILED` leaves
  the region unavailable for normal use.

Redo entries are `(offset, width, after-image)` stores. Replaying the same
valid record, including one whose original caller received `0`, is therefore
byte-level idempotent and does not require durable invalidation merely to
prevent a duplicate effect.

Invalid input and capacity rejection can be known before a persistence
boundary and are definite non-commits. `DualTxnWal.requiresRecovery()`
distinguishes those results from commit-originated persistence failure without
changing the `u64` result or on-region format. `RegionTransaction` and
`PWRegion` now expose the same distinction through `requiresRecovery()`, so a
public failure with a clear latch remains a definite validation/capacity
rejection while a set latch requires abandon, reopen, and recovery.

The shadow tests make the rule executable: copy-then-fail can leave either a
replayable record or a valid fresh header despite returning failure, while
fail-before-copy discards those bytes at crash. `DualTxnWal` now latches
fresh-header, commit-record, after-image preparation, overwrite-guard, recovery,
explicit-flush, final-data-close, and slot-scrub persistence failures. Once
latched, the instance rejects append, commit, apply, persist, recover and close
persistence work without another backend call. Only a new instance may inspect
or recover the durable image. The transaction facade retains its dirty cache
when after-image application fails, and allocator entry points reject new work
on the latched mount.

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
  if requiresRecovery() → return false
  if !isDirty() → return true
  appendToWal()             // iterate addrs → wal.append(offset, value, width)
  txnSeq = wal.commit()     // write one durable WAL record; 0 == failure
  if txnSeq == 0 → return false  // leave cache dirty; query requiresRecovery()
  if !applyToRegion() → return false // acknowledged record remains recoverable;
                                      // leave cache dirty and require reopen
  clear()                   // reuse the cache/map storage
  return true
```

The committing transaction's applied after-images are recoverable from its durable slot, but their direct data persistence is deferred. The next commit's single phase-B boundary persists those pending ranges together with the next record. `flush()` calls `wal.persistAppliedData()` when an idle/unmount boundary is required, and `PWRegion.deallocate()` reaches the same operation through `wal.close()`.

`DualTxnWal.applyUpdate()` now returns `false` and latches recovery-required if
range preparation fails. `RegionTransaction.applyToRegion()` surfaces that
result without clearing buffered writes. `RegionTransaction.requiresRecovery()`
delegates to the WAL, and `PWRegion.requiresRecovery()` exposes it to allocator
callers; allocation and free entry points reject work after the latch is set.

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

`ImmixPWRegion extends PWRegion` adds a line-mark metadata table alongside each allocated chunk. `createChunk()` stores the region-relative offset of the chunk's first line mark in its transactional header, so the link remains valid after remount. The persisted line-mark metadata descriptor's `unitSize` controls the line size; the built-in `MemRegions` descriptor defaults it to 256 bytes.

- `resetAllLineMarks()` — clears all line marks at the start of a GC cycle.

---

## Platform wrappers

**File:** `src/engine/x86-64/X86_64PWRegion.v3`

Convenience subclasses that wire a backend to `PWRegion` / `ImmixPWRegion`:

| Class | Backend |
|---|---|
| `X86_64PWMemRegion` | `VolatileBackend` |
| `X86_64PWNVRegion` | `PmemMmapBackend` (regular file on an fsdax mount) |
| `X86_64PWBlockDeviceRegion` | `FileMmapBackend` |
| `X86_64ImmixPWMemRegion` | `VolatileBackend` + Immix metadata |
| `X86_64ImmixPWNVRegion` | `PmemMmapBackend` over fsdax + Immix metadata |

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

Audited 2026-07-31 and extended 2026-08-06: the implementation-specific
x86-64 Linux suite contains 116 registered tests. All 116 pass with no expected
failures when run in an amd64 Docker container on the current Darwin arm64
host.

| Test file | Tests | What it covers |
|---|---:|---|
| `DualTxnWalTest.v3` | 34 | active two-slot WAL, shadow live/durable crash model, phase-B boundary count, recovery, overwrite guard, fresh-header and after-image preparation faults, persistence outcomes including unacknowledged record replay, and recovery-required enforcement |
| `RegionTransactionTest.v3` | 16 | transaction cache and active `DualTxnWal` integration, commit/apply/flush recovery-required propagation, and oversize rejection |
| `TxnPWRegionTest.v3` | 44 | allocator, invalid-input rejection, Immix line geometry/linkage, overflow and recovery-required propagation, mmap/PMEM backend state, graceful and abrupt-process file-backed remount, and `DualTxnWal` recovery |
| `MultiTxnWalTest.v3` | 22 | retained ring WAL: superblocks, recovery, epochs, wrap/checkpoint, validation and hardening regressions |

`SingleTxnWal` and the platform wrapper classes have no dedicated tests. Immix
coverage currently checks descriptor-driven line geometry and chunk-to-line-
mark linkage. As of 2026-07-31, the direct `DualTxnWalTest` crash cases use
`ShadowDurableRegion`: a newly mounted WAL sees a live image restored from
separate durable bytes, so unpersisted writes disappear. The core phase-B
commit/apply/N+1, replay, flush, close, corruption, fail-before and torn-record
windows now have byte-level protocol-model evidence. The fault matrix also
covers after-image preparation failure during normal apply and recovery, plus
fail-before-copy and copy-then-fail during fresh-header initialization.
Normative copy-then-fail tests confirm that a complete record may replay and a
complete header may reopen even though the original persistence call failed.

The file-backed tests exercise the actual `fdatasync` and page-aligned
`msync(MS_SYNC)` code paths, including basic failure propagation, committed-WAL
recovery, graceful close/remount, forked writers that call `exit_group`, and a
writer deterministically stopped after allocator after-image application before
the parent sends `SIGKILL`. The applied-after-image cases cover a complete
split-allocation transaction and validate its memory-order links, free-list
links, used/list state, and chunk header after remount. These tests do not yet
clear the kernel page cache, reset a VM, interrupt power, trace syscall
ordering, or inject syscall failures. A same-kernel remount can observe cached
data that has not been shown to survive a system crash. Full gaps and priorities
are maintained in `docs/ROADMAP.md` Next Steps #3.

The PMEM-labelled unit coverage is structural only:
`txn_backend:pmem_region_tracks_pending_writeback` wraps an anonymous mapping
in `PmemMmapRegion`. It does not call `PmemMmapBackend.create()` and therefore
does not exercise `MAP_SYNC`, filesystem DAX, an emulated `/dev/pmem0`, or a
real PMEM device. The three-stage integration plan—DAX/remount, guest
crash/restart, then real-hardware durability—is documented in
`docs/pmem-emulation.md`.

### Correctness argument by layers

No single test backend or experiment proves end-to-end durability. The project
uses a layered argument so that each class of evidence has a precise claim:

| Layer | Claim | Required evidence |
|---|---|---|
| 1a. Abstract WAL protocol | `DualTxnWal` and `RegionTransaction` preserve acknowledged updates and recover correctly at every abstract persistence boundary. | Deterministic shadow durable-memory tests that separate live and durable bytes, discard unpersisted bytes on crash, and inject success, failure, indeterminate and torn outcomes. |
| 1b. PMEM event model | The protocol recovers for every explored ordering of dirty-line eviction, asynchronous `CLWB` completion, `SFENCE`, and crash within a declared bound and persistence-domain model. | A trace-driven state explorer that generates concrete durable images and feeds them into the production recovery implementation; see [PMEM Crash Model](pmem-crash-model.md). |
| 2. Backend translation | A `BackendRegion` implementation maps the abstract operations to the intended mechanism and propagates its result: `fdatasync`/`msync` for files, cache-line write-back/fence for PMEM. | Backend unit/integration tests, syscall or instruction tracing where practical, bounds/error tests, and explicit failure injection. |
| 3. Software crash consistency | The complete allocator and WAL recover after the running process or VM disappears without a clean close. | Child-process `_exit`/`SIGKILL` tests for the file backend; DAX integration plus guest reset/QEMU restart for emulated PMEM; structural allocator-invariant checks after reopen. |
| 4. Physical durability | Acknowledged state survives loss of the host and volatile hardware caches on the target medium. | Implemented `CLWB`/`CLFLUSHOPT`/`CLFLUSH` + `SFENCE` path and controlled power-interruption tests on real PMEM. |

Evidence at an outer layer does not replace an inner layer. For example, a
successful filesystem remount is not an exhaustive WAL fault model, while a
shadow backend cannot establish that Linux or a storage device honoured a
syscall. Together the layers support scoped conclusions: protocol correctness
under the abstract boundary and bounded PMEM event model, correct backend
translation, software crash consistency, and finally physical durability.

### Shadow durable-memory test backend

`DualTxnWalTest.v3` now contains a test-only `ShadowDurableRegion` implementing
the existing `BackendRegion` interface. It is not a fourth production storage
backend. It is an executable model of the persistence contract:

```text
ordinary Pointer stores                  persistence operation
          │                                       │
          v                                       v
    live byte array  -------------------->  durable shadow
          ^                                       │
          └----------- crash restore -------------┘
```

- Direct WAL and after-image stores modify only the live array.
- `persistRange(offset, size)` copies exactly that live range to the durable
  shadow.
- `prepareChangedRange(offset, size)` records a pending range;
  `persistChanges()` copies every prepared range to the shadow and clears the
  pending set.
- `crash()` discards volatile state by restoring the live array from the shadow
  and clearing pending ranges. A newly constructed `DualTxnWal` then mounts
  those surviving bytes.

The model supports three injected persistence outcomes:

1. **fail before copy** — no requested bytes become durable;
2. **copy then fail** — bytes become durable but the caller receives an error,
   modelling an indeterminate syscall outcome; and
3. **partial copy then fail** — only a prefix or selected ranges survive,
   modelling a torn record/data update.

This model operates at persistence-call granularity. Ordinary stores never
reach the durable image through background eviction, `prepareChangedRange()`
only queues whole ranges, and `persistChanges()` chooses one outcome for all
queued ranges. Consequently it does not enumerate arbitrary cache-line subsets
or model `CLWB` completing before a later `SFENCE`. Those are deliberate scope
limits, not claims about real PMEM. The planned trace-driven extension and its
machine-model assumptions are specified in
[PMEM Crash Model](pmem-crash-model.md).

This distinction exercises the recovery-required contract. A failed phase-B
boundary returns `0` while a complete checksummed record may remain in the
durable slot. Recovery is allowed to validate and replay that unacknowledged
attempt because replaying after-images is idempotent. The model also injects
`prepareChangedRange()` failure after an acknowledged commit and during replay:
both latch before a later boundary can claim durability. Fresh-header tests
show the corresponding definite fail-before-copy/reformat and indeterminate
copy-then-fail/clean-reopen outcomes.

The direct `DualTxnWal` core crash/fault matrix and backend self-tests are in
place. Fresh initialization, commit, apply, recovery, explicit flush,
final-data close and slot scrub now latch and enforce recovery-required state.
That state now propagates through `RegionTransaction`/`PWRegion`. The remaining
core integration work is a test-only `ShadowTxnBackend` factory that exposes
the same live/durable pair to `PWRegion` so complete
allocation split/exact-fit and free/coalescing transactions are checked after
simulated crashes. The shadow model establishes Layer 1a; it complements the
planned Layer-1b trace explorer rather than replacing the file/DAX and hardware
work in Layers 2–4.

Run with:

```bash
test/unit.sh
```

---

## Open items

| # | Location | Description |
|---|---|---|
| 1 | `X86_64TxnBackend.v3:88-93` | `flushCacheLine()` and `storeFence()` need Virgil compiler intrinsics for `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE`. Until then PMEM persistence is not truly durable. |
| 2 | `DualTxnWalTest.v3` | Extend the shadow live/durable model through a `ShadowTxnBackend` allocator integration factory. |
| 3 | `TxnBackend.v3:55-56` | Consider renaming `TxnRegionBackend` → `RegionManager` to better reflect its role as a factory. |
| 4 | `X86_64TxnBackend.v3:58` | Page size is hardcoded as `4096`; should be a named constant or queried via `sysconf(_SC_PAGESIZE)`. |
| 7 | `X86_64TxnPWRegion.v3` | `getHeader()` copies the header into a fresh `Array<byte>` on every call (minor GC pressure). |
| 8 | `TxnPWRegionTest.v3` | PMEM coverage bypasses `PmemMmapBackend.create()` and `MAP_SYNC`; an opt-in fsdax integration test is still required. |
| 9 | `docs/pmem-crash-model.md` | Add an instrumentable persistent-store/flush/fence seam and a bounded trace explorer for background eviction, asynchronous `CLWB`, `SFENCE`, and crash schedules. |
