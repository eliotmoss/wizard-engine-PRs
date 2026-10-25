# Persistent Backends: Design and Implementation

This document covers the design of the persistent/transactional memory backend system on the `pwregions` branch. The system is meant to give the garbage collector of a persistent WASM heap durable storage (PMEM/DAX, file-backed mmap, or explicit direct I/O to a file or raw block device) with crash-consistent allocation via a write-ahead log (WAL). No collector uses it yet: the allocator has no connection to WASM execution ([Design Critique](CRITIQUE.md), item 8). See [PMEM Emulation](pmem-emulation.md) for the supported emulated-PMEM development environment and validation limits, and [PMEM Crash Model](pmem-crash-model.md) for the proposed store/`CLWB`/`SFENCE` trace explorer.

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
│  Backend region     (BackendRegion)          │  storage abstraction: memory / file / PMEM / direct I/O
└─────────────────────────────────────────────┘
```

All interfaces live in `src/engine/TxnBackend.v3`; x86-64 implementations live under `src/engine/x86-64/`.

---

## The direct-I/O backend (added 2026-09-24, measured 2026-09-27)

`DirectIoRegion` (`src/engine/x86-64/X86_64DirectIoBackend.v3`) is the third
persistent backend. The region lives in a process-private anonymous mapping, the
*staging buffer*; `create()` reads the whole region into it, and write-back is
explicit: `pwrite` of whole 4 KiB units on an `O_DIRECT` descriptor, then one
`fdatasync` per boundary. The target is either a preallocated regular file
(`direct`) or a raw block device (`direct-device`).

Why a third one. `FileMmapRegion` is a page-cache backend: the kernel owns
writeback, may write any dirty page at any time, and keeps dirty data across
the death of the process. Here nothing reaches the device unless the region
writes it, and nothing survives the process unless it was written. Process death
therefore discards unwritten data the way a reset discards unflushed cache
lines, which is what makes an ordinary `SIGKILL` loop sensitive to missing
writebacks on this backend and on no other (see [crash behaviour](#crash-behaviour-process-death-is-the-crash)).

**How it sits on the seam.** The boundary methods mirror `PmemMmapRegion`
exactly: `prepareChangedRange` issues one `clwb()` per 64-byte line through the
region's provider, and `persistChanges`/`persistRange` one `sfence()`. The
provider, `DirectIoOperations`, forwards every call to an inner provider and, on
`clwb()`, marks the line's 4 KiB unit dirty instead of executing CLWB. At the
fence the region writes every marked unit back (adjacent units in one `pwrite`)
and then calls `fdatasync` once. `persistRange` drains every marked unit, not
only its own range, because the `SFENCE` that ends a PMEM `persistRange`
completes every outstanding CLWB. Two consequences:

- The recorded `STORE`/`CLWB`/`SFENCE` trace of a history over this backend is
  the PMEM backend's trace of the same history (`direct_io:trace_matches_pmem_region`,
  at 2 KiB and 4 KiB blocks). No conditional above the seam depends on the
  backend.
- Because the dirty marking lives in the provider, the elided-writeback mutant
  works unchanged: its no-op `clwb()` leaves nothing to write back.

**Audit (2026-10-19).** A text search of the allocator and the log,
`X86_64TxnPWRegion.v3` and `X86_64DualTxnWal.v3`, at `afcf5525` and again at
`fc7466a3` (after the change to `format()` below), with comments set aside.
Neither file has a type test (`.?`) or a cast to a backend or region class, or
names a backend or region class other than the abstract `BackendRegion` and
`TxnRegionBackend`. Of the medium words searched for (pmem, dax, mmap, msync,
fdatasync, direct, and also fsync, clwb, sfence, file and volatile), only
"direct" occurs, in the name of `DirectRegionWriter`, the allocator's
non-transactional writer. `backendRegion` is used only through
`prepareChangedRange`, `persistChanges`, `persistRange`, `range` and `destroy`,
besides null checks and being handed to `X86_64PersistentOps.ensureFor()` and
`DualTxnWal`; the region itself comes from `TxnRegionBackend.create()`. The
backend is chosen outside both files: by `X86_64Backends`
(`X86_64TxnBackend.v3`) and `Backends` (`TxnBackend.v3`), through the wrappers
in `X86_64PWRegion.v3`, or by a caller that passes its own `TxnRegionBackend`.
The change to `format()` adds one `backendRegion` call, a second
`persistRange()`, for the magic. This is a search of the two files' text, not a
proof: it does not follow the calls into the providers and regions, where the
backends differ by design.

**Safeguards.** Setting `O_DIRECT` proves little, so `create()` checks behaviour:
a misaligned one-byte `pwrite` must fail with `EINVAL`. That refuses tmpfs (which
accepts `O_DIRECT` and buffers anyway from kernel 6.6), ext4 with `data=journal`,
and a flag mistranslated by an emulator; the probe writes back the byte it has
just read, so a descriptor that accepts it changes nothing. A block device is
opened once with `O_EXCL`, which fails with `EBUSY` while it is mounted or
claimed; its logical block size must divide 4096; and a fresh format is refused
if the first 128 KiB carry a known partition-table, filesystem, LVM, LUKS or
swap signature, before the region is zeroed. Both refusals were checked on
sean-tan-PC against a mounted root partition and an ext4 signature.

**What it costs elsewhere.** DRAM equal to the region; a mount reads the whole
region before `PWRegion` can read its header; regions below 2 GiB, because
`FdMmapRegion` forges its range with `int.!`.

### Cost: the same seam call, a different persistence point

`pwbench` at 512 × 4096 = 2 MiB, 8 entries, 20,000 commits after 2,000 warm-up,
medians of per-run medians over three repetitions. The `pwrite` and `fdatasync`
halves are means (totals over boundaries), from the timing region's split.

| Host | Target | What Linux reports | `direct` boundary | `pwrite` | `fdatasync` | `file` backend, same filesystem |
|---|---|---|---|---|---|---|
| Magpie | ext4 on LVM on `sda`, a pass-through disk on a Broadcom MegaRAID SAS3508 (Dell PERC H740P, eHBA) | rotational, `write through`, no FUA | **128.7 µs** | ~144 µs | **~1.7 µs** | 136.6 µs |
| sean-tan-PC | ext4 on Solidigm NVMe `nvme1n1` | `write back`, FUA, volatile write cache present (VWC 0x7), atomic write unit 512 B | **241.4 µs** | ~23 µs | **~233 µs** | 237.3 µs |
| sean-tan-PC | raw `/dev/pmem0` (memmap-reserved DRAM, pmem driver, no BTT) | `write back`, no FUA | 0.66 µs | 0.52 µs | 0.14 µs | — |

Results: `results/20260927T074301Z-magpie`,
`results/20260927T080050Z-magpie-bs2048-4096`,
`results/20260927T083305Z-sean-tan-PC-direct-nvme`.
Every direct run measured exactly 1.000 boundaries per commit and one 8 KiB write
per boundary: the record's unit and the scratch data's unit are adjacent, so
they coalesce.

**1. Where the cost sits depends on where the device puts its persistence
point, and the interface shows neither.** On Magpie the kernel sees a
write-through device, so `fdatasync` has no flush to send and returns in about
1.7 µs, and the write carries 99 % of the boundary. On the PC the NVMe has a
volatile write cache, the write takes about 23 µs, and the flush carries 91 %.
The code, the seam call and the WAL's single boundary per commit are identical.

**2. Magpie's block numbers are the latency to an early acknowledgement, not
to a disk.** `sda` reports itself as a 7,200 rpm drive, whose average rotational
latency alone is about 4 ms; a write acknowledged in ~130 µs has not reached a
platter. `sda` sits behind the MegaRAID controller, which reports
`write through` and no FUA, so the durability point Linux sees is an
acknowledgement from below the kernel. This applies to every `file-block`
figure on this page, not only to the direct backend. This section first read it
as the controller's; the
[root sitting of 2026-10-16](#what-acknowledges-a-write-on-home) found the
controller (a Dell PERC H740P) in eHBA mode with no virtual drive, `sda` passed
through with its own write cache disabled, and write-through documented as the
only policy for such disks. So what acknowledges the write is not identified,
and whether the acknowledgement is power-safe is still not established. The
regime switches of the
[block-media configuration](#the-block-media-configuration-is-not-a-controlled-measurement-here)
were offered as consistent with the controller's cache state changing between
sittings; with no cache documented in the path, that candidate is withdrawn.

**3. Bypassing the page cache changes little on either host.** At 2 MiB the
direct and file backends are within 8 % of each other at every size, and in
opposite directions on the two hosts: direct is 2–6 % cheaper on Magpie
(127–135 µs against 134–137 µs) and 0–8 % more expensive on the PC
(241–258 µs against 237–243 µs). Whole commits follow: 180.3 µs against
192.3 µs per commit on Magpie, 270.0 µs against 264.6 µs on the PC. The device
side dominates both.

**4. The page cache's hidden cost is a fault per dirtied page per commit.** The
mmap backends take a write-protect fault the first time a page is stored to
after each writeback: exactly 2 extra minor faults per commit for `file-block`
(the WAL page and the data page), on both hosts, and none for `direct`. On DAX
the count is **1 per commit at 2 MiB and 2 at 1 MiB**: at 2 MiB both dirtied
pages sit under one 2 MiB DAX entry, so one fault re-dirties both. That is
independent, root-free corroboration of the
[region-size mechanism](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries),
which the `fs_dax:dax_writeback_one` tracepoint has since observed directly
([2026-10-16](#fdatasync-on-dax-writes-back-whole-2-mib-entries-observed)). At
these device latencies the faults are negligible.

**5. The 1 MiB penalty on Magpie is below the page cache.** At 512 × 2048 both
block configurations are slower than at 512 × 4096 (direct 149–176 µs, file
157–168 µs, against 129–137 µs), and on the direct path the difference is all in
the write: 178 µs against 144 µs per 8 KiB `pwrite`, with `fdatasync` unchanged
at ~1.8 µs. The only difference in what is written is its file offset, 0 rather
than 4096. Earlier campaigns saw the opposite sign for `file-block`, so the
geometry effect stays withdrawn; what this adds is that, whatever it is, it is
not the page cache.

**6. The raw block path costs well under a microsecond.** Over DRAM-backed
`/dev/pmem0` the whole direct boundary is 0.66 µs, so the software path — the
block layer, `O_DIRECT`, the region's write-back scan — is not where the
130–250 µs on the other two targets goes. (This is not a media comparison: the
pmem driver over memmap DRAM persists nothing across power loss, and without
BTT it is not sector-atomic.)

### Crash behaviour: process death is the crash

| Host, target | Harness | Ordinary provider | Elided-writeback mutant |
|---|---|---|---|
| Magpie, `/home` (file) | `pwreboot` setup → arm → verify | `SURVIVED`, `REPLAYED`, cursor 162,560 = acknowledged | **`LOST`**, `CLEAN`, cursor 65,024 = setup's |
| Magpie, `/home` (file) | `pwsieve`, 20 random kills | `OK`, 8 acknowledged-step checks, 0 lost | **`LOST`**, 8 of 8 lost |
| sean-tan-PC, `$HOME` (file) | `pwreboot` | `SURVIVED` | **`LOST`** |
| sean-tan-PC, `$HOME` (file) | `pwsieve`, 20 random kills | `OK`, 17 checks, 0 lost | **`LOST`**, 19 of 19 lost |
| sean-tan-PC, raw `/dev/pmem0` | `pwsieve`, 20 random kills | `OK`, 7 checks, 0 lost; table full, 376,256 primes below 5,429,504 | **`LOST`**, 20 of 20 lost; 696 steps acknowledged, none durable |
| Magpie, DAX (`pmem` backend, for contrast) | `pwsieve`, 20 random kills | `OK`, 11 checks, 0 lost | `OK`, 13 checks, 0 lost |

Results: `results/20260927T073911Z-magpie` (direct-control),
`results/20260927T074021Z-magpie` (the PMEM control rerun),
`results/20260927T081826Z-sean-tan-PC`,
`results/20260927T083305Z-sean-tan-PC-direct-nvme`.

The pwreboot pair reproduces the Stage 2c warm-reset outcome and its cursor
values with no reboot and no host setup. The pwsieve pairs add what Stage 2c
cannot: the discrimination at random crash points. The PMEM row is the
contrast: the same mutant, under the same stricter acknowledgement check, is
invisible to a kill loop on DAX, as the negative control documents.

What these runs show and do not. They show that the production placement of
write-back requests — every `prepareChangedRange`/`persistRange` the allocator,
the WAL and the sieve issue — is necessary, at arbitrary crash points, on real
hardware, under a crash that discards exactly what was never handed to the
kernel. The sensitivity is coarse: write-back is in 4 KiB units and every fence
drains everything marked, so a missing request for a line that shares a unit
with a requested one goes unnoticed; the explorer remains the fine-grained
check. They say nothing about `CLWB`/`SFENCE` on real PMEM (Stage 2c's job) or
about the device under power loss: a killed process never takes the device's
cache with it. The relation of this backend's crash images to the PMEM model is
stated in [PMEM Crash Model](pmem-crash-model.md#the-direct-backend-is-a-restriction-of-the-pmem-model).

## The file backend, a restriction of the PMEM model (2026-10-13)

`FileMmapRegion` now sits on the persistent-operations seam as the direct
backend does, so the PMEM crash model, and with it every explorer result, speaks
for it. `prepareChangedRange` issues one `clwb()` per 64-byte line through the
region's provider, which is the direct backend's `DirectIoOperations` and marks
the line's 4 KiB page; `persistChanges` and `persistRange` issue one `sfence()`
and then one `fdatasync` if any page is marked, and nothing otherwise. The
recorded trace is the PMEM backend's for the same history
(`file_mmap:trace_matches_pmem_region`). The argument that every image the
backend can leave is one the model admits for that trace, its assumptions, and
which of them are checked, are in
[PMEM Crash Model](pmem-crash-model.md#the-file-backend-is-a-restriction-of-the-pmem-model-on-block-storage-only-conditionally).
In short: on fsdax the restriction needs the baseline profile and the kernel's
`fsync` contract; on block storage it also needs every 64-byte line to reach
the device as it stood at one instant (B2), which no specification promises and
which holds by construction only under stable writes, which sean-tan-PC's NVMe
does not request, and nor does any of Magpie's block devices
([checked 2026-10-16](#b2-on-magpie)).

Before the change the backend set a flag in `prepareChangedRange`, called
`fdatasync` in `persistChanges`, and synced a `persistRange` with an `msync` of
the range's own pages. Two things differ. The trace holds the `CLWB`s; before,
it said nothing was ever written back, so the model could not speak for the
backend. And a `persistRange` syncs every marked page, not only its own, because
the `SFENCE` that ends a PMEM `persistRange` completes every outstanding `CLWB`.
In the sieve that `persistRange` is the bitmap's, which now also makes the
allocation's after-images durable, one boundary earlier than before.

### The fence: one `fdatasync`

- **`msync(MS_SYNC)` per run of marked pages** syncs exactly what was asked, but
  on ext4 each call is an `fsync` of its range with its own journal commit or
  device flush, so a fence over several runs pays several flushes. Measured
  below as `file-block-msync`: 7.67 syncs a sieve step instead of 4.00, and the
  step 78 % slower.
- **`sync_file_range()`** writes no metadata and sends the device no flush, so it
  covers neither a page's first allocation nor the device's cache. Its manual
  page: unless the writes only overwrite already-allocated blocks "there are no
  guarantees that the data will be available after a crash", and it "does not
  flush disk write caches". It cannot be a fence, so it was not measured.
- **`fdatasync`** makes durable every page of the file dirty when it is called,
  marked or not, with one flush. An unmarked dirty page holds each of its lines'
  full prefix, which is the model's eviction, so the superset is admitted.

`FileBoundary.MSYNC` and `FileBoundary.LEGACY`, the boundary before the change,
stay selectable through `FileMmapBackend.boundary` and the benchmarks'
`boundary=` keyword, for comparison only.

### Cost, old against new (sean-tan-PC, 2026-10-13)

Each campaign ran every configuration from one binary (the sieve and pwops at
`c1dfd14f`, pwbench at `e3c04344`, whose engine and benchmark code are the
same), interleaved within each repetition, five repetitions, pinned to CPU 2 (a performance core), on the NVMe
root (ext4 on `/dev/nvme1n1p3`, `bin/ab-block`). The governor was `powersave`
(EPP `balance_performance`); it cannot be changed without root. These figures
compare with each other and with the 2026-09-28 `powersave` runs, not with the
`performance` figures elsewhere in this document.

**Sieve step** (`results/20261013T124441Z-sean-tan-PC-pwsieve-bench-cpus2-powersave-file-ab`,
256 × 4 KiB, 20 rounds of 159 steps). Wall time per step, the median over
repetitions with their range; the median step (`rdtsc`) likewise; phases are
means:

| Boundary | Wall per step (range) | Median step (range) | compute | alloc | bitmap | publish | retire | persistence (share) | syncs per step |
|---|---|---|---|---|---|---|---|---|---|
| new | 1,540 µs (1,521–1,545) | 1,593 µs (1,582–1,595) | 497 µs | 267 µs | 265 µs | 252 µs | 259 µs | 1,042 µs (67.7 %) | 4.00 |
| legacy | 1,528 µs (1,510–1,535) | 1,572 µs (1,570–1,575) | 490 µs | 269 µs | 255 µs | 255 µs | 259 µs | 1,038 µs (67.9 %) | 4.00 |
| `msync` per run | 2,734 µs (2,704–2,769) | 2,667 µs (2,661–2,670) | 708 µs | 619 µs | 863 µs | 266 µs | 277 µs | 2,025 µs (74.1 %) | 7.67 |

- **New against legacy: a small cost, consistent in the median and not
  resolvable in the mean.** Wall time per step is 0.8 % longer, inside both
  ranges. The median step is 1.3 % longer, and that is in every repetition:
  the ranges do not meet. The persistence phases are 4 µs (0.4 %) longer, and
  the share is the same (67.7 against 67.9 %). The phases show where the work
  moved: the bitmap's boundary is 10 µs longer and the publish commit 4 µs
  shorter, in every repetition, as expected now that the bitmap's fence also
  writes the allocation's after-image pages, which the publish commit used to.
- **`msync` per run costs 78 % a step**, 80 % of it in the two phases whose
  fences span several runs: the allocation (619 against 267 µs) and the bitmap
  (863 against 265 µs). The computation is also 42 % longer, plausibly the
  clock penalty of blocking more often under `powersave` (see the sieve
  section).
- 2026-09-28's `powersave` run with the legacy boundary
  (`results/20260928T105045Z-sean-tan-PC-pwsieve-bench-cpus2-powersave`) gave
  1,558 µs, 1,042 µs of persistence and 66.9 %: the same machine state.

**Commit boundary** (pwbench, `results/20261013T130143Z-sean-tan-PC-pwbench-cpus2-powersave-file-ab`,
512 × 4 KiB, 20,000 commits after 2,000 warm-up; commit `e3c04344`, whose
engine and benchmark code are `c1dfd14f`'s). The boundary's median, then the
wall time per commit, each the median over repetitions with their range:

| Entries | new boundary | legacy boundary | `msync` boundary | new per commit | legacy per commit | lines per commit (new) |
|---|---|---|---|---|---|---|
| 1 | 241.3 µs (241.2–241.8) | 241.9 µs (241.7–242.4) | 241.1 µs (240.8–241.5) | 255.5 µs (254.6–258.5) | 255.9 µs (255.0–257.0) | 4 |
| 8 | 255.3 µs (235.8–258.3) | 237.0 µs (236.6–237.4) | 236.9 µs (235.4–242.0) | 267.6 µs (265.6–278.0) | 263.5 µs (262.9–265.8) | 8 |
| 24 | 241.6 µs (241.3–242.3) | 245.0 µs (245.0–245.5) | 241.6 µs (241.1–241.7) | 280.9 µs (278.6–281.7) | 278.9 µs (276.5–283.3) | 18 |

- **The same boundary within this drive's two modes.** At 1 entry the three
  are equal. At 24 the new boundary is 3.4 µs (1.4 %) *shorter* than legacy's
  in every repetition, unexplained and small. At 8 entries three of the five
  new runs sit in the upper of the two levels about 20 µs apart that this drive
  shows (see [basic operations](#basic-operations-what-an-allocation-a-free-a-mount-and-a-recovery-cost-2026-10-13),
  "two modes"), and no legacy run does; the other two new runs are at
  legacy's level. Per commit, new is 0.2 % faster at 1 entry and 1.6 % and
  0.7 % slower at 8 and 24, inside or at the edge of the ranges.
- **The `msync` fence is the same as `fdatasync` here**, one sync a commit:
  pwbench's record page and the previous commit's after-image page are
  adjacent, so a fence marks one run. The sieve's fences span several runs,
  which is what makes it 78 % slower there.
- The file backend now reports the lines its commits write back, as the PMEM
  and direct backends do: 4, 8 and 18 a commit. Legacy reports none.

**Basic operations** (pwopsbench, `results/20261013T124629Z-sean-tan-PC-pwops-bench-cpus2-powersave-file-ab`,
50,000 operations after 2,000 warm-up, 200 mounts after 20). The median over
repetitions of each run's median, the spread of those medians, and the p90:

| Operation | new median (spread) | legacy median (spread) | new p90 | legacy p90 | work, new (legacy) |
|---|---|---|---|---|---|
| `alloc-1` | 283,225 (0.3 %) | 283,095 (0.2 %) | 306,997 | 306,406 | 16 / 1 / 15 (0) |
| `alloc-8` | 284,299 (11.4 %) | 283,123 (0.2 %) | 308,911 | 306,519 | 16 / 1 / 17 (0) |
| `alloc-64` | 307,167 (0.4 %) | 287,293 (7.8 %) | 310,858 | 309,591 | 16 / 1 / 17 (0) |
| `free-1` | 275,308 (0.3 %) | 275,533 (0.5 %) | 299,388 | 300,191 | 10 / 1 / 11 (0) |
| `free-8` | 277,452 (16.4 %) | 275,294 (1.2 %) | 300,860 | 299,911 | 10 / 1 / 13 (0) |
| `free-64` | 299,359 (0.1 %) | 298,570 (6.6 %) | 302,710 | 302,419 | 10 / 1 / 13 (0) |
| `mount-1mib` | 14,676 (52.5 %) | 16,265 (4.8 %) | 18,793 | 19,057 | 0 / 0 / 0 |
| `mount-64mib` | 4,474 (29.2 %) | 16,624 (1.6 %) | 4,974 | 17,671 | 0 / 0 / 0 |
| `recover-8` | 271,424 (8.7 %) | 271,767 (0.7 %) | 272,940 | 272,719 | 8 / 1 / 8 (0) |
| `recover-24` | 271,658 (8.5 %) | 271,734 (0.8 %) | 279,565 | 279,607 | 24 / 1 / 24 (0) |
| `replay-8` (derived) | 256,748 | 255,502 | | | |
| `replay-24` (derived) | 256,982 | 255,469 | | | |

ns per operation; work is entries / boundaries / lines written back, checked on
every operation.

- **Allocations, frees and recoveries are unchanged** outside the two modes:
  every p90 is within 0.8 %, and where both spreads are under 1 % (`alloc-1`,
  `free-1`) the medians are within 0.1 %. The large spreads are runs in the
  other mode, in both configurations. `alloc-64` is 306–308 µs in all five new
  runs, and 284–287 µs in three legacy runs and 305–306 µs in the other two.
  The new run of repetition 4 is 20–30 µs below the others in `alloc-8`,
  `free-8` and both recoveries (and its 1 MiB mount 8.9 against 14–17 µs), and
  new `free-8` has one run 20 µs above. The replay is one `fdatasync` either
  way, 255.5–257.0 µs.
- **The 64 MiB mount is not faster.** Its 4.5 against 16.6 µs reproduced in
  every repetition and in either order, with the same system calls and the
  same minor faults (17.3 and 17.4 per iteration of the mount loops;
  `mount-transient.txt` in the results). With 5,000 samples
  instead of 200 the two agree, 3.8 and 3.9 µs: the difference is a transient
  at the start of the 200-sample loop, which follows the 64 MiB format's sync.
  The clock ramping up after that sync is a plausible cause, untested; Magpie's
  1 MiB mount is dearer than its 64 MiB one even on PMEM, where nothing blocks
  ([below](#basic-operations-what-an-allocation-a-free-a-mount-and-a-recovery-cost-2026-10-13)),
  so the clock is not the only influence on these mounts. The same transient
  is probably in the 14.2 µs reported for this mount below.
- The file backend's work column now has lines: the same as the direct
  backend's for every operation.

### Do the quoted sieve figures change?

The sieve section's 86 % (sean-tan-PC's NVMe, 85.6 %, `performance`), 79 %
(the same on an E-core, 79.1 %) and 55 % (Magpie's `/home`, 54.6 %) were
measured with the legacy boundary. Both hosts have since run the sieve with the
current boundary and the legacy one interleaved, in one sitting each. Every
campaign here ran a build from before "The timer from 2026-10-15" (below), the
two of 2026-10-15 included, so all use the old conversion and unordered reads,
as the figures they are compared with do. Wall time per step and the
persistence phases, each the median over repetitions, and the share:

| Host, storage, governor | current boundary | legacy boundary | results |
|---|---|---|---|
| sean-tan-PC, NVMe, CPU 2 (P-core), `performance` | 1,080 µs, 924 µs (85.6 %) | 1,085 µs, 927 µs (85.5 %) | `20261015T052543Z-sean-tan-PC-pwsieve-bench-cpus2-performance-file-ab` |
| sean-tan-PC, NVMe, CPU 20 (E-core), `performance` | 1,258 µs, 997 µs (79.3 %) | 1,266 µs, 1,007 µs (79.5 %) | `20261015T111803Z-sean-tan-PC-pwsieve-bench-cpus20-performance-file-ab` |
| sean-tan-PC, NVMe, CPU 2 (P-core), `powersave` | 1,540 µs, 1,042 µs (67.7 %) | 1,528 µs, 1,038 µs (67.9 %) | `20261013T124441Z-…-powersave-file-ab` ([above](#cost-old-against-new-sean-tan-pc-2026-10-13)) |
| Magpie, `/home` | 2,676 µs, 1,550 µs (57.9 %) | 2,576 µs, 1,448 µs (56.2 %) | `20261013T134636Z-magpie-pwsieve-bench` |
| Magpie, `/home` | 2,679 µs, 1,552 µs (57.9 %) | 2,583 µs, 1,443 µs (55.9 %) | `20261014T025706Z-magpie-pwsieve-bench` |

- **On sean-tan-PC the 86 % stands.** The `performance` campaign ran at
  `b358dbf0` with the sieve section's protocol: `file-block`,
  `file-block-legacy` and `direct-block` interleaved, five repetitions, pinned
  to CPU 2, on the NVMe root, with the governor `performance` on all 28 CPUs
  and EPP `performance`. The share is 85.6 % with the current boundary,
  85.5 % with the legacy one and 86.0 % through the direct backend, as on
  2026-09-28. The wall ranges overlap (1,078.8–1,083.5 against
  1,082.3–1,085.2 µs), although the current boundary is the faster in every
  repetition, by 0.1–0.6 %. Every phase is within 6 µs of legacy's. A step is
  1.6 % shorter than on 2026-09-28 (1,080 against 1,097 µs): the computation by
  1.9 % (155.1 against 158.1 µs) and the persistence phases by 1.5 % (924
  against 938 µs). The kernel was 7.0.0-34 then and 7.0.0-38 now.
- **The E-core's 79 % stands too.** Fifteen repetitions pinned to CPU 20, as on
  2026-09-28, otherwise as above, at `a39d024f` (whose engine code is
  `b358dbf0`'s): 79.3 % with the current boundary, 79.5 % with the legacy one
  and 79.0 % through the direct backend, against 79.1 % and 78.9 % then. The
  current boundary is the faster in every repetition, by 0.3–1.1 % in all but
  the eighth. There legacy's and direct's steps took 1,385 and 1,310 µs, every
  persistence phase 11–42 µs longer than in the seventh and the computation
  unchanged, which fits a disturbance on the storage path. The medians are
  unaffected, and the wall ranges just overlap (1,251.3–1,263.7 against
  1,262.6–1,385.0 µs, the top of legacy's from the eighth).
- **On Magpie the current boundary costs `/home` 2 points**, and both sittings
  agree. The step is 3.7–3.9 % longer, outside both ranges in each sitting, and
  the persistence phases 102–109 µs longer. The work moved as on sean-tan-PC,
  from the publish commit to the bitmap's fence, which now also writes the
  allocation's after-image pages. Here, though, the bitmap's fence grows by
  372–378 µs (646–647 against 269–274 µs), while the publish shrinks by only
  229–233 µs and the retire by 37–39 µs; on sean-tan-PC each moved by 10 µs or
  less. A plausible reading, untested, is that behind the write-through
  controller each page written costs time of its own, where the NVMe charges
  per flush. The two runs were at `cede598e` and `42edc6ff`.
- So the sieve section's 55 % (2026-09-28) belongs to the legacy boundary and
  to that sitting. At the current boundary, quote 57.9 % (file) and 58.3 %
  (direct, `20261014T025706Z`), and compare boundaries only within a sitting:
  Magpie's block storage moves between sittings
  ([below](#magpie-again-every-backend-in-one-sitting-2026-10-14)).

### Crash behaviour

Unchanged by the restriction: process death loses nothing on this backend,
because the page cache is the kernel's, so a `SIGKILL` samples the model's
eager image and the kill loop cannot discriminate flush placement. On
sean-tan-PC's NVMe after the change, `pwsieve` with the ordinary provider gave
`OK` over 20 kills (20 acknowledged-step checks, 0 lost), and so did the
elided-writeback mutant, whose fences now sync nothing: 4 kills at the default
delay before the table filled (4 checks, 0 lost), and 20 with the kill delay
capped at 2,000 µs (6 checks, 0 lost). A kernel reset, which discards the
page cache, does separate them: on 2026-10-21, one run each, the ordinary
build's verdict was `SURVIVED` and the mutant's `LOST`, with every
acknowledged step gone
([below](#a-kernel-reset-separates-the-file-backends-builds)). The rest of the evidence for this backend is the
model and the checks in `FileMmapRegionTest.v3`.

### On Magpie

Run from a clean tree at the commit under test; each campaign interleaves its
configurations and pins to the DAX namespace's node.

```
# Unit tests: the full binary (2,031 of 2,038 should pass since the B+Tree's 22
# were added, the 7 known failures failing), then the file backend's restriction
# checks on their own, then the
# opt-in PMEM DAX integration tests
make -j bin/unittest.x86-64-linux && bin/unittest.x86-64-linux
bin/unittest.x86-64-linux 'file_mmap:*'
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean make pmem-integration

# B2 without root: stable pages requested, and whether any layer is dm-crypt
cat /sys/block/*/queue/stable_writes
lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT
cat /sys/block/dm-*/dm/uuid

# The file backend's kill loop on /home, ordinary and mutant (cannot discriminate)
mkdir -p $HOME/pwsieve-file
make bin/pwsieve.x86-64-linux
for p in ordinary elide-clwb; do
    bin/pwsieve.x86-64-linux $HOME/pwsieve-file 20 1 512 4096 file $p
done

# Sieve step, file on DAX and on /home, old against new
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean PWSB_BLOCK_DIR=/home/users/u7599095 \
    PWSB_CONFIGS="file-dax file-dax-legacy file-dax-msync file-block file-block-legacy file-block-msync" \
    PWSB_NUMA_NODE=0 scripts/pwsieve-bench.sh campaign

# Commit boundary (pwbench), the same configurations
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean PWEXP_BLOCK_DIR=/home/users/u7599095 \
    PWEXP_CONFIGS="file-dax file-dax-legacy file-dax-msync file-block file-block-legacy file-block-msync" \
    PWEXP_NUMA_NODE=0 PWEXP_REPS=5 PWEXP_SIZES="1 8 24" scripts/pmem-experiments.sh cost

# Basic operations (pwopsbench has no msync boundary)
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean PWOB_BLOCK_DIR=/home/users/u7599095 \
    PWOB_CONFIGS="file-dax file-dax-legacy file-block file-block-legacy" \
    PWOB_NUMA_NODE=0 scripts/pwops-bench.sh campaign
