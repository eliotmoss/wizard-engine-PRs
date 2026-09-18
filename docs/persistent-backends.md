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

## Persistence-boundary cost (measured 2026-09-18, Magpie)

Phase B's design note justified its per-commit data flush as "cheap fences —
acceptable". Measured, on one host, one sample per configuration.

Three configurations, so the boundary primitive and the media are separable.
`pwbench` drives 20,000 commits of 8 aligned `u64` redo entries each through the
production path, after 2,000 warm-up commits, at 512 × 4096 = 2 MiB.

| # | Backend | Media | Boundary | Median boundary | Per commit | Boundary share |
|---|---|---|---|---|---|---|
| 1 | `pmem` | DAX `/mnt/pmem0.0` | `CLWB` loop + `SFENCE` | **`SFENCE` 11 ns** (26 cycles) | 13.7 µs | 3.3 % |
| 2 | `file` | DAX `/mnt/pmem0.0` | `fdatasync` | **927 µs local / 1,147 µs cross-socket** | 939–1,160 µs | 98.8 % |
| 3 | `file` | ext4 on LVM, `/home` | `fdatasync` | **133 µs** | 188 µs | 70.9 % |

Figures are medians over the 24 runs of each configuration in `results/`
(two campaigns × three repetitions × four transaction sizes), at 8 entries
except where a size is named. Configuration 2 is bimodal; see below.

All three measured **exactly 1.000 persistence boundaries per commit**, which is
phase B's steady-state claim confirmed on hardware in three configurations
rather than on a counting stub.

### The fences are cheap; they are also not where the cost is

An `SFENCE` costs 11 ns, so the design note's claim holds. But on PMEM the
boundary's *prepare* side — the `CLWB` loop, 14 cache lines per commit at eight
entries — costs about 20.4 M cycles against the fence's 0.52 M, **39× more**.
The expensive half of a PMEM boundary is the cache-line writeback, not the
fence. The note is correct and argues for the wrong reason.

### Isolating the two variables

- **Primitive, media held constant (1 vs 2).** A whole PMEM boundary is 453 ns
  per commit at eight entries; `fdatasync` on the *same DAX filesystem* costs
  927 µs in its low mode. **≈ 2,000×.** This is the cleanest statement of what
  the unified interface hides: identical media, identical workload, identical
  geometry, one interface, three orders of magnitude.
- **Media, primitive held constant (2 vs 3).** `fdatasync` on DAX is **7.0×
  slower** than on ordinary block storage when the process is on the socket
  owning the namespace, and **8.6×** when it is not — 927 or 1,147 µs against
  133 µs. This is the opposite of the
  expected direction and is discussed below.
- **Deployment (1 vs 3).** 453 ns against 133 µs, ≈ 295×.

### The file backend on DAX is the worst of both worlds

The surprise is configuration 2. Putting the file backend on DAX media is
*slower* than putting it on a spinning-or-flash block device, by 6.3×, while
also forgoing the `SFENCE` path entirely — so it pays a worse boundary than
block storage and gets none of the benefit of the medium it is sitting on. The
plausible mechanism is that `fdatasync` on a DAX mapping must walk and write
back the dirty range itself rather than handing pages to an optimised page-cache
writeback path, but this measurement does not establish the mechanism and no
claim about it should be made without one.

The consequence for the design is the important part: **the abstraction must not
be allowed to hide which medium is underneath.** A caller who unified on the
file backend "because it works everywhere" and deployed it on PMEM would land in
configuration 2 and be 71× slower per commit than configuration 1, on the same
hardware, with no error and no warning. That is the cost of unification stated
as a number.

### What phase B's boundary reduction is worth, per medium

Phase B exists to reduce boundaries per commit. Its value is entirely
medium-dependent:

- On a file over DAX, the boundary is 95–99 % of commit cost, so removing one is
  nearly a halving.
- On a file over block storage it is 52–86 %, falling as the transaction grows,
  because the boundary is flat while record construction is not. An earlier
  version of this page gave "80–99 % on a file" as one figure; that holds for
  DAX and overstates the block case at every size above the smallest.
- On PMEM, the boundary is ~3 % of commit cost, so removing one is noise.

On PMEM the remaining ~97 % is WAL record construction — `zeroBytes` and
`computeRecordChecksum` walk the record a byte at a time
(`X86_64DualTxnWal.v3:212,239`). At 13.7 µs per commit against 0.45 µs of
boundary, **record construction outweighs the entire durability boundary by
29×**. Optimising the boundary further on PMEM would be effort spent on 3 % of
the cost; the byte-at-a-time loops are where the time goes. That is a
consequence of the measurement, not a planned change.

### Reproducing these numbers

`scripts/pmem-experiments.sh` runs the whole campaign and records what is needed
to attribute the result:

```
scripts/pmem-experiments.sh doctor   # what this host can run, and why not
scripts/pmem-experiments.sh cost     # the three configurations, swept and repeated
scripts/pmem-experiments.sh control  # the flush-placement negative control
```

Each invocation writes a self-contained directory under `results/` holding the
raw log of every run, a machine-readable `cost.csv`, and a provenance file with
the commit, host, CPU, mount options and load average. It refuses to start from
a dirty working tree, because a number that cannot be attributed to a revision
is not evidence. It skips the block-media configuration, loudly, when that
directory turns out to be on a network filesystem. Repetitions are interleaved
by construction rather than by the operator remembering to interleave them.

The defaults reproduce the tables below: `PWEXP_REPS=3`,
`PWEXP_SIZES="1 8 32 56"`, 20,000 commits after 2,000 warm-up commits.

### Repeats: `fdatasync` on DAX is bimodal, and the cause is NUMA

This is the most important methodological caveat on this page, and two earlier
versions of it were wrong before the mechanism was found.

Within a single 20,000-commit run, the boundary cost is tight — a couple of
percent from minimum to p99. Across runs, `fdatasync` on DAX is not noisy but
**bimodal**: every run lands squarely in one of two modes and stays there.

| | Median | Runs |
|---|---|---|
| low mode | 927,254 ns | 12 of 24 |
| high mode | 1,147,424 ns | 12 of 24 |

The ratio between the modes is 1.237, and the split is exactly even over the two
scripted campaigns (`results/20260918T044131Z-magpie`,
`results/20260918T045605Z-magpie`). The first campaign drew 10 low and 2 high;
the second drew 2 low and 10 high. A representative run from each shows how
little the mode moves within a run:

```
low  (e1)   min   923,561   med   927,181   p90   928,265   p99   944,683
high (e32)  min 1,140,702   med 1,143,660   p90 1,145,580   p99 1,153,374
```

**The earlier readings of this were both mistaken.** The first reported
"6.25×–6.28× on every pairing" and called it robust — that was four runs that
happened to draw the same mode, precision mistaken for accuracy. The second
called the difference a between-session drift and attributed it to load on a
shared host. That is also wrong: the provenance files record a load average of
`0.00 0.00 0.00` at the start of both campaigns, so the machine was idle, and
the modes interleave *within* a campaign rather than separating between them.

### The mechanism is NUMA locality

Pinning the process to each socket separates the modes completely.
`ndctl` puts `region0` on NUMA node 0, and `/mnt/pmem0.0` is backed by `pmem0`:

| `numactl --cpunodebind` | Runs (median boundary ns) | Median |
|---|---|---|
| **0** — local to `pmem0` | 927,371 / 927,082 / 927,443 | **927,371 ns** |
| **1** — remote | 1,148,685 / 1,146,904 / 1,149,433 | **1,148,685 ns** |

No overlap, and both pinned medians land within 0.1 % of the corresponding
unpinned mode (927,254 and 1,147,424 ns). The unpinned runs were simply being
scheduled onto one socket or the other, and the 12/12 split is the scheduler
being indifferent.