```

The unit tests never touch DAX: `file_mmap:` writes its region in `/tmp`, and
the `O_DIRECT` re-read in whichever of `/tmp` and `bin/` honours `O_DIRECT`, so
on Magpie it checks that path's filesystem and device. Nothing in the
restriction's checks needs Magpie; the runs above price it there and confirm
the kill loop's result on a second host.

### Follow-ups that need root

Desktop flush tracing (no reset; two six-minute benchmark timeouts plus
matched idle windows). Build as yourself first, since under `sudo` the PATH has
no `v3c`: `make bin/pwbench.x86-64-linux`, then
`sudo env PWROOT_USER=sean-tan scripts/desktop-root-checks.sh`.
This records the root ext4 mount/superblock and NVMe queue facts, then traces
`block:block_rq_issue` on `nvme1n1` during file and direct pwbench runs with
Magpie's parameters (2 MiB, 8 entries, 2,000 measured commits after 200 warm-up);
it only checks with `make -q` that pwbench is current (and says to run `make`
as yourself if not),
and checks the file run's `boundary fdatasync` line. Each run has an idle trace
window of the same requested duration (actual durations are recorded), to put
root journal commits (`commit=5`), desktop IO and `/boot/efi` traffic in context;
before each idle window it syncs the benchmark directory and waits 10 s outside
the trace, so the window does not catch the benchmark's own last commit.
Counts include all commands, with a `pwbench`/`jbd2`/`kworker`/other breakdown;
workers can issue benchmark IO. Ratios use pwbench's reported **measured persist
boundaries**, each a `fdatasync`, rather than an assumed count of commits. The
whole-process numerator also includes setup, warm-up and close, so those ratios
and a variable idle baseline cannot establish one flush/FUA per syscall. The
trace shows requests sent, not that the device makes them durable. INT, TERM
and HUP stop and wait for the benchmark before removing the private trace
instance; cleanup failures are reported. Run 2026-10-21: a cache flush
followed every boundary's writes
([below](#sean-tan-pcs-root-checks-2026-10-21)).

1. **A kernel crash on block storage, with discrimination.** `pwreboot` already
   runs the file backend, and `arm` with an inherited `/proc/sysrq-trigger`
   descriptor resets the machine straight after the `fsync` of its last
   acknowledgement. A warm reset discards the page cache; the intended
   discriminator is ordinary `SURVIVED` against mutant `LOST`, not an assumed
   result. On sean-tan-PC (`pc-ubuntu`), save all work first: **arm immediately
   resets the machine without syncing or unmounting**, putting the shared root
   filesystem at risk. **Check that GRUB's default entry is Ubuntu before
   arming.** Run each command from this checkout:

   ```bash
   scripts/desktop-reboot-check.sh prepare ordinary
   sudo env PWROOT_USER=sean-tan scripts/desktop-reboot-check.sh arm ordinary --yes-reset-this-machine
   # After the machine is back (the arm command also prints an exact run-specific command):
   scripts/desktop-reboot-check.sh verify ordinary
   # Then a separate run with a fresh region and the negative-control provider:
   scripts/desktop-reboot-check.sh prepare elide-clwb
   sudo env PWROOT_USER=sean-tan scripts/desktop-reboot-check.sh arm elide-clwb --yes-reset-this-machine
   # After the second reset:
   scripts/desktop-reboot-check.sh verify elide-clwb
   ```

   `prepare` and `verify` run without root. Preparation always runs incremental
   `make bin/pwreboot.x86-64-linux`, requires `make -q` to confirm it is current,
   and records that result and the binary hash in the manifest. It uses a fresh
   directory under the owner's home on the ext4 root, runs
   `setup ... file 512 4096 2`, then `sync -f`; arm uses three more steps
   and inherited descriptor 3. State files and boot IDs live under `results/`
   on that same ext4 root, never `/tmp` (tmpfs). A different state filesystem
   would be preferable, so that its `fsync` cannot write the region back, but
   this desktop has no other writable disk filesystem available. `pwreboot`
   fsyncs every state line, and combines the last acknowledgement and summary
   in one fsync immediately before resetting. **Inference:** under `data=ordered` an fsync
   forces out only data blocks newly allocated in its transaction, so a state
   fsync could mask the mutant's losses only if ext4 fell back to nodelalloc
   (low free space); heavy concurrent dirtying could mask them through
   background writeback instead.
   The wrapper records that limitation and rejects verification until the boot
   ID changes. Before arming it records the effective ext4 options, Dirty and
   Writeback memory, `vm.dirty_*`, `df /`, and, as root,
   `nvme smart-log /dev/nvme1` (power cycles and unsafe shutdowns); if nvme-cli
   is absent it
   checks for sysfs equivalents and reports when none are exposed. Arm outputs
   are opened as the ordinary owner. Non-root `verify` prints an exact sudo
   command to save the post-reboot counters in the run directory. This checks
   kernel/filesystem cache loss while the device stays powered, **not device-cache power-loss
   durability**; both providers surviving would not establish discrimination.
      Run 2026-10-21, once per provider: ordinary `SURVIVED`, `elide-clwb` `LOST`
   ([below](#a-kernel-reset-separates-the-file-backends-builds)). `scripts/stage2c.sh` treats
   the file backend as a dry run without a reboot, so it cannot be used as it
   stands.

2. **Block-level images (dm-log-writes).** The `log-writes` device-mapper target
   logs every write and flush beneath the filesystem, and xfstests'
   `replay-log` rebuilds the device entry by entry. Each image, mounted on a
   copy, could be checked against the trace. It checks B3–B5 over the writes the
   kernel actually issued, not B2: the target copies each write's data when it
   is submitted, not when the device reads it. Each prefix of the log is one
   crash state; losing an arbitrary subset of the writes completed since the
   last flush is not enumerated. What is missing is the checker: a dump of the
   scenario's trace and an offline `dioAdmittedAt()` over a region file. An
   image between fences k and k + 1 must be admitted at the cut just before
   `SFENCE` k + 1, and must meet fence k's floor. The setup, on loop devices:

   ```
   # replay-log: two C files from xfstests, system headers only
   git clone --depth 1 https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git /tmp/xfstests
   gcc -O2 -o $HOME/bin/replay-log /tmp/xfstests/src/log-writes/replay-log.c /tmp/xfstests/src/log-writes/log-writes.c

   truncate -s 1G /var/tmp/lw-data.img /var/tmp/lw-log.img /var/tmp/lw-replay.img
   DATA=$(sudo losetup -f --show /var/tmp/lw-data.img)
   LOG=$(sudo losetup -f --show /var/tmp/lw-log.img)
   REPLAY=$(sudo losetup -f --show /var/tmp/lw-replay.img)
   sudo dmsetup create lw --table "0 $(sudo blockdev --getsz $DATA) log-writes $DATA $LOG"
   sudo mkfs.ext4 -q /dev/mapper/lw
   sudo dmsetup message lw 0 mark mkfs
   sudo mkdir -p /mnt/lw && sudo mount /dev/mapper/lw /mnt/lw && sudo chown $USER /mnt/lw
   bin/pwsieve.x86-64-linux /mnt/lw 5 1 512 4096 file    # or the trace scenario, once it can dump its trace
   sudo dmsetup message lw 0 mark done
   sudo umount /mnt/lw && sudo dmsetup remove lw

   # Rebuild the filesystem, then replay to each flush and run the check there.
   sudo $HOME/bin/replay-log --log $LOG --replay $REPLAY --end-mark mkfs
   sudo $HOME/bin/replay-log --log $LOG --replay $REPLAY --start-mark mkfs --end-mark done \
       --check flush --fsck /var/tmp/lw-check.sh
   ```

   `replay-log` stops at the first check that exits non-zero. `lw-check.sh`
   must not change the replay device, so it copies it first:
   `cp --sparse=always /var/tmp/lw-replay.img /var/tmp/lw-copy.img`, then
   `mount -o loop` the copy (the journal is recovered on the copy), runs the
   checker on the region file, and unmounts. `--check 1` checks after every
   entry instead of every flush.

3. **Stable writes.** `sudo env PWROOT_USER=sean-tan scripts/desktop-stable-writes.sh`
   (no reset) prices the mapped-file sieve's `file-block` configuration with
   `stable_writes=1` against `0` on two fresh ext4-over-loop filesystems, **not
   on the NVMe directly**; it measures cost, not crash durability. The root
   ext4 mount is the only available ext4 and stable writes are read at mount,
   so the script leaves its queue unchanged: it fully writes two private
   2 GiB images in `/var/tmp`, attaches loops with direct IO, verifies each
   loop's backing path before formatting, and sets each loop's queue before
   `mkfs.ext4` and mounting under `/mnt`. Formatting disables discard and lazy
   inode-table/journal initialization. After one discarded warm-up campaign on
   each mount, four measured pairs run in balanced ABBA order twice (1, 0, 0, 1,
   1, 0, 0, 1), as the owner. Each campaign uses five rounds, 256 x 4096, eight
   warm-up steps, and CPU 2 by default. This is intended to finish within 30
   minutes, with a 24-minute deadline covering warm-up and measured campaigns.
   Build it as yourself first (`make bin/pwsievebench.x86-64-linux`); the
   script only checks with `make -q` that it is current, then hashes it;
   campaigns must preserve that hash and remain current. Results include
   queue/mount facts, per-campaign `/proc/vmstat` snapshots and deltas (including
   `nr_dirtied` and `nr_written`), and `/proc/sys/vm/dirty_*`. Any exposed named
   stable-page/writeback-wait counters are included; absent counters are
   reported. **Read a null result with those counters and dirty settings:**
   stable pages add a wait only when a store hits a page under writeback.
   `fdatasync` waits for writeback, so this single-threaded 1 MiB sieve relies
   on background writeback (normally `dirty_expire_centisecs=3000`) to overlap
   stores. Near-zero cost may mean no stable-page waits occurred. The vmstat
   counters are system-wide, so unrelated activity also contributes.
   INT, TERM and HUP stop and wait for the campaign before cleanup attempts to
   unmount, detach and remove private resources. Busy or failed resources are
   retained and recorded in `cleanup.txt`; interrupted loop attachments are
   rediscovered by backing image. This requires writable loop
   `queue/stable_writes` support and refuses if setting it fails. Run
   2026-10-21: a median +3.0 % on the sieve step, with no stable-page wait
   shown ([below](#stable-writes-on-the-sieve-about-3--with-no-stable-page-wait-shown)).
4. **The A/B under `performance`**, to compare with the 86 % directly:
   `echo performance | sudo tee /sys/devices/system/cpu/cpu2/cpufreq/scaling_governor`,
   then the campaigns above, then set it back to `powersave`. Done for the
   sieve on 2026-10-15, on a P-core and an E-core
   ([above](#do-the-quoted-sieve-figures-change)), with every CPU's governor
   set; pwbench and pwopsbench have not been rerun.
5. **Magpie's block stack, for B2.** `scripts/magpie-root-checks.sh` now also
   records, read-only, `dmsetup table` and `dmsetup info -c` (is `/home`'s LVM
   volume `linear` and unencrypted, so that no layer copies pages with the
   CPU?), `lsblk`, the dm uuids and every block device's `queue/stable_writes`,
   in `block-stack.txt` and a line of `summary.txt`:
   `sudo env PWROOT_USER=u7599095 <checkout>/scripts/magpie-root-checks.sh`.
   Run 2026-10-16: `linear`, unencrypted, and no device requests stable writes
   ([below](#b2-on-magpie)).
6. **Magpie's core clock on block storage (2026-10-15).** The same script's
   section 5 is the intervention the clock probe could not make on Magpie
   ([below](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence)): probed sieve runs
   (`file` and `direct`) and a B+Tree run (`file`) on `/home`, pinned to CPU 2,
   interleaved between that CPU's idle states as they are and C1E and C6
   disabled on it alone (restored after each run), under `turbostat` (busy
   clock and idle-state residency) and `perf stat` (cycles over reference
   cycles, instructions). If the 1.0 GHz after a boundary is C1E, the default
   runs show C1E residency and the probe's drop goes away with C1E off; the
   B+Tree's clock is then measured rather than inferred. On this model
   intel_idle switches off the hardware's own promotion of C1 to C1E
   (`disable_promotion_to_c1e` for Skylake-X, which covers Cascade Lake), so
   the disabled state is enough. Results in `clock-*.log`, `.turbostat`,
   `.perf` and a block of `summary.txt`. Run 2026-10-16: the drop is the idle
   states, and the B+Tree's core runs at about 1.0 GHz either way
   ([below](#the-clock-after-a-blocking-boundary-is-the-idle-states)).

## Magpie's root sitting (2026-10-16)

A Magpie administrator ran `scripts/magpie-root-checks.sh` with sudo on
2026-10-16, for `u7599095` (`results/20261016T004310Z-magpie-root-checks`;
script and benchmarks at `49812234`, kernel 6.8.0-137). It answers follow-ups 5
and 6 above, and the three questions the rest of this page left for root: what
acknowledges a write on `/home`, whether `fdatasync` on DAX writes back whole
2 MiB entries, and which idle state a core enters after a blocking boundary.
Every figure below is from the files in that directory; the sieve's shares are
its persistence phases over wall time per step, as in every sieve campaign.

### What acknowledges a write on `/home`

**The controller passes `sda` through.** PERCCLI (`controller.txt`) reports a
Dell PERC H740P Adapter (Broadcom's SAS3508 under Dell's subsystem ID, so the
same card the rest of this page calls a MegaRAID SAS3508), firmware
5.130.00-3337, in the **eHBA** personality, with **no virtual drive
configured**. All three drives are online as non-RAID (JBOD) disks. Slot 0 is a
Seagate Exos 7E8 `ST1000NM004A`: 1 TB, 7,200 rpm, SATA, 512-byte sectors.
`smartctl` reads the same serial number through the controller and from
`/dev/sda`, so `sda` is that drive. The other two are an 8 TB Seagate disk and a
960 GB Toshiba SAS SSD. `/home` is a `linear` LVM volume on `sda3`
(`block-stack.txt`).

**Every cache the reports show is off or battery-backed.** All three drives'
own write caches are `Disabled`, in PERCCLI and in `smartctl`'s reading of each
drive. The controller has a battery (`BBU`, state `Optimal`, 98–99 % charge, no
replacement required) and no CacheVault. Dell documents write-through as the
only cache policy for non-RAID disks
([PERC 10 User's Guide, "Non-RAID disk"](https://www.dell.com/support/manuals/en-ae/perc-h745/perc10_ug/non-raid-disk?guid=guid-1fedc318-388d-41c2-b90e-d36a304ff232&lang=en-us)),
so on Dell's account the controller's cache is not in `/home`'s path. `sdparm`
is not installed on Magpie, so the cache bit the controller presents to Linux
was not read directly; Linux reports it as `write through`.

**`fdatasync` sends no flush.** With `block:block_rq_issue` traced during
pwbench (2 MiB, 8 entries, 2,000 commits after 200 warm-up), each backend
issued 2,211 requests to `sda`, every one `WS` (a synchronous write), none
flagged as a flush or FUA. The inference from `fdatasync`'s ~1.7 µs
([above](#cost-the-same-seam-call-a-different-persistence-point)) is now
observed: a write-through device is sent no flush, and the write carries the
boundary.

**Yet each write is acknowledged before the platter can have it.** 2,199 of each
backend's 2,211 requests are the same 8 KiB at sector 1,553,156,104, one per
boundary: the two adjacent 4 KiB units a boundary writes, coalesced as before. Each
is issued a median 210 µs after the one before (p10 201, p90 237 µs; the file
backend 214 µs), and the boundary's median is 177.3 µs (file 171.7 µs). A
7,200 rpm disc turns once every 8.3 ms, and a sector just written has to come
round again before it can be rewritten, so a rewrite that reached the platter
would take about 8 ms, some 47 times the boundary. Something below Linux
acknowledges the write before the platter has it, and none of the reports names
it. Two candidates, both untested:

- **A non-volatile cache inside the drive** that its write-cache setting does not
  govern, such as an on-disc media cache. A 2015 SNIA presentation describes
  such caches as giving "write cache enabled performance with the data security
  of write cache disabled", and says the new ones are "embedded in the base
  product and very likely cannot be disabled"
  ([*Cache Assist in Hard Drives*, slides 5 and 7](https://snia.org/sites/default/files/emerald/EPA_Storage_Stakeholders_Nov-2015/Cache_Assist.pdf)).
  Nothing here shows that this model has one.
- **The controller caching non-RAID writes** despite the documented policy. Its
  cache is battery-backed.

Either would survive a power cut. One that would not, a volatile cache in the
drive that ignores its own `Disabled` setting, is not ruled out by anything
here. So **whether `/home`'s acknowledgements are power-safe is still not
established**, but the question has moved: the controller's configuration is
now known, and what is open is what this drive does with a write its own cache
setting says it does not cache. Seagate's documentation for the model is the
cheap next step; a power cut is not available on Magpie (Stage 3 in
`ROADMAP.md`).

**What this changes on this page.** "A RAID controller's acknowledgement" was
the right reading of what Linux could see, but the controller is not acting as
a RAID controller for `/home`, and on Dell's account its cache is not involved.
Every `file-block` and `direct-block` figure on Magpie is the latency to an
acknowledgement given before the platter is written, by a component not yet
identified. The controller's cache changing state between sittings is no
longer a candidate for
[the two block-media regimes](#the-block-media-configuration-is-not-a-controlled-measurement-here).

A side observation: the two traced runs' region files, each created and removed
in turn, occupied the same sectors. That is the premise of the untested
sticky-placement candidate for those regimes
([below](#region-size-at-fixed-block-size-and-the-numa-penalty-at-1-mib)); one
observation shows that reuse happens, not that it selects the regime.

### `fdatasync` on DAX writes back whole 2 MiB entries: observed

`fs_dax:dax_writeback_one` traced during pwbench on `/mnt/pmem0.0/sean`, file
backend, 8 entries, 200 commits after 20 warm-up, so 220 commits a run:

| Region | Events | `pglen` | `pgoff` | Events per commit |
|---|---|---|---|---|
| 2 MiB (512 × 4096) | 226 | every one `0x200` (512 pages: one 2 MiB entry) | every one 0 | 1.03 |
| 1 MiB (512 × 2048) | 456 | every one `0x1` (one 4 KiB page) | 225 at page 0, 221 at page 1, 10 at pages 250–255 | 2.07 |

This is [the region-size mechanism's](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries)
prediction exactly. At 2 MiB every `fdatasync` writes back the whole entry the
region's first 2 MiB sits under; at 1 MiB, where the kernel uses 4 KiB entries,
it writes back the two dirtied pages and nothing else. The mechanism is now
observed in the kernel rather than inferred from timing. The ten events at
pages 250–255 come one to three times a run, not per commit.

The runs were not pinned. They ran on CPU 87, which turbostat lists in package
1, and the namespace is on node 0; the 2 MiB boundary's median, 1,146.4 µs,
matches the cross-socket figure at 8 entries (1,145.5 µs,
[below](#region-size-at-fixed-block-size-and-the-numa-penalty-at-1-mib)), and
the 1 MiB one is 10.2 µs. Both ran under tracing, so neither is for comparison.

### B2 on Magpie

`/home` is `dm-2`, one `linear` target on `sda3` (8:3). All three of Magpie's
device-mapper volumes are `linear`, with `LVM-` uuids and none `CRYPT-`. No
block device on the host has `queue/stable_writes` set: not `sda`, not `dm-2`,
not the NVMe drives or the pmem devices. So no layer copies a page with the
CPU, and none holds a page stable while it is written. B2 holds by
construction on Magpie no more than on sean-tan-PC's NVMe, and the file
backend's restriction on `/home` rests on the platform's DMA read granularity
there too
([PMEM Crash Model](pmem-crash-model.md#the-file-backend-is-a-restriction-of-the-pmem-model-on-block-storage-only-conditionally)).

### The clock after a blocking boundary is the idle states

Section 5 of the script ran probed sieve steps (`file` and `direct`, 256 × 4096,
20 rounds of 159 measured steps, the geometry of every earlier Magpie sieve
campaign) and a B+Tree run (`file`) on `/home`, pinned to CPU 2. Each ran twice,
interleaving CPU 2's idle states as they are (POLL, C1, C1E and C6, all
enabled, with exit latencies 0, 2, 10 and 133 µs) with C1E and C6 disabled on
that CPU alone. Per sieve step, each repetition, in µs, with the probe's own
time removed as in
[the clock campaign](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence):

| Backend | Idle states | Wall per step | Compute | Persistence phases | Share | Clock after the sieve; after each boundary | C1E; C6 residency |
|---|---|---|---|---|---|---|---|
| `file` | as they are | 2,452.2 / 2,491.4 | 1,067.6 / 1,071.2 | 1,384.3 / 1,419.9 | 56.5 / 57.0 % | 1,678–1,775 MHz; 986–987 MHz | 22.6–22.7 %; 10.5–10.8 % |
| `file` | C1E, C6 off | 1,603.6 / 1,604.6 | 448.5 / 448.3 | 1,155.0 / 1,156.2 | 72.0 / 72.1 % | 3,356–3,452 MHz at every mark | 0; 0 (C1 49.9 %) |
| `direct` | as they are | 2,571.3 / 2,561.5 | 1,112.9 / 1,107.2 | 1,458.1 / 1,454.0 | 56.7 / 56.8 % | 1,677–1,678 MHz; 986–987 MHz | 22.4–22.9 %; 15.8–16.4 % |
| `direct` | C1E, C6 off | 1,790.7 / 1,780.6 | 504.3 / 503.1 | 1,286.3 / 1,277.4 | 71.8 / 71.7 % | 3,153–3,156 MHz at every mark | 0; 0 (C1 54.7–55.0 %) |

The busy reference is 3,552 MHz in every run. One `file` run's publish mark
read 1,479 MHz; every other boundary mark with the states enabled read
986–987 MHz.

- **The 1.0 GHz after a boundary is the idle states.** With them as they are,
  the probe reproduces the clock campaign of 2026-09-29: 1.0 GHz after every
  boundary and 1.7–1.8 GHz at the end of the sieve, against 3.55 GHz busy, while
  turbostat puts the core in C1E for 22–23 % of the run and C6 for 11–16 %.
  With C1E and C6 disabled on that core and nothing else changed, the clock
  reads 3.15–3.45 GHz at every mark, 89–97 % of busy, and the core idles in C1
  instead. This is established by intervention, as the governor established it
  on Raptor Lake. C1E and C6 were disabled together, so which of the two lowers
  the clock is not separated.
- **The computation comes back almost to PMEM's.** It is 448 µs (`file`) and
  503–504 µs (`direct`) against 1,068–1,113 µs with the states enabled; on PMEM
  the same geometry computes for 426.2 µs (`20261014T025706Z`, another
  sitting). Part of the remaining 5 % and 18 % is the clock, still 3–11 %
  under the busy reference; the rest is not separated.
- **The persistence phases shrink too**, by 17–19 % (`file`) and 12 % (`direct`).
  Part of each boundary is CPU work, the kernel's included, and it ran at
  1.0 GHz as well. That is an inference: the phases are not split into CPU and
  device time.
- **A step costs 30–36 % less, and the share rises from 57 % to 72 %.** The
  clock campaign's conclusion, that on block storage the measured share
  understates what durability costs a program, now has a size. With the states
  enabled the `file` step spends 1,068–1,071 µs computing what takes 448 µs
  without them (`direct`: 1,107–1,113 against 503–504 µs), and the ~600 µs
  between is caused by blocking in the boundaries but counted as computation. Counting it with the persistence phases gives 80–82 % of the
  step on both backends against the measured 57 %. That is an attribution, not
  a measurement: it assumes the idle states are the only difference in the
  computation.
- **The setting is the host's, not the program's.** Every other Magpie figure
  on this page ran with all idle states enabled, so a block-storage share there
  is a property of the host's power configuration as well as of the workload.
- **Disabling the states does not hold the clock up after a longer idle.** The
  250 µs sleep reference still reads 1,972–1,973 MHz as its median with C1E and
  C6 disabled, and 986 MHz at its p90: a core idle in C1 for 250 µs sometimes
  comes back at the lowest clock all the same. Something besides the idle state
  lowers the clock, which fits the B+Tree below.

### The B+Tree's clock

The B+Tree run (`file`; each round loads 5,000 keys and then runs 5,000
operations, half lookups and half updates; three rounds after one audited,
seed 1) measures the clock
under [its computation on `/home`](#a-second-workload-what-a-btree-mutation-costs-2026-10-14),
which had been inferred:

| Idle states | Busy clock (turbostat; perf) | Busy | C1; C1E; C6 | Insert median | Update median | Compute per mutation | Lookup median |
|---|---|---|---|---|---|---|---|
| as they are | 1,006; 1,002 MHz | 37.3 % | 0.2; 46.0–46.3; 17.9–18.2 % | 2,190.4 / 2,195.5 µs | 2,252.2 / 2,257.9 µs | 13.5–13.6 µs | 1,368–1,371 ns |
| C1E, C6 off | 1,026–1,027; 1,022–1,024 MHz | 36.4–36.6 % | 70.6–70.7; 0; 0 % | 2,179.2 / 2,175.5 µs | 2,250.2 / 2,247.3 µs | 13.5 µs | 1,340–1,357 ns |

- **The core runs at about 1.0 GHz either way.** Disabling C1E and C6 moves its
  busy clock by 2 %, the insert and update medians by under 1 % and the lookup
  medians by 0.8 % and 2.3 % (1,371 / 1,368 ns against 1,340 / 1,357 ns,
  `clock-btree-file-{default,shallow}-r{1,2}.log`), and the
  computation per mutation stays at 13.5–13.6 µs (13.3–13.5 µs in the campaign
  of 2026-10-14) against 5.2–5.6 µs on PMEM. So the B+Tree's slower computation
  on `/home` fits a 1.0 GHz clock, but not the idle-state exit that slows the
  sieve.
- **What holds it there is not explained.** Magpie has no cpufreq driver, so the
  platform chooses the frequency. One untested candidate is a
  utilisation-driven policy in the platform: the B+Tree's core is busy 36–37 %
  of its run against the sieve's 46–52 % with the same states disabled, and the
  sleep reference shows the clock falling without C1E or C6.

### What the sitting leaves open

- What acknowledges a write on `/home` before the platter, and whether it is
  power-safe.
- Which of C1E and C6 lowers the clock after a boundary, and why the B+Tree's
  core stays at 1.0 GHz with both disabled.
- The script restores C1E and C6 after every run and on exit, but records CPU
  2's idle states only before section 5. `cat
  /sys/devices/system/cpu/cpu2/cpuidle/state*/disable` (no root) shows whether
  they are back on; recording them after the runs too is a one-line change to
  the script.
- Two repetitions per condition. Each pair agrees to within 1.6 % on wall time
  per step.

## sean-tan-PC's root checks (2026-10-21)

Sean ran the desktop's three
[follow-ups that need root](#follow-ups-that-need-root) with sudo on
2026-10-21, on kernel 7.0.0-38, each binary built by the owner first and
current under `make -q`: the flush trace (`scripts/desktop-root-checks.sh`,
`results/20261021T040954Z-sean-tan-PC-desktop-root-checks`) and the
stable-writes A/B (`scripts/desktop-stable-writes.sh`,
`results/20261021T041120Z-sean-tan-PC-desktop-stable-writes`), both at
`dd0c1cc5`, and the kernel reset (`scripts/desktop-reboot-check.sh`, over SSH,
at `b369a1de`: `results/20261021T054239Z-sean-tan-PC-desktop-reboot-ordinary-9eopfe`
and `results/20261021T054626Z-sean-tan-PC-desktop-reboot-elide-clwb-BExf3S`).
`b369a1de` changed only docs and results after `dd0c1cc5`. Every figure below
is from those directories. A fourth check, which no follow-up had listed,
failed one write below the file system, on ext4 and XFS
(`scripts/desktop-fsyncfail-check.sh`, at `af6f9680`;
[below](#a-failed-write-below-ext4-and-xfs-the-same-boot-reopen-replays-a-record-the-disk-lacks)).

### `fdatasync` sends the NVMe a cache flush: observed

The root filesystem is ext4 on `nvme1n1p3`, with `data=ordered`, `delalloc`,
`dioread_nolock` and `barrier` in effect (`/proc/fs/ext4/nvme1n1p3/options` in
`block-stack.txt`). The drive reports `write_cache` `write back`, `fua` 1,
`stable_writes` 0 and `atomic_write_unit_max_bytes` 512. With
`block:block_rq_issue` traced on `nvme1n1` during pwbench with Magpie's
parameters (2 MiB, 8 entries, 2,000 measured boundaries after 200 warm-up, one
`fdatasync` each):

| Backend | Requests | Writes (`WS`), all pwbench | Flushes (`FF`) | jbd2 (`WSM`); FUA (`WFSM`) | Strictly alternating write, flush |
|---|---|---|---|---|---|
| `file` | 4,427 | 2,212 | 2,209 | 3; 3 | 2,202 pairs, from the 24th request to the last |
| `direct` | 4,433 | 2,218 | 2,209 | 3; 3 | 2,203 pairs, from the 28th request to the last |

- **Every write is followed by a cache flush before the next sync's writes.**
  From the 24th request (`direct`: the 28th) to the last, the trace strictly
  alternates one pwbench write with one standalone flush (issued from
  `kworker/*:1H` threads): 2,202 pairs (`direct` 2,203), against the run's
  2,200 boundaries. The requests before that, in the run's first 6.1 ms
  (`direct`: 9.1 ms), are setup and the first allocating syncs: groups of one
  to nine writes (on `direct`, the 2 MiB region written whole), each followed
  by a standalone flush or by a jbd2 journal commit, whose journal write is
  followed by a flush and a FUA commit block. No two flushes are adjacent.
  **Inference:** pwbench is single-threaded and a boundary returns only after
  its `fdatasync`, so every boundary's writes were followed by a flush before
  the next boundary began, and in the steady state each boundary sent one
  write, almost always 8 KiB, and one flush of its own. On `direct` the write
  is the boundary's `O_DIRECT` `pwrite`, on `file` the `fdatasync`'s own
  writeback.
- **No boundary in the steady state uses FUA.** The three FUA writes are jbd2's
  journal commit blocks in the first few milliseconds, each after a journal
  write and a flush.
- **The idle windows are empty.** Each run's idle window of the same length
  (0.73 s and 0.71 s, after a sync and a 10 s wait) saw no request to
  `nvme1n1`, so neither trace mixes in the root's journal commits or desktop IO.
- **What this checks.** The filesystem half of B4 on this host, for the syncs
  traced: ext4 follows every `fdatasync`'s writes with a cache flush, as `ext4_sync_file()` →
  `blkdev_issue_flush()` predicts, for the file backend, whose fence is that
  `fdatasync`, and for the direct backend, whose fence writes its marked units
  and then calls it. It shows the requests sent, not that the drive makes a
  flushed write durable: that half of B4, like B3, is what the drive keeps when
  its power fails, which no test here exercises. Magpie's write-through disk is
  sent no flush ([above](#what-acknowledges-a-write-on-home)); this drive, with
  a write-back cache, is sent one after every boundary's writes. The runs were traced, so their
  boundary times (file median 239.3 µs) are not for comparison.

### Stable writes on the sieve: about 3 %, with no stable-page wait shown

The root ext4 is the only ext4 here and stable writes are read at mount, so the
script made two fresh ext4 filesystems on 2 GiB images in `/var/tmp`, each on
a loop device with direct IO (`loop24`, `loop25`), and set one loop's
`stable_writes` to 0 and the other's to 1 before `mkfs.ext4` and mount
(`queue-*-mounted.txt`). Each sample is one `file-block` sieve campaign (256 ×
4096, five rounds of 159 measured steps, the reference sieve checked), pinned
to CPU 2 under `powersave`; one discarded warm-up campaign per mount, then four
pairs in ABBA order twice. Wall time per step, in ns:

| Pair | `stable_writes=0` | `stable_writes=1` | Difference |
|---|---|---|---|
| 1 | 2,601,693 | 2,632,438 | +1.2 % |
| 2 | 2,537,149 | 2,652,631 | +4.6 % |
| 3 | 2,593,308 | 2,588,629 | −0.2 % |
| 4 | 2,460,313 | 2,670,283 | +8.5 % |

The medians are 2,565,228 against 2,642,534 ns, +3.0 %, and the persistence
phases' 1,863,736 against 1,913,426 ns, +2.7 % (`summary.txt`).

- **The cost is small and not resolved.** Three pairs of four are slower with
  stable writes, and the differences span −0.2 to +8.5 %, so four single-run
  pairs do not separate 3 % from the spread. The one-minute load average rose
  from 0.34 to 0.84 across the campaigns, and each setting had its own image and
  loop device, so the setting is confounded with them.
- **No stable-page wait is shown.** `/proc/vmstat` exposes no named
  stable-page or writeback-wait counter (`writeback-counter-availability.txt`).
  A store waits only when it hits a page under writeback, and every fence's
  `fdatasync` already waits for writeback to finish; with
  `dirty_expire_centisecs` 3000 and campaigns starting about 3 s apart,
  background writeback had little chance to overlap the sieve's stores. Each
  campaign dirtied and wrote about 9,000 pages system-wide (`nr_dirtied`,
  `nr_written` in `vmstat-*.delta`) with either setting. **Inference:** few or
  no stores waited, so this prices stable writes for a single-threaded workload
  whose fences wait for writeback, not for one whose stores overlap background
  writeback, and on ext4 over a loop device rather than on the NVMe.
- **Nothing on either host changed.** Neither host's devices request stable
  writes, so B2 still holds by construction on neither.

### A kernel reset separates the file backend's builds

Follow-up 1, run once per provider. `prepare` ran `pwreboot setup` on a fresh
2 MiB region (512 × 4096) in a mapped file under `~/pwfile-reboot` on the root
ext4, two sieve steps, then `sync -f`. `arm` ran three more steps, each
acknowledged by an fsynced state line in `results/`, and wrote `b` to an
inherited `/proc/sysrq-trigger` descriptor straight after the last
acknowledgement's fsync, so the machine reset without syncing. `verify` ran
after the reboot, once, on a copy-preserved image (`region-before-verify.img`):

| Provider | Setup cursor | Acknowledged cursor; primes | Recovery | Durable cursor; primes | Verdict |
|---|---|---|---|---|---|
| ordinary | 65,024 | 162,560; 14,891 | `REPLAYED` | 162,560; 14,891 | `SURVIVED`: "all acknowledged steps are durable and every invariant holds" |
| `elide-clwb` | 65,024 | 162,560; 14,891 | `CLEAN` | 65,024; 6,495 | `LOST`: "every acknowledged step was lost" |

- **The discrimination the kill loop cannot make.** A killed process leaves the
  page cache, so on this backend the ordinary build and the mutant both pass
  the kill loop ([above](#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)).
  A reset discards it: the ordinary build's fences carried all three
  acknowledged steps to the drive, and the mutant, whose fences sync nothing,
  kept only what setup's `sync -f` had made durable.
- **Recovery shows whether the records arrived.** `recover()` replays
  whenever a slot holds a valid record, and records stay in their slots until
  a clean close ([Recovery and close](#recovery-and-close)), so the ordinary
  build's `REPLAYED` says its arm records reached the drive, not that any
  after-image was missing; replaying a durable one is harmless. The mutant's
  `CLEAN` says no valid record did. The raw images hold 7,205 and 5,420
  nonzero bytes. This repeats, through a real reset and the page cache, the
  cursors and recovery outcomes of the direct backend's `pwreboot` pair
  ([above](#crash-behaviour-process-death-is-the-crash)), which ran without a
  reboot; the sieve is deterministic.
- **The drive stayed powered.** `nvme smart-log` read 557 power cycles and 7
  unsafe shutdowns before the first arm, again before the second (after the
  first reset), and after the second reset (`verify-smart-after.txt` of the
  `elide-clwb` run, read before any further boot). The ordinary run has no
  after-reading of its own; the second run's before-reading serves. Each run's boot ID
  changed (`verify-boot.txt` against `arm-before.txt`), and dirty memory before
  arming was 2,056 and 4,700 kB.
- **Limits.** One run per provider, each one cut, straight after the last
  acknowledgement; the reset keeps the drive powered, so this checks the loss
  of the page cache, not of the drive's cache or power. The state file shares
  the root filesystem with the region, so a state fsync could have masked a
  mutant loss only through the conditions in `notes.txt`; the mutant lost
  every step, so none did here.

### A failed write below ext4 and XFS: the same-boot reopen replays a record the disk lacks

Sean ran `scripts/desktop-fsyncfail-check.sh run` with sudo on 2026-10-21, at
`af6f9680`, on kernel 7.0.0-38:
`results/20261021T095453Z-sean-tan-PC-fsyncfail-nNagao` (ext4) and
`results/20261021T100005Z-sean-tan-PC-fsyncfail-rzHcHs` (ext4 again, and XFS
with `mkfs.xfs` 6.18.0). A first attempt,
`results/20261021T080228Z-sean-tan-PC-fsyncfail-diEiwq`, stopped before
arming. `/usr/bin/dd` here is uutils coreutils 0.10.0, whose read buffer is
not 512-byte aligned, so its `O_DIRECT` read of the dm device failed with
`EINVAL` ("IO error: Invalid input"); the loop device needs 512-byte alignment
(`dma_alignment` 511) where the NVMe drive needs 4 (3). The script now reads
with `gnudd`, GNU coreutils 9.7 (`af6f9680`).

**Method.** Each case builds a fresh file system with default options (ext4
mounts `data=ordered`) on a dm device over a loop file (`--direct-io=on`)
under the owner's home on `nvme1n1p3`. It prepares a 2 MiB region (512 ×
4096, two sieve steps, clean close) whose log chunk, at file offset 4096, is
allocated and written. `filefrag` maps the chunk to eight device sectors,
checked against an `O_DIRECT` read of the file. One `pwreboot fault-commit`
process mounts the region, then commits one transaction while the dm table
sends those sectors to the `error` target. The transaction is one redo entry
storing a random nonce in an unused word of the sieve's root chunk, at file
offset 12264, on another page. `dm-flakey` was not used: it also fails the
device's empty flushes, which aborts the journal, Rebello et al.'s Table 1,
Q8–Q9, a different case. The script then restores the linear table, compares
the log chunk read through the page cache with an `O_DIRECT` read, lets the
process abandon the latched mount and reopen it in the same boot, and compares
again. Last, it unmounts and remounts the file system, which drops the file's
pages, and runs `fault-verify`. The direct-I/O backend runs the same steps as
the control.

| Case | `commit()` | Latched | Same-boot recovery; nonce | Log chunk, cache vs device | After remount: recovery; nonce | Verdict | FS |
|---|---|---|---|---|---|---|---|
| ext4, file (2 runs) | 0 | yes | `REPLAYED`; present | differ; nonce in the cache only | `CLEAN`; present | `CONSISTENT` | rw |
| ext4, direct (2 runs) | 0 | yes | `CLEAN`; absent | equal; no nonce | `CLEAN`; absent | `CONSISTENT` | rw |
| XFS, file | 0 | yes | `REPLAYED`; present | differ; nonce in the cache only | `CLEAN`; present | `CONSISTENT` | rw |
| XFS, direct | 0 | yes | `CLEAN`; absent | equal; no nonce | `CLEAN`; absent | `CONSISTENT` | rw |

- **The fault hit the log chunk and nothing else.** ext4 logged `I/O error 10
  writing to inode 14 starting block 33281`, sector 266,248, the chunk; XFS
  logged `writeback error on inode 132, offset 4096, sector 112`. Both stayed
  `rw`, ext4's `errors_count` stayed 0, and XFS's remount reported "Ending
  clean mount", so this is a failed data write, not a journal failure.
- **Both file systems kept the failed record in a clean page, and the reopen
  read it.** That is what Rebello et al. found for ext4 and XFS on Linux 5.2
  (Table 1, Q4–Q5), seen again on 7.0. The reopened `FileMmapRegion` maps the
  same file, so it read the record from the page cache, and recovery replayed
  it. The page stayed clean and nothing rewrote it: after the remount the
  device's log chunk is byte for byte the pre-commit chunk, SHA-256
  `806427bd…` in every case, the controls' included.
- **The disk then holds the transaction's data without its record.** Replay
  stored the nonce into its own page, outside the failed sectors, and
  recovery's `persistChanges()` wrote that page through the restored device.
  After the remount `recover()` returns `CLEAN` with the nonce present. The
  data became durable and its record never did, the reverse of write-ahead
  order, and the contract's "`recover() == CLEAN` resolves the attempted
  transaction as absent" fails for this backend after a same-boot reopen
  ([Persistence-failure contract](#persistence-failure-contract)). The
  invariants hold here because the transaction is one word.
- **The direct-I/O backend is not affected by this failure.** Its `create()`
  reads the region through `O_DIRECT`, so the reopen saw the device's copy, no
  record, and replayed nothing.
- *Inference:* with after-images on several pages, a crash during the replay's
  write-back would leave part of the transaction durable and no durable record
  to finish it, so failure atomicity is lost too, not only the transaction's
  outcome. Not tested.
- *Inference:* XFS's ten `Buffer I/O error … async page read` lines on sectors
  112–119, just before its writeback error, are buffered reads of the dm
  device, most likely udev's probe after the table change, which reads near
  the device's start, where XFS placed the chunk. The script's own reads use
  `O_DIRECT`. They read the block device's cache, not the file's, so the
  result does not depend on them.
- **Limits.** ext4 twice and XFS once (three times and twice with the repeat
  below); one transient write error, since the device works again before the
  reopen, as in the paper's one failed write; 4 KiB blocks; a one-word
  transaction after a clean close. The longer histories below add two
  acknowledged transactions before the failure, 8 KiB blocks and two-word
  transactions. A lasting error would also fail recovery's
  own boundary, which latches again. For the direct backend, a completed write
  followed by a failed device flush remains untested.

#### Two longer histories: an acknowledged write lost, an unacknowledged one torn

Sean ran `run` again on 2026-10-21 at `bd23bd4f`, on kernel 7.0.0-38:
`results/20261021T105823Z-sean-tan-PC-fsyncfail-Px6IUW`, three scenarios on
ext4 and XFS with both backends, twelve cases. `single` repeated the table
above, ext4's third run and XFS's second. The two new scenarios start from two
acknowledged transactions whose records fill both slots: `fault-prepare`
commits N-2 = 1 (word M = A) and N-1 = 2 (M = B), makes their data durable
with `flush()`, which scrubs no slot, and exits without a clean close. The
error target then covers only the 4 KiB page holding slot N mod 2. The
per-case `dmesg.txt` files are incomplete: the script found its window by
counting ring-buffer lines, which shift once the buffer wraps.
`kernel-journal.txt`, read from the journal afterwards, has every message, and
the script now selects the window by timestamp.

| Scenario | Blocks | History | File backend, ext4 and XFS | Direct backend, ext4 and XFS |
|---|---|---|---|---|
| `stale-slot` | 8 KiB: the slots on different pages | commit N (M = C) fails; same-boot reopen; one more commit, "next" (M2 = D), acknowledged; umount and mount | `LOST`: "M holds N-2's value A: the acknowledged N-1's write is undone" | `CONSISTENT` |
| `tear` | 4 KiB: both slots on one page | commit N (M = C, Z = E) fails; same-boot reopen; umount and mount | `TORN`: "N (unacknowledged) is partly present: its Z = E is durable and its M = C is undone" | `CONSISTENT` |

- **Every fault hit its page.** The journal has ext4's `I/O error 10 writing
  to inode 14 starting block 33283` (stale-slot, slot 1's page) and `… block
  33281` (tear), and XFS's `writeback error on inode 132, offset 12288, sector
  120` and `… offset 4096, sector 112`. Every file system stayed `rw`, ext4's
  `errors_count` stayed 0 and every XFS mount ended clean. The allocator's and
  the sieve's invariants held in all twelve cases.
- **Stale slot: how an acknowledged write is lost.** The log comparisons give
  the record sequences in slots 0 and 1. After the failed commit the page
  cache held (2, 3) and the device (2, 1). The same-boot reopen replayed record
  3 from the cache, so "next" became sequence 4 and went to slot 0: cache
  (4, 3), device (4, 1). Nothing wrote slot 1's page again, so after next's
  boundary the device still held the stale record N-2 there. After the remount
  recovery replayed 1 and then 4, which put N-2's value back over the
  acknowledged N-1's write. On the direct backend the reopen read (2, 1) from
  the device, "next" became 3 and overwrote the stale slot, and nothing was
  lost.
- **Tear: how an unacknowledged transaction splits.** The failed page held both
  slots, so the device kept (2, 1). The same-boot replay of N made both of N's
  words durable through recovery's boundary. After the remount recovery
  replayed 1 and 2, which restored M to N-1's value but left Z, which neither
  touches, at N's: N is partly present, which the contract allows neither as
  absent nor as replayed. No crash was needed, unlike the inference above
  about a crash during the replay's write-back.
- **Which configurations are exposed.** At 4 KiB blocks both slots share a
  page, the tear case. From 8 KiB up they sit on different pages (`slotBytes`,
  [Active on-region layout](#active-on-region-layout)), the stale-slot case,
  which includes the platform wrappers' default 512 KiB block
  ([`PWRegionHeader`](#pwregionheader-88-bytes-stored-at-offset-0)). Both need
  a failed write on the file backend over ext4 or XFS and a reopen in the same
  boot; a crash alone does not produce them.
- *Inference:* replay's idempotence does not help, since what recovery replays
  is chosen from slots whose device copy no longer matches the cache; and no
  structural check after one crash flags either outcome, since the invariants
  hold.
- **Not fixed** ([Open Issues](ROADMAP.md#open-issues), #7). Options, none
  built: recovery reads the log through `O_DIRECT` and refuses to mount when it
  differs from the mapping, as the direct backend in effect does (Rebello et
  al., §5 #8); a failed boundary on this backend requires the page cache gone,
  as after a reboot, before the reopen; or recovery stores each record it
  validates back into its slot before replaying, so that the page is written
  again (§5 #7), at one more boundary per recovery.

### What the checks leave open

- Repeats of the kernel reset, and cuts other than straight after an
  acknowledgement.
- Repeats of the failed-write runs (`single` three times on ext4 and twice on
  XFS, the two longer histories once each), a lasting error, transactions whose
  after-images span more pages, and, for the direct backend, a failed flush
  after a completed write.
- Whether the drive keeps a flushed write through a power failure: B3 and B4's
  device half.
- What stable writes cost when background writeback overlaps a program's
  stores.

---

## Persistence-boundary cost (measured 2026-09-18, Magpie)

Phase B's design note justified its per-commit data flush as "cheap fences —
acceptable". Measured across five campaigns on one host: three unpinned, and one
pinned to each NUMA node. All raw logs, CSVs and provenance are in `results/`.

Three configurations, so the boundary primitive and the media are separable.
`pwbench` drives 20,000 commits of 8 aligned `u64` redo entries each through the
production path, after 2,000 warm-up commits, at 512 × 4096 = 2 MiB.

**Every figure for configuration 2 below is conditional on that geometry.** A
2 MiB region on this namespace is mapped with a single 2 MiB DAX entry, and
`fdatasync` flushes the whole entry; at 1 MiB the same boundary costs ~5 µs,
not 927 µs. See [Region size](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries)
and [Matched geometry](#matched-geometry-all-three-configurations-at-1-mib-and-2-mib)
(both measured 2026-09-23), which supersede the media reading of the
comparisons that follow.

| # | Backend | Media | Boundary | Median boundary | Per commit | Boundary share |
|---|---|---|---|---|---|---|
| 1 | `pmem` | DAX `/mnt/pmem0.0` | `CLWB` loop + `SFENCE` | **`SFENCE` 11 ns** (26 cycles) | 13.7 µs | 3.3 % |
| 2 | `file` | DAX `/mnt/pmem0.0` | `fdatasync` | **927 µs local / 1,147 µs cross-socket** | 939–1,160 µs | 98.8 % |
| 3 | `file` | ext4 on LVM, `/home` | `fdatasync` | **133–181 µs** (see caveat) | 188–240 µs | 71–86 % |

**The PMEM boundary share is a timing-window figure (2026-09-28).** It counts
the cycles inside `rdtsc`-bracketed `CLWB` calls, which is not what the
writebacks cost the commit: at eight entries that is about 36 %, not 3.3 %. See
[`CLWB` evicts on Cascade Lake](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows).

**Configuration 3 is not a disk (established 2026-09-27).** `/home` is LVM on
`sda`, behind a MegaRAID SAS3508 that reports `write through`: `fdatasync`
sends no flush, and the figure is the latency to the controller's
acknowledgement. See [the direct-I/O backend](#cost-the-same-seam-call-a-different-persistence-point).

Figures are medians over the runs of each configuration in `results/`
(five campaigns × three repetitions × four transaction sizes), at 8 entries
except where a size is named. Configuration 2's two values are socket-local and
cross-socket; configuration 3 has not reproduced between sittings. Both are
explained below.

All three measured **exactly 1.000 persistence boundaries per commit**, which is
phase B's steady-state claim confirmed on hardware in three configurations
rather than on a counting stub.

### The fences are cheap; they are also not where the cost is

An `SFENCE` costs 11 ns, so the design note's claim holds. But on PMEM the
boundary's *prepare* side — the `CLWB` loop, 14 cache lines per commit at eight
entries — costs about 20.4 M cycles against the fence's 0.52 M, **39× more**.
The expensive half of a PMEM boundary is the cache-line writeback, not the
fence. The note is correct and argues for the wrong reason. (2026-09-28: the
writeback costs the commit far more than these prepare cycles, and most of it
lands outside the timed window; see
[`CLWB` evicts on Cascade Lake](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows).)

### Isolating the two variables

- **Primitive, media held constant (1 vs 2).** A whole PMEM boundary is 453 ns
  per commit at eight entries; `fdatasync` on the *same DAX filesystem* costs
  927 µs in its low mode. **≈ 2,000×.** This is the cleanest statement of what
  the unified interface hides: identical media, identical workload, identical
  geometry, one interface, three orders of magnitude. The geometry matters: at a
  1 MiB region `fdatasync` on DAX is 5.0 µs while the PMEM boundary is
  unchanged, so the gap is **11×** at eight entries — one order of magnitude,
  not three.
- **Media, primitive held constant (2 vs 3).** At 2 MiB, `fdatasync` on DAX is
  **4.7× to 7.1× slower** than on ordinary block storage: 927 µs socket-local
  against a block figure that has ranged from 131 to 196 µs between sittings.
  The span is the block measurement's instability, not a property of the media.
  DAX is slower in every one of the 60 block runs — but every one of them used a
  2 MiB region. **The comparison does not isolate the media**: the DAX side's
  cost is set by the kernel's 2 MiB flush granularity. At a matched 1 MiB
  region in one campaign the direction reverses: DAX is **31–33× faster**
  (5.0 µs against 157–169 µs). See below.
- **Deployment (1 vs 3).** 453 ns against 133 µs, ≈ 295×.

### The file backend on DAX pays the kernel's flush granularity

The surprise is configuration 2. At the 2 MiB geometry every campaign used,
putting the file backend on DAX media is *slower* than putting it on an
ordinary block device — between 4.7× and 7.1× — while also forgoing the
`SFENCE` path entirely. This page originally called that "the worst of both
worlds" and attributed it to the media. **The region-size sweep below shows the
cause is how the kernel maps and flushes a DAX file, not the device**: with a
2 MiB DAX entry, every `fdatasync` writes back all 32,768 cache lines of it,
however few bytes the commit touched. With 4 KiB entries the same boundary on
the same media is ~5 µs.

This is a separate question from the NUMA bimodality below, which explains the
*two modes within* DAX, not the level of either.

The consequence for the design is sharper than the original reading, not
weaker: **the abstraction must not be allowed to hide what is underneath — and
on DAX, what matters is a mapping decision the backend neither makes nor can
see.** A caller who unified on the file backend "because it works everywhere"
and deployed it on PMEM with a region of 2 MiB or more — the normal case —
would land in configuration 2 and be **69× slower per commit socket-local, or
85× cross-socket**, than configuration 1, on the same hardware, with no error
and no warning. The same code with a 1 MiB region is **1.27× slower** per
commit at eight entries, and at 24 entries it is *faster* than the PMEM
backend. That is the cost of unification stated as a number, and the number
depends on region geometry.

### Region size: `fdatasync` on DAX flushes whole 2 MiB entries

Measured 2026-09-23 on Magpie (`results/20260923T032952Z-magpie-regionsize`):
configuration 2 only, 8 entries, pinned to node 0, three repetitions per size.
pwbench's region is always 512 blocks, so its `blockSize` argument sets the
region size.

| Region | `blockSize` | Median boundary (3 runs) |
|---|---|---|
| 1 MiB | 2048 | **5,094 / 4,940 / 4,966 ns** |
| 2 MiB | 4096 | 927,370 / 925,718 / 928,089 ns |
| 4 MiB | 8192 | 928,583 / 926,620 / 924,790 ns |
| 8 MiB | 16384 | 926,124 / 928,610 / 928,170 ns |

The sweep was designed to separate three explanations for the 927 µs, and it
rejects two of them:

- **A fixed per-call cost** (journal commit, device flush) predicts ~927 µs at
  1 MiB. The measured cost is **~187× lower**, so at most ~5 µs of the 927 µs
  is per-call.
- **A cost proportional to the mapping** predicts ~1.85 ms at 4 MiB and ~3.7 ms
  at 8 MiB. The cost is **flat from 2 MiB to 8 MiB to within 0.5 %**.
- **Flushing whole 2 MiB DAX entries** predicts exactly this shape. A 1 MiB
  file cannot be mapped with a 2 MiB entry, so the kernel falls back to 4 KiB
  entries and writes back only the few dirty pages. At 2 MiB and above, the
  file's extents let the kernel use 2 MiB entries (`filefrag`: all five extents
  observed are 512 blocks long and start on a multiple of 512 blocks). Every
  per-commit write — the WAL slot in block 1, and the scratch chunk, which a
  split allocation takes from the front of the free space at block 2 — lands
  in the first 2 MiB, so one entry is dirtied per commit regardless of region
  size, and `fdatasync` writes back all of it.

The arithmetic agrees: 927 µs over 32,768 lines is 28.3 ns, or 65 cycles, per
line, against 72.0–73.5 cycles per line for the user-space `CLWB` loop measured
on the PMEM backend (an in-window figure rather than a cost, as established
later; the order of magnitude is what the comparison needs). The mechanism also accounts for the earlier findings that
had no explanation: the cost is **flat in transaction size** because the flush
is the whole entry whatever was written, and the NUMA penalty is a **constant
+24 % at every transaction size** because every `fdatasync` runs the same
32,768-line loop over memory on the namespace's socket. The follow-up at 1 MiB
supports this: the cross-socket penalty falls from ~220 µs to ~1 µs, in
proportion to the lines flushed (see [below](#region-size-at-fixed-block-size-and-the-numa-penalty-at-1-mib)).

**What this does and does not establish.** The mechanism was inferred from
timing and file layout. The direct confirmation is the
`fs_dax:dax_writeback_one` tracepoint, whose `pglen` should read 512 (a 2 MiB
entry) at 2 MiB and 1 (a 4 KiB page) at 1 MiB, and it does: in the root sitting
of 2026-10-16 every writeback at 2 MiB was one whole entry, once per commit, and
every one at 1 MiB a single page, twice per commit
([observed](#fdatasync-on-dax-writes-back-whole-2-mib-entries-observed)). The PMEM
backend and block storage at 1 MiB are covered by the matched-geometry campaign
below, and the NUMA penalty at 1 MiB by the follow-up after it. Not yet
measured: the prediction that a commit dirtying *k* separate 2 MiB entries costs about *k* × 927 µs —
pwbench cannot test that yet, because all its writes land in one entry. Large
regions on a 2 MiB-aligned namespace will normally get 2 MiB entries, so the
927 µs figure is the realistic one, and a workload whose commits scatter
across the region could pay a multiple of it.

A side observation from the same `filefrag` output: the 8 MiB region file is
sparse (logical blocks 512–1535 unallocated). `RegionFileIO.create()` zeroes a
fresh region by extending it with `ftruncate`, so storage is allocated on first
touch. Reads see zeros either way, so this is not a correctness issue, but a
workload writing into untouched parts of a large region pays block allocation
at fault time, which none of these measurements exercise.

### Matched geometry: all three configurations at 1 MiB and 2 MiB

Measured 2026-09-23 on Magpie (`results/20260923T043535Z-magpie-bs2048-4096`):
all three configurations at `blockSize` 2048 (1 MiB) and 4096 (2 MiB), 1, 8 and
24 entries, three repetitions, pinned to node 0. The two geometries are
interleaved within each repetition, so any difference between them is not a
difference between sittings — the property the block configuration has lacked.
Every cell's three runs agree to within 0.5 %, and the start-of-run load was
`0.00`. 24 entries replaces 32 and 56 because a 2048-byte block's WAL slot holds
26. Medians of three:

| Configuration | Region | 1 entry | 8 entries | 24 entries |
|---|---|---|---|---|
| `pmem-dax`, whole boundary | 1 MiB | 140 ns | 453 ns | 1,210 ns |
| | 2 MiB | 139 ns | 453 ns | 1,210 ns |
| `file-dax`, `fdatasync` | 1 MiB | **5,125 ns** | **5,024 ns** | **5,047 ns** |
| | 2 MiB | 926,976 ns | 928,659 ns | 927,693 ns |
| `file-block`, `fdatasync` | 1 MiB | 168,573 ns | 157,825 ns | 156,682 ns |
| | 2 MiB | 196,592 ns | 180,504 ns | 170,453 ns |

The PMEM "whole boundary" is `CLWB` prepare plus `SFENCE` per commit; the
`SFENCE` alone is 11–13 ns at both geometries. `CLWB` lines per commit are 4, 14
and 38, matching `ceil((112 + 32n)/64) + n` at the new size too.

Against the predictions made before the run:

- **`file-dax` — held.** 5.0 µs at 1 MiB against 927 µs at 2 MiB, 181–185×,
  flat in transaction size at both geometries. The 1 MiB figure reproduces the
  region-size sweep to 1.2 %.
- **`pmem-dax` — held.** Identical at both geometries to within 1 ns. Its
  boundary is a user-space loop over the lines the commit wrote, so the kernel's
  mapping granularity never enters it.
- **`file-block` — did not hold.** The prediction was no change, since the page
  cache works in 4 KiB pages either way. Instead 1 MiB is **14 %, 13 % and 8 %
  cheaper** at 1, 8 and 24 entries, with no overlap between the geometries in
  any cell. It is not the rate-dependence suggested for this configuration's
  shape: the time between boundaries is the same at both geometries (24.3 and
  24.5 µs outside the boundary at one entry). **This turned out not to be a
  stable geometry effect.** An hour later the 2 MiB figure had moved to another
  regime while the 1 MiB figure had not, and the sign reversed; see
  [below](#region-size-at-fixed-block-size-and-the-numa-penalty-at-1-mib).

**The media comparison at matched geometry.** At 1 MiB, `fdatasync` on DAX is
**31–33× faster** than on block storage; at 2 MiB it is **4.7–5.4× slower**
(7.0× in the later campaign below, where block storage was in its other
regime). Both
are within one campaign on one geometry each, so this is the controlled version
of the comparison the 2026-09-18 campaigns could not make. The earlier finding
that DAX is slower than block storage is **reversed** once the kernel maps the
file with 4 KiB entries, which confirms it was a property of the mapping, not
the media.

**The primitive comparison at matched geometry.** At 1 MiB the PMEM boundary is
37×, 11× and 4.2× cheaper than `fdatasync` on DAX at 1, 8 and 24 entries,
against 6,669×, 2,050× and 767× at 2 MiB.

**Whole commits tell a different story from boundaries.** Wall time per commit:

| Region | Entries | `pmem-dax` | `file-dax` | `file-block` |
|---|---|---|---|---|
| 1 MiB | 1 | 4.5 µs | 12.5 µs | 212 µs |
| | 8 | 13.4 µs | 17.1 µs | 221 µs |
| | 24 | 37.3 µs | **28.9 µs** | 250 µs |
| 2 MiB | 8 | 13.2 µs | 940 µs | 245 µs |

At 1 MiB and eight entries, the file backend on DAX is only **1.27×** slower per
commit than the PMEM backend, against 71× at 2 MiB, and at 24 entries it is
**1.29× faster**. (**Corrected 2026-09-28:** the crossover was the PMEM
backend's per-entry writeback placement, not the media or the primitive. With
the batched apply the PMEM backend commits in 21.6 µs at 24 entries against
29.3 µs for the file backend in the same sitting, and it is faster at every
measured size: 2.8×, 1.8× and 1.4× at 1, 8 and 24 entries
(`20260928T051804Z`). See
[`CLWB` evicts on Cascade Lake](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows).)
The boundary is not the reason. Outside its boundary, a PMEM
commit costs 4.3, 13.0 and 36.1 µs at 1, 8 and 24 entries, against 7.4, 12.0 and
23.8 µs for the file backend at 1 MiB. That is about 1.44 µs per entry against
0.74 µs, on the same media, for the same record-construction code. What makes
the PMEM backend's non-boundary work grow twice as fast was **not established**
when this was written. It is now: `CLWB` evicts on Cascade Lake, and the PMEM
backend writes each after-image back as soon as it is stored, so the next
entry's store into the same line misses. That accounts for about 95 % of the
gap; see
[below](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows).
The candidate first recorded here — that the *next* commit's writes miss — is
not supported. The file backend's extra fixed ~3 µs at one entry is consistent
with re-dirtying write faults after each `fdatasync` write-protects the pages;
the fault counts below now support that.

This refines the earlier "record construction outweighs the boundary by 29×"
finding: record construction dominates the PMEM commit, but above about eight
entries part of that cost is specific to the PMEM backend, because the file
backend runs the same construction code faster. (The 29× itself is superseded
by the section below.)

### `CLWB` evicts on Cascade Lake, and the writebacks cost far more than the boundary shows

Measured 2026-09-28 on Magpie (`results/20260928T001505Z-magpie-clwb-eviction`,
`scripts/clwb-eviction.sh`), pinned to node 0, 1 MiB region (512 × 2048), 1, 8
and 24 entries, three repetitions interleaved, each at 20,000 and 120,000
commits. **There are no hardware counters**: `perf_event_paranoid` is 4 and
the experiment has no root, so every conclusion here rests on timing. The
campaign script's writeback-label check rejected all 18 `pmem-clflushopt` runs
by comparing `clflushopt` against the label `CLFLUSHOPT`. The runs themselves
are valid; `runs.csv` was rebuilt from the logs (`runs.csv.orig` is the
campaign's own) and the check is fixed. Two follow-up campaigns the same day,
same geometry and protocol, test the mechanism:
`results/20260928T022934Z-magpie-clwb-eviction` (stride 64; its deferred rows
are invalid, see below) and `results/20260928T024904Z-magpie-clwb-eviction`
(the deferred rerun, with production and no-writeback controls from the same
sitting). The production configuration reproduced across all three campaigns
to within 0.4 % at 24 entries (37,617, 37,616 and 37,741 ns).

**`CLWB` evicts the line it writes back.** `scripts/clwbprobe.c`, which is
independent of the engine, dirties a line, writes it back, fences, and times
one re-access. Median TSC cycles, three repetitions agreeing within ~4 %:

| | no writeback | `CLWB` | `CLFLUSHOPT` |
|---|---|---|---|
| DRAM load / store | 48 / 48 | 176 / 256 | 176 / 256 |
| PMEM load / store | 32 / 48 | 1,426 / 1,442 | 1,424 / 1,448 |

A line re-accessed after `CLWB` misses exactly as it does after `CLFLUSHOPT`,
which always invalidates: about 620 ns on PMEM.

**The writebacks account for the whole per-entry gap.** pwbench's
`writeback=` argument changes the instruction inside the timing provider;
`none` issues no writeback (timing only, never durable). Wall time per commit,
median of three:

| Entries | `pmem`, `CLWB` | `pmem`, `CLFLUSHOPT` | `pmem`, no writeback | `file` on DAX |
|---|---|---|---|---|
| 1 | 4,414 ns | 4,359 ns | 3,803 ns | 12,586 ns |
| 8 | 13,444 ns | 13,234 ns | 8,661 ns | 17,229 ns |
| 24 | 37,617 ns | 37,258 ns | 21,331 ns | 29,243 ns |
| slope per entry | 1,444 ns | 1,430 ns | 762 ns | 724 ns |

`CLFLUSHOPT` in place of `CLWB` changes the commit by 1–2 %. Removing the
writebacks takes the slope from 1,444 to 762 ns per entry, the file backend's
rate: the writebacks cost **681 ns per entry**, about one PMEM miss each. This
reproduces the 1.44 against 0.74 µs finding above and accounts for it.

**The candidate as first stated is not supported.** It said the *next*
commit's writes miss because the lines were evicted. The file backend's lines
are written back between commits too — `fdatasync` on DAX writes back each
dirty page, with `CLWB` on x86 — yet its slope equals the no-writeback slope,
so a miss on the next commit's stores costs next to nothing per entry
(plausibly because the record is written sequentially and the prefetchers
cover it). What the PMEM backend does and the file backend does not is write
back *within* the commit: `DualTxnWal.applyUpdate()` stores one after-image and
immediately prepares its line, which on PMEM is a `CLWB`, and pwbench's entries
are consecutive u64s. So seven of every eight after-image stores land in a line
the previous entry's writeback has just evicted, a miss nothing can prefetch.
Removing the writebacks cannot tell that apart from their write traffic to
Optane; separating the entries can.

**The within-commit store is the cost.** pwbench's `stride=64` puts each entry
on its own cache line. That keeps the writebacks exactly as they were — 38 per
commit at 24 entries at both strides — and removes every store into a line that
was just written back. `writeback=deferred` instead records each requested line
and writes each distinct line back once, immediately before the fence, which
leaves durability unchanged. Wall time per commit, median of three, all six
from one sitting (`20260928T024904Z`):

| Entries | production, stride 8 | production, stride 64 | deferred, stride 8 | deferred, stride 64 | none, stride 8 | none, stride 64 |
|---|---|---|---|---|---|---|
| 1 | 4,439 ns | 4,434 ns | 4,923 ns | 4,979 ns | 3,791 ns | 3,794 ns |
| 8 | 13,445 ns | 10,472 ns | 9,837 ns | 12,749 ns | 8,696 ns | 8,804 ns |
| 24 | 37,741 ns | 22,609 ns | 24,984 ns | 26,361 ns | 21,501 ns | 21,125 ns |
| slope per entry | 1,448 ns | 790 ns | 872 ns | 930 ns | 770 ns | 754 ns |
| writebacks per commit at 24 | 38 | 38 | 18 | 38 | — | — |

With the same writebacks and no same-line store after one, the excess over no
writeback falls from **678 to 37 ns per entry**. About 95 % of the per-entry cost
is the store into a just-evicted line; the writebacks themselves, with their
write traffic, cost 0.6–1.7 µs per commit at stride 64 (1.5 µs, 7 %, at 24
entries, against 16.2 µs, 43 %, at stride 8). Stride moves the no-writeback
configuration's slope by 2 % and the file backend's by 2 % outside the boundary
(5 % in wall time, `20260928T022934Z`), so it is not a confound.
Per such store the cost is about 775 ns (678 ns over seven stores in eight),
somewhat above the probe's ~620 ns re-access. A plausible reason is that the
store follows its line's writeback by nanoseconds, while the probe fences first;
that is untested.

**Deferring the writebacks to the fence helps only where lines are reused.** At
stride 8, deferral is the fastest durable configuration at 8 and 24 entries,
**27 % and 34 % faster** than production, because it removes the same-line
stores and writes each line back once (18 lines instead of 38 at 24 entries).
But it is 11 % *slower* than production at one entry, and at stride 64, where
there is no reuse to remove, it is 12–22 % slower at every size. What deferral
adds is concentration. The writebacks run back to back just before the fence,
and just before the next commit's after-images store into those same data
lines. The in-window boundary shows the first part: 4.0 µs against 1.3 µs for
production at stride 64, with the same 38 lines. That reading is an
interpretation of timing, not a measurement of the cause.

**What this points to — implemented and measured 2026-09-28.** The better
placement is between the two:
write back each distinct after-image line once, at the end of the apply loop.
That keeps deferral's benefits (no same-line store after a writeback, one
writeback per line) and keeps production's spacing: a whole record
construction separates each writeback from the fence and from the next store to
its line. It predicts production at stride 8 approaching the stride-64 residual
(~1.5 µs at 24 entries rather than 16.2). This is a change to
`RegionTransaction.applyToRegion()` and `DualTxnWal.applyUpdate()`, not to the
benchmark. The crash model permits it — every writeback still precedes the same
fence — but it reorders the recorded `STORE`/`CLWB` events, so the explorer and
trace tests that pin that order need updating and rerunning. The layout
pwbench uses, consecutive u64s, is the benchmark's worst case, but not an
artificial one: any transaction that writes several fields of one line — a
block-table entry, a chunk header — pays the same miss on this CPU. The line
formula above already shows the redundancy: it counts `n` after-image
writebacks for `ceil(n / 8)` distinct lines.

It is now production. `DualTxnWal.storeUpdate()` stores an after-image and
records its extent; `prepareApplied()` sorts the extents and prepares each line
once, merging adjacent lines into one range; `RegionTransaction.applyToRegion()`
stores the whole transaction and then calls it. The obligation is structural,
not the caller's: every boundary that advances `dataDurableSeq` — the commit
point, `persistAppliedData()` and recovery — prepares any extent still
outstanding first. `applyUpdate()` keeps the per-entry behaviour for recovery
replay and for the tests that pin it. Seven unit tests cover the change, among
them a crash-explorer check of a three-transaction batched history against
production recovery: exhaustive over every cut of the batched apply, bounded
over the commit that reclaims its slot. Each of four deliberately broken
variants fails at least one of them: a merged range left unprepared, the
commit's drain removed, `persistAppliedData()`'s drain removed, and the facade
skipping `prepareApplied()`. The full suite passes (2,004 tests). pwbench's
`apply=entry` restored the old placement for the same-sitting comparisons below
and on Raptor Lake; it and `RegionTransaction.perEntryWriteback` were removed
on 2026-09-28 once those were recorded. `scripts/clwb-eviction.sh` still
rebuilds and summarises the `-entry` directories and refuses new `-entry` runs.

**Measured.** `results/20260928T045134Z-magpie-clwb-eviction`, at `380ca7d3`,
same geometry and protocol, all eight configurations in one sitting. Wall time
per commit, median of three:

| Entries | batched, stride 8 | per entry, stride 8 | none, stride 8 | batched, stride 64 | per entry, stride 64 | `file`, batched | `file`, per entry |
|---|---|---|---|---|---|---|---|
| 1 | 4,496 ns | 4,445 ns | 3,819 ns | 4,487 ns | 4,437 ns | 12,635 ns | 12,602 ns |
| 8 | 9,601 ns | 13,530 ns | 8,684 ns | 10,526 ns | 10,360 ns | 17,520 ns | 17,301 ns |
| 24 | 22,083 ns | 37,859 ns | 21,392 ns | 23,426 ns | 22,665 ns | 30,039 ns | 29,321 ns |
| slope per entry | 765 ns | 1,453 ns | 764 ns | 823 ns | 793 ns | 757 ns | 727 ns |

- **The batched apply removes the cost.** At stride 8 it is **29 % and 42 %
  faster** than the per-entry apply at 8 and 24 entries, and its slope equals
  no writeback's (765 against 764 ns per entry). The writebacks now cost
  0.7–0.9 µs per commit, 3 % of a 24-entry commit, against 16.5 µs (43 %)
  before. It beats deferral to the fence at every size (4,496, 9,601 and
  22,083 ns against 4,923, 9,837 and 24,984 ns in `20260928T024904Z`), and the
  per-entry configuration reproduces the earlier production figure (37,859
  against 37,617–37,741 ns).
- **Where there is nothing to coalesce it was slightly slower**, outside every
  repetition's spread: +0.17 and +0.76 µs at stride 64, and +0.22 and +0.72 µs
  on the file backend, at 8 and 24 entries. The same regression on two
  backends that share nothing below the WAL pointed at CPU work, and the
  binary confirmed it. The merge loop's `lineOf()` compiled to a 64-bit `divq`:
  the optimiser rewrites `/ 64` as a shift only for a value it can prove
  non-negative, even for an unsigned type. It ran twice per extent, and every
  extent also went through non-inlined `Vector` accessors. The bookkeeping now
  uses two plain arrays and shifts, and skips the sort when extents arrive in
  address order; the disassembly shows no `divq` and no per-element call on the
  path.
- **Measured with the fix** (`results/20260928T051804Z-magpie-clwb-eviction`,
  at `79473c8b`, same protocol). Wall time per commit, median of three:

  | Entries | batched, stride 8 | per entry, stride 8 | none, stride 8 | batched, stride 64 | per entry, stride 64 | `file`, batched | `file`, per entry |
  |---|---|---|---|---|---|---|---|
  | 1 | 4,472 ns | 4,437 ns | 3,813 ns | 4,459 ns | 4,433 ns | 12,666 ns | 12,588 ns |
  | 8 | 9,412 ns | 13,562 ns | 8,514 ns | 10,426 ns | 10,485 ns | 17,269 ns | 17,304 ns |
  | 24 | 21,639 ns | 37,751 ns | 20,858 ns | 23,086 ns | 22,747 ns | 29,327 ns | 29,451 ns |

  The file backend's regression is gone: at 24 entries the two placements'
  repetitions overlap (29,301–29,466 against 29,285–29,492 ns). Both batched
  PMEM configurations are ~0.5 µs faster at 24 entries than before the fix,
  with and without writebacks, which is the bookkeeping removed. Production
  is now **31 % and 43 % faster** than the per-entry apply at 8 and 24 entries,
  and the writebacks cost 0.66–0.90 µs per commit (3.6 % at 24 entries).
- **What remains is placement, where nothing coalesces.** At stride 64 and 24
  entries the batched apply is still 0.34 µs (1.5 %) slower, outside the
  repetitions' spread (23,047–23,091 against 22,713–22,785 ns); at 8 entries it
  is 0.6 % faster. It is not bookkeeping — the file backend shows none, and at
  stride 64 the batched path does less software work, one merged range where
  the per-entry path makes 24 preparations. It is the 24 writebacks being
  issued back to back after the stores rather than one after each: the
  deferred placement's cost, much reduced. With reuse the batched apply saves
  16 µs of a 24-entry commit; without it, it costs 0.34 µs.
- The in-window boundary at one entry rose from 143 to ~325 ns with the fix,
  in every repetition, while the wall time stayed within 1 % — one more
  instance of that figure not being a cost.
- Allocator transactions store their after-images out of address order: a
  mutant that skips the sort fails the sieve and direct-I/O suites. The sort is
  needed in production, not only in the tests.
- `validEntryFields()` also compiled to three `divq`, and it runs for every
  entry in both `append()` and the apply. That cost is the same in both
  placements, so it took no part in the comparison. **Removed 2026-09-28** (a
  mask for `offset % size`, whose divisor is a checked power of two, and shifts
  for the two `/ 64`); the disassembly shows no `divq`. **It is not a measured
  saving on Raptor Lake** (`results/20260928T092723Z-sean-tan-PC-divq-layout`,
  P-core, pwbench, paired runs). As built, the change made pwbench 1–2 %
  *slower* per commit on both backends (+36 ns at 8 entries, +67 ns at 24,
  every pair): shrinking the function by 24 bytes moved the 2,291 functions
  after it, among them `writeAfterImage`, `noteExtent` and the timing
  provider's `clwb`/`sfence`, which lost their alignment. A control build
  padded back to the old layout, with every function at its old address and
  still no `divq`, is 48–75 ns faster than the fix and 11 ns (0.5 %) faster
  than the original at 8 entries, 0 ns at 24. So on this core out-of-order
  execution hid the divides almost entirely, and a 24-byte layout shift
  outweighs them. An A/A control (two identical binaries) differed by at most
  0.2 %. The E-core is too noisy to resolve it, and Cascade Lake, whose 64-bit
  divide is much slower, is unmeasured. The fix stays for its simplicity; the
  1–2 % is placement, which the next unrelated change will reshuffle.

**The boundary figures on this page do not measure what the writebacks cost.**
Each writeback is bracketed with `rdtsc`, which is not ordered with `CLWB`, so
the prepare cycles are what lands inside the window, not the instruction's cost
to the commit. At 24 entries the same commit reports 1,222 ns of boundary with
`CLWB`, 437 ns with `CLFLUSHOPT`, and 369 ns with no writeback at all — the loop
and `rdtsc` overhead — while the wall times are 37.6, 37.3 and 21.3 µs. Per line
inside the window that is 73, 26 and 21 cycles. The writebacks' cost is the
wall-time difference from no writeback: **14 %, 36 % and 43 % of the commit** at
1, 8 and 24 entries, against a measured boundary share of 3.2 %. Consequently:

- "`CLWB` linear at 72.0–73.5 cycles per line" still reproduces, but it is an
  in-window figure, not a cost.
- "The boundary is ~3 % of a PMEM commit" and "record construction outweighs the
  boundary by 29×" are **superseded**. At eight entries the commit without
  writebacks is 64 % of the commit with them; the writebacks and their side
  effects are the other 36 %.
- The fence is unaffected: `SFENCE` is 11–13 ns, and removing a boundary on PMEM
  is still noise. What is not noise is how the after-images are written back.

**The file backend's fixed cost has a measured candidate.** pwbench counts minor
faults over the measured commits: 2.01–2.24 per commit for the file backend on
DAX, 0.014 for PMEM. The file backend's extra fixed cost at one entry, 7.4
against 3.8 µs outside the boundary, is about 1.8 µs per fault. That supports
the re-dirtying-fault reading above — each `fdatasync` write-protects the
dirtied pages and the next commit faults them back — without proving the faults
are where the time goes.

#### On Raptor Lake `CLWB` does not evict, and the same-line store is still the cost

Measured 2026-09-28 on sean-tan-PC, an i7-14700KF (Raptor Lake: family 6,
model 183, stepping 1, microcode 0x133), with the same script, geometry and
protocol as on Magpie. Two differences bound what the result says:

- **The media is DRAM.** `memmap=1G!8G` reserves DRAM as `/dev/pmem0`, with
  ext4 `dax=always` on it, so a miss costs a DRAM access (~54 ns in the probe),
  not an Optane one (~620 ns). This measures the CPU-side property — whether
  `CLWB` keeps the line — and not what either outcome costs on real PMEM.
- **The CPU is hybrid.** CPUs 0–15 are performance cores (`cpu_core`, Raptor
  Cove) and 16–27 efficiency cores (`cpu_atom`, Gracemont). Each type was
  measured on one core, CPU 2 and CPU 20 (`PWCLWB_CPUS`); CPU 20 shares its L2
  with 21–23, which were idle.

No counters (`perf_event_paranoid` is 4), governor `performance` except where
noted. The load at each start was 0.17–0.23, or 0.59–0.65 for the sittings
that began straight after another (the one-minute average of the benchmark just
finished; the machine was otherwise idle). All directories are
`results/20260928T<time>-sean-tan-PC-clwb-eviction-cpus<N>`:

| Time | Core | Configurations | Repetitions |
|---|---|---|---|
| `075258Z` | P | stride 8: `CLWB`/`CLFLUSHOPT` × batched/per entry, no writeback, file | 3 |
| `075458Z` | E | the same | 3 — too noisy to use, superseded |
| `075906Z` | E | the same | 15 |
| `083750Z` | P | the five PMEM configurations at strides 8 and 64 | 3 |
| `083851Z` | E | the same | 15 |
| `082812Z`, `082916Z` | P, E | replicate of the two above, under `powersave` after a reboot; in the E-core's last repetition the governor was changed (119 of 900 runs, excluded where used) | 3, 15 |

Figures are medians with both commit counts pooled, each run being its own
measured window: 6 samples per cell on the P-core, 30 on the E-core.

**The probe: `CLWB` leaves the line within reach on both core types.** Median
TSC cycles (3.417 GHz), three repetitions agreeing within ±2 cycles and across
all five sittings. The DRAM and "PMEM" rows agree, as they must here:

| | no writeback | `CLWB` | `CLFLUSHOPT` |
|---|---|---|---|
| P-core load / store | 33 / 50 | 73 / 77 | 216–219 / 83 |
| E-core load / store | 63 / 61 | 111 / 97–99 | 243–244 / 117 |

A load after `CLWB` costs +40 cycles (P) and +48 (E), about 12–14 ns; after
`CLFLUSHOPT` it costs +183–186 and +180, a DRAM access. The line is neither
held at hit cost nor evicted; where it is held cannot be told without counters.
**The store row does not discriminate on these cores.** A store after
`CLFLUSHOPT` shows only +33 (P) and +56 (E) cycles, a fraction of the load's
miss, so its `EVICTED` label came from the nearest-neighbour rule, not from an
eviction. Adding `LFENCE` after the store window's `MFENCE` (the SDM's
`MFENCE; LFENCE` before `RDTSC`), tested on a scratch copy of the probe, shifts
the row by a constant and leaves it otherwise unchanged, so the window is not
closing early. A plausible reading is that these cores let a store become
globally visible before its data arrives and Cascade Lake did not; that is
untested. The summary now labels such a row "not discriminating".

**The campaign agrees with the load row.** Stride 8, wall time per commit in
ns; the percentage is the per-entry apply's excess over the batched one with
the same instruction:

| Entries | no writeback | `CLWB`, batched | `CLWB`, per entry | `CLFLUSHOPT`, batched | `CLFLUSHOPT`, per entry | `file` on DAX |
|---|---|---|---|---|---|---|
| P, 1 | 914 | 947 | 936 | 978 | 972 | 3,469 |
| P, 8 | 2,075 | 2,118 | 2,270 (+7.2 %) | 2,108 | 2,667 (+26.5 %) | 4,632 |
| P, 24 | 5,213 | 5,252 | 5,706 (+8.7 %) | 5,258 | 6,748 (+28.3 %) | 7,674 |
| E, 1 | 1,922 | 1,962 | 1,962 | 1,991 | 1,984 | 5,820 |
| E, 8 | 4,306 | 4,366 | 4,533 (+3.8 %) | 4,372 | 4,908 (+12.3 %) | 8,168 |
| E, 24 | 10,606 | 10,474 | 11,230 (+7.2 %) | 10,678 | 12,290 (+15.1 %) | 14,490 |

- **`CLWB` is not `CLFLUSHOPT` here.** On Magpie the two gave the same commit
  to within 1–2 %. Here, per entry at 24 entries, `CLFLUSHOPT` costs 18 % (P)
  and 9 % (E) more than `CLWB`: 52–53 ns per re-stored line on both cores, with
  the same placement and writebacks, against the probe's 39–43 ns load
  difference. On the P-core every cited difference separates all six samples
  from all six (IQR ≤0.6 %).
- **Neither prediction holds exactly.** "Keeps the line" predicted the
  per-entry apply within a few percent of the batched one with `CLWB`; it is
  7–9 % slower on the P-core and 4–7 % on the E-core. "Evicts" predicted `CLWB`
  ≈ `CLFLUSHOPT`, which fails. `CLWB` costs about a third of `CLFLUSHOPT`'s
  per-entry penalty (0.27–0.31 P, 0.31–0.47 E).
- **The batched apply still pays, much less.** It is 8.0 % (P) and 6.7 % (E)
  faster than the per-entry apply at 24 entries, against 43 % on Magpie; with
  `CLFLUSHOPT` it would be 22 % and 13 %. Its writebacks cost at most 3.6 % of
  a commit over no writeback on either core type (0.7 % at 24 entries on the
  P-core), and under it the two instructions are indistinguishable at 8 and 24
  entries.
- At one entry `CLFLUSHOPT` is 3.3 % (P, six of six samples) and 1.5 % (E)
  slower than `CLWB` in both placements. Unexplained.
- The PMEM backend is faster than the file backend on DAX at every size on both
  core types.

**The E-core is noisier, and the noise is per run.** Every configuration, no
writeback included, has a second mode about 10 % faster than its main one. It
appears in single runs scattered through the campaign, not in bursts, with
identical fault counts; its cause is not known. With three repetitions
(`075458Z`) the per-entry apply even came out 3.9 % faster at 24 entries.
Fifteen repetitions settle the ordering — no writeback ≈ batched with either
instruction < `CLWB` per entry < `CLFLUSHOPT` per entry — and it holds within
each mode. A rank test puts `CLFLUSHOPT` per entry above batched in 98–99 % of
cross pairs, and `CLWB` per entry above batched in 77–84 %: real, but
overlapping.

**`CLWB`'s remaining per-entry cost is the same-line store, as on Magpie.** At
stride 8 the per-entry apply differs from the batched one in two ways at once:
20 of 24 after-image stores land in a line just written back (re-access), and
the commit issues 38 writebacks instead of 18 (traffic). At stride 64 the
per-entry apply keeps the 38 writebacks and has no re-access. So the excess
over no writeback at stride 64 is the traffic, and the stride-8 excess minus
the stride-64 one is the re-access. Same sitting (`083750Z`, `083851Z`), wall
time per commit, 90 % bootstrap intervals:

| `CLWB`, per entry | P, 8 entries | P, 24 | E, 8 | E, 24 † |
|---|---|---|---|---|
| excess over no writeback, stride 8 | +217 ns | +454 ns | +226 ns | +690 ns |
| excess over no writeback, stride 64 (traffic) | +52 ns | +28 ns | +54 ns | +85 ns |
| re-access per re-stored line (6 at 8 entries, 20 at 24) | 27.4 ns [24.4, 38.9] | 21.4 ns [17.2, 23.9] | 28.6 ns [24.8, 33.2] | 30.2 ns [26.7, 33.3] |
| re-access share | 76 % | 94 % | 76 % | 88 % |

† Upper quartile, not median: at 24 entries the E-core's medians sit on the
boundary between its two modes, and the median estimate is uninformative
(25.2 ns per line, [−9.5, 38.5]). The upper quartile lies in the main mode of
every configuration. The `powersave` replicates agree: 26.8 and 22.5 ns per
line on the P-core (medians), 31.2 and 29.0 ns on the E-core (upper quartile,
runs before the governor change only). Stride alone moves no writeback by
1.3 % (P) and 1.8 % (E) at 24 entries, which the subtraction removes.

- The same-line store is 76–94 % of `CLWB`'s per-entry cost on both core
  types, against ~95 % on Magpie; the writebacks themselves cost a few
  nanoseconds each. The mechanism is the one found on Magpie. Its price per
  store is ~21–30 ns here, against ~775 ns there.
- A store right after its line's `CLWB` costs about twice the probe's fenced
  re-load (21–30 against 12–14 ns). Magpie showed the same direction (775
  against 620 ns), and the same untested reason fits both: the workload's store
  follows the writeback by nanoseconds.
- Where nothing coalesces (stride 64, 24 entries) the batched apply is 171 ns
  (3.2 %) slower than per entry on the P-core, interval [111, 194]; Magpie
  showed 0.34 µs (1.5 %). On the E-core it is 62 ns (0.6 %, [36, 80]) by the
  upper quartile and inside the noise by the median.
- For `CLFLUSHOPT`, stride 64 is not a traffic-only control: every line it
  invalidates misses on the next commit. Per entry at stride 64 it costs +943
  ns (P) and +869 ns (E) over no writeback at 24 entries, against +197 and +183
  batched, so interleaving an invalidating writeback with each store costs
  ~0.7 µs even without reuse within the commit. Mechanism untested.

**What generalises.** Cascade Lake's eviction does not: on both Raptor Lake
core types `CLWB` keeps the line out of memory. The mechanism does: storing
into a line just written back is what the per-entry placement cost on both
machines, and the batched apply removes it on both. What changes is the price.
This machine cannot give that price for real PMEM on a CPU that retains the
line. The line is retained here, so the store does not reach the medium, but
whether the ~20–30 ns grows with Optane's writeback latency behind it is not
measured. Under the batched apply the two instructions give the same commit
here (Magpie never ran `CLFLUSHOPT` batched), so without the per-entry
placement the campaign cannot discriminate eviction in the workload; the
probe's load row can.

### A real workload: what a sieve step costs, and how much is persistence

pwbench measures one transaction shape the harness chooses: a fixed number of
u64 entries. `test/pwsievebench.main.v3` measures a program's: the resumable
sieve (`PWSieve`) through the production allocator and WAL. A step computes a
segment in DRAM, allocates a chunk (its own commit), writes the bitmap directly
and persists it (one boundary), publishes the descriptor and root counters (one
commit of about seven fields sharing lines), and retires the segment leaving the
retention window (one commit). PWSieve reports the end of each phase through an
optional `onPhase` hook. Each run is 20 rounds, each a freshly formatted 1 MiB
region (256 × 4 KiB), 8 unmeasured steps, then the 159 steps its descriptor table
has left, verified afterwards against an independent reference sieve: 3,180
measured steps per run. `scripts/pwsieve-bench.sh` interleaves the
configurations and repeats them.

Measured 2026-09-28 on sean-tan-PC first, and then on Magpie (below). On
sean-tan-PC the caveats of the Raptor Lake subsection above apply: DRAM stands in for PMEM (`memmap`), and each core type is one
core of a hybrid CPU. Governor `performance`, idle machine, block storage the NVMe
root (ext4). `results/20260928T100258Z-sean-tan-PC-pwsieve-bench-cpus2` (P-core,
five repetitions) and `…T100404Z-…-cpus20` (E-core, fifteen). Wall time per step,
median over repetitions:

| Configuration | P-core step | of which compute | persistence phases | E-core step | persistence phases |
|---|---|---|---|---|---|
| `pmem`, production (`CLWB`) | 166.9 µs | 151.8 µs | 15.1 µs (9.1 %) | 312 µs | 26.3 µs (8.4 %) |
| `pmem`, `CLFLUSHOPT` | 167.1 µs | 151.6 µs | 15.5 µs (9.2 %) | 307 µs | 26.6 µs (8.7 %) |
| `pmem`, no writeback | 168.3 µs | 153.7 µs | 14.5 µs (8.6 %) | 312 µs | 25.7 µs (8.3 %) |
| `file` on DAX | 181.6 µs | 153.8 µs | 27.7 µs (15.3 %) | 329 µs | 46.0 µs (14.0 %) |
| `file` on NVMe | 1,097 µs | 158.1 µs | 938 µs (85.6 %) | 1,265 µs | 1,000 µs (79.1 %) |
| `direct` on NVMe | 1,125 µs | 158.4 µs | 968 µs (86.0 %) | 1,277 µs | 1,007 µs (78.9 %) |

On the P-core the repetitions' wall ranges are 0.3–0.5 % wide; on the E-core
about 6 %, and almost all of that is in the compute phase, while its persistence
phases stay within ±1.5 %. The per-run CPU effect seen in pwbench on this core
type lives in computation, not in the persistence path.

- **On PMEM a step is computation.** The four persistence phases are 9 % of a
  step on both core types: on the P-core 3.4 µs to allocate, 6.2 µs to write and
  persist the 4 KiB bitmap, 2.3 µs to publish and 3.2 µs to retire. The publish
  commit, about seven fields, costs what pwbench's 8-entry commit does (2.1 µs).
  On the file backend on DAX the same work is 1.8× as long (27.7 µs, 15 % of a
  step), with 12.8 minor faults per step against 2.1, the write-protect faults
  after each `fdatasync` described above. On the NVMe, persistence is 79–86 % of
  a step.
- **Four boundaries per step on every backend**, as designed: three commits and
  the bitmap's `persistRange()`, which on the file backend was then an `msync`
  (since 2026-10-13 an `fdatasync`; [old against new](#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)). On the
  NVMe each costs about 235 µs (P-core), close to the 237 µs pwbench records for
  this machine's file-backend boundary. The direct backend is 2.6 % slower than the file backend
  there, the direction pwbench shows on this machine (241 against 237 µs per
  boundary).
- **The writeback instructions cost almost nothing, and removing them does not
  make the step faster.** On the P-core, no writeback is 0.8 % *slower* than
  production, in every repetition and outside both ranges. The phases say where:
  the persistence phases are 0.57 µs shorter without the instructions, and the
  compute phase is 1.9 µs longer, in every repetition. A plausible reading is
  that lines `CLWB` would have cleaned are instead written back when they are
  evicted, during the next computation; that is untested. So `writeback=none`
  bounds what the instructions cost a step (0.57 µs, 0.34 %), not what getting
  the data to memory costs. On the E-core the difference is inside the noise.
- **`CLFLUSHOPT` in place of `CLWB` changes the step by 0.1 % on the P-core**,
  inside both ranges; its persistence phases are 0.3 µs longer, consistently.
  With the batched apply a transaction stores into each line before writing it
  back, so an invalidating writeback leaves little reuse to penalise.
- What this cannot show: the batched apply against the per-entry one on this
  workload, since the per-entry placement is gone.

**On Magpie, with Optane, the step is still computation.** Same geometry and
protocol, pinned to the namespace's node 0, five repetitions, idle host
(`results/20260928T102833Z-magpie-pwsieve-bench`). Block storage is `/home`,
ext4 on LVM behind the write-through RAID controller. Wall time per step,
median; every PMEM and DAX range is under 0.7 % wide:

| Configuration | Step | of which compute | persistence phases |
|---|---|---|---|
| `pmem`, production (`CLWB`) | 479.4 µs | 425.1 µs | 54.3 µs (11.3 %) |
| `pmem`, `CLFLUSHOPT` | 479.2 µs | 426.9 µs | 52.4 µs (10.9 %) |
| `pmem`, no writeback | 475.1 µs | 426.1 µs | 49.0 µs (10.3 %) |
| `file` on DAX | 520.9 µs | 426.7 µs | 94.3 µs (18.1 %) |
| `file` on `/home` | 2,446 µs | 1,104 µs | 1,335 µs (54.6 %) |
| `direct` on `/home` | 2,675 µs | 1,151 µs | 1,526 µs (57.0 %) |

- **Optane raises the persistence phases 3.6×, and the share only from 9 % to
  11 %.** They are 54.3 µs against the Raptor Lake P-core's 15.1 µs (alloc
  12.8, bitmap 20.2, publish 9.2, retire 12.1 µs), but Magpie's cores also
  compute 2.8× slower. The publish commit again costs what pwbench's 8-entry
  commit does there (9.4 µs), and the file backend on DAX again spends about
  1.7× PMEM's persistence time.
- **Here the writeback instructions are a measurable saving.** Without them the
  step is 4.3 µs (0.9 %) faster, in every repetition and outside both ranges.
  The persistence phases shrink by 5.3 µs and the compute phase again grows,
  by 1.0 µs, the same direction as on Raptor Lake but now a net saving.
- **`CLFLUSHOPT` gives the same step as `CLWB`** (−0.03 %), as it should where
  `CLWB` evicts. Its persistence phases are 1.9 µs shorter, consistently, and
  its compute phase longer; unexplained, and small.

**On block storage, blocking costs clock speed, and no boundary figure shows
it.** Computing a segment is the same DRAM work on every backend, yet on
Magpie's block configurations it takes 1,104 and 1,151 µs, 2.6–2.7× the PMEM
figure, in every repetition. Four observations locate the cause:

| compute phase per step | Raptor Lake, `performance` | Raptor Lake, `powersave` | Magpie |
|---|---|---|---|
| `pmem` (never blocks) | 151.8 µs | 155.0 µs | 425.0 µs |
| `file` on block storage | 158.1 µs (1.04×) | 516.7 µs (3.3×) | 1,104 µs (2.6×) |
| `direct` on block storage | 158.4 µs (1.04×) | 462.3 µs (3.0×) | 1,151 µs (2.7×) |

- It is not scheduler migration: pinned to one CPU
  (`results/20260928T104138Z-magpie-pwsieve-bench-cpus2`) the figures are
  unchanged (1,104 and 1,150 µs).
- It is not the syscalls or the faults: the file backend on DAX makes the same
  `fdatasync` and `msync` calls and takes the same 12.8 write-protect faults
  per step, and its compute phase is normal (427 µs). What differs is that on
  block storage the thread blocks for 180–680 µs in each of them.
- A utilisation-driven frequency policy reproduces it: on the Raptor Lake
  P-core under `powersave` (`…T105045Z-sean-tan-PC-pwsieve-bench-cpus2-powersave`,
  three repetitions) the block configurations' computation is 3.0–3.3× PMEM's,
  and under `performance` it is 1.04×. There a `file`-on-NVMe step costs 42 %
  more under `powersave` (1,558 against 1,097 µs), most of it outside the
  persistence phases.
- Magpie has no cpufreq driver at all (`/sys/devices/system/cpu/cpu*/cpufreq`
  is absent), so its clock is set by the platform, outside the OS; `intel_idle`
  offers C1, C1E and C6, all enabled. A core idle in `fdatasync` can reach C1E,
  which runs at the lowest frequency, and C6, which also empties its private
  caches.

**Observed without root (2026-09-29): it is the clock.** `pwsievebench
clock=probe` reads the core clock at each of a step's six marks (after the
sieve, each of the four boundaries, and the short count between the bitmap and
the publish) by timing 4,096 dependent register operations between
`lfence`-ordered `rdtsc` reads. The probe touches no memory, so its time depends
on the clock alone; corrected for its fixed ~1.4 % overhead, every reading on
both hosts is a whole number of 100 MHz steps. Two references go with it: the
clock after 200 ms of busy probing, and just after a 250 µs `nanosleep`, which
blocks with no storage behind it. Every configuration ran plain and probed,
interleaved, five repetitions, pinned to CPU 2
(`results/20260929T025219Z-magpie-pwsieve-bench-cpus2-clock`,
`…T025351Z-sean-tan-PC-pwsieve-bench-cpus2-clock-powersave`,
`…T031445Z-sean-tan-PC-pwsieve-bench-cpus2-clock-performance`). The clock as a
share of the busy reference (3.55 GHz implied on Magpie, 5.43 GHz on the
P-core), medians over repetitions:

| | Raptor Lake, `performance` | Raptor Lake, `powersave` | Magpie |
|---|---|---|---|
| `pmem` and `file` on DAX, at every mark | 100 % | 100 % | 100 % |
| block storage, after each boundary | 100 % | 29–33 % | 28 % (1.0 GHz) |
| block storage, at the end of the sieve | 100 % | 29–33 % | 47–50 % (1.7–1.8 GHz) |
| after a 250 µs sleep, no storage | 100 % | 35–36 % | 28 % |
| computation on block storage ÷ PMEM, probed runs | 1.02× | 2.87–3.16× | 2.53–2.66× |
| clock ratio to PMEM, sieve start / end | 1.00× / 1.00× | 3.06–3.44× / same | 3.60× / 2.00–2.12× |

- **On Magpie a thread that blocks comes back at the lowest frequency**, 1.0 GHz
  against 3.6 GHz busy, and reaches only 1.7–1.8 GHz by the end of the ~1.1 ms
  sieve. The sieve and boundary medians agree to within 1 MHz across all five
  repetitions. The computation's 2.53× (file) and 2.66× (direct) falls between
  the clock ratios at the sieve's start and end; if the clock rose steadily
  between the two readings, the mean would predict 2.57× and 2.67×. The shape
  of the climb is not observed, so that agreement is consistency, not proof.
- **Idleness lowers the clock, not storage.** The 250 µs sleep leaves Magpie's
  core at 1.0 GHz on every sample. Nothing on the PMEM or DAX paths blocks long
  enough to matter.
- **Raptor Lake under `powersave` holds one low clock through the whole step**,
  1.6–1.8 GHz, rather than dropping and climbing, and the computation's
  2.87–3.16× is just below the clock ratios of 3.06–3.44×, as expected where
  part of the work waits on memory. Under `performance` the clock stays at
  5.43 GHz everywhere, and the slowdown shrinks to 1.02–1.03× (1.04× on
  2026-09-28). That residual is outside the ranges, is not the clock, and is not
  explained; the file backend on DAX, which also enters the kernel at every
  boundary, computes 1.8 % faster than PMEM in the plain runs.
- **Cold caches are not supported.** The first probe of each pair exceeds the
  second by at most 4 ticks (about 1 ns) anywhere, including after the direct
  backend's 620 µs bitmap boundary on Magpie. That covers only the probe's own
  instructions, but the clock leaves little of the slowdown to explain.
- **The probe's own effect is small and measured.** With the clock pinned
  (`performance`) probed runs differ from plain ones by −0.8 to +1.2 %, of both
  signs, which bounds the probe's residue. Under `powersave` the probed block
  runs compute 3.3–3.6 % faster, outside both ranges: the probe's ~30 µs of busy
  time per step raises the utilisation the governor sees, so there its readings
  slightly overstate the unprobed clock. On Magpie the difference is 1.5 %, at
  the edge of the ranges.

On Raptor Lake the cause is therefore established by intervention: changing
only the governor removes both the clock drop and the slowdown. On Magpie, which
has no frequency control for the OS to change, it was observed rather than
intervened on until the
[root sitting of 2026-10-16](#the-clock-after-a-blocking-boundary-is-the-idle-states)
disabled C1E and C6 on the core. Then the clock after every boundary stayed at
3.15–3.45 GHz instead of 1.0 GHz, the computation fell to 448 µs (`file`) and
503–504 µs (`direct`), and the step to 1.60 and 1.78–1.79 ms, so on Magpie too
the cause is established by intervention: the idle states. The consequence
stands as before. On block storage a durable step costs more than its
boundaries: the 55–57 % persistence share on Magpie understates what blocking
costs the program (by the attribution in that section, the boundaries account
for 80–82 % of the step), and pwbench, which issues boundaries back to back with
almost no computation between them, cannot see it.

**Still open: Magpie's per-boundary pattern.** On `/home` the sieve's boundaries
cost 180–680 µs against pwbench's back-to-back median of 150–176 µs on the same
directory (`20260923T052859Z`, `20260927T080050Z`). On the file backend the two
boundaries that follow a stretch of computation (alloc 430 µs, publish 410 µs)
cost about 1.7× the two that follow another boundary (bitmap and retire, 247–248
µs). On the direct backend alloc is 466 µs and the bitmap boundary 680 µs, while
publish and retire are 186–194 µs. Raptor Lake under `powersave` shows neither:
all four of its boundaries are 248–283 µs. That points at Magpie's storage path
(LVM, then the write-through controller) rather than the CPU; untested. The
clock does not explain it. The pattern reproduces in the clock campaign (file:
alloc 396 and publish 375 µs against bitmap 226 and retire 253 µs), and the two
slow boundaries are the ones that start at the higher clock, after the sieve
(1.8 GHz) and after the count (1.5 GHz), while the fast two start at 1.0 GHz:
the opposite of what a clock cause would predict.

### A second workload: what a B+Tree mutation costs (2026-10-14)

The sieve is one end of the interface: on PMEM a step is mostly computation,
with a few boundaries around a bulk write. A B+Tree mutation is the other end:
little computation, and every changed node is a fresh chunk that must be
durable before it is published. `test/unittest/x86-64-linux/PWBTree.v3` is a
B+Tree of u64 keys and values over a `PWRegion`. Like PWSieve it is a workload
driver, not engine code, and has no WASM component; the only interface under
test is PWRegion's. `test/pwbtreebench.main.v3` times its operations through
the production allocator and WAL.

**Layout.** Every node is one chunk of one block (`allocChunk(1)`), so nothing
sits between the tree and the allocator. After the 32-byte chunk header a leaf
is `[tag][count][key, value]*` and an internal node
`[tag][count][child 0][key, child]*`; child offsets are region-relative, and
the tag is a magic number carrying the node's level (0 for a leaf). A node
holds at most the keys an internal node of the block size can,
((blockSize − 32) / 8 − 3) / 2: 252 at 4 KiB. A smaller capacity can be asked
for, so that tests reach a deep tree with few keys. A root chunk, published at
`userRoot` and never freed, holds a magic number, the geometry (block size and
capacity, checked on open), the root node's offset, the height, the key and
node counts, and a mutation count that never decreases. Format publishes an
empty root leaf, so the height is at least 1 and every mutation replaces at
least one node. Leaves have no sibling links and there is no delete: nothing
scans a range or merges nodes. A chunk is block aligned, but PWRegion allows any
block size that is a multiple of 8, so a node need not start on a cache line;
its writebacks start on the line that holds its first word, as `persistRange()`
aligns its range (tested at 4,104-byte blocks; until a review on 2026-10-14
they started at the chunk and raised `PersistentOperationError` there).

**Copy-on-write, because a node cannot go through the log.** A redo entry
carries at most 8 bytes in a 32-byte slot, so a 4 KiB node would overflow a
record many times over, as the sieve's bitmap would. A `put()` therefore never
writes a reachable node. It copies the path from the root to the leaf, with the
change and any splits, into freshly allocated chunks; writes them directly
through the persistent-operation seam and makes them durable; and only then
publishes them, in one transaction that swaps the root fields. Its phases, each
reported through an optional `onPhase` hook:

| Phase | Work | Boundaries |
|---|---|---|
| COMPUTE | descend, find the leaf slot, count the splits | 0 |
| ALLOC | `allocChunk(1)` for each of the k new nodes, each its own commit | k |
| COMPUTE | build the k nodes in DRAM, child offsets filled in | 0 |
| WRITE | the nodes' direct stores; every line but the last node's handed to the provider, then one `persistRange()` over the last node, whose fence completes them all | 1 |
| PUBLISH | the root fields buffered, then `freeChunk()` of the old root node, which commits both | 1 |
| FREE | `freeChunk()` of each other replaced node | h − 1 |

At height h with k new nodes (k = h without a split, plus one per node that
splits and one for a new root), a mutation makes **k + h + 1 boundaries**: 3 at
height 1, 5 for an update or a non-splitting insert at height 2, 6 for a leaf
split there. A lookup makes none. One fence covers every new node because each
backend's fence completes everything outstanding: the `SFENCE` after the
`CLWB`s on PMEM, one `fdatasync` of every marked page or unit on the file and
direct backends.

**Several frees cannot share a commit; the first shares the publish.**
`allocChunk()` and `freeChunk()` each end in `performCommit()`, which commits
everything the shared `RegionTransaction` holds, and the allocator has no call
that allocates or frees without committing. Buffering the root swap before the
first free makes the swap and that free one transaction, PWSieve's retirement
recipe; each later free commits on its own. Two orderings carry the argument:

- **Unpublication precedes freeing.** The old root node is freed in the commit
  that stops the tree reaching it, and the other replaced nodes after it. The
  reverse order would let the allocator hand out a chunk the durable tree still
  reaches: corruption, not a leak. Mutation-tested by hand on 2026-10-14 and not
  committed: freeing the replaced nodes before the publish fails both
  `pwbtree_dio:` tests.
- **New nodes are durable before the publish.** Every reachable node is
  durable and allocated at every commit point. A crash between an allocation
  and the publish, or between the publish and the last free, leaves allocated
  chunks that nothing reaches: leaks, never an inconsistency. `open()` sweeps
  them as PWSieve's does. It marks every node reachable from the root, walks the
  memory-order chain, and frees each used chunk it did not mark, one commit
  each, counting them; with no root it frees every used chunk, which reclaims a
  format that crashed before `setUserRoot()`. Eliding the node writebacks (by
  hand, not committed) fails the boundary-count test and both `pwbtree_dio:`
  tests.

`checkInvariants()` checks the root's magic and geometry and walks the tree:
every node in range, block-aligned, reached once, allocated and on no free
list, tagged with the magic and the level its depth implies; at most capacity
keys, and at least capacity / 2 in every node but the root (only splits happen,
and a split leaves both halves that full); keys strictly increasing and within
the separators above; the totals equal to the root's key and node counts.
`forEach()`, which the reference comparisons use, checks each node it reaches
the same way (in the region, a node's tag at the level its depth implies,
within the capacity) and returns a reason instead of walking on, so neither
walk recurses deeper than the height, at most 32, on a corrupted or cyclic
image. `forEach()` does not track reachability: it walks a subtree reached
twice, boundedly, and `compare()` requires the keys it yields to strictly
increase, which the repeat fails even when the repeated leaf is the size of
the one it displaced and the count matches. Neither `open()` nor the walks add
a size to an offset read from the region before checking it: the published
root and every node must be block aligned and below the region's size, a
whole number of blocks, so an offset near 2^64 cannot wrap into range.

**Method.** pwbtreebench runs rounds, each on a freshly formatted region: a
load of N random distinct keys, each insert timed, then N operations, half
lookups and half updates of uniformly chosen loaded keys (a YCSB-A-like mix),
each kind timed apart. After each round the invariants run and the whole tree
is compared with a DRAM map. Round 0 is unmeasured and audits every mark
through counting backends (pwopsbench's): each commit one boundary and the
lines its WAL record predicts (`commitLines()`, counted from the record's real
offset: at a block size that is not a multiple of a line, 4,104 bytes say, a
log slot starts inside a line and a record touches one more, which until a
review on 2026-10-14 the prediction missed), WRITE one boundary and exactly the
lines the new nodes occupy, read back from them. Every operation of every
round must then make k + h + 1 boundaries, with k and h read from the durable
root, and every measured operation exactly the boundaries, prepare calls and
lines its counterpart made in round 0: each round replays the same seeded
history on the same deterministic allocator. Any mismatch fails the run and
keeps the image; an off-by-one in the predicted lines and a wrong boundary
count, each planted by hand, do. The phases are the `onPhase` marks, so the
persistence share is measured, not inferred. `scripts/pwbtree-bench.sh`
interleaves the configurations, repetition outermost, refuses a dirty tree, and
records the commit, host, CPU, governor, load, mount options and device chain.

**Measured on sean-tan-PC's NVMe only, 2026-10-14.** The `pmem-auto`,
`pmem-none` and `file-dax` configurations need a DAX mount; the memmap
`/dev/pmem0` has no filesystem mounted now and mounting one was out of scope, so
they ran on Magpie (below). `file` and `direct` ran on `/dev/nvme1n1p3`
(ext4, `rw,relatime`; the Solidigm SSD, write cache write back), pinned to
CPU 2, a P-core, under `powersave` (EPP `balance_performance`): five
repetitions of three measured rounds after the audited one, 5,000 keys and then
5,000 operations per round, a 1 MiB region (256 × 4 KiB), seed 1, at 73f5aed2
(`results/20261014T041846Z-sean-tan-PC-pwbtree-bench-cpus2-powersave`). After
the load the tree holds 5,000 keys at height 2 in 33 nodes. Per operation, the
median over repetitions of each run's statistic; the phases are means. The
persistence share is the four persistence phases over the mean time of the
whole operation (`rdtsc` around each `put()` or `get()`), as the sieve's is over
a whole step's wall time, so what falls outside the marks counts against it.
(The first summary divided by compute plus persistence instead, which made
every mutation 99.5 %; it was regenerated from the same runs on 2026-10-14.)

| Operation, backend | Median | p90 | compute | alloc | write | publish | free | persistence share |
|---|---|---|---|---|---|---|---|---|
| insert, `file` | 1,396 µs | 1,423 µs | 6.7 µs | 555 µs | 278 µs | 281 µs | 261 µs | 99.4 % |
| insert, `direct` | 1,444 µs | 1,471 µs | 6.6 µs | 559 µs | 303 µs | 262 µs | 268 µs | 99.5 % |
| update, `file` | 1,395 µs | 1,423 µs | 6.5 µs | 561 µs | 277 µs | 281 µs | 274 µs | 99.5 % |
| update, `direct` | 1,445 µs | 1,472 µs | 6.5 µs | 583 µs | 310 µs | 265 µs | 287 µs | 99.5 % |
| lookup, `file` | 878 ns | 1,129 ns | 876 ns | – | – | – | – | 0 |
| lookup, `direct` | 871 ns | 1,112 ns | 881 ns | – | – | – | – | 0 |

The work per operation, identical on both backends and checked on every
operation of every round:

| Operation | Boundaries, mean (min–max) | Lines written back | Prepare calls | Splits |
|---|---|---|---|---|
| insert | 4.905 (3–6) | 94.876 | 16.430 | 93 in 15,000 |
| update | 5.000 (5–5) | 94.660 | 16.945 | 0 in 7,539 |
| lookup | 0 | 0 | 0 | 0 in 7,461 |

- **A mutation's time is persistence: 99.4–99.5 % of it, on both backends.**
  The persistence phases are 99.4 % of an insert's mean time on `file` and
  99.5 % of every other mutation's. Descending, planning and building the new
  node images take 6.5–6.7 µs of a 1.4 ms mutation, and what the marks leave
  out under 2 µs more (mean less phases); the rest is boundaries. The sieve on
  PMEM is the other end
  ([above](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence));
  the two bracket the interface.
- **The boundary counts are the model's, to the operation.** Every update made
  five. The insert mean is the round's composition: 252 inserts into the root leaf
  at 3, the root split at 5, 30 leaf splits at 6 and the other 4,717 inserts at
  5 make 24,526 boundaries over 5,000 inserts, 4.905 (arithmetic, matching the
  measured figure). The 31 splits per round (93 over three) leave 32 leaves
  under one root: the 33 nodes the load reports.
- **Every boundary costs about the same, so a mutation costs its count.** The
  persistence phases over the boundaries they make come to 278.5–288.8 µs per
  boundary (insert 280.2 and 283.7, update 278.5 and 288.8, `file` then
  `direct`), and the alloc phase, two boundaries at height 2, is about twice
  each of the others. On this storage a mutation is about five `fdatasync`s,
  and the lever is their number ([below](#what-these-numbers-cannot-show)).
- **`direct` against `file` is inside the noise.** The direct medians are
  3.5–3.6 % higher, but the repetitions spread 10.6–10.8 % on both backends, and
  a difference is real only outside both spreads.
- **The spread is most likely the clock.** It comes from repetitions 3 and 4 of
  `file` (insert medians 1,294 and 1,269 µs) and repetition 3 of `direct`
  (1,290 µs), against 1,396–1,446 µs in the others. The lookups of the same
  repetitions, which touch no storage, took 494–527 ns against 854–908 ns. Pure
  DRAM work changing that much in the same runs points at the core's clock
  under `powersave`, which the sieve's clock probe showed running far below its
  busy speed on this machine's block configurations, and not under
  `performance`
  ([above](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence)).
  Why the clock was higher in those repetitions is not known. This benchmark
  has no probe, so here it is an inference, and the governor was not changed to
  test it. The lookups' 43–47 % spread is the same effect.
- **Lines are not the cost on this storage.** A mutation writes back about 95
  lines in about 16–17 prepare calls, but the file backend syncs whole pages and
  the direct backend writes whole 4 KiB units, so the line count is not what a
  mutation pays here. On PMEM each line is a `CLWB`; Magpie measured what they
  cost there (below).
- Wall time per insert during the load is 1,384 µs (`file`) and 1,400 µs
  (`direct`); per operation of the mix, 705 and 731 µs, about half an update,
  since half the mix is lookups.

**Measured on Magpie, every configuration, 2026-10-14.** The Xeon Gold 6252N
was pinned to node 0, which owns the namespace. `pmem-auto`, `pmem-none` and
`file-dax` ran on `/mnt/pmem0.0/sean` (`dax=always`), and `file-block` and
`direct-block` on `/home/users/u7599095`: ext4 on LVM on the rotational `sda`
behind the write-through controller
([above](#cost-the-same-seam-call-a-different-persistence-point)). The host has
no cpufreq driver, so there is no governor. The parameters are the PC run's:
five repetitions of three measured rounds after the audited one, 5,000 keys and
then 5,000 operations, a 1 MiB region and seed 1. The campaign took 17 minutes
from a start load of 0.08, at `1d7c3276`
(`results/20261014T111205Z-magpie-pwbtree-bench`). All 25 runs ended `OK`
(`pmem-none`'s `OK timing-only`), every round 0 audit passed, and `summary`
recomputes the committed summary from `runs.csv`. The tree and the work per
operation are the PC's: height 2 and 33 nodes after the load, and the same
boundaries, lines and splits. PMEM makes no prepare calls. Figures are in µs,
lookups in ns; the phases are means.

| Operation, configuration | Median | p90 | Mean | compute | alloc | write | publish | free | persistence share |
|---|---|---|---|---|---|---|---|---|---|
| insert, `pmem-auto` | 58.7 | 64.1 | 59.4 | 5.6 | 24.3 | 7.8 | 13.7 | 8.0 | 90.4 % |
| insert, `pmem-none` | 50.6 | 55.3 | 51.4 | 3.4 | 21.9 | 6.2 | 12.6 | 7.0 | 93.1 % |
| insert, `file-dax` | 127.2 | 134.5 | 127.0 | 5.5 | 53.2 | 20.5 | 24.4 | 23.3 | 95.6 % |
| insert, `file-block` | 2,141 | 2,679 | 2,165 | 13.3 | 904 | 614 | 242 | 387 | 99.2 % |
| insert, `direct-block` | 2,195 | 2,893 | 2,663 | 13.3 | 1,078 | 749 | 226 | 597 | 99.5 % |
| update, `pmem-auto` | 58.1 | 60.7 | 58.5 | 5.2 | 23.6 | 7.6 | 13.7 | 8.2 | 90.8 % |
| update, `pmem-none` | 50.1 | 52.1 | 50.3 | 3.4 | 21.1 | 6.1 | 12.5 | 7.2 | 93.0 % |
| update, `file-dax` | 126.3 | 131.0 | 127.0 | 5.1 | 53.6 | 19.7 | 24.4 | 24.2 | 96.0 % |
| update, `file-block` | 2,220 | 2,584 | 2,215 | 13.3 | 920 | 639 | 245 | 398 | 99.4 % |
| update, `direct-block` | 2,534 | 23,224 | 6,725 | 13.5 | 2,879 | 867 | 404 | 2,561 | 99.8 % |
| lookup, `pmem-auto` | 1,333 ns | 2,212 ns | 1,343 ns | 1,337 ns | – | – | – | – | 0 |
| lookup, `pmem-none` | 277 ns | 312 ns | 278 ns | 274 ns | – | – | – | – | 0 |
| lookup, `file-dax` | 1,331 ns | 2,175 ns | 1,330 ns | 1,322 ns | – | – | – | – | 0 |
| lookup, `file-block` | 1,216 ns | 1,462 ns | 1,248 ns | 1,220 ns | – | – | – | – | 0 |
| lookup, `direct-block` | 1,257 ns | 1,684 ns | 1,321 ns | 1,268 ns | – | – | – | – | 0 |

- **On PMEM a mutation is still nine-tenths persistence.** The persistence
  phases are 90.4 % of an insert's mean time and 90.8 % of an update's on
  `pmem-auto`. With the file backend they are 95.6–96.0 % on DAX, 99.2–99.4 % on
  `/home`, and through the direct backend 99.5–99.8 %. A boundary costs
  10.6–11.0 µs on PMEM, 24.4–24.7 µs with the file backend on DAX and 438–440 µs
  with it on `/home`: the persistence phases over the boundaries they make. The
  sieve on the same host spends 11.2 % of a step on persistence on PMEM, 18.9 %
  with the file backend on DAX, and 57.9–58.3 % on `/home`
  ([above](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence),
  `results/20261014T025706Z-magpie-pwsieve-bench`). On one host, then, the two
  workloads bracket the share: 11–90 % on PMEM and 58–99 % on the disk.
- **The writebacks cost a PMEM mutation 14 %, and not only inside its
  boundaries.** `pmem-auto − pmem-none` is 8.1 µs per insert (13.8 %) and 7.9 µs
  per update (13.6 %). For the sieve the same difference is 1.0 % of a step. An
  insert computes for 5.6 µs with the writebacks and 3.4 µs without them; for an
  update it is 5.2 against 3.4 µs. A lookup makes no boundary, yet it takes
  1,333 ns on `pmem-auto`, 1,331 ns on `file-dax` and 277 ns on `pmem-none`.
  That is consistent with `CLWB` evicting on Cascade Lake
  ([above](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows)):
  the next operation finds the nodes a mutation wrote back no longer cached. This
  is an inference: the benchmark counts no misses.
- **On `/home` the computation is slower too.** It takes 13.3–13.5 µs against
  5.2–5.6 µs on PMEM, and a lookup takes 1.2–1.3 µs. That matches the sieve's
  computation after a blocking boundary
  ([above](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence)).
  pwbtreebench has no clock probe, so this was an inference; turbostat has
  since measured the core's busy clock over a B+Tree run on `/home` at about
  1.0 GHz, and found it unchanged with C1E and C6 disabled, unlike the sieve's
  ([2026-10-16](#the-btrees-clock)).
- **The direct backend's mutations on `/home` have a heavy tail, not
  explained.** In every repetition its updates' p90 is 9.4–25.5 ms and their
  p99 35.6–43.6 ms, against `file-block`'s 2.6 ms and 2.8–3.0 ms. The medians
  stay close: 2.41–2.67 ms against 2.21–2.23 ms per repetition. The inserts'
  p99 is 17.0–32.0 ms against 3.1 ms. About 91 % of the update's excess mean
  lies in the alloc and free phases, which are commits. The mean update,
  6.7 ms, is 2.7 times the median, and the per-repetition means run 4.8, 6.7,
  5.2, 8.7 and 8.2 ms. The sieve's `direct-block` steps earlier the same day
  have no such tail: p90 is 1.18–1.20 times the median, against `file-block`'s
  1.16. The direct backend writes whole 4 KiB units (`WRITE_UNIT`), which rules
  out a sub-sector read-modify-write. The controller's cache, the candidate for
  the [block-media regimes](#the-block-media-configuration-is-not-a-controlled-measurement-here),
  is one here too, and is untested. The share is 99.5–99.8 % with the tail and
  `file-block`'s 99.2–99.4 % without it, so the bracket does not depend on it.
- An insert takes 2.14–2.19 ms (median) on Magpie's `/home` against
  1.40–1.44 ms on the PC's NVMe, and 58.7 µs on Magpie's PMEM, so there the
  disk takes 36–37 times as long as PMEM. Wall time
  per insert during the load is 60.0 µs (`pmem-auto`), 127.6 µs (`file-dax`),
  2,167 µs (`file-block`) and 2,664 µs (`direct-block`).

**Height 2, not 3.** A third level needs the root, an internal node, to split,
which takes more than 253 leaves of one block each; the region has 256 blocks in
all, some of them the header, WAL and allocator metadata. At 252 keys per node
height 3 takes a larger region and, every node but the root being at least half
full, over 30,000 keys (253 × 126; arithmetic, not run). The unit tests and the
kill loop reach heights 3 and 4 with small node capacities instead.

#### Crash behaviour of the tree

`test/pwbtree.main.v3` is pwsieve's kill loop for the tree. A child applies a
seeded history of puts while the parent sleeps a random 50 µs–20 ms and sends
`SIGKILL`; the keys come from a bounded space, so the history starts with
inserts that split and grow the tree and moves on to updates. The parent
remounts with the production provider, opens the tree (which sweeps the kill's
leaks), runs the invariants, and compares the whole tree with a DRAM map at the
durable mutation count. Every acknowledged put must survive. The put in flight
may or may not, and the last phase mark the child reached, kept in memory
shared with the parent, says which: unpublished before the WRITE mark,
published from the PUBLISH mark on. Since a review on 2026-10-14 the loop says
`OK` only if at least one kill came after an acknowledged mutation, so that an
acknowledgement was checked; otherwise it ends `UNCHECKED` (exit 3). Before,
one short iteration killed after the first publish but before the child stored
its acknowledgement could pass having checked nothing. The runs below predate
the rule and made 44 or 45 such checks each, so their verdicts stand.
Capacity 8, keys from [0, 600), seed 1, 50 kills per run, unpinned, at
62300c6c (`results/20261014T042933Z-sean-tan-PC-pwbtree-kill`):

| Backend, sean-tan-PC NVMe | Ordinary provider | Elided-writeback mutant |
|---|---|---|
| `file` | `OK`: 45 acknowledged-mutation checks, 0 lost | `OK`: 45 checks, 0 lost (cannot discriminate) |
| `direct` | `OK`: 44 checks, 0 lost | **`LOST`**: 45 of 45 lost; 6,818 puts acknowledged, none durable |

- The ordinary runs' kills landed in every phase. A kill is filed under the
  last mark reached, so "after COMPUTE" is in the first allocation or the node
  writes. On `file`: 15 after COMPUTE, 16 after an ALLOC, 8 after WRITE, 7
  after PUBLISH and 4 after a FREE. On `direct`: 17, 13, 6, 7 and 6, and one
  while the child was still mounting. The put in flight was durable 19 times on
  each backend and not durable 31 (`file`) and 30 (`direct`) times, each time on
  the side its mark allows.
- The sweep reclaimed 95 leaked chunks on 44 of the 50 remounts (`file`) and 90
  on 42 (`direct`). The trees reached height 3 (169 and 160 keys, 34 nodes
  each).
- The mutant on `file` passes, as the sieve's does: process death leaves the
  page cache, so the image after a kill is the model's eager one. Its fences
  sync nothing, so its children acknowledged 6,756 puts against the ordinary
  children's 187, and ran the whole history (600 keys, height 4, 125 nodes). On
  `direct` process death discards what was never written back, and the mutant
  loses every acknowledged mutation.

Magpie used the same parameters, unpinned, at `82778885`
(`results/20261014T110033Z-magpie-pwbtree-kill`). The directory has no
provenance file; the revision is the commit its results were added on. PMEM ran
on `/mnt/pmem0.0/sean`, `file` and `direct` on `/home/users/u7599095`:

| Backend, Magpie | Ordinary provider | Elided-writeback mutant |
|---|---|---|
| `pmem` (DAX) | `OK`: 49 acknowledged-mutation checks, 0 lost | not run (process death leaves the cache, so it cannot discriminate) |
| `file` on `/home` | `OK`: 44 checks, 0 lost | not run (cannot discriminate) |
| `direct` on `/home` | `OK`: 19 checks, 0 lost | **`LOST`**: 37 of 37 lost; 1,969 puts acknowledged, none durable |

- The PMEM children acknowledged 2,956 puts and ran almost the whole history
  (597 keys, height 4, 124 nodes). On `/home`, where a boundary costs about
  0.5 ms, the `file` children acknowledged 119 and the `direct` ones 54. The
  sweep reclaimed 121 leaked chunks on 47 remounts (PMEM), 97 on 45 (`file`)
  and 36 on 19 (`direct`).
- **The direct run checked fewer acknowledgements.** 27 of its 50 children were
  killed before they confirmed their wiring, that is, while still mounting,
  against one on sean-tan-PC. That left 19 checks against the PC's 44. A direct
  mount reads the whole region, and pwopsbench times a 1 MiB direct mount on
  `/home` at 24.4 ms, longer than the loop's longest delay of 20 ms. Why 23
  mounts finished sooner is not established. More iterations, or a longer delay
  (the eighth argument), would check more; one check suffices for the verdict.

The deterministic counterpart is `pwbtree_dio:`: a child on the direct backend
is stopped at every phase mark of two mutations, an insert that splits a leaf,
every internal node on its path and the root (height 3 to 4), and an update at
height 4, then killed. Before the PUBLISH mark the remounted tree must be the
one before the mutation and from it on the one after, and the chunks reclaimed
must be exactly the new nodes allocated so far or the replaced nodes not yet
freed. What these runs show, and not, is what the sieve's
[show](#crash-behaviour-process-death-is-the-crash): process-crash consistency,
discriminating on the direct backend at a coarse grain (4 KiB units, drain-all
fences), and nothing about `CLWB`/`SFENCE` or power loss. The crash-image
explorer (layer 1b) checks those, and is in the next section.

#### What says the tree is consistent, and how far it reaches (2026-10-15)

Every check above ends in the same two calls. `PWBTree.checkInvariants()`
walks the durable tree from its root and returns the first violation:

- the root chunk is allocated, and its magic, block size and capacity are
  unchanged;
- every node's offset is block aligned and in the region; its tag carries the
  node magic and the level its depth implies, so every leaf is at the tree's
  height; and it holds no more keys than the capacity;
- keys strictly increase in every node and lie within the separators above it;
- no node is reached twice;
- every node below the root is at least half full, which splits alone keep,
  since there is no delete;
- every reachable node is an allocated chunk; and
- the keys and nodes it reaches equal the counts in the root.

`open()` runs it before trusting a tree, then frees every allocated chunk the
tree does not reach. `PWBTreeReference.compare()` compares every key and value
with an independent DRAM map. The unit tests run both after every mutation,
`pwbtreebench` after every round, and the kill loop after every kill, at the
durable mutation count.

**Each check fires.** `pwbtree:corrupted_image_fails_cleanly` plants the damage
a walk must survive: a cycle, a node at the wrong level, a shared child, heights
the tree does not have, and a root offset that wraps. `pwbtree:checker_names_each_violation`
plants each of the 21 violations `checkInvariants()` can report, in a tree of
height 3. It asserts which check names each, and that `open()` refuses it:
- keys out of order, below their separator, and at or above it, in leaves and
  in internal nodes;
- an internal node with no key, a node below half full, and one over capacity;
- a wrong node magic, an offset unaligned and one past the region, and a node
  at the wrong level;
- a node reached twice, and a reachable node in a freed chunk;
- key and node counts one too many, and heights of 0 and `MAX_HEIGHT + 1`;
- the root's magic, block size and capacity changed, and its chunk freed.

A build with the half-full check deleted fails the test, which names the check
that caught the plant instead. One half of one message is not planted: the root
chunk reached as a child. Its first word is the tree's magic, so the node magic
check refuses it first.

**Consistent is not durable.** The direct backend's elided-writeback mutant
above passed `checkInvariants()` and the comparison at every remount, holding an
empty tree, and still lost every acknowledged mutation. The acknowledgement
check caught it. The integrity checks cannot, because an older tree is a
consistent one.

**The tree in the crash-image explorer.** `persistent_btree:`
(`test/unittest/x86-64-linux/PersistentBTreeTest.v3`) does for the tree what
`persistent_sieve:` does for the sieve:
- **What it records.** One put's `STORE`/`CLWB`/`SFENCE` order, over a
  recording PMEM region of 32 blocks of 2 KiB at capacity 3. It then mounts the
  images a crash could leave through production recovery.
- **The two puts.** An insert that splits a leaf and the root, taking the tree
  from height 2 to 3: 5 new nodes, 8 boundaries and 4,601 events. And an update
  at height 3: 3 new nodes, 7 boundaries and 2,967 events.
- **The property.** The allocator's invariants, then `open()`, then
  `checkInvariants()`. Then the allocator again after the sweep's frees, and a
  second mount that finds nothing to reclaim. The contents must equal the tree
  before the put or after it, as the durable mutation count says. Up to the
  WRITE mark only the tree before is allowed, and from the PUBLISH mark on only
  the tree after.
- **The container.** Images are mounted in an anonymous mapping, not in a
  heap array, which `openArray()` used until 2026-10-19. The tree allocates
  while it is checked, a collection can move a heap array, and `PWRegion`
  keeps the raw address.

How far each check reaches. A cut admits the distinct images that the product
of its lines' classes counts. The log record is written a byte at a time, so a
line of it can hold many distinct contents. Counted on 2026-10-20, the insert's
busiest cut (2,908 of its 4,602) admits 1,194,997,579,776,000 distinct images,
and 4,422 of its cuts admit more than 16; the update's busiest (1,657 of 2,968)
admits 26,066,309,068,800, and 2,795 of its cuts admit more than 16:

- **Every cut, bounded.** The sweep checks up to 4 distinct images a cut, in
  the explorer's order: the extremes first (every line at its floor, every line
  at its last, then each line alone at its last with the rest at their floors),
  then class vectors drawn at random from a seed fixed by the trace and the
  cut. It checked 18,330 images for the insert and 11,818 for the update, and
  reports itself truncated. `persistent_sieve:`'s sweeps are bounded the same
  way. (Until 2026-10-20 this paragraph described the prefix odometer that
  preceded distinct images, which started from the floor image and varied the
  lowest lines first: up to about 2^70 images a cut, all but 72 of the insert's
  cuts above 16, and 18,167 and 11,730 images checked.)
- **The final cut, complete.** All 36 images the completed insert permits, and
  all 20 the update permits, hold the tree after the put.
- **Durable before published, complete.** From the WRITE mark to the end of the
  put, every new node's lines are at their floor, with nothing pending, at
  every cut. An image's lines range from the floor up, so no image at those
  cuts lacks a byte of a new node. This shows the tree's own ordering claim for
  every image without enumerating them.
- **The negative control.** The insert's trace loses its 10 node writebacks, the
  `CLWB`s between the build and the WRITE mark. That leaves 97 of 107 `CLWB`s,
  with the 8 `SFENCE`s unchanged. The mutant fails the complete line check and
  the bounded sweep (until 2026-10-19 this said "both complete checks", but the
  sweep is the bounded one and the final-cut check is not run on the mutant):
  - the line check, at the WRITE mark itself;
  - the sweep, at event 4,207 of 4,591, inside the publish's commit, with "the
    tree could not reopen after recovery".

  The kill loop cannot show this on PMEM or on a file, where the mutant passes.

What this does not show:
- The rest of the property (the log, the allocator, the contents) is checked
  only on the sample, except at the final cut and at the cuts that admit 4
  distinct images or fewer: 39 of the insert's 4,602 cuts and 31 of the
  update's 2,968 (counted 2026-10-20; the 33 and 27 given until then were
  counted before the explorer counted distinct images).
- It covers two puts at one geometry, not the benchmark's 4 KiB blocks and 252
  keys a node.
- It takes the bytes before the put as durable, as `persistent_sieve:` does.
- As for all of layer 1b, it assumes the hardware obeys the model.

#### What these numbers cannot show

- **Power loss on real hardware.** Magpie measured the PMEM share and the
  writebacks' cost (above), and its kill loop on DAX cannot discriminate. The
  tree's writeback placement is checked in the explorer under the baseline
  model (above), for two puts at a small geometry. No run cuts power.
- **The direct backend's tail on Magpie's `/home`.** It is observed in every
  repetition and not explained (above).
- **Five boundaries where the work needs two.** At height 2 a mutation's
  essential ordering is one fence over the new nodes, then one commit that
  allocates them, swaps the root and frees the old path. The other three
  boundaries belong to the allocator's interface: `allocChunk()` and
  `freeChunk()` each commit ([Design Critique](CRITIQUE.md) #1). An interface
  that buffered allocations and frees into the caller's transaction would make
  every mutation two boundaries whatever its height and splits, and leak
  nothing on a crash, provided the record holds the entries (by the
  [slot layout](#active-on-region-layout), a 4 KiB-block slot holds at most 58
  entries). With one writer, filling chunks whose allocation is not yet durable
  is safe, since nothing else can allocate them before the commit. On this
  storage that would bring a mutation to about two-fifths of its time
  (inference from the even per-boundary cost; not built).
- **Copy-on-write rewrites a path to change 8 bytes.** An update copies h nodes,
  about 95 lines and 5 boundaries, to change one value; a value update logged in
  place through the WAL would be one entry in one commit. It is not
  implemented: inserts would still need copy-on-write, since shifting a full
  leaf's keys rewrites up to 504 words against the 58 entries a record holds,
  and two write paths would double the crash argument. The cost is conceded: an
  update makes five boundaries where an in-place logged one would make one.
- **No delete, range scan or concurrency.** No merge or redistribution, so
  splits alone maintain the half-full invariant; no sibling links, which under
  copy-on-write would make each split rewrite its left neighbour and that
  neighbour's path; one writer.
- **A node is a block.** The capacity follows the block size (252 keys at
  4 KiB); smaller nodes would need several per chunk and an allocator inside the
  tree.
- **The clock, and height 2.** The PC's `powersave` caveat and the height limit
  are above. Magpie has no cpufreq driver, but its block runs block too. A run
  with a clock probe would separate the clock from the storage on either host.
  On Magpie turbostat has since measured the clock, about 1.0 GHz busy with the
  idle states enabled or not ([2026-10-16](#the-btrees-clock)), but not what
  sets it.

#### Reproducing the tree's figures, and on Magpie

```
# sean-tan-PC, block storage only, on a P-core: the commands behind the results above
make -j bin/unittest.x86-64-linux && bin/unittest.x86-64-linux 'pwbtree*'
mkdir -p bin/pwbtree-bench-block
PWBB_BLOCK_DIR=$PWD/bin/pwbtree-bench-block PWBB_CONFIGS="file-block direct-block" PWBB_CPUS=2 \
    PWBB_OUT=$PWD/results/<stamp>-sean-tan-PC-pwbtree-bench-cpus2-powersave \
    scripts/pwbtree-bench.sh campaign