**Cross-socket access costs +23.9 % on the durability boundary.** The extent
alignment hypothesis is excluded: it predicted a property of the file, and this
is a property of where the process runs.

The asymmetry between the backends is the interesting part. The PMEM backend
showed no bimodality at all, and now it is clear why: nothing on its path blocks
on media latency. `CLWB` is fire-and-forget, and an `SFENCE` at 11 ns plainly is
not waiting for anything to reach ADR — the writebacks drain asynchronously
inside the 13.7 µs the rest of the commit takes. `fdatasync` is the only
operation here that synchronously waits for data to reach the medium, so it is
the only one that pays the interconnect. The same hardware penalty is invisible
through one backend and 24 % through the other.

That is a third instance of this page's theme, and the sharpest one, because it
is not about the interface at all: **CPU-to-media locality is a cost dimension
that byte-addressable persistent memory has and a block device does not.**
`/home` shows no such structure because its LVM volume is not socket-attached in
the way a PMEM DIMM is. A unified interface cannot expose a knob it has no
concept of.

The practical consequence is concrete: a persistent-region allocator on PMEM
should run on the socket that owns the namespace, and an engine that cannot
guarantee that should at least report the mismatch. Neither `PWRegion` nor the
backends currently have any notion of NUMA (out of scope here, and recorded as
future work).

`file-block` shows no such structure: 130,620–135,561 ns across all 24 runs,
median 133,126 ns.

So the DAX-versus-block factor is **7.0× socket-local and 8.6× cross-socket**.
With the cause identified the figure is no longer a lottery, but it is still two
numbers rather than one, and it is conditional on placement the allocator does
not control.

### One figure that has not reproduced

The earlier hand-run measurements put `file-block` at 148.0–148.2 µs across four
runs. Both scripted campaigns put it at 133.1 µs median, about 10 % lower, with
no overlap. Same host, same commit, same parameters, same directory, and the
machine idle in both cases.

No explanation is offered here because none has been established. It is recorded
because it bears directly on how much weight any single absolute latency on this
page can carry: the answer is less than four tightly-agreeing runs suggest.


### Transaction-size sweep on PMEM: the fence is flat, the writeback is linear

20,000 commits at each size, PMEM backend.

| Entries | `CLWB` lines/commit | `SFENCE` median | Prepare cycles/line | Whole boundary/commit | Boundary share |
|---|---|---|---|---|---|
| 1 | 4 | 11 ns | 72.2 | 139 ns | 3.1 % |
| 8 | 14 | 11 ns | 72.8 | 455 ns | 3.4 % |
| 32 | 50 | 11 ns | 73.1 | 1,604 ns | 3.2 % |
| 56 | 86 | 11 ns | 72.6 | 2,734 ns | 3.3 % |

Two clean results:

- **`SFENCE` is flat.** 11 ns at every transaction size from 1 to 56 entries,
  4 to 86 dirty cache lines. Total fence cycles stay within 523 k–607 k across
  an 86× change in record size. A fence costs what it costs regardless of how
  much it is fencing.
- **`CLWB` is linear**, at **72.0–73.5 cycles (~31.6 ns) per cache line** across
  a 21× range in line count and all 24 PMEM runs. The whole PMEM boundary therefore scales with the
  record, and it scales entirely through its prepare side.

The line count is exactly predictable. A record is a 64-byte header, a 48-byte
trailer and one 32-byte `LogEntry` per buffered write, aligned up to 64, and
each after-image is prepared separately, so

```
lines/commit = ceil((112 + 32n) / 64) + n
```

which gives 4, 14, 50 and 86 at n = 1, 8, 32, 56 — matching every one of the 24
PMEM runs exactly.

Boundary share stays between 2.9 % and 3.4 % at every size, because record
construction scales with record length for the same reason the `CLWB` loop does.

### `fdatasync` is flat too, so the headline ratio is size-dependent