make bin/pwbtree.x86-64-linux
for b in file direct; do for p in ordinary elide-clwb; do
    bin/pwbtree.x86-64-linux $PWD/bin/pwbtree-bench-block 50 1 256 4096 $b $p
done; done
```

```
# Magpie. Unit tests: the full binary (2,031 of 2,038 should pass, the 7 known
# failures failing), then the B+Tree's 22
make -j bin/unittest.x86-64-linux && bin/unittest.x86-64-linux
bin/unittest.x86-64-linux 'pwbtree*'

# What the host can run, then every configuration, pinned to the namespace's node
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean PWBB_BLOCK_DIR=/home/users/u7599095 \
    scripts/pwbtree-bench.sh doctor
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean PWBB_BLOCK_DIR=/home/users/u7599095 \
    PWBB_NUMA_NODE=0 scripts/pwbtree-bench.sh campaign

# The kill loop on DAX (cannot discriminate), through the file backend on /home,
# and through the direct backend, ordinary and then the mutant (must end LOST);
# UNCHECKED (exit 3) means no acknowledgement was checked: rerun with more iterations
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean make pwbtree-pmem
PWBTREE_DIR=/home/users/u7599095 make pwbtree
PWDIRECT_DIR=/home/users/u7599095 make pwbtree-direct
PWDIRECT_DIR=/home/users/u7599095 make pwbtree-direct-mutant
```

### Basic operations: what an allocation, a free, a mount and a recovery cost (2026-10-13)

pwbench times a commit whose shape the harness chooses, and the sieve times a
program. `test/pwopsbench.main.v3` times the operations the interface offers,
one at a time, in the form of Corundum's Table 5 (Hoseinzadeh and Swanson,
ASPLOS '21), which gives basic-operation latencies over 50,000 operations.
Every operation goes through the production `PWRegion`, `RegionTransaction` and
`DualTxnWal` on each backend. Corundum's BST, KVStore and B+Tree workloads are
out of scope; the sieve above is this project's workload.

| Operation | What is timed | Persistence work |
|---|---|---|
| `alloc-1`, `alloc-8`, `alloc-64` | `PWRegion.allocChunk(n)` of n 4 KiB blocks, its own committed transaction | one boundary |
| `free-1`, `free-8`, `free-64` | `freeChunk()` of that chunk, its own transaction | one boundary |
| `commit-empty` | `RegionTransaction.commit()` with nothing buffered | none: it returns before the WAL (`X86_64TxnPWRegion.v3:444`) |
| `timer` | an empty `rdtsc` window | the floor under every figure |
| `mount-1mib`, `mount-64mib` | opening a cleanly closed region of 256 or 16,384 blocks | none: `close()` scrubbed the log, recovery reports `CLEAN` |
| `recover-8`, `recover-24` | opening a 1 MiB region whose log holds one committed, unapplied transaction of 8 or 24 `u64` entries | one boundary, the replay; recovery reports `REPLAYED` |
| commit of 1, 8, 24 entries | not measured here: pwbench's, [below](#commits-of-k-entries-pwbenchs-figures) | one boundary |

**Method.**

- **One chunk, alternating.** Allocations and frees run on a freshly
  formatted 1 MiB region (256 × 4 KiB) whose user blocks are one free chunk.
  `alloc-n` splits it and `free-n` coalesces it back, so each operation leaves
  the allocator as it found it, and every operation of a kind does the same
  work: an allocation commits 16 entries and a free 10, whatever n. For each n
  in turn, 2,000 unmeasured then 50,000 measured allocation–free pairs, each
  operation timed on its own. Then 2,000 and 50,000 empty commits, and the
  same of the empty timer window.
- **The work is checked on every operation, not sampled.** Counting backends
  (duplicated from pwsievebench, not shared) count boundaries, prepare calls
  and writeback requests (lines). An allocation or free must make exactly one
  boundary and write back the record's lines plus each distinct line its
  after-images touch; that expectation is derived from the record the commit
  wrote (`PWOps.latestRecord()`, read through a second `DualTxnWal` over the
  same log) during warm-up, and every measured operation must match it. An
  empty commit and a clean mount must do nothing; a recovery of k entries one
  boundary and k lines, because `redoSlot()` replays through `applyUpdate()`,
  which prepares each entry on its own (`X86_64DualTxnWal.v3:426`), while
  commits use the batched apply. Any mismatch fails the run with exit 1 and
  keeps the region image (tested by mutating an expectation). The suite hosts
  have no DAX mount, so `PWOpsTest.v3`'s six tests check the same expectations
  on the production `PmemMmapRegion` boundary over anonymous memory, recording
  every `CLWB` and `SFENCE`.
- **How the recovery state is produced.** `PWOps.commitUnapplied()`, which is
  `PmemDaxIntegrationTest`'s recipe: open the cleanly closed region's backend
  directly, without a `PWRegion`, build the production `DualTxnWal` over it,
  append k `u64` after-images to a chunk allocated for them, and `commit()`,
  which writes the record and its commit-point boundary exactly as a
  `RegionTransaction` commit does. Nothing is applied, and the backend region
  is destroyed without `close()`, which would persist the data and scrub the
  record. The durable state is a crash straight after a commit point: the
  record valid, its after-images absent. That setup is untimed. The timed
  mount must report `REPLAYED` with the expected counts, and afterwards every
  replayed value (distinct per sample, so a replay that did nothing is caught)
  and the allocator's invariants are checked.
- **Mounts are interleaved.** 20 unmeasured and 200 measured samples of each
  kind (a direct mount reads the whole region). `mount-1mib`, `recover-8` and
  `recover-24` alternate within each sample, so `replay-k = recover-k −
  mount-1mib` compares like with like. In a first version each kind had its own
  loop, the recoveries running after the 64 MiB mounts, and on the direct
  backend `recover-8` measured 591 µs against `mount-1mib`'s 785 µs: a negative
  replay. What the order changed was not isolated.
- **`pmem-none` is not eADR.** `writeback=none` drops `CLWB` and keeps
  `SFENCE`, which approximates the timing of an eADR platform, where the
  caches are inside the persistence domain. Magpie is ADR (`memory_controller`
  persistence domain, `docs/pmem-emulation.md`), so there it is a timing
  configuration that is never durable, and its runs end `OK timing-only`. The
  direct backend has no such configuration: its writeback request only marks a
  unit for the boundary to write.
- **Reported:** per run, the minimum, median, p90, p99, maximum and mean in ns
  (TSC calibrated per run); over five repetitions, interleaved with the
  configuration innermost, the median of each statistic and the spread of the
  per-run medians, `(max − min) / median`. A difference is real only outside
  both spreads. `scripts/pwops-bench.sh` refuses a dirty tree and records the
  commit, host, CPU, governor, idle states, mount options, the block device's
  write cache and the load.

**sean-tan-PC, NVMe, P-core, `powersave`**
(`results/20261013T084519Z-sean-tan-PC-pwops-bench-cpus2-powersave`). i7-14700KF
pinned to CPU 2 (a performance core), block storage the Solidigm NVMe root
(ext4, write cache `write back`), five repetitions, 15.5 minutes, start load
0.36. The emulated PMEM was not mounted that day, so the DAX configurations
wait for Magpie, and the governor could not be changed without root (see the
last point below). ns per operation, the median over repetitions of each run's
median and p90, with the spread of the medians; the work column is the direct
backend's, and the file backend's was the same with 0 lines, since its
preparation then made no writeback request (since 2026-10-13 it is the same
with the lines; [old against new](#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)):

| Operation | `file` median | `file` p90 | `direct` median | `direct` p90 | entries / boundaries / lines |
|---|---|---|---|---|---|
| `alloc-1` | 283,242 (0.2 %) | 300,624 | 305,654 (0.1 %) | 306,872 | 16 / 1 / 15 |
| `alloc-8` | 283,665 (0.4 %) | 307,326 | 305,787 (0.3 %) | 307,069 | 16 / 1 / 17 |
| `alloc-64` | 290,233 (7.4 %) | 310,017 | 280,677 (0.2 %) | 304,846 | 16 / 1 / 17 |
| `free-1` | 275,217 (0.3 %) | 298,415 | 301,849 (6.9 %) | 303,719 | 10 / 1 / 11 |
| `free-8` | 275,748 (1.0 %) | 300,496 | 302,485 (8.1 %) | 303,926 | 10 / 1 / 13 |
| `free-64` | 299,285 (2.4 %) | 303,094 | 277,561 (0.1 %) | 279,053 | 10 / 1 / 13 |
| `commit-empty` | 6 | 7 | 6 | 7 | 0 / 0 / 0 |
| `timer` | 4 | 5 | 4 | 6 | 0 / 0 / 0 |
| `mount-1mib` | 16,161 (4.1 %) | 18,976 | 652,609 (9.2 %) | 700,938 | 0 / 0 / 0 |
| `mount-64mib` | 14,213 (2.0 %) | 17,185 | 9,644,380 (1.1 %) | 9,758,914 | 0 / 0 / 0 |
| `recover-8` | 271,888 (0.8 %) | 273,051 | 903,255 (10.3 %) | 954,945 | 8 / 1 / 8 |
| `recover-24` | 272,031 (0.7 %) | 276,408 | 942,416 (6.2 %) | 992,542 | 24 / 1 / 24 |
| `replay-8` (derived) | 255,727 | | 250,646 | | |
| `replay-24` (derived) | 255,870 | | 289,807 | | |

The lines are what the PMEM backend issues for the same operation: the direct
backend's requests come from the same provider calls, which is the trace
identity `DirectIoRegionTest` pins, and `PWOpsTest` checks the counts on the
PMEM path itself.

- **An allocation or a free is one boundary, and on this drive it costs what a
  boundary costs.** 275–299 µs on the file backend and 278–306 µs on the direct
  one, against pwbench's whole 8-entry commit of 265 µs (file) and 267 µs
  (direct) on the same drive (2 MiB region, `20260927T083305Z`, governor not
  recorded). The allocator's own work does not show at this scale: 64 blocks
  cost what one does, because a split commits the same 16 fields whatever its
  size, and a coalescing free 10.
- **What does vary on the direct backend is the number of writes.** `strace`
  of a short run: an allocation's boundary writes units 0–2 (header, log, first
  user block) as one `pwrite` and block-table units 253 and 255 as two more,
  then `fdatasync`; a free writes units 0–1 and the same two. At n = 64 the
  split also touches unit 254, so 253–255 coalesce and the boundary makes two
  writes. That is the 25 µs by which `alloc-64` and `free-64` undercut the
  other sizes (281 and 278 µs against 302–306 µs), about one O_DIRECT write on
  this drive (~23 µs, [above](#cost-the-same-seam-call-a-different-persistence-point));
  pwbench's commit, which makes one write, is 267 µs. On the file backend,
  whose boundary is one `fdatasync` and no `msync`, n = 64 goes the other way:
  `free-64` is 293–300 µs against 275–278 µs in every repetition, and
  `alloc-64` 284–306 µs against 283–284 µs. Not explained by this host alone;
  Magpie suggests a reason (below).
- **The 7–8 % spreads are two modes.** A run's median lands near one of two
  levels about 20 µs apart: the direct `free-1` median is 301–303 µs in four
  repetitions and 282 µs in the fifth, `free-8` 278 µs in one of five, the file
  `alloc-64` 305–306 µs in two. Each run is internally tight; which level a run
  takes is not explained.
- **An empty commit is no boundary.** `RegionTransaction.commit()` returns
  `true` before the WAL when nothing is buffered: no record, store, writeback
  or fence, checked on all 52,000 calls and by `pwops:empty_commit_issues_nothing`.
  It costs 5–6 ns against the empty window's 4–5 ns, 1–2 ns over the floor.
  Their spreads (17 % and 25 %) are integer nanoseconds.
- **A clean mount is flat in region size on the file backend, and a read of
  the whole region on the direct one.** File: 16.2 µs at 1 MiB, 14.2 µs at
  64 MiB, opening and mapping the file and checking the header and log, with
  pages faulted in only when touched. Direct: `DirectIoRegion.create()` reads
  the region into its staging buffer (`X86_64DirectIoBackend.v3:397`), and
  `strace -T` shows that one `pread` is the mount's time. 64 MiB in 9.64 ms is
  about 7 GB/s; at that rate 1 MiB would take 0.15 ms, so most of the 1 MiB
  mount's 0.65 ms is not transfer, and 64 times the region costs 14.8 times as
  long. The direct
  1 MiB mount is also unsteady, run medians 640–701 µs with one run's minimum
  at 397 µs. That the file backend's 1 MiB mount is slower than its 64 MiB one
  is plausibly the clock (last point): the 1 MiB samples alternate with
  recoveries that block in `fdatasync`, while the 64 MiB mounts run back to
  back and never block. Untested, and Magpie shows the same on PMEM, where
  nothing blocks, so the clock is at most part of it (below). The 64 MiB
  figure is itself mostly a transient at the start of its 200-sample loop:
  over 5,000 samples it is 3.8–3.9 µs ([measured 2026-10-13](#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)).
- **A recovery is a mount plus one boundary.** The replay costs 256 µs on the
  file backend at both sizes, one `fdatasync` (pwbench's file boundary on this
  drive is 237 µs). On the direct backend 251 and 290 µs; the 39 µs between 8
  and 24 entries is inside `recover-8`'s 10 % spread.
- **All of it is under `powersave`.** On this host a thread that blocks comes
  back at about a third of its busy clock ([the sieve above](#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence)),
  so the work around each boundary runs slow. Figures dominated by a boundary
  move little; the file mounts, and whatever each operation spends outside its
  boundary, are inflated. A rerun under `performance` separates the two.

**Magpie, PMEM and `/home`, node 0**
(`results/20261013T114908Z-magpie-pwops-bench`). Xeon Gold 6252N pinned to
node 0, which owns the namespace; `pmem-auto`, `pmem-none` and `file-dax` on
`/mnt/pmem0.0/sean`, `file-block` and `direct-block` on `/home/users/u7599095`
(ext4 on LVM on the rotational `sda` behind the write-through controller,
[above](#cost-the-same-seam-call-a-different-persistence-point)); five
repetitions, 41 minutes, start load 0.01. All 25 runs ended `OK` (`pmem-none`'s
`OK timing-only`), so every operation did exactly the work expected of it. ns
per operation, the median over repetitions of each run's median, with the
spread of the medians; the p90s are in `summary.txt`. The work per operation is
the sean-tan-PC table's on every configuration, with 0 lines on `file-dax` and
`file-block`. The run is at commit `8b364dc2` (its `provenance.txt`), before
the file backend's boundary changed on 2026-10-13, so the `file-dax` and
`file-block` rows are the legacy boundary, hence the 0 lines. The change's
effect on Magpie, and the whole table again in one sitting at the current
boundary, are [below](#magpie-again-every-backend-in-one-sitting-2026-10-14)
([old against new](#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)):

| Operation | `pmem-auto` | `pmem-none` | `file-dax` | `file-block` | `direct-block` |
|---|---|---|---|---|---|
| `alloc-1` | 15,788 (0.1 %) | 14,412 (0.1 %) | 33,146 (2.7 %) | 512,489 (8.6 %) | 517,780 (6.3 %) |
| `alloc-8` | 16,301 (0.3 %) | 14,492 (0.1 %) | 33,526 (2.1 %) | 512,953 (9.5 %) | 517,658 (6.9 %) |
| `alloc-64` | 16,117 (0.1 %) | 14,491 (0.2 %) | 37,136 (2.1 %) | 414,476 (8.3 %) | 393,630 (11.8 %) |
| `free-1` | 10,993 (0.3 %) | 9,957 (0.1 %) | 29,342 (2.8 %) | 496,754 (7.9 %) | 496,832 (6.6 %) |
| `free-8` | 11,416 (0.4 %) | 10,042 (0.3 %) | 29,851 (2.0 %) | 496,835 (8.7 %) | 496,380 (7.2 %) |
| `free-64` | 11,420 (0.4 %) | 10,041 (0.4 %) | 33,539 (2.2 %) | 402,862 (8.4 %) | 376,666 (12.0 %) |
| `commit-empty` | 14 | 13 | 14 | 13 | 14 |
| `timer` | 11 | 13 | 11 | 12 | 12 |
| `mount-1mib` | 9,367 (15.0 %) | 9,240 (1.5 %) | 9,970 (13.1 %) | 34,632 (14.3 %) | 24,368,514 (0.1 %) |
| `mount-64mib` | 5,763 (0.4 %) | 5,790 (0.6 %) | 5,768 (1.0 %) | 23,751 (2.2 %) | 503,308,559 (3.8 %) |
| `recover-8` | 20,864 (7.6 %) | 14,850 (1.0 %) | 19,373 (8.1 %) | 190,176 (11.8 %) | 21,778,030 (0.1 %) |
| `recover-24` | 36,911 (5.2 %) | 20,515 (0.6 %) | 25,678 (5.9 %) | 209,829 (10.2 %) | 24,815,807 (0.0 %) |
| `replay-8` (derived) | 11,497 | 5,610 | 9,403 | 155,544 | −2,590,484 |
| `replay-24` (derived) | 27,544 | 11,275 | 15,708 | 175,197 | 447,293 |

- **On PMEM an allocation costs what a commit of as many entries does.** An
  allocation commits 16 entries and a free 10. pwbench's commits on this host
  (below; means, 1 MiB, stride 8) interpolate to 15.5 µs at 16 entries and
  10.9 µs at 10; `alloc-n` takes 15.8–16.3 µs and `free-n` 11.0–11.4 µs.
  Without writeback, 14.4–14.5 µs against 14.7 µs and 10.0 µs against 10.05 µs.
  The allocator's search and bookkeeping add nothing visible, to within 5 %,
  beyond the entries they commit. Spreads are 0.1–0.4 %.
- **The writebacks cost about 0.1 µs a line.** `pmem-auto − pmem-none`, paired
  within each repetition: 1.38 µs for `alloc-1`'s 15 lines, 1.62–1.81 µs for
  the other sizes' 17, 1.04 µs for `free-1`'s 11 and 1.38 µs for 13. That is
  92–106 ns a line, 9–12 % of the operation.
- **The recovery prediction held.** It was: replay prepares each entry on its
  own, so on Cascade Lake, where `CLWB` evicts, each replayed entry after the
  first in its line stores into a line just written back, the cost the batched
  apply removed from commits
  ([above](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows)).
  The entries start 32 bytes into a line, after the chunk header, so 24 span
  four lines and make 20 such stores, and at ~775 ns each `replay-24` on
  `pmem-auto` should exceed `pmem-none`'s by roughly 15 µs. Per repetition it
  exceeds it by 15.9–16.8 µs, about 0.8 µs a store; for 8 entries (two lines,
  six such stores) by 5.6–5.9 µs. The writebacks are 51 % (8 entries) and 59 %
  (24) of the replay, and the PMEM backend replays slower than the file backend
  on DAX: 27.5 µs against 15.7 µs at 24 entries, the inversion the batched apply
  removed from commits. It is paid once per recovery, not per commit. Replaying
  through `storeUpdate()` and `prepareApplied()` would remove it; not done.
- **Interleaving the mounts paid off.** On `pmem-auto`, `mount-1mib` and both
  recoveries sit about 1.2 µs lower in repetitions 2 and 3 than in the others,
  all three together, hence their 5–15 % spreads; `file-dax`'s repetition 5 does
  the same. The paired differences cancel it: `pmem-auto`'s `replay-8` is
  11.2–11.6 µs in every repetition. Which level a run takes is not explained.
- **At n = 64 a boundary writes one page more, in one write fewer, and each
  medium charges for a different half.** On sean-tan-PC `strace` showed that at
  n = 64 the operation also touches unit 254, so units 253–255 go out together.
  Per repetition, n = 64 minus n = 8:
  - `file-dax`: +3.5 to +3.9 µs, allocations and frees alike. At this region
    size the kernel's `fdatasync` writes back each dirty 4 KiB page whole
    ([above](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries)), so
    one more page is 64 more lines, ~57 ns each.
  - `file-block` −80 to −102 µs, `direct-block` −119 to −136 µs: on this
    volume a separate write costs of the order of the 144–178 µs `pwrite`
    measured [above](#cost-the-same-seam-call-a-different-persistence-point).
  - PMEM: 17 lines at either size. `pmem-none` shows no difference;
    `pmem-auto`'s allocations are 0.17–0.20 µs cheaper (different lines, not
    pursued).

  The same split would explain sean-tan-PC's results: the direct backend saves
  a `pwrite` (25 µs); the file backend's writes leave together from one
  `fdatasync` to an NVMe that serves them in parallel, so the extra page is what
  remains to pay (7–22 µs). That is a candidate, not tested.
- **On `/home` an allocation is three writes.** `alloc-1` costs 512–518 µs
  against pwbench's 213–214 µs for a commit that makes one write (below), and
  `alloc-64`, two writes, 394–414 µs. On sean-tan-PC, where an O_DIRECT write
  is ~23 µs, the same three writes cost an allocation 9–19 % more than
  pwbench's one-entry commit.
- **A direct mount on `/home` is a read off the disk, and replay cannot be had
  by subtraction there.** 1 MiB takes 24.4 ms and 64 MiB 503 ms (about
  133 MB/s; 64 times the data takes 20.7 times as long). The three interleaved
  kinds each take a reproducible time, spreads 0.0–0.1 %, but not the same one:
  `recover-8` 21.8 ms, `mount-1mib` 24.4 ms, `recover-24` 24.8 ms. Their timed
  windows differ only by the replay and by what ran just before the read (a
  recovery's setup reads the region, writes the log and calls `fdatasync`; the
  clean mount follows the previous recovery's `close()`), and a replay cannot
  be negative, so the gap belongs to the storage. `replay-8` comes out at
  −2.6 ms in every repetition and `replay-24` at +0.45 ms; neither measures a
  replay. Timing the read apart from the rest of the mount would; pwopsbench
  does not.
- **On DAX too the 1 MiB mount is the dearer one, which the clock cannot
  explain.** `mount-1mib` is 9.2–10.0 µs against `mount-64mib`'s 5.8 µs on all
  three DAX configurations (34.6 µs against 23.8 µs on `/home`). On sean-tan-PC
  this section put the file backend's version down to the clock, since the
  1 MiB mounts follow recoveries that block; on PMEM nothing blocks, so that
  does not explain it here. A candidate is the mapping: a 1 MiB DAX file is
  mapped with 4 KiB entries and a 64 MiB one with 2 MiB entries
  ([above](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries)), so the
  pages a mount touches cost a fault each at 1 MiB and share one per 2 MiB at
  64 MiB. Untested: pwopsbench counts no faults, and it would not cover `/home`'s
  page-cache file.
- **The first repetition on block storage was faster.** On both block
  configurations repetition 1 ran 6–12 % faster than the others on allocations
  and frees (and on `file-block`'s recoveries); repetitions 2–5 agree to within
  0.1–1.9 %, so the 6–12 % spreads of the block allocations and frees are that
  one run. Not explained; the n = 64 differences above are well outside it.
- **An empty commit is no boundary here either:** 13–14 ns against the empty
  window's 11–13 ns.

#### Magpie again, every backend in one sitting (2026-10-14)

Two campaigns ran the evening after, at the current file boundary, with the same
host, pinning (node 0), directories and parameters as above:

- `results/20261014T113013Z-magpie-pwops-bench`: the file backend's
  boundary new against legacy (`file-dax`, `file-block` and their `-legacy`
  variants), at `d45f5047`. It took 27 minutes, and all 20 runs ended `OK`.
- `results/20261014T121109Z-magpie-pwops-bench`: all five configurations, at
  `fc73b0a6`, whose engine code is `d45f5047`'s. It took 39 minutes from a start
  load of 0.00, and all 25 runs ended `OK` (`pmem-none`'s `OK timing-only`).

Both summaries recompute from their `runs.csv`. Every configuration now does
the same work per operation, the sean-tan-PC table's, because the file backend
writes its lines back at the boundary. The table is the second campaign's, in ns
with the spread of the medians:

| Operation | `pmem-auto` | `pmem-none` | `file-dax` | `file-block` | `direct-block` |
|---|---|---|---|---|---|
| `alloc-1` | 15,542 (0.3 %) | 14,006 (0.1 %) | 33,649 (1.6 %) | 455,040 (0.1 %) | 450,697 (0.6 %) |
| `alloc-8` | 16,047 (0.3 %) | 14,094 (0.1 %) | 34,024 (1.0 %) | 455,574 (0.1 %) | 450,943 (0.2 %) |
| `alloc-64` | 15,850 (0.3 %) | 14,101 (0.1 %) | 38,028 (0.6 %) | 383,906 (3.7 %) | 355,854 (0.3 %) |
| `free-1` | 10,818 (0.3 %) | 9,717 (0.1 %) | 29,657 (1.9 %) | 438,727 (0.2 %) | 431,646 (0.6 %) |
| `free-8` | 11,231 (0.3 %) | 9,779 (0.1 %) | 30,344 (1.4 %) | 439,329 (0.2 %) | 431,425 (0.3 %) |
| `free-64` | 11,238 (0.4 %) | 9,781 (0.1 %) | 34,219 (0.3 %) | 367,833 (2.1 %) | 339,342 (0.3 %) |
| `commit-empty` | 13 | 13 | 13 | 13 | 13 |
| `timer` | 12 | 12 | 12 | 13 | 13 |
| `mount-1mib` | 8,088 (16.2 %) | 9,131 (14.9 %) | 8,869 (14.8 %) | 31,780 (15.8 %) | 24,391,189 (0.0 %) |
| `mount-64mib` | 5,755 (3.6 %) | 5,761 (0.8 %) | 7,538 (9.0 %) | 8,809 (48.7 %) | 525,819,999 (1.6 %) |
| `recover-8` | 19,288 (8.1 %) | 14,653 (10.1 %) | 18,306 (8.5 %) | 176,296 (2.8 %) | 21,786,751 (0.1 %) |
| `recover-24` | 35,798 (5.5 %) | 20,213 (7.9 %) | 25,025 (6.3 %) | 195,552 (1.9 %) | 24,814,042 (0.0 %) |
| `replay-8` (derived) | 11,200 | 5,522 | 9,437 | 144,516 | −2,604,438 |
| `replay-24` (derived) | 27,710 | 11,082 | 16,156 | 163,772 | 422,853 |

- **Quote one sitting: Magpie's block storage moved 12–13 % overnight.** The
  legacy file boundary's `alloc-1` on `/home` took 512,489 ns on 2026-10-13 and
  451,646 ns on 2026-10-14, and `direct-block`'s took 517,780 against
  450,697 ns. That is the [block-media regime
  shift](#the-block-media-configuration-is-not-a-controlled-measurement-here)
  again. The two evening campaigns agree to within 0.3 % on `/home` for every
  allocation and free, and to within 0.8 % on DAX. PMEM moved too, though less:
  `pmem-auto`'s `alloc-1` and `free-1` are 1.6 % lower than on 2026-10-13, and
  `pmem-none`'s `alloc-1` 2.8 %, outside the spreads.
- **On one host and one sitting, the disk takes 29 times as long as PMEM for an
  allocation.** `alloc-1` takes 15.5 µs on `pmem-auto`, 33.6 µs with the file
  backend on DAX (2.2 times), and 455.0 and 450.7 µs with the file and direct
  backends on `/home`.
- **The file backend's current boundary costs 2–4 % on DAX and under 1 % on
  `/home`.** In the first campaign, against the legacy boundary interleaved
  with it, the cost is +2.3 to +3.7 % at every size on DAX. On `/home` it is
  +0.5 to +0.7 % at n = 1 and 8, outside the spreads, and inside them at
  n = 64.
- **Direct is cheaper than the file backend on `/home` in one sitting.** It is
  1.0–1.8 % cheaper at n = 1 and 8, and 7.3–7.7 % at n = 64, where it saves a
  write ([above](#basic-operations-what-an-allocation-a-free-a-mount-and-a-recovery-cost-2026-10-13)).
  This is in line with the 2–6 % at 2 MiB
  ([above](#cost-the-same-seam-call-a-different-persistence-point)).
- **The writebacks are 10–13 % of a PMEM allocation or free.**
  `pmem-auto − pmem-none` is 1,101–1,953 ns (9.9–13.0 %), as on 2026-10-13.
- **The direct mount reproduces.** A direct mount of 1 MiB takes 24.4 ms and
  of 64 MiB 526 ms (21.6 times), and `replay-8` again comes out at −2.6 ms.

#### Commits of k entries: pwbench's figures

Not re-measured; wall time per commit, the median over repetitions of each
run's mean:

| Host and configuration | 1 entry | 8 entries | 24 entries | Source |
|---|---|---|---|---|
| Magpie, `pmem`, production (batched apply) | 4.5 µs | 9.4 µs | 21.6 µs | `20260928T051804Z`, 1 MiB, stride 8, node 0 |
| Magpie, `pmem`, no writeback | 3.8 µs | 8.5 µs | 20.9 µs | same |
| Magpie, `file` on DAX | 12.7 µs | 17.3 µs | 29.3 µs | same |
| Magpie, `file` on `/home` | 213 µs | 220 µs | 255 µs | `20260927T080050Z`, 1 MiB |
| Magpie, `direct` on `/home` | 214 µs | 215 µs | 245 µs | same |
| Raptor Lake P-core, `pmem` (DRAM-emulated), production | 0.95 µs | 2.12 µs | 5.25 µs | [table above](#on-raptor-lake-clwb-does-not-evict-and-the-same-line-store-is-still-the-cost), `performance` |
| same, no writeback | 0.91 µs | 2.08 µs | 5.21 µs | same |
| same, `file` on DAX | 3.47 µs | 4.63 µs | 7.67 µs | same |
| Raptor Lake, `file` on NVMe | 260 µs | 265 µs | — | `20260927T083305Z`, 2 MiB, governor not recorded |
| Raptor Lake, `direct` on NVMe | 257 µs | 267 µs | — | same |

#### Reproducing

```
make bin/pwopsbench.x86-64-linux     # the campaign also builds it
scripts/pwops-bench.sh doctor        # what this host can run, and why not