The same sweep on the file backend over DAX gives 927.2, 926.9, 926.4 and
927.5 µs at 1, 8, 32 and 56 entries in the low mode, and 1,147.7, 1,146.3,
1,148.7 and 1,147.5 µs in the high mode — **under 0.25 % variation across a 56×
change in transaction size, within either mode.** One `fdatasync` is one
whole-file syscall, and it costs the same whether the transaction dirtied
32 bytes or 1,792. Block storage is flat too: 133.8, 133.7, 133.9 and 130.8 µs.

Both boundary primitives are therefore flat in transaction size. The only thing
that scales is PMEM's `CLWB` loop, and that is enough to move the ratio by a
factor of twenty:

| Entries | PMEM boundary/commit | `fdatasync` on DAX (low mode) | Ratio |
|---|---|---|---|
| 1 | 139 ns | 927.2 µs | 6,669× |
| 8 | 453 ns | 926.9 µs | 2,048× |
| 32 | 1,595 ns | 926.4 µs | 581× |
| 56 | 2,731 ns | 927.5 µs | 340× |

Against the high mode every ratio is 1.24× larger.

**The 2,000× headline is a property of eight-entry transactions, not of the
media.** Quoting it without the transaction size overstates the gap by 6× at the
large end and understates it by 3× at the small end. Combined with the
bimodality, the defensible claim is "about three orders of magnitude at small
transaction sizes, closing to about two at the largest the WAL slot allows" —
not any single multiplier.

### What batching is worth, per medium

Because the boundary is flat and per-commit, amortising it over a larger
transaction is the obvious optimisation. Its value is not remotely the same on
the two media — whole-commit cost per entry:

| Entries | PMEM | file on DAX | file on block |
|---|---|---|---|
| 1 | 4,436 ns | 1,045,072 ns | 171,634 ns |
| 8 | 1,710 ns | 130,872 ns | 23,528 ns |
| 32 | 1,600 ns | 36,741 ns | 7,606 ns |
| 56 | 1,553 ns | 17,393 ns | 4,890 ns |

Batching 1 → 56 entries is worth **60× on a file over DAX, 35× over block
storage, and 2.9× on PMEM**, and on PMEM it has essentially plateaued by eight
entries. The reason is structural: on a file the flat boundary is most of the
commit and divides down across entries, while on PMEM the boundary is ~3 % and
both it and record construction scale with the record, so there is little fixed
cost left to amortise.

An earlier note here speculated that the optimal transaction size would run in
*opposite* directions on the two media. The measurement does not support that
and it should not be repeated: larger transactions are cheaper per entry on both
media. The finding is the magnitude, not the sign — a batching strategy tuned on
one medium is not wrong on the other, merely pointless.

### Limits of these numbers

- **`fdatasync` on DAX has two costs**, socket-local and cross-socket, differing
  by 23.9 %. Unpinned runs draw one at random. Every figure for configuration 2
  on this page is the socket-local one unless stated.
- **One absolute figure has not reproduced at all**: `file-block` measured
  148 µs by hand and 133 µs in both scripted campaigns, unexplained.
- What *has* reproduced, across all 72 runs in `results/`: exactly 1.000
  boundaries per commit, `SFENCE` at 11–13 ns, both boundary primitives flat in
  transaction size, `CLWB` linear at 72.0–73.5 cycles per line, and
  `lines/commit = ceil((112 + 32n)/64) + n` exactly at every size.
- Treat the ratios as orders of magnitude and the absolute latencies as
  properties of this host's storage stack on the day.
- The **mechanism** behind configuration 2's slowness is not established, only
  its magnitude and its reproducibility.
- Samples are `rdtsc`, converted with a TSC frequency calibrated per run against
  `CLOCK_MONOTONIC` (2294 cycles/µs on every run here). There is no invariant-TSC
  check in the tree, so that conversion is an assumption, stated rather than
  hidden.
- The absolute `fdatasync` figures are properties of this host's storage stack,
  not of the design. The ratios are the portable result.

## Layer 1 — Storage Abstraction

**Files:** `src/engine/TxnBackend.v3`, `src/engine/x86-64/X86_64TxnBackend.v3`

### Interfaces

```
BackendRegion (abstract class)
    range: Range<byte>                       // the mapped bytes
    persistentOperations()                   // per-region scalar/CLWB/SFENCE provider
    destroy()                                // release storage
    prepareChangedRange(offset, size)        // mark region dirty (write-behind)
    persistChanges()                         // flush all pending dirty ranges
    persistRange(offset, size)               // synchronously flush a specific range (used by WAL)

TxnRegionBackend (abstract class)           // factory for BackendRegion instances
    create(size: u64, prot: BackendProt, fresh: bool) -> BackendRegion
    isPersistent() -> bool
    name() -> string
```

The narrow `PersistentOperations` interface provides naturally aligned
`storeU8`/`storeU16`/`storeU32`/`storeU64`, region-relative `clwb`, and
`sfence`. A single provider belongs to each region, allowing active-WAL stores
and PMEM writeback/fence requests to share one observable order. The production
x86-64 provider performs ordinary native scalar stores and reaches the existing
writeback/fence hooks. A recording provider mutates the same live byte image and
retains typed `STORE`/`CLWB`/`SFENCE` events for deterministic tests.

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

`MmapRegionUtils.flushCacheLine()` selects `CLWB`, `CLFLUSHOPT`, or `CLFLUSH`
from CPUID feature bits, and `storeFence()` emits `SFENCE`; both reach native
pre-generated stubs in `X86_64Target`. Exact encodings and the production
CPUID/writeback/fence path are covered by `PersistentOperationsTest.v3`.

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

`DualTxnWal` is the WAL wired into `PWRegion` and `RegionTransaction`. It keeps at most two committed transactions in fixed slots selected by `txnSeq % 2`. Redo entries are absolute, idempotent after-images, so recovery validates both slots and replays them in ascending sequence order without a superblock, epoch, replay floor, ring, or checkpoint policy. Fresh construction, record zeroing and fields, checksum publication, after-image application/replay, and slot scrubbing all store through the backend region's `PersistentOperations` provider.

`MultiTxnWal` remains compiled and has dedicated comparison tests, but it is no longer on the allocator commit path. `SingleTxnWal` remains a reference implementation with baseline commit, recovery, checksum, boundary-count, and silent-overflow comparison tests. See `docs/wal-comparison.md` for the design comparison and `docs/checkpoint-policy.md` for the retained ring-WAL policy record.

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

### `PWRegionHeader` (88 bytes, stored at offset 0)

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
| `userRoot` | u64 | region-relative offset of the caller's root object; `0` = none |

#### The durable root

`userRoot` is the allocator's only concession to what a caller stores in the
region. Without it a mounted region is opaque to its owner: the block table
records which extents are in use, but not which of them the caller wants to
reach after a restart, so every caller has to remember an offset out of band.
`PWRegion.getUserRoot()` / `setUserRoot(offset)` publish and read one
region-relative offset transactionally, which is enough for a caller to anchor
an arbitrary structure of its own.

`0` means "no root". Offset 0 is the region header, which is never allocatable,
so the sentinel cannot collide with a real target. `setUserRoot()` rejects an
offset at or past the end of the region, so a remount cannot hand back a wild
address; the rejection is ordinary and leaves the mount usable, distinguishable
from a persistence failure via `requiresRecovery()`. `format()` stores the zero
explicitly so a reformat clears a previous run's root rather than inheriting it.