# sean-tan-PC, block storage only, on a performance core:
PWOB_BLOCK_DIR=$PWD/bin/pwops-bench-block PWOB_CONFIGS="file-block direct-block" \
    PWOB_CPUS=2 scripts/pwops-bench.sh campaign

# Magpie, every configuration, pinned to the namespace's node:
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean PWOB_BLOCK_DIR=/home/users/u7599095 \
    PWOB_NUMA_NODE=0 scripts/pwops-bench.sh campaign
```

Each campaign writes `results/<stamp>-<host>-pwops-bench[-cpus<list>]/` with
every run's log, `runs.csv`, `summary.txt` and `provenance.txt`;
`scripts/pwops-bench.sh summary <dir>` recomputes the summary, and `rebuild
<dir>` re-derives `runs.csv` from the logs first. `PWOB_REPS`, `PWOB_OPS`,
`PWOB_WARMUP`, `PWOB_MOUNTS` and `PWOB_MOUNT_WARMUP` default to 5, 50,000,
2,000, 200 and 20.

### Region size at fixed block size, and the NUMA penalty at 1 MiB

Measured 2026-09-23 on Magpie, two campaigns back to back, 1, 8 and 24 entries,
three repetitions, geometries interleaved within each repetition:

- `results/20260923T052859Z-magpie-g512x2048-256x4096-512x4096`, node 0.
  256 × 4096 is a 1 MiB region with the 2 MiB baseline's block size, so the same
  WAL slot and the same write positions; 512 × 2048 is the earlier 1 MiB
  geometry.
- `results/20260923T053541Z-magpie-g256x4096-512x4096`, node 1 (remote from the
  namespace), for the cross-socket penalty at both region sizes.

pwbench's seventh argument supplies the block count. Every cell's three runs
agree to within 0.5 %, except the ~5 µs `file-dax` cells, which spread by 2–6 %
(the widest because of one run at 5.5 µs).

**Region size alone sets the DAX cost.** Medians, node 0:

| Configuration | 512 × 2048 (1 MiB) | 256 × 4096 (1 MiB) | 512 × 4096 (2 MiB) |
|---|---|---|---|
| `file-dax`, 1 / 8 / 24 entries | 5,102 / 5,011 / 4,999 ns | 5,202 / 5,038 / 4,964 ns | 928,441 / 928,149 / 926,761 ns |
| `pmem-dax` whole boundary | 138 / 454 / 1,210 ns | 138 / 454 / 1,212 ns | 138 / 454 / 1,209 ns |
| `file-block` | 168.5 / 157.9 / 156.8 µs | 170.1 / 159.3 / 157.8 µs | **132.7 / 132.6 / 133.1 µs** |

Both 1 MiB geometries give the same `file-dax` cost to within 2 %, so the
~185× drop comes from region size, not from the smaller block's WAL slot or
write positions, as predicted. `pmem-dax` is unchanged at all three, as
predicted. At 1 MiB the file backend on DAX is again 1.26× slower per commit
than the PMEM backend at eight entries and 1.30× faster at 24, reproducing the
matched-geometry campaign.

**The block configuration's "geometry effect" was a regime change.** The two
1 MiB geometries also agree with each other for `file-block`, to within 1 %, so
block size and write position are excluded. But the 2 MiB baseline is now
**flat at ~133 µs**, the regime the 2026-09-18 unpinned campaigns saw first,
where 50 minutes earlier it was 196 → 170 µs. The 1 MiB file has not moved:

| Campaign (2026-09-23) | Node | 1 MiB (either geometry) | 2 MiB |
|---|---|---|---|
| `043535Z` | 0 | 168.6 / 157.8 / 156.7 µs | 196.6 / 180.5 / 170.5 µs |
| `052859Z` | 0 | 168.5–170.1 / 157.9–159.3 / 156.8–157.8 µs | 132.7 / 132.6 / 133.1 µs |
| `053541Z` | 1 | 170.6 / 160.2 / 158.6 µs | 134.1 / 133.5 / 134.0 µs |

So "1 MiB is 8–14 % cheaper" became "1 MiB is 18–28 % dearer" between
campaigns, and neither is a property of region size. The 2 MiB file has now
shown both regimes on one day, and switches between them on a timescale of tens
of minutes. Every repetition in a campaign lands in the same regime, even
though each run creates and removes its own file. The 1 MiB file has shown one
state in all four measurements across three campaigns, to within 1.5 %. What
selects the regime is **not established**. One untested candidate: each run
creates and unlinks a file of the same size, so ext4 may hand the next run the
blocks the last one freed, which would make physical placement on the shared
LVM volume sticky across runs until other traffic takes those blocks. Running
`filefrag -v` on the `/home` region file in each regime would test it without
root. Reuse does happen: on 2026-10-16 two traced runs' region files, each
created and removed in turn, occupied the same sectors
([root sitting](#what-acknowledges-a-write-on-home)). Whether it selects the
regime is still untested.

**The NUMA penalty is proportional to what `fdatasync` flushes.** Node 1
against node 0:

| Configuration | Region | Node 0 | Node 1 | Penalty |
|---|---|---|---|---|
| `file-dax`, 1 / 8 / 24 entries | 2 MiB | 928.4 / 928.1 / 926.8 µs | 1,148.5 / 1,145.5 / 1,147.0 µs | **+220 / +217 / +220 µs** (+23.4–23.8 %) |
| | 1 MiB | 5.20 / 5.04 / 4.96 µs | 6.08 / 6.04 / 6.04 µs | **+0.88 / +1.00 / +1.08 µs** (+17–22 %) |
| `pmem-dax` whole boundary | both | 138 / 454 / 1,210 ns | 138 / 454 / 1,210 ns | none |
| `file-block` | both | | | +0.3–1.1 % |

The absolute penalty falls by a factor of about 220 when the region drops to
1 MiB. That fits the 2 MiB entry explanation: the penalty is ~6.7 ns per line
flushed at 2 MiB (220 µs over 32,768 lines), and at the same rate two 4 KiB
pages (128 lines) would cost 0.86 µs, against 0.88–1.08 µs measured. The
two-page figure is itself inferred, not traced. The percentage is lower at
1 MiB, consistent with part of the 5 µs being per-call work that does not cross
the socket. **The NUMA finding and the region-size finding are one mechanism**:
cross-socket placement makes each flushed line dearer, and the 2 MiB entry
decides how many lines are flushed.

The PMEM boundary is again immune. The PMEM *commit* is not quite: wall time per
commit is 6–10 % higher on node 1 (13.5 → 14.3 µs at eight entries and 38.2 →
40.4 µs at 24, both at 1 MiB). That cost is outside the boundary, presumably the stores
themselves reaching memory on the other socket. The earlier NUMA table did not
report it because it compared boundaries only.

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

**Correction (2026-09-28).** The 3 % and the 29× count only the cycles inside
`rdtsc`-bracketed `CLWB` calls. Measured by removing the writebacks, they cost
14–43 % of a PMEM commit at 1–24 entries (36 % at eight), because on Cascade
Lake `CLWB` evicts the line and the after-image loop stores into lines it has
just written back; with one entry per line the same writebacks cost 7 % at 24
entries. The fence is still cheap and a boundary is still noise; the
writebacks are not. See
[`CLWB` evicts on Cascade Lake](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows).

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
`PWEXP_SIZES="1 8 32 56"`, 20,000 commits after 2,000 warm-up commits, at the
2 MiB geometry (`PWEXP_REGION_BLOCKSIZES=4096`). That variable takes a list —
`"2048 4096"` measures 1 MiB and 2 MiB regions interleaved within each
repetition, so a cross-geometry comparison is never also a cross-sitting one. A
2048-byte block holds 26 entries per WAL slot, so pair it with
`PWEXP_SIZES="1 8 24"`; the script refuses a size that cannot fit before any
run starts.

Block size is not a pure region-size knob: it also sets the WAL slot capacity
and moves the per-commit writes, since the WAL sits at one block and the scratch
chunk at two. `PWEXP_REGION_GEOMETRIES` takes `<blocks>x<blockSize>` pairs
instead (pwbench's seventh argument is the block count), so
`"512x2048 256x4096 512x4096"` compares two 1 MiB regions that differ only in
block size against the 2 MiB baseline, all interleaved. It replaces
`PWEXP_REGION_BLOCKSIZES`, and setting both is refused.

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
alignment hypothesis is excluded *as the cause of the bimodality*: it predicted
a property of the file, and this is a property of where the process runs.
(Extent alignment and region size do turn out to set the *level* of the cost;
see [Region size](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries).)

The asymmetry between the backends is the interesting part, and it is measured
rather than inferred. Pinning the *PMEM* backend the same way gives a median
`SFENCE` of 11 ns on both nodes (minima 9 and 10 ns) — no node sensitivity at
all. The `CLWB` loop agrees independently: 72.0–73.5 cycles per line across all
24 unpinned PMEM runs, which spanned both sockets, with no bimodality anywhere
in the range.

| Backend | node 0 (local) | node 1 (remote) | Penalty |
|---|---|---|---|
| `pmem` (`CLWB` + `SFENCE`) | 11 ns | 11 ns | **none** |
| `file` (`fdatasync`) | 927,371 ns | 1,148,685 ns | **+23.9 %** |

Nothing on the PMEM path blocks on media latency.

Two full pinned campaigns (`results/20260918T062309Z-magpie` at node 0 and
`…062908Z…` at node 1, 36 runs each) extend that spot-check to every
configuration and transaction size:

| Configuration | n=1 | n=8 | n=32 | n=56 |
|---|---|---|---|---|
| `file-dax` penalty | **+24.0 %** | **+23.6 %** | **+23.6 %** | **+23.7 %** |
| `pmem-dax` penalty | 0.0 % | 0.0 % | 0.0 % | 0.0 % |
| `file-block` penalty | +0.1 % | +0.3 % | +0.9 % | +0.7 % |

**The penalty is constant in transaction size**, which is what a fixed
per-`fdatasync` interconnect cost predicts and what a per-byte one would not.
`pmem-dax` is unaffected to the resolution of the measurement at every size, and
`file-block` is unaffected because an LVM volume is not socket-attached in the
way a PMEM DIMM is. The pinned node-0 figures also reproduce the unpinned low
mode to within 0.2 % at every size, so all five campaigns tell one story.

Nothing on the PMEM path blocks on media latency. `CLWB` is fire-and-forget, and
an `SFENCE` at 11 ns plainly is not waiting for anything to reach ADR — the
writebacks drain asynchronously inside the 13.7 µs the rest of the commit
takes. `fdatasync` is the only
operation here that synchronously waits for data to reach the medium, so it is
the only one that pays the interconnect. The same hardware penalty is invisible
through one backend and 24 % through the other. At a 1 MiB region the penalty
falls from ~220 µs to ~1 µs, in proportion to the lines `fdatasync` has to
flush, so it is a per-line cost multiplied by the 2 MiB entry (see
[Region size at fixed block size](#region-size-at-fixed-block-size-and-the-numa-penalty-at-1-mib)).

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

`file-block` shows no such bimodality, but it has a different problem of its
own; see below.

So at a 2 MiB region the DAX-versus-block factor is **7.0× socket-local and 8.6×
cross-socket**. With the cause identified the figure is no longer a lottery, but
it is still two numbers rather than one, and it is conditional on placement the
allocator does not control — and, as the region-size sweep shows, on a mapping
granularity it does not control either.

### The block-media configuration is not a controlled measurement here

Once the socket is pinned, the two DAX configurations reproduce to a fraction of
a percent across campaigns. `file-block` does not reproduce at all. Five
campaigns, chronologically:

| campaign | pinning | n=1 | n=8 | n=32 | n=56 |
|---|---|---|---|---|---|
| 044131Z | unpinned | 133,004 | 133,113 | 132,928 | 130,672 |
| 045605Z | unpinned | 133,815 | 134,172 | 134,027 | 131,645 |
| 062309Z | node 0 | 196,244 | 180,136 | 168,769 | 164,943 |
| 062908Z | node 1 | 196,432 | 181,075 | 170,285 | 166,047 |
| 065813Z | unpinned | 196,316 | 180,771 | 169,643 | 164,859 |

**Pinning is not the cause.** The last campaign was run unpinned specifically to
break the confound — the pinned campaigns had also been the later ones — and it
matches pinned node 0 to within 0.52 % at every size. What changed between the
second and third campaigns was elapsed time and the state of `/home`, not the
CPU set.

Two regimes are visible, and the *shape* differs between them as well as the
level. In the first two campaigns the boundary is **flat** in transaction size
at ~133 µs, like the DAX configurations. In the last three it **falls
monotonically**, 196 µs down to 165 µs from one entry to fifty-six — and those
three agree with each other to 0.5 %, so the shape is a reproducible feature of
the later regime rather than noise.

That pattern is at least consistent with rate-dependence, offered as a
hypothesis and not a result: a larger transaction takes longer to construct, so
boundaries are issued further apart, and a queued block device has more time to
drain between them. When the device is fast there is nothing to drain and the
cost is flat; when it is slower, spacing starts to matter. DAX has no such
queue, which would be why neither DAX configuration shows it at any time. What
moved `/home` between regimes is not established — it is a shared LVM volume
whose other traffic is neither controlled nor visible in a CPU load average.

As a by-product, the unpinned campaign also reconfirms the NUMA mechanism:
`file-dax` goes bimodal again the moment pinning is removed, 5 of its 12 runs
landing in the high mode, while both pinned campaigns stayed wholly in one mode.

**The consequence for this page is specific.** The comparison that isolates the
boundary *primitive* — configuration 1 against 2, on the same DAX filesystem —
is reproducible to 0.1 % across five campaigns and carries the headline result.
The comparison that isolates the *media* — 2 against 3 — rests on a
configuration that has moved 50 % between sittings on this host, and its
multiplier is a range, 4.7×–7.1×, rather than a number. The *direction* at
2 MiB is unaffected: DAX was slower in all 60 block runs, worst case 4.7×. It is
not a media comparison, though: at a 1 MiB region the DAX side falls to ~5 µs
(see [Region size](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries)),
so the direction depends on geometry. The matched-geometry campaign confirms
the reversal within one sitting: 31–33× faster at 1 MiB. `/home` is a shared LVM volume whose other
traffic is neither controlled nor visible in a CPU load average.

**What `/home` is (2026-09-27).** The volume sits on `sda` behind a Broadcom
MegaRAID SAS3508. Linux sees `write through` and no FUA, so `fdatasync` never
sends a flush: the direct backend's split puts it at ~1.7 µs, with the write
taking the rest. The "queued block device" above is therefore a RAID
controller, and every figure in this section is the latency to its
acknowledgement. Its cache state changing between sittings is a candidate for
the two regimes; nothing has tested it.

**And what it is not (2026-10-16).** The controller is a Dell PERC H740P in
eHBA mode with no virtual drive, `sda` is passed through to Linux with its own
write cache disabled, and Dell documents write-through as the only cache
policy for such disks. So "a RAID controller" above is the card, not a RAID
volume, and the acknowledgement comes from below Linux before the platter is
written, from a component not yet identified
([root sitting](#what-acknowledges-a-write-on-home)). With no cache documented
in the path, the controller's cache state is withdrawn as a candidate for the
two regimes; what moves `/home` between them is open.


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
  record, and it scales entirely through its prepare side. **Caveat
  (2026-09-28):** this is what lands inside the `rdtsc` window, not what a
  `CLWB` costs the commit. `CLFLUSHOPT` measures 26 cycles per line in the same
  window, and an empty loop 21, for the same wall time as `CLWB`; see
  [`CLWB` evicts on Cascade Lake](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows).

The line count is exactly predictable. A record is a 64-byte header, a 48-byte
trailer and one 32-byte `LogEntry` per buffered write, aligned up to 64, and
each after-image was prepared separately (until 2026-09-28; since then each
distinct data line is prepared once, so the `+ n` term becomes the number of
data lines the transaction touched), so

```
lines/commit = ceil((112 + 32n) / 64) + n
```

which gives 4, 14, 50 and 86 at n = 1, 8, 32, 56 — matching every one of the 24
PMEM runs exactly.

Boundary share stays between 2.9 % and 3.4 % at every size, because record
construction scales with record length for the same reason the `CLWB` loop does.
(As an in-window share it understates the writebacks tenfold at eight entries;
see the caveat above.)

### `fdatasync` is flat too, so the headline ratio is size-dependent

The same sweep on the file backend over DAX gives 927.2, 926.9, 926.4 and
927.5 µs at 1, 8, 32 and 56 entries in the low mode, and 1,147.7, 1,146.3,
1,148.7 and 1,147.5 µs in the high mode — **under 0.25 % variation across a 56×
change in transaction size, within either mode.** One `fdatasync` writes back
the whole 2 MiB DAX entry the commit dirtied (see
[Region size](#region-size-fdatasync-on-dax-flushes-whole-2-mib-entries)), so
it costs the same whether the transaction dirtied 32 bytes or 1,792.

Block storage was flat in the first two campaigns (133.8, 133.7, 133.9,
130.8 µs) but *not* in the later pinned pair, where it falls monotonically from
196 µs to 165 µs. Flatness is established for the DAX configurations and
unsettled for block storage; see the reproducibility note above.

Both boundary primitives are therefore flat in transaction size on DAX. The only thing
that scales is PMEM's `CLWB` loop, and that is enough to move the ratio by a
factor of twenty:

| Entries | PMEM boundary/commit | `fdatasync` on DAX (low mode) | Ratio |
|---|---|---|---|
| 1 | 139 ns | 927.2 µs | 6,669× |
| 8 | 453 ns | 926.9 µs | 2,048× |
| 32 | 1,595 ns | 926.4 µs | 581× |
| 56 | 2,731 ns | 927.5 µs | 340× |

Against the high mode every ratio is 1.24× larger.

**The 2,000× headline is a property of eight-entry transactions in a 2 MiB
region, not of the media.** Quoting it without the transaction size overstates
the gap by 6× at the large end and understates it by 3× at the small end.
Combined with the bimodality, the defensible claim is "about three orders of
magnitude at small transaction sizes, closing to about two at the largest the
WAL slot allows, for regions the kernel maps with 2 MiB DAX entries" — not any
single multiplier. With 4 KiB entries the file side is 5.0 µs, and the measured
gap is 37×, 11× and 4.2× at 1, 8 and 24 entries: about one order of magnitude.

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
commit and divides down across entries, while on PMEM the boundary is ~3 % (as
measured inside the timing window; the writebacks' real cost is larger, see
[`CLWB` evicts on Cascade Lake](#clwb-evicts-on-cascade-lake-and-the-writebacks-cost-far-more-than-the-boundary-shows))
and both it and record construction scale with the record, so there is little
fixed cost left to amortise.

An earlier note here speculated that the optimal transaction size would run in
*opposite* directions on the two media. The measurement does not support that
and it should not be repeated: larger transactions are cheaper per entry on both
media. The finding is the magnitude, not the sign — a batching strategy tuned on
one medium is not wrong on the other, merely pointless.

### Limits of these numbers

- **`fdatasync` on DAX has two costs**, socket-local and cross-socket, differing
  by 23.9 %. Unpinned runs draw one at random. Every figure for configuration 2
  on this page is the socket-local one unless stated.
- **The block-media configuration measures an acknowledgement given before
  the platter**, not a disk: `/home` is on `sda`, which a Dell PERC H740P
  (Broadcom's SAS3508) in eHBA mode passes through with the drive's own write
  cache disabled; Linux sees `write through`, so its `fdatasync` sends no flush
  (2026-09-27; traced 2026-10-16). What acknowledges the write is not
  identified, and whether that acknowledgement is power-safe is not established
  ([root sitting](#what-acknowledges-a-write-on-home)). Until 2026-10-25 this
  bullet said the configuration measures a RAID controller.
- **The block-media configuration has not reproduced**: at 2 MiB it has two
  regimes, flat at ~133 µs and falling 196 → 165 µs, which differ in shape as
  well as level. It has now switched between them within one day, on a
  timescale of tens of minutes, while a 1 MiB file stayed in one state across
  three campaigns. Pinning, block size and write position are excluded as the
  cause; what selects the regime is not established. Any comparison involving
  it across campaigns is order-of-magnitude at best. Within a campaign it is
  tight (0.5 % across repetitions).
- What *has* reproduced, across all 381 runs in `results/`: exactly 1.000
  boundaries per commit, `SFENCE` at 11–13 ns, the DAX boundary primitives flat
  in transaction size at every geometry, `CLWB` linear at 72.0–73.5 cycles per
  line inside the timing window, `lines/commit = ceil((112 + 32n)/64) + n` exactly at every size, the
  socket-local 2 MiB `fdatasync`-on-DAX figure to within 0.2 % once pinned, the
  1 MiB figure at ~5.0 µs across three campaigns and both 1 MiB geometries, and
  the PMEM boundary identical on both sockets.
- Treat the ratios as orders of magnitude and the absolute latencies as
  properties of this host's storage stack on the day.
- The **mechanism** behind configuration 2's slowness, that `fdatasync` writes
  back a whole 2 MiB DAX entry, was identified from timing and file layout and
  has since been observed in the kernel: `fs_dax:dax_writeback_one` wrote back
  one whole 2 MiB entry per commit at a 2 MiB region and single 4 KiB pages at
  1 MiB ([2026-10-16](#fdatasync-on-dax-writes-back-whole-2-mib-entries-observed)).
  Every configuration-2 figure is specific to regions mapped with 2 MiB entries
  unless a 1 MiB region is named. Until 2026-10-25 this bullet said the
  mechanism was not yet observed in the kernel.
- **Unexplained:** what selects the block configuration's regime at 2 MiB. The
  PMEM backend's faster per-entry growth is explained (2026-09-28): stores into
  lines the previous after-image's `CLWB` just evicted, about 95 % of it,
  established by a stride intervention on timing alone, since there are no
  hardware counters. Why the per-store cost (~775 ns) exceeds the probe's
  re-access (~620 ns), and why deferring writebacks to the fence costs time
  where there is no reuse, are interpretations, not measurements. The block
  configuration's apparent 8–14 % geometry effect is withdrawn: the sign
  reversed when the 2 MiB figure changed regime.
- Samples are `rdtsc`, converted with a TSC frequency calibrated per run against
  `CLOCK_MONOTONIC` (2294 cycles/µs on every run here). There is no invariant-TSC
  check in the tree, so that conversion is an assumption, stated rather than
  hidden; Magpie's recorded CPU flags (each campaign's `provenance.txt`)
  include `constant_tsc` and `nonstop_tsc`, which together are the invariant
  TSC it assumes. `rdtsc` is also not ordered with `CLWB`, so a timed writeback
  reports what lands inside its window, not what it costs; only wall-time
  differences measure the writebacks (2026-09-28).
- **The timer from 2026-10-15.** Every bench now calibrates against
  `CLOCK_MONOTONIC_RAW`, which NTP does not slew, and keeps the frequency in
  kHz (`tsc kHz` in the log; the `tsc cycles per microsecond` line stays for
  the scripts), where a whole number of cycles per µs rounded away up to one
  part in 2,294. pwopsbench, pwsievebench and pwbtreebench also read the TSC
  between two `LFENCE`s (`Target.rdtscOrdered`, the SDM's sequence), so earlier
  instructions have executed before a read and later ones wait for it; stores
  and `CLWB` are still not waited for. pwbench keeps its unordered reads, which
  the boundary analysis above is about. Every result before that date used the
  old conversion and unordered reads. The ordered reads' cost is not yet
  measured in a campaign; in one uncommitted smoke run on sean-tan-PC (tmpfs,
  CPU 2) pwopsbench's `timer` median went from 5 to 11 ns.
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

Loads have a seam of their own since 2026-10-19. The provider carries a
nullable `loadObserver: PersistentLoadObserver`, null in production, whose one
method, `observe(offset, length)`, is called with region-relative offsets
*before* the bytes are loaded and may rewrite them. Every load the allocator,
the WAL and the workloads make from a region is made, or observed first,
through a `DirectRegionReader` over the region's provider (the counterpart of
`DirectRegionWriter`): typed `load*` methods, `observe()` for byte loops, and
per-layout `forge*` helpers that observe a layout's bytes before forging its
`Ref`. With no observer, a reader load is the same `Pointer.load` as before,
behind a call and a never-taken branch. A recording provider can keep loads too
(`recordLoads()`), in a list of their own, so a trace stays
`STORE`/`CLWB`/`SFENCE` only. The contract, what goes through the reader and
what stays raw, the load audit and the cost are in
[PMEM Crash Model](pmem-crash-model.md#loads-2026-10-19).

`BackendProt` mirrors Linux `PROT_*` flags: `NONE(0) READ(1) WRITE(2) EXEC(4)`.

### Implementations

| Class | Storage | `prepareChangedRange` | `persistChanges` | `persistRange` |
|---|---|---|---|---|
| `VolatileRegion` | `Array<byte>` (GC'd) | no-op | no-op | no-op |
| `FileMmapRegion` | file + `mmap(MAP_SHARED)` | provider `clwb()` per line marks its 4 KiB page (the direct backend's `DirectIoOperations`); sets `hasDirtyChanges` | fence, then one `fdatasync()` if any page is marked | as `persistChanges`, after marking the range: syncs every marked page |
| `PmemMmapRegion` | file + `mmap(MAP_SHARED_VALIDATE\|MAP_SYNC)` | cache-line flush; sets `hasPendingWriteback` | store fence | flush range + store fence |
| `DirectIoRegion` | anonymous staging buffer + `O_DIRECT` file or block device | provider `clwb()` per line marks its 4 KiB unit; sets `hasPendingWriteback` | fence, `pwrite` marked units, `fdatasync` | as `persistChanges`, after marking the range: drains every marked unit |

`FileMmapRegion`, `PmemMmapRegion` and `DirectIoRegion` all extend `FdMmapRegion`, which holds the `Mapping` and `fd` and handles `destroy()`. For `DirectIoRegion` the `Mapping` is the anonymous staging buffer, not a mapping of the `fd`.

Until 2026-10-13 `FileMmapRegion` set a flag in `prepareChangedRange`, called `fdatasync` in `persistChanges` if it was set, and synced a `persistRange` with `msync(MS_SYNC)` of the range's own pages; it made no provider call, so its trace held no `CLWB` and the PMEM model said nothing about it. That boundary is still selectable, for the old-against-new comparison only, as `FileBoundary.LEGACY` (`FileMmapBackend.boundary`, the benchmarks' `boundary=legacy`), and so is `FileBoundary.MSYNC`, one `msync` per run of marked pages in place of the `fdatasync`; see [the file backend, a restriction of the PMEM model](#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13).

```
FdMmapRegion  (common mmap logic: bounds check, unmap, close fd)
  ├── FileMmapRegion   (marks pages through the provider; fdatasync at each fence)
  ├── PmemMmapRegion   (PMEM durability via clflush + sfence)
  └── DirectIoRegion   (explicit pwrite + O_DIRECT from a private staging buffer, then fdatasync)
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
| `DirectIoBackend(path, FILE \| BLOCK_DEVICE)` | `DirectIoRegion` |