**Root publication is a separate transaction from the allocation it names.**
`allocChunk()` commits on its own (see [Design Critique](CRITIQUE.md) #1), so a
crash between allocating an extent and publishing it leaks that extent: it stays
marked used and nothing reaches it. This is a space leak, not an inconsistency
— the durable state always satisfies the allocator's invariants — and it is the
cost of the current per-operation commit granularity.

**Format change.** The header grew 80 → 88 bytes. Sentinels sit immediately
after the header (`formatSentinels()` uses `PWRegionHeader.size`), so they moved
with it and a region formatted by an older build cannot be mounted by this one:
`magic`, `numBlocks` and `blockSize` still validate at their unchanged offsets,
but the sentinel array would be read 8 bytes early. Regions must be reformatted.
This follows the precedent of the 72 → 80 growth that added `logChunk`.

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

`ImmixPWRegion extends PWRegion` adds a line-mark metadata table alongside each allocated chunk. `createChunk()` stores the region-relative offset of the chunk's first line mark in its transactional header, so the link remains valid after remount. The persisted line-mark metadata descriptor's `unitSize` controls the line size, and its `fixedBytes` prefix precedes the per-line table; the built-in `MemRegions` descriptor defaults to a 256-byte line size and no prefix.

- `resetAllLineMarks()` — clears all line marks at the start of a GC cycle. Line marks are explicitly transient GC state: mark/reset operations bypass `RegionTransaction` and issue no persistence boundary. A caller mounting after a crash must rebuild them; the allocator does not currently do that automatically.

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

Audited 2026-07-31 and extended 2026-08-13: the implementation-specific
x86-64 Linux suite contains 173 registered tests across six files. All 173 pass
with no unexpected failures in the current native x86-64 Linux run; the full
unit binary contains 1,884 tests including portable and spec-parser coverage.

| Test file | Tests | What it covers |
|---|---:|---|
| `SingleTxnWalTest.v3` | 4 | retained single-transaction WAL baseline: commit/recovery persistence ordering and ranges, checksum rejection, and silent-overflow characterization |
| `DualTxnWalTest.v3` | 40 | active two-slot WAL, shadow live/durable crash model, phase-B boundary count, recovery, natural-alignment/entry-boundary and checksummed malformed-record validation, overwrite guard, fresh-header and after-image preparation faults, persistence outcomes including unacknowledged record replay, and recovery-required enforcement |
| `PersistentOperationsTest.v3` | 5 | typed scalar-store recording and little-endian mutation, cache-line range translation and conditional fences, one/two-transaction phase-B order, and production recovery replay events |
| `RegionTransactionTest.v3` | 16 | transaction cache and active `DualTxnWal` integration, commit/apply/flush recovery-required propagation, and oversize rejection |
| `TxnPWRegionTest.v3` | 80 | allocator, direct hand-written and reproducibly generated mixed-history memory-order/free-list invariant checks, invalid-input rejection, copied/remounted Immix descriptors, prefix-aware line lookup/linkage/reset and transient persistence policy, all five platform wrappers, overflow and allocation/free recovery-required propagation, exclusive-create collision rejection, fresh/missing-file backend creation, mount geometry validation and legacy WAL-offset fallback, mmap/PMEM backend state, real-file `fdatasync` commit ordering and injected-error recovery, page-aligned `msync` format ordering and clean-close failure recovery, graceful and abrupt-process file-backed remount including N+1 piggyback and explicit-flush boundaries, and `DualTxnWal` recovery |
| `MultiTxnWalTest.v3` | 28 | retained ring WAL: superblocks, recovery, epochs, wrap/checkpoint, validation and hardening regressions |
| `PWSieveTest.v3` | 13 | resumable segmented sieve workload: mount/reattach, foreign-root rejection, prime counts against an independent sieve, cross-object invariants after every commit, retirement returning blocks, leak reclamation, retention-window enforcement, and resume across real file-backed remounts |
| `PersistentSieveTest.v3` | 6 | the sieve through the crash-image explorer: recorded step validates against the baseline, exhaustive final-cut check, budgeted allocator- and sieve-property sweeps over every cut of an ordinary and a retiring step, and a damaged-bitmap self-check |

The trace recorder deliberately has no durable image, background eviction,
asynchronous writeback completion, crash cuts, or schedule exploration yet.
Its scope is to prove that real active-WAL execution emits the expected ordered
operations. `PWRegion.format()` and its direct header/block-table/descriptor
stores, non-cached allocator setters, retained comparison WALs, and transient
Immix line marks remain outside the store seam pending a later audit.

The platform wrapper classes each have a dedicated construction test. Immix
coverage checks copied and remounted descriptors, descriptor-prefix-aware line
geometry, bounded line lookup, chunk linkage, complete reset, and the explicit
transient/non-WAL persistence policy. As of 2026-07-31, the direct
`DualTxnWalTest` crash cases use
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
writer deterministically stopped at either a split, exact-fit, or coalescing-
free transaction's commit-before-apply boundary or after allocator after-image
application before the parent sends `SIGKILL`. Both crash windows cover all
three complete multi-entry transaction shapes. The commit-before-apply cases
stop inside the test file backend after the real `fdatasync`. Two additional
cases stop at the second real `fdatasync`: one verifies that transaction N+1's
commit boundary has persisted transaction N's applied after-images before N+1
applies, and one kills during an explicit flush before it returns or clean-close
work begins.
They validate memory-order links, free-list links, used/list state, and chunk
headers where applicable after remount. A separate integration test intercepts
the production file-sync seam around a successful real `fdatasync` and pins
WAL-record preparation before that boundary and allocator after-image
preparation after it. The same seam injects one real `EBADF` result through
`fdatasync(-1)`: the allocator propagates failure, latches recovery-required,
blocks same-mount retry/flush, and replays the complete page-cache record after
remount. The mapped-range seam additionally records the exact page-aligned
`msync` spans: fresh format orders two WAL initialization syncs before the
whole-region publication, while clean close completes final-data `fdatasync`
before an injected failing slot-scrub `msync`. The latter latches its old WAL
instance and remount preserves the allocated structure. These tests do not yet
clear the kernel page cache, reset a VM, interrupt power, or trace at the kernel
syscall layer beyond the explicit test seams. A same-kernel remount can observe
cached data that has not been shown to survive a system crash. Full gaps and
priorities are maintained in `docs/ROADMAP.md` Next Steps #3.

The default PMEM-labelled unit coverage is structural only:
`txn_backend:pmem_region_tracks_pending_writeback` wraps an anonymous mapping
in `PmemMmapRegion`. It does not call `PmemMmapBackend.create()` and therefore
does not exercise `MAP_SYNC`, filesystem DAX, an emulated `/dev/pmem0`, or a
real PMEM device. The separate opt-in `PmemDaxIntegrationTest.v3` closes that
functional gap: it reserves a unique private file inside a caller-supplied
fsdax scratch directory, then requires production `PmemMmapBackend.create()` /
`MAP_SYNC`, clean allocator remount, and WAL replay.
Run it with:

```bash
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean make pmem-integration
```

Both opt-in cases passed with this command on Magpie's real `/dev/pmem0` fsdax
filesystem on 2026-08-31, after the native instruction encoding and smoke tests
passed on the same host. The suite is excluded from the default unit/CI binary
and remains controlled backend/hardware integration evidence, not an abrupt
process, host-reset, or power-loss durability result. Those remaining stages
are documented in `docs/pmem-emulation.md`.

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

### Resumable workload driver

`test/unittest/x86-64-linux/PWSieve.v3` is a segmented Sieve of Eratosthenes
over a `PWRegion`, used as a workload rather than as engine code. It exists to
drive the allocator the way a program would: stop at an arbitrary point, and on
the next run find its own state through the durable root and continue. It has no
WASM component -- the WASM-facing object-graph persistence layer is separate
work.

The root chunk holds a `SieveRoot` (cursor, prime count, segment count, span,
capacity, largest prime) followed by a fixed table of segment descriptors, and is
published at `userRoot`. Each segment covers a contiguous span of integers, one
bit each, in its own chunk; segments outside a retention window have their chunks
freed while their descriptors survive, so the historical count stays exact and
the allocator sees sustained allocate/free/coalesce churn.

Three ordering decisions carry the design:

- **Bulk data is not logged.** A kilobyte bitmap would overflow a 32-byte-entry
  record slot many times over. Bitmaps are written through the
  `PersistentOperations` seam and made durable *before* the transaction that
  publishes their descriptor. Safe because an unpublished chunk is unreachable,
  so no reader can observe a partial one.
- **Publication follows allocation, and leaks.** `allocChunk()` commits on its
  own (see [Design Critique](CRITIQUE.md) #1), so a crash between allocating an
  extent and naming it leaves a block marked used with nothing pointing at it.
  Measured, not hypothetical: 8-18 extents per crash-loop run, and without
  reclamation a small region stops making progress after about six crashes.
  `open()` sweeps the region's memory-order chain and frees what no descriptor
  names -- only the workload can do this, since the allocator only knows the
  block is used.
- **Unpublication precedes freeing, atomically.** Retirement buffers the
  descriptor clear and then calls `freeChunk()`, which commits the shared cache,
  so both land in one transaction. The reverse order would leave a descriptor
  naming a block the allocator may hand out again -- corruption, not a leak.

`checkInvariants()` is deliberately cross-object: a descriptor lives in the root
chunk and the bitmap it describes in another, so a torn commit shows as a
disagreement between them. It checks the descriptor count against the bitmap's
popcount, the root total against the sum of descriptors, the cursor against the
segment count, and every live bitmap against a freshly recomputed sieve of its
range byte for byte. Publication and retirement are separate transactions, so the
bound that holds at every instant is `live <= window + 1`; `open()` finishes an
interrupted retirement so the surplus cannot accumulate.

Three harnesses drive it, at three evidence layers:

| Harness | Layer | What it shows |
|---|---|---|
| `PWSieveTest.v3` | 3 | Graceful remounts preserve and resume the workload; retirement recycles blocks; a leak is reclaimed |
| `test/pwsieve.main.v3` (`make pwsieve`) | 3 | Random-timer `SIGKILL` at arbitrary points, remount, invariants, monotone progress, final count against an independent sieve |
| `test/pwsieve.main.v3` (`make pwsieve-pmem`) | 3 | The same loop through `PmemMmapBackend`: `MAP_SYNC` + the native `CLWB`/`SFENCE` path on filesystem DAX. Passed on Magpie 2026-09-01 (13 kills, all `REPLAYED`, 376,256 primes matching an independent sieve). Needs `PWASM_PMEM_TEST_DIR`. Executes the production path on real media but does **not** discriminate flush placement — a killed process on a DAX mapping loses nothing still in cache; that sensitivity is layer 1b's |
| `PersistentSieveTest.v3` | 1b | Every durable image a crash schedule permits, mounted through production recovery, checked against both the allocator's and the workload's invariants |

The crash loop forks a child that sieves while the parent sleeps a seeded
pseudo-random 50 us - 20 ms interval and sends `SIGKILL`. Across five seeds at
25-30 iterations, every restart reported `DualWalRecovery.REPLAYED` -- the kills
all landed mid-transaction rather than while the child was idle -- and the final
count matched the reference exactly (376,256 primes below 5,429,504). Same
boundary as the rest of the file-backed work: process-crash consistency under one
kernel, not host power-loss proof.

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
| 2 | `DualTxnWalTest.v3` | Extend the shadow live/durable model through a `ShadowTxnBackend` allocator integration factory. |
| 3 | `TxnBackend.v3:55-56` | Consider renaming `TxnRegionBackend` → `RegionManager` to better reflect its role as a factory. |
| 4 | `X86_64TxnBackend.v3:58` | Page size is hardcoded as `4096`; should be a named constant or queried via `sysconf(_SC_PAGESIZE)`. |
| 7 | `X86_64TxnPWRegion.v3` | `getHeader()` copies the header into a fresh `Array<byte>` on every call (minor GC pressure). |
| 9 | `docs/pmem-crash-model.md` | Extend the completed persistent-operation seam and typed recorder with durable images plus a bounded explorer for background eviction, asynchronous `CLWB`, `SFENCE`, and crash schedules. |