`X86_64Backends` is the platform-level component that dispatches among the first three; `DirectIoBackend` is constructed directly by its callers, and its `makeDirectRegion()` factory hook is what the test and timing subclasses override.

### File I/O (`RegionFileIO`)

`RegionFileIO` wraps the raw syscalls needed by the mmap backends:

- `open(path)` — opens an existing file (`O_RDWR`, mode `0644`); returns `-errno` if it does not exist
- `create(path)` — creates/re-creates a fresh file (`O_RDWR | O_CREAT | O_TRUNC`, mode `0644`); `O_TRUNC` plus the `sizeBacking` `ftruncate` extension leaves the region zero-initialised
- `openBacking(path, fresh)` — selects `create` for a fresh format, otherwise `open` (falling back to `create` when the file is missing)
- `sizeBacking(fd, size)` — `ftruncate` + `fsync` an empty file to `size`; refuse, unchanged, a non-empty file of any other size (returns the reason, or null). Until 2026-10-21 it was `ensureSize`, which resized any file
- `fdatasync(fd)` — data-only sync (no metadata)
- `close(fd)`, `unlink(path)`

Fresh-format intent reaches the backend through `TxnRegionBackend.create(size, prot, fresh)`: `PWRegion` passes its `forceFormat` flag down, so a fresh format zero-initialises the backing store while a mount attaches to the existing one without resizing it.

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
`RegionFileIO.sizeBacking()`.

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

`close()` is the clean-unmount boundary: it persists the last applied transaction, then scrubs only slots whose data is known durable, oldest sequence first, each under its own `persistRange()`. Unrecovered records and records protected by a failed final persist remain available for the next mount.

The order matters for correctness. Even sequences use slot 0, so sequence N+1 can sit in slot 0 with N in slot 1. Scrubbing by slot index would then erase N+1 first, and a crash before N's scrub would let recovery replay N's after-images over N+1's durable data, losing an acknowledged update. Scrubbing oldest first means an interrupted close leaves the newer record (`dual_wal:close_indeterminate_first_scrub_preserves_latest_value`, `pwregion_bd:sigkill_close_first_slot_scrub_preserves_latest_state`). The crash explorer does not cover close (`docs/THESIS.md`: "Not explored by the model"). Until 2026-10-20 this section did not give the order; `close()` has scrubbed oldest first since 2026-08-11 (ROADMAP, "Two-slot redo WAL, phase B").

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
  `applyUpdate()` — or, on the batched path, `prepareApplied()` or the drain
  inside the next boundary — returns `false` and latches recovery-required,
  without advancing `dataDurableSeq`. Recovery uses
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
- **Not for the file backend on block storage after a same-boot reopen.** With
  a real write error below ext4 or XFS, the reopen read the failed record from
  the page cache and replayed it, recovery's boundary made the after-image
  durable, and the record never reached the device, so a later `CLEAN` came
  with the transaction's data present (observed 2026-10-21,
  [sean-tan-PC's root checks](#a-failed-write-below-ext4-and-xfs-the-same-boot-reopen-replays-a-record-the-disk-lacks)). Over longer
  histories it is worse: with the slots on different pages (8 KiB blocks and
  up) a later recovery replayed a stale record over an acknowledged
  transaction's write, and with both on one page (4 KiB) the failed
  transaction was left partly present
  ([two longer histories](#two-longer-histories-an-acknowledged-write-lost-an-unacknowledged-one-torn)). The direct backend reads the
  device on reopen and was not affected.

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
range preparation fails, and so do `storeUpdate()`/`prepareApplied()`, the
batched pair `RegionTransaction` uses since 2026-09-28. `RegionTransaction.applyToRegion()` surfaces that
result without clearing buffered writes. `RegionTransaction.requiresRecovery()`
delegates to the WAL, and `PWRegion.requiresRecovery()` exposes it to allocator
callers; allocation and free entry points reject work after the latch is set.

### Read path (cache miss)

```
readU8(addr)
  if cache.has(addr) → return cached value
  // fall through to live region memory, through the WAL's reader
  return wal.readU8(offset) → reader.loadU8(regionStart + offset)
```

**Constraint:** Only aligned accesses are cached. There is no support for sub-word reads that span a cached boundary.

---

## Layer 4 — Block Allocator

**File:** `src/engine/x86-64/X86_64TxnPWRegion.v3` (class `PWRegion`)

`PWRegion` implements a first-fit block allocator over the persistent region; it hands out chunks, runs of one or more contiguous blocks. Once the region is formatted, every allocator metadata mutation (block-table entries, sentinels, chunk headers, the durable root) goes through `RegionTransaction`, so it is WAL-protected. Two kinds of store do not: `format()` writes its structures directly through the region's `DirectRegionWriter` (see *Format vs. mount*), and the transient Immix line marks are stored through a `DirectRegionWriter` with no writeback or fence (see *Immix GC extension*). Until 2026-10-20 this paragraph said that all metadata mutations go through `RegionTransaction`, which `format()` never did.

### Region layout

```
Block 0      PWRegionHeader (88 B), then the free-list sentinels:
             BlockLists.MAX_LISTS = 8 entries x 40 B at offsets 88-407,
             of which SMALL_FREE (0) and LARGE_FREE (1) are used
Block 1      WAL log chunk
Block 2..    User data: chunks, allocated or free
Last blocks  Metadata, carved down from the region's end: the block table
             (numBlocks + 1 entries) at the end, the descriptor table below
             it, and each descriptor's metadata (e.g. Immix line marks)
             below that
```

`format()` sets the sentinels at `PWRegionHeader.size` and records that offset in the header's `sentinels` field; `validGeometry()` reserves all eight. The metadata blocks are the fewest whole blocks that hold the metadata area, and form one `METADATA` chunk. Until 2026-10-20 this diagram put the sentinels in the metadata area; they have followed the header since 2025-07-06 (`4d43a8cd`).

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
| `magic` | u64 | `MAGIC_TAG \| FORMAT_VERSION << 56` = `0x0100_0050_5741_534D`: the "PWASM" tag `0x50_57_41_53_4D` in bytes 0–4, bytes 5–6 zero, the format version (1) in byte 7; see **Format version** below |
| `blockSize` | u64 | bytes per block (wrapper default 512 KiB, `MemRegions.BlockSize = 512u64 * 1024u64`) |
| `logChunk` | u64 | region-relative offset of the WAL log chunk (block 1 in the current layout) |
| `userRoot` | u64 | region-relative offset of the caller's root object; `0` = none |

#### The durable root

`userRoot` is the allocator's only concession to what a caller stores in the
region. Without it a mounted region is opaque to its owner: the block table
records which chunks are in use, but not which of them the caller wants to
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
crash between allocating a chunk and publishing it leaks that chunk: it stays
marked used and nothing reaches it. This is a space leak, not an inconsistency
— the durable state always satisfies the allocator's invariants — and it is the
cost of the current per-operation commit granularity.

**Format change.** The header grew 80 → 88 bytes. Sentinels sit immediately
after the header (`formatSentinels()` uses `PWRegionHeader.size`), so a region
formatted by an older build has them at offset 80, where this build's
`userRoot` lies. `mount()` reads the `sentinels`, `blockTable` and `logChunk`
offsets from the stored header, and `magic`, `numBlocks` and `blockSize` sat at
unchanged offsets, so until 2026-10-21 such a region still validated and
mounted. Its `userRoot`, though, was the first 8 bytes of the `SMALL_FREE`
sentinel (`listNum`, `used` and padding): `getUserRoot()` returned the zero
that format left there, and `setUserRoot()` stored into the sentinel. The
header had no version, so nothing refused an older region; and because
`init()` formats any region without the magic, changing the magic's value
alone would have formatted an older region, erasing it, rather than refusing
it. Since 2026-10-21 the magic carries a format version, and such a region is
refused (**Format version**, below). When the 72 → 80 growth added `logChunk`,
`mount()` gained a fallback instead: a stored `logChunk` of 0 means block 1
(`pwregion_bd:legacy_log_chunk_fallback`). Until 2026-10-20 this paragraph said
an older region could not be mounted because the sentinel array would be read
8 bytes early; `mount()` has read the stored `sentinels` offset since
2026-03-13 (`bf2cf90a`). The mount of an 80-byte region was read from the code,
not tested.

**Format version (2026-10-21).** The version sits in the magic word's top
byte, which the 5-byte "PWASM" tag left unused, rather than in a field of its
own: a new header field would move the free-list sentinels, which start at
`PWRegionHeader.size` (88), onto different cache lines and change what a
measured commit writes back. In `PWRegions`, `MAGIC_TAG` is the tag
(`0x50_57_41_53_4D`), `FORMAT_VERSION` is 1, and
`MAGIC = MAGIC_TAG | FORMAT_VERSION << 56`; bytes 5 and 6 stay zero.
`isTagged(magic)` holds when the low 7 bytes are the tag and those two zero
bytes, whatever the version; `versionOf(magic)` is the top byte. Version 0 is
every region formatted before 2026-10-21: its magic is the bare tag, and the
88-byte regions among them carry the same layout as version 1. `init()` without
`forceFormat` now does one of three things:

- magic equal to `MAGIC`: mount, as before;
- magic tagged with another version, older or newer: refuse. `init()`
  formats and writes nothing, a `format version mismatch` line is traced, and the
  region is left as `mount()` leaves a block-size or block-count mismatch:
  `backendRegion` set, `txn` null and `logChunk` null, which is how a caller
  detects any refused mount. `requiresRecovery()` does not report it, as it
  does not report the geometry refusals: it is false while `txn` is null.
  An `ImmixPWRegion` so refused has an empty line table, and
  `resetAllLineMarks()` on it writes nothing (see **Immix GC extension**);
- anything else (zero, garbage, the tag with a nonzero byte 5 or 6): format,
  as before.

Before `init()` runs, the backend checks the file's size (2026-10-21). An
attach (`create()` without `fresh`) sizes only an empty file, one that was
missing or has length 0, which is then formatted as before. A non-empty file
whose length is not `numBlocks * blockSize` is refused before it is mapped or
read: `RegionFileIO.sizeBacking()` returns the reason, which the mapped
backends trace (`the region file has N bytes, not the M requested: refusing to
resize it without a fresh format`) and `DirectIoBackend` keeps in `lastError`,
and nothing is truncated, extended, synced or written. `PWRegion` is then left
as after any backend failure: `backendRegion`, `txn` and `logChunk` all null,
and an `ImmixPWRegion` has an empty line table. A null `txn` therefore still
detects every refused open. Reopening a region with fewer or more blocks than
its file holds, of this version or another, changes no byte of it, provided
no other process changes the file while it is being opened. The check
runs before anything can read the header, so it also refuses a non-empty file
of another size that carries no magic, where a resize-and-format would destroy
whatever the file holds: refusing every such file is the one rule that can
never destroy a tagged region, and such a file is replaced only by
`forceFormat` or after it is removed. At the requested size, the three
outcomes above apply. `forceFormat` still opens the file with `O_TRUNC`, so a
forced format takes any size. `DirectIoBackend`'s file target shares the
helper; its `BLOCK_DEVICE` target never sized the device and is unchanged: it
refuses a device smaller than the region and uses the first `size` bytes of a
larger one.

**Precondition: one process owns the region file.** The attach path does not
defend against another process changing the file while it opens it, and two
races, both older than the check above, remain (review, 2026-10-21, each
reproduced by pausing the opener): an attach whose `open()` finds no file
falls back to a create with `O_TRUNC`, so a region that appears in between is
erased and formatted; and a file seen with length 0 is then sized with
`ftruncate`, so a region written into it in between is truncated and refused.
A concurrent shrink of a matching-size file can also raise `SIGBUS`. The
engine assumes one writer (pmem-crash-model.md, "Agreed baseline persistence
profile"), and nothing here locks the file. Treating only `ENOENT` as missing
and creating with `O_EXCL` rather than `O_TRUNC` would close the first race;
the second needs exclusive ownership of the file (a lock held from the check
through use). Neither is done.

Until 2026-10-21 the helper, then `ensureSize()`, ran `ftruncate` and `fsync`
to the requested size on any file before `init()` read the magic. Reopening a
region with fewer or more blocks than it had shrank or grew the file first and
then refused it (review, 2026-10-21: a 32 KiB version-0 file reopened at four
4 KiB blocks was truncated to 16 KiB, then refused; at sixteen it was extended
to 64 KiB, then refused). This predated the version and applied equally to the
block-size and block-count refusals, and a file without the magic was resized
and formatted.

`forceFormat` still formats unconditionally, and it is the only way to bring a
refused region to version 1: there is no in-place upgrade, so a refused region
must be reformatted, losing its contents. `format()` stores the versioned
`MAGIC`, still last and under a fence of its own. Of the harnesses,
`pwbench`, `pwsievebench` and `pwbtreebench` always format, and the `pwsieve`
and `pwbtree` kill loops format before they remount; `pwopsbench` checks
`txn`. `pwreboot arm` now fails on a null `txn` before it steps or resets, and
`pwreboot verify` reads the raw header before it mounts: a region tagged with
another version gives `INVALID` ("the region has another format version"),
since setup was run by a different build (run 2026-10-21 on a file-backed
setup whose magic was then overwritten with the bare tag; the file was
unchanged). `pwregion_bd:` checks the three outcomes over a file-backed
region that this build formatted and whose magic is then overwritten:
`version_0_magic_refused_unchanged` stores the bare tag and
`future_version_magic_refused_unchanged` version 2, and each requires a null
`txn` and log chunk, the stored magic intact, and every byte of the backing
file the same in the mapping while it is open and in the file once it is
closed; `untagged_magic_reformatted` stores 0, `0xDEAD_BEEF_CAFE_F00D` and the
tag with byte 5 set or with byte 6 set, and requires a mounted region with
the current magic and no root; `force_format_replaces_version_0` reformats a
bare-tag region. A current region's remount is `persist_and_remount` and
`legacy_log_chunk_fallback`. Made to format a tagged region instead of
refusing it, the build fails both refusal tests (checked 2026-10-21). Three
more open a file-backed `ImmixPWRegion` whose 128 line marks were all set to
`0xA5` and written back: `immix_version_0_refused_unchanged` stores the bare
tag, `immix_incompatible_descriptor_refused` version 2 with the line-mark
descriptor's `unitSize` set to 0, and
`immix_num_blocks_mismatch_refused_unchanged` a stored block count of 7. Each
requires the refusal above, an empty line table, and the backing file
unchanged after a `resetAllLineMarks()` on the refused region. No region
formatted by an older build was opened.

Eight tests cover the size check (2026-10-21). Four `pwregion_bd:` tests
reopen an eight-block (32 KiB) file-backed region without `forceFormat` at
four and at sixteen blocks: `current_version_other_size_refused_unchanged`
(after an allocation and a root, which a reopen at eight blocks then finds),
`version_0_other_size_refused_unchanged` (the bare tag),
`untagged_other_size_refused_unchanged` (magic `0xDEAD_BEEF_CAFE_F00D`;
formatted when reopened at its own size) and
`immix_other_size_refused_unchanged` (the marked line table). Each requires a
null `backendRegion`, `txn` and log chunk, an empty Immix line table after
`resetAllLineMarks()`, and the closed file's length and every byte unchanged.
`missing_and_empty_file_sized_and_formatted` opens a missing path at four
blocks and a zero-length file at sixteen without `forceFormat`, and
`force_format_other_size_resizes` forces four and then sixteen blocks over
the formatted file; each requires a formatted region and a file of the
requested size. `txn_backend:attach_other_size_refused_unchanged` attaches
`FileMmapBackend` and `PmemMmapBackend` at 4 KiB and at 16 KiB to an 8 KiB
patterned file and requires no region and the file unchanged. The PMEM
backend refuses before it maps, so this runs on tmpfs; no DAX mount was
available, and no PMEM open at a matching size was run.
`direct_io:attach_other_size_refused_unchanged` checks the same through
`DirectIoBackend` and `PWRegion`, then remounts at eight blocks and forces
sixteen. With the old helper restored, the six refusal tests fail and the
other two pass. A helper that refused every attach at another size, empty
files included, fails only `missing_and_empty_file_sized_and_formatted`; one
that checked the size before a forced open's `O_TRUNC` fails only
`force_format_other_size_resizes` (both checked 2026-10-21). `pwreboot arm`
over a 512-block file region, at 256 and at 1,024 blocks, fails with the
reason traced and the file's length and SHA-1 unchanged, and still arms at
512.

### `BlockEntry` (40 bytes)

The block table holds `numBlocks + 1` entries, one per block plus an
end-of-region marker, but only the entry of a chunk's first block is live.
A chunk runs to the next live entry in address order, so its length is not
stored. An interior entry belongs to no chain or list; a split gives the
remainder's first entry a live role.

| Field | Type | Meaning |
|---|---|---|
| `listNum` | i16 | free-list index (see `ListKind`) |
| `used` | u1 | 1 = allocated |
| `prev` | i64 | first entry of the previous chunk in address order |
| `next` | i64 | first entry of the next chunk in address order |
| `listPrev` | i64 | previous chunk on the same free list, or the list's sentinel |
| `listNext` | i64 | next chunk on the same free list |

`ListKind` values: `METADATA(-1)`, `NONE(-2)`, `USED(-3)`, `SMALL_FREE(0)`, `LARGE_FREE(1)`.
An allocated chunk carries `NONE`, which `removeFromList()` sets; `USED` is
defined but never stored. The header block and the log block are `METADATA`
chunks of one block each, the metadata blocks one `METADATA` chunk, and the
end marker carries `NONE` with `used` set. Until 2026-10-20 this section said
each block had an entry of its own in the chains; the allocator has used
chunks since 2025-07-24 (`faed4563`).

### Allocation strategy

- Single-block requests try `SMALL_FREE` first, then fall back to `LARGE_FREE`.
- Multi-block requests search `LARGE_FREE` for a first fit.
- If the found chunk is larger than needed, it is split: the front is allocated, and the remainder, whose first entry becomes live, is re-inserted into the appropriate list.
- A free coalesces the chunk with a free neighbour on either side in address order before inserting it into a list.
- Every allocation or free calls `performCommit()` to commit the updated block table entries atomically via the WAL.

### Format vs. mount

```
PWRegion.__new(backend, numBlocks, metaDataDescs, blockSize, forceFormat)
  if forceFormat                  → format(blockSize)
  else if magic == MAGIC          → mount(blockSize)
  else if isTagged(magic)         → refuse: another format version; write nothing,
                                    txn and logChunk stay null   -- since 2026-10-21
  else                            → format(blockSize)            -- no PWRegion magic

format(blockSize)                -- every store through the DirectRegionWriter, not the log
  header: numBlocks, numBytes, blockSize, userRoot = 0
  formatSentinels(): header.sentinels = 88; clear all 8 entries
  block table (numBlocks + 1 entries) carved from the region's end; cleared
  descriptor table, then each descriptor's metadata, carved below it
  if numBlocks < metadataBlocks + 3: return     -- too small; magic never stored
  entries: block 0 (header) → block 1 (log), both METADATA
  header.logChunk = block 1; fresh DualTxnWal header   -- the log persists its own
  block 2 heads one free chunk of every user block, alone on LARGE_FREE
    → first metadata block (one METADATA chunk) → end marker (NONE, used)
  backendRegion.persistRange(0, full_size)   -- everything but the magic
  store MAGIC (the tag and FORMAT_VERSION)
  backendRegion.persistRange(magic, 8)       -- then the magic's line alone

mount(blockSize)
  -- header fields are read one at a time through the region's
  -- DirectRegionReader (magic in init(), then these), since 2026-10-19
  verify blockSize and numBlocks match header
  locate sentinels via header.sentinels
  restore block table handle via header.blockTable
  locate log chunk via header.logChunk       -- fall back to block 1 if unset (0)
  init DualTxnWal + RegionTransaction
  txn.recover()                              -- replay committed WAL if present
```

Until 2026-10-20 the `format()` sketch above said it linked every user block in
memory order and inserted each onto `LARGE_FREE`, and left out the descriptors,
the size guard and the log's initialisation; the code makes one free chunk.
Until 2026-10-21 `init()` had two outcomes, mounting a region with the magic
and formatting any other, so a region with an older magic would have been
formatted; the refusal is described under **Format version** above.

**The magic is published last (2026-10-19).** `mount()` trusts any header that
carries the magic, so the magic must not become durable before what it vouches
for. Until 2026-10-19 `format()` stored the magic last and made the whole
region durable with one `persistRange()`; under the crash model a line can
become durable before lines stored ahead of it, so a crash inside that persist
could leave the magic durable beside a block table that was not, and a later
open would mount it. `format()` now persists everything else first, then
stores the magic and persists its line under a fence of its own: one more fence
per format, four in all with the log's two. `persistent_alloc:` records
`format()` (598 events over 16 lines, at 8 blocks of 2 KiB) and opens every
crash image as production does, mounting it if it carries the magic and
reformatting it if not; every image must open into an allocator that passes the
invariant walk. From the magic's store on, every other line is at its floor
(`format_publishes_the_magic_last`, from the trace, for every image at every
cut), so the 3 cuts from there on are checked exhaustively, 5 images. The 596
cuts before it admit up to 46,080 distinct images each (at cut 338), 12,360,709
in all, and only 55 of them admit 8 or fewer; they are bounded at 8 distinct
images a cut, 4,739 checked in all (`crash_during_format_opens_consistent`,
counted 2026-10-20; until then this said "up to about 2^61 images each" and
"4,254 in all", figures from before the explorer counted distinct images). The
negative control, `early_magic_is_caught`, moves the magic back into the old
order (until 2026-10-21 a trace whose digest equals the one `afcf5525`
records; since then the magic's stored value carries the format version, so
the digests differ) and must fail both checks at the magic's cut, 339 of 596;
against `afcf5525`'s own `format()` the sweep fails at that cut. The sweep's failing image is the third
it checks there, an extreme: the header's first line alone at its last, magic
included, with every other line at its floor (2026-10-20).

### Handle types (unboxed)

These are zero-allocation wrappers around raw memory addresses:

- `BlockTableHandle` — indexable view of the block table
- `BlockEntryHandle` — single block entry; `.getCached(txn)` / `.setCached(txn)` for transactional access, and direct `.get(r)` / `.set(w, …)`, which take the region's `DirectRegionReader` (`region.reader()`, since 2026-10-19) and `DirectRegionWriter`
- `ChunkHandle` — allocated chunk with `offset` and `limit`; direct getters take the reader too
- `LineMarkTableHandle` — line-mark bitmap for Immix GC

---

## Immix GC extension

**File:** `src/engine/x86-64/X86_64TxnPWRegion.v3` (class `ImmixPWRegion`)

`ImmixPWRegion extends PWRegion` adds a line-mark metadata table alongside each allocated chunk. `createChunk()` stores the region-relative offset of the chunk's first line mark in its transactional header, so the link remains valid after remount. The persisted line-mark metadata descriptor's `unitSize` controls the line size, and its `fixedBytes` prefix precedes the per-line table; the built-in `MemRegions` descriptor defaults to a 256-byte line size and no prefix.

- `resetAllLineMarks()` — clears all line marks at the start of a GC cycle. Line marks are explicitly transient GC state: mark/reset operations bypass `RegionTransaction` and issue no persistence boundary. A caller mounting after a crash must rebuild them; the allocator does not currently do that automatically.
- Since 2026-10-21 the constructor rebuilds the line table from the stored descriptors only when `init()` leaves a transaction (`txn` non-null), that is, after a format or a mount. A region that `init()` leaves unopened (another format version, a stored block size or block count that does not match, or a region too small to format) keeps an empty table: `lineMarks` is `(0, 0)` and `numLineMarks` and `lineSize` are 0, so `resetAllLineMarks()` writes nothing. Before, the table was rebuilt whenever the backend region existed. On a refused region the constructor then read descriptors whose layout this build had not validated, and a reset stored into the refused file. A review on 2026-10-21 reproduced both: a version-0 region kept 128 line marks and a reset turned a stored `0xA5` into 0 in the file, and a version-2 image whose line-mark descriptor read as `unitSize` 0 threw `DivideByZeroException` in the constructor instead of returning a refused region. The geometry refusals had the same gap. The `pwregion_bd:immix_*` tests (**Format version**, above) cover all three refusals. With the check back to `backendRegion != null`, the version-0 and block-count tests fail on the non-empty table, and with that assertion removed they fail on the file, which first differs at byte 32,248, the first line mark; the descriptor test throws `DivideByZeroException` (checked 2026-10-21).
- Since 2026-10-19 the marks' stores go through the persistent-operation seam, as every other store the allocator makes does. `LineMarkHandle.setMark(w, v)` takes the region's `DirectRegionWriter` (`lineMarkWriter()`), like the other non-cached setters, and `resetAllLineMarks()` passes it; before, both stored through a forged `Ref<LineMark>`. A recorded trace therefore shows each mark as a 1-byte `STORE`, and marking and resetting add no `CLWB` or `SFENCE` (`persistent_ops:immix_line_marks_cross_the_seam`). Since the same day `getMark(r)` reads through the region's `DirectRegionReader`, like the other direct getters, rather than through a forged ref.

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
      else → wal.readU8(offset) → reader.loadU8(regionStart + offset)
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
| `PersistentOperationsTest.v3` | 21 | typed scalar-store recording and little-endian mutation, cache-line range translation and conditional fences, one/two-transaction phase-B order, and production recovery replay events; the store audit over `PWRegion`; and, since 2026-10-19, the load seam: reader loads equal raw loads, an observer runs before the load it is shown and its rewrite is what the code loads, the load audit (`load_audit_covers_fields`: a mount, recovery and walk observe the header fields mount reads and not the others, the WAL header and both records whole, and every block entry the walk visits) and the inert-bytes audits over every cut of an allocator scenario and a sieve step and every fourth cut of a B+Tree update (bytes neither observed nor stored set to 0x00, 0xFF and a hash change no load, store or verdict), and the B+Tree descents' node fetches, which no reattach exercises |
| `RegionTransactionTest.v3` | 16 | transaction cache and active `DualTxnWal` integration, commit/apply/flush recovery-required propagation, and oversize rejection |
| `TxnPWRegionTest.v3` | 101 | (recounted 2026-10-21 from the file's registrations: `pwregion:` 23, `txn_backend:` 13, `pwregion_immix:` 7, `pwregion_wrappers:` 5, `pwregion_recovery:` 2, `pwregion_overflow:` 1, `pwregion_bd:` 50; the table's other rows and the totals above are not recounted) allocator, direct hand-written and reproducibly generated mixed-history memory-order/free-list invariant checks, invalid-input rejection, copied/remounted Immix descriptors, prefix-aware line lookup/linkage/reset and transient persistence policy, all five platform wrappers, overflow and allocation/free recovery-required propagation, exclusive-create collision rejection, fresh/missing-file backend creation, mount geometry validation and legacy WAL-offset fallback, format-version refusal (version 0 and a newer version refused with the backing file unchanged, untagged headers reformatted, and for an Immix region an empty line table on a version or block-count refusal, since 2026-10-21), mmap/PMEM backend state, real-file `fdatasync` commit ordering and injected-error recovery, marked-page `fdatasync` format ordering and clean-close failure recovery, graceful and abrupt-process file-backed remount including N+1 piggyback and explicit-flush boundaries, and `DualTxnWal` recovery |
| `MultiTxnWalTest.v3` | 28 | retained ring WAL: superblocks, recovery, epochs, wrap/checkpoint, validation and hardening regressions |
| `PWSieveTest.v3` | 13 | resumable segmented sieve workload: mount/reattach, foreign-root rejection, prime counts against an independent sieve, cross-object invariants after every commit, retirement returning blocks, leak reclamation, retention-window enforcement, and resume across real file-backed remounts |
| `PWBTreeTest.v3` | 22 | the persistent B+Tree workload (2026-10-14), over regions in anonymous mappings rather than the volatile backend, whose heap array Virgil's copying collector moves under PWRegion's raw addresses (a collection during a test aborted the full binary on 2026-10-14; `pwsieve:` and the `pwregion:` groups still use that backend): format, reattach, foreign-root and other-capacity refusal, the 252-key default capacity, splits to height 3 and beyond in ascending, descending and random key orders, updates, seeded histories at capacities 4 and 5 against a DRAM map with the invariants after every mutation, a planted leak and rootless orphans reclaimed, a full region failing cleanly, three forced collections between mutations, and a corrupted or cyclic image refused rather than walked: a node that is its own child, one at the wrong level and impossible heights by `open()` and `forEach()`; a published root offset whose sum with the block size wraps past zero by `open()`; and a node reached twice by `open()` and by `compare()`, whose keys from `forEach()` must strictly increase, even when the repeated leaf is the size of the one it displaced; on the production PMEM boundary path, counted, k + h + 1 fences per put, each commit the lines its record predicts and WRITE the lines its new nodes occupy, again at 4,104-byte blocks, where nodes start mid-line; resume across real file-backed remounts (`pwbtree_bd:`), one at 4,104-byte blocks through the production file provider; and a child on the direct backend killed at every phase mark of a root split and of an update (`pwbtree_dio:`) |
| `PWOpsTest.v3` | 6 | the basic-operation benchmark's expectations on the production PMEM boundary path: exact `CLWB`/`SFENCE` counts per allocation and free against the record, the steady state alternating them returns to, no event for an empty commit, no boundary for a clean mount, and one line per replayed entry under one fence for a recovery |
| `PersistentSieveTest.v3` | 8 | the sieve through the crash-image explorer: recorded step validates against the baseline, exhaustive final-cut check, budgeted allocator- and sieve-property sweeps over every cut of an ordinary and a retiring step (since 2026-10-19 a budget counts distinct images: 5,798 for the ordinary step's sweep at 4 per cut, against 5,776 before; since 2026-10-20 the budget is 16 and the sweep checks 22,659), and a damaged-bitmap self-check; since 2026-10-19 its images are mounted in an anonymous mapping, not a heap array the collector can move, and a forced collection under a mounted image leaves it in place; since 2026-10-19 a recovery that skips the record checksum (a test-only flag) is rejected at 12 images per cut, though not at 4, the suite's budget until 2026-10-20; at the suite's 16 since then a sweep with the flag set fails at cut 289 |
| `FileMmapRegionTest.v3` | 6 | the file backend as a restriction of the PMEM model (2026-10-13): trace identity with the PMEM backend, every page written back before a fence covered by that fence's syncs, the file after every sync admitted by the model exactly (eager and marked-only images), an `O_DIRECT` re-read of every synced range, no sync under the elided-writeback mutant, and the legacy boundary unchanged; at 2 KiB and 4 KiB blocks, with the `fdatasync` and `msync` fences |

The trace recorder deliberately has no durable image, background eviction,
asynchronous writeback completion, crash cuts, or schedule exploration yet.
Its scope is to prove that real active-WAL execution emits the expected ordered
operations. `PWRegion.format()` and its direct header/block-table/descriptor
stores, non-cached allocator setters, retained comparison WALs, and transient
Immix line marks remain outside the store seam pending a later audit. (Since the
store audit of 2026-08-14 `format()` and the non-cached setters go through the
seam, and since 2026-10-19 the line marks' stores do too, still with no
writeback or fence of their own; only the comparison WALs remain outside.)

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

The file-backed tests exercise the actual `fdatasync` code path (and, until
2026-10-13, the page-aligned `msync(MS_SYNC)` that synced a `persistRange`),
including basic failure propagation, committed-WAL
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
remount. The same seam records which pages each `fdatasync` was asked to make
durable: fresh format issues two WAL initialization fences, each marking the
log's one page, before the whole-region publication, and since 2026-10-19 a
fourth, after it, marking the header's page alone for the magic, while clean close
completes the final-data `fdatasync` before an injected failing slot-scrub
`fdatasync` marking the log page alone. The latter latches its old WAL instance
and remount preserves the allocated structure. These tests do not yet
clear the kernel page cache, reset a VM, interrupt power, or trace at the kernel
syscall layer beyond the explicit test seams. A same-kernel remount can observe
cached data that has not been shown to survive a system crash. With a real
write error below the file system it observes data the device lacks: on ext4
and XFS the remount replays a record that never reached the device
([sean-tan-PC's root checks](#a-failed-write-below-ext4-and-xfs-the-same-boot-reopen-replays-a-record-the-disk-lacks)). Full gaps and
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

No single test backend or experiment proves end-to-end durability. The argument
is layered so that each class of evidence has a precise claim and a known blind
spot. These are *evidence* layers. They are numbered independently of the four
software layers this document is organised by (Layer 1 — Storage Abstraction to
Layer 4 — Block Allocator). The numbering is the one the negative control and
the test sources already use ("layer 1b", "layer 3").

| Evidence layer | Claim | Evidence | Blind spot |
|---|---|---|---|
| 0. Functional | Each component behaves correctly when nothing crashes: the cache's read and write-behind paths, allocation, splitting and coalescing, record validation, input rejection. | `region_transaction:`; `pwregion:`, including seeded 64-step mixed histories checked after every operation; the `dual_wal:` validation cases; `txn_backend:`; `pwsieve:`; `pwbtree:`. | Anything about crashes. |
| 1a. Abstract WAL protocol | `DualTxnWal`, `RegionTransaction` and `PWRegion` preserve acknowledged updates at every abstract persistence boundary, and a failed or indeterminate boundary latches recovery-required instead of claiming durability. | `ShadowDurableRegion` (see below): separate live and durable bytes, with fail-before-copy, copy-then-fail and partial-copy outcomes; the `dual_wal:` crash and fault matrix; injection in `region_transaction:` and `pwregion_recovery:`. | One outcome per persistence call: no eviction, no asynchronous `CLWB`, one partial outcome rather than every subset of lines. |
| 1b. PMEM event model | Production recovery restores an allowed state from every durable image a crash cut admits under the baseline profile, within the stated scenario bounds. | The crash-image explorer over recorded production traces (`persistent_trace:`, `persistent_image:`, `persistent_explore:`), checked against the WAL contract (`persistent_recovery:`), the allocator invariants (`persistent_alloc:`), the sieve's cross-object invariants (`persistent_sieve:`) and the B+Tree's (`persistent_btree:`), including multi-transaction histories, crash during recovery and failed recovery boundaries. `persistent_control:` keeps it sensitive to flush placement. Since 2026-10-20 the WAL properties also run under the lazy search, which runs once per set of images recovery cannot tell apart and checks its own partition, verdicts and seam (`persistent_lazy:`). See [PMEM Crash Model](pmem-crash-model.md). | Short scenarios. Since 2026-10-19 the WAL scenarios cover every distinct image of every cut (lazily, since 2026-10-20, in 377 to 14,058 executions a history, sound as far as the load seam is complete, which `persistent_lazy:` checks only for the scenarios it runs); the allocator, format, sieve and B+Tree scenarios are budgeted in distinct images per cut, and an over-budget cut checks its extreme images and then a seeded random sample. Assumes the trace is complete and the hardware obeys the model. Cannot see instruction emission or the kernel. Speaks for the direct and file backends through their restriction arguments; for the file backend on block storage only under assumptions B2–B5, of which nothing guarantees B2. |
| 2. Backend translation | Each backend maps the abstract operations to the intended mechanism and propagates its result. | Instruction encodings and the native CPUID/writeback/fence smoke path (`persistent_ops:`); `fdatasync` ordering and real `EBADF` injection at the file-sync seam (`pwregion_bd:`); marking, coalescing, drain, the `O_DIRECT` probe and device refusals (`direct_io:`); fence coverage of every requested page and an `O_DIRECT` re-read of every synced range (`file_mmap:`); `MAP_SYNC` integration on Magpie's fsdax (`pmem_dax:`, opt-in). | Whether the protocol is correct; anything a crash loses. |
| 3a. Process crash, nothing lost | The allocator, WAL and workload recover after the process dies without a clean close, both at named protocol boundaries and at arbitrary points over long histories. | Thirteen abrupt-termination tests at named boundaries (`pwregion_bd:`); the random-timer `pwsieve` kill loop on the file and PMEM backends, which requires every acknowledged step to survive; the `pwbtree` kill loop, which requires every acknowledged mutation to survive, on the file and PMEM backends (2026-10-14; until 2026-10-25 this cell said PMEM was not yet run). | Flush placement. Process death on an mmap backend loses nothing, because the page cache or the CPU cache keeps every store, so the surviving image is the model's eager one. The elided-writeback mutant passes here (measured 2026-09-18, again 2026-09-27, on the file backend after its 2026-10-13 change, and under the B+Tree on 2026-10-14). |
| 3b. Real loss of unwritten data | On real hardware, under a crash that discards what was never written back, the production write-back placement is needed (the mutant loses acknowledged state) and suffices at the crash points reached (the ordinary build loses none). | Stage 2c warm reset over reserved DRAM (`pwreboot`: `SURVIVED` and `LOST`, 3 of 3 each); the `pwsieve` and `pwbtree` kill loops on the direct backend, at random crash points (see [Crash behaviour](#crash-behaviour-process-death-is-the-crash) and [the tree's](#crash-behaviour-of-the-tree)); `pwbtree_dio:`, a child killed at every phase mark of two tree mutations. | Stage 2c has one crash point per run, and DRAM stands in for PMEM. The direct backend works in 4 KiB units with drain-all fences, and says nothing about `CLWB`/`SFENCE`. |
| 4. Physical durability | Acknowledged state survives power loss on the target medium and persistence domain. | None; not attainable on Magpie. ADR is assumed, and the DIMM audit (dirty-shutdown count 0 on all twelve DIMMs) is the baseline a future run would be read against. | — |

The validation stages of [PMEM Emulation](pmem-emulation.md#validation-stages)
map onto these layers: Stage 0a is layer 1a, 0b is 1b, Stage 1 is part of
layer 2, Stage 2 is 3a, Stage 2c is 3b and Stage 3 is 4.

Evidence at an outer layer does not replace an inner layer. A successful
filesystem remount is not an exhaustive WAL fault model, and a shadow backend
cannot establish that Linux or a storage device honoured a system call. The
layers also do not merely coexist. Several tests exist to discharge the
explorer's assumptions: the store audit shows that the trace is complete,
`validate()` shows it is inside the model's domain, and the reduced search is
checked against the full one. `direct_io:boundary_images_are_model_images`
and `file_mmap:boundary_images_are_model_images` compare real file bytes with
the model. Each crash layer also samples a predictable
part of the explorer's image set: layer 3a the eager end, the direct backend
the lazy end rounded up to 4 KiB, Stage 2c one real image. That is why layer
3a cannot discriminate flush placement and layer 3b can. The argument, and the
exact statement of what is covered, is in
[Honours Thesis](THESIS.md#how-the-evidence-fits-together).

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
  own (see [Design Critique](CRITIQUE.md) #1), so a crash between allocating a
  chunk and naming it leaves a block marked used with nothing pointing at it.
  Measured, not hypothetical: 8-18 chunks per crash-loop run, and without
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

Its harnesses sit at four of the [evidence layers](#correctness-argument-by-layers):

| Harness | Evidence layer | What it shows |
|---|---|---|
| `PWSieveTest.v3` | 0 | Graceful remounts preserve and resume the workload; retirement recycles blocks; a leak is reclaimed |
| `test/pwsieve.main.v3` (`make pwsieve`) | 3a | Random-timer `SIGKILL` at arbitrary points, remount, invariants, monotone progress, final count against an independent sieve |
| `test/pwsieve.main.v3` (`make pwsieve-pmem`) | 3a | The same loop through `PmemMmapBackend`: `MAP_SYNC` + the native `CLWB`/`SFENCE` path on filesystem DAX. Passed on Magpie 2026-09-01 (13 kills, all `REPLAYED`, 376,256 primes matching an independent sieve). Needs `PWASM_PMEM_TEST_DIR`. Executes the production path on real media but does **not** discriminate flush placement — a killed process on a DAX mapping loses nothing still in cache; that sensitivity is layers 1b and 3b's |
| `test/pwsieve.main.v3` (`make pwsieve-direct`) | 3b | The same loop on the direct backend, where process death discards what was never written back: the elided-writeback mutant loses every acknowledged step (see [Crash behaviour](#crash-behaviour-process-death-is-the-crash)) |
| `test/pwreboot.main.v3` (`scripts/stage2c.sh`) | 3b | Stage 2c: the sieve armed, then a warm reset that discards the CPU cache over reserved DRAM, verified after reboot |
| `PersistentSieveTest.v3`, `PersistentControlTest.v3` | 1b | Every durable image a crash schedule permits, mounted through production recovery, checked against both the allocator's and the workload's invariants; the control changes only the provider and must catch the mutant |

The crash loop forks a child that sieves while the parent sleeps a seeded
pseudo-random 50 us - 20 ms interval and sends `SIGKILL`. Across five seeds at
25-30 iterations, every restart reported `DualWalRecovery.REPLAYED` -- the kills
all landed mid-transaction rather than while the child was idle -- and the final
count matched the reference exactly (376,256 primes below 5,429,504). Same
boundary as the rest of the file-backed work: process-crash consistency under one
kernel, not host power-loss proof.

`test/unittest/x86-64-linux/PWBTree.v3` (2026-10-14) is the second workload
driver, a B+Tree of u64 keys and values whose design and costs are in
[A second workload](#a-second-workload-what-a-btree-mutation-costs-2026-10-14).
It keeps the sieve's three rules, with whole nodes in place of bitmaps: nodes
are written directly and made durable before the transaction that publishes
them, `open()` sweeps the chunks a crash leaves allocated and unreachable, and
the old root node is freed in the commit that unpublishes it, the other
replaced nodes after it. Its harnesses:

| Harness | Evidence layer | What it shows |
|---|---|---|
| `PWBTreeTest.v3` (`pwbtree:`, `pwbtree_bd:`) | 0 | Format, reattach and refusal; splits to height 3 and beyond; seeded histories against a DRAM map with the invariants after every mutation; leaks reclaimed; a full region fails cleanly; the tree unchanged across forced collections; a corrupted or cyclic image refused; graceful remounts preserve and resume the tree |
| `PWBTreeTest.v3` (`pwbtree:each_put_makes_k_plus_h_plus_1_boundaries`, `pwbtree:unaligned_block_size_writes_back_whole_lines`) | 0 | On the production PMEM boundary path over anonymous memory, counted: every put makes k + h + 1 fences, each commit the lines its record predicts, WRITE exactly the lines of its new nodes, and a lookup nothing; at 4 KiB and at 4,104-byte blocks |
| `PWBTreeTest.v3` (`pwbtree_dio:`) | 3b | A child on the direct backend stopped at every phase mark of a root split (height 3 to 4) and of an update, then killed: the tree before the mutation up to the PUBLISH mark and after it from there on, and exactly the expected chunks reclaimed |
| `test/pwbtree.main.v3` (`make pwbtree`, `make pwbtree-pmem`) | 3a | Random-timer `SIGKILL`, remount, invariants, the whole tree against a DRAM map; every acknowledged mutation survives, and the one in flight lands on the side its last phase mark allows; `OK` needs at least one acknowledgement checked, else `UNCHECKED`. File: `OK` on sean-tan-PC and on Magpie's `/home`. PMEM: `OK` on Magpie's DAX, 49 acknowledged-mutation checks, 0 lost. All 2026-10-14 ([the tree's crash behaviour](#crash-behaviour-of-the-tree)); until 2026-10-25 this row said PMEM was not yet run |
| `test/pwbtree.main.v3` (`make pwbtree-direct`, `make pwbtree-direct-mutant`) | 3b | The same loop on the direct backend: the ordinary build `OK`, the elided-writeback mutant `LOST` with every acknowledged mutation lost (see [the tree's crash behaviour](#crash-behaviour-of-the-tree)) |
| `PersistentBTreeTest.v3` (`persistent_btree:`) | 1b | Two recorded puts, an insert that splits a leaf and the root (height 2 to 3) and an update at height 3, through the crash-image explorer: each image mounted through production recovery and checked by the allocator walk, `open()`, `checkInvariants()` and the tree before or after the put as its phase marks allow; every cut bounded, the final cut and the new nodes' durability before the publish complete; the insert with its node writebacks elided is caught (see [what says the tree is consistent](#what-says-the-tree-is-consistent-and-how-far-it-reaches-2026-10-15)) |
| `test/pwbtreebench.main.v3` (`scripts/pwbtree-bench.sh`) | — | Cost per operation; fails any run whose operations do other persistence work than k + h + 1 boundaries and the audited round's prepare calls and lines |

Until 2026-10-25 this section said no crash-image explorer scenario (layer 1b)
drives the tree; `persistent_btree:` has done so since 2026-10-15.

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
That state now propagates through `RegionTransaction`/`PWRegion`. A test-only
`ShadowTxnBackend` factory, exposing the same live/durable pair to `PWRegion`,
was planned so that complete allocator transactions would be checked after
simulated crashes. It was not built, because other layers reached the same
transactions under stronger fault models. `persistent_alloc:` mounts every image
a split allocation and a coalescing free admit as a real `PWRegion` and walks
it (layer 1b). `pwregion_recovery:` injects a failed commit point into an
allocation and a free. The file-sync seam injects a real `EBADF` whose record
may still be durable, which is the copy-then-fail case
(`pwregion_bd:file_commit_fdatasync_failure_requires_reopen`). Exact-fit
allocation is the one transaction shape left outside the explorer. It is covered
by `SIGKILL` at its commit boundary and after its apply (layer 3a), which sees
only the eager image. The shadow model establishes evidence layer 1a. It
complements the layer-1b trace explorer rather than being replaced by it. The
explorer enumerates which bytes survive a crash, and injects a failed boundary
only into recovery and mount. The shadow covers a persistence call that fails or
whose outcome is unknown at every boundary: fresh initialization, commit, apply,
recovery, flush and close. Neither replaces the backend and hardware work in
layers 2–4.

Run with:

```bash
test/unit.sh
```

---

## Open items

| # | Location | Description |
|---|---|---|
| 3 | `TxnBackend.v3:55-56` | Consider renaming `TxnRegionBackend` → `RegionManager` to better reflect its role as a factory. |
| 4 | `X86_64TxnBackend.v3:58` | Page size is hardcoded as `4096`; should be a named constant or queried via `sysconf(_SC_PAGESIZE)`. |
| 7 | `X86_64TxnPWRegion.v3` | `getHeader()` copies the header into a fresh `Array<byte>` on every call (minor GC pressure). |
