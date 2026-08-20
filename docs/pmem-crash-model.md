# PMEM Crash-Consistency Model and Trace Exploration

This document specifies the proposed deterministic failure model for the
persistent-memory backend. It complements the abstract shadow backend, the
file/DAX integration tests, and eventual physical-PMEM testing described in
[Persistent Backends](persistent-backends.md) and
[PMEM Emulation](pmem-emulation.md).

The central observation is that DAX mapping is not the difficult part of a
protocol test. A byte array or ordinary file is sufficient to hold simulated
live and durable images. The difficult part is enumerating which stores have
actually reached the persistence domain when a crash occurs, given that dirty
cache lines can be evicted without an explicit flush, `CLWB` is asynchronous,
and `SFENCE` orders and completes earlier writebacks.

---

## Decision summary

The project should retain its current tests and add a bounded, trace-driven
PMEM persistence explorer:

1. Route persistent stores, cache-line writebacks, and fences through an
   instrumentable operation layer.
2. Record the actual `STORE`, `CLWB`, and `SFENCE` actions produced by a short
   WAL or allocator scenario.
3. Explore every distinct durable image allowed by the declared PMEM model at
   each selected crash point.
4. Materialize each image and run the real `DualTxnWal`/`PWRegion` recovery
   implementation against it.
5. Check WAL outcomes and allocator invariants after recovery.

A specialized explorer is the recommended first implementation. A general
model checker remains useful for a separate abstract proof of the two-slot
protocol, but it should not replace tests that exercise the real byte layout,
checksums, and recovery code.

---

## Existing evidence and its boundary

| Test mechanism | What it establishes | What it does not establish |
|---|---|---|
| `ShadowDurableRegion` | WAL correctness at the `BackendRegion` boundary; live/durable separation; fail-before-copy, copy-then-fail, and one deterministic partial-copy outcome | Spontaneous cache eviction, asynchronous per-line `CLWB` completion, arbitrary subsets of durable lines, or fence semantics |
| Counting backends | Number of prepares and persistence boundaries per commit | Which bytes survive a crash or whether the native instruction ordering is correct |
| Abrupt file-backed child tests | Real mmap/file integration and recovery without `deallocate()`/`close()` at commit-before-apply and apply-before-next-boundary windows | Controlled cache loss, exhaustive crash images, host crash, or power loss; the verifier shares the kernel page cache |
| Opt-in DAX integration | `MAP_SYNC` and the completed PMEM backend operate against fsdax | Exhaustive persistence schedules or physical power-loss durability |
| Physical PMEM campaign | Behaviour on the target persistence domain under controlled interruption | Exhaustive proof over every protocol state |

The current shadow model is intentionally operation-level:

```text
ordinary store              changes live bytes only
prepareChangedRange         queues a whole range
persistChanges              copies queued ranges to durable bytes
crash                       restores live bytes from durable bytes
```

This is a useful executable model of `BackendRegion`, especially for API
failure propagation. It under-approximates PMEM behaviour because ordinary
dirty lines never become durable early and a prepared range becomes durable
only at the simulated boundary. Its partial outcome copies a fixed prefix; it
does not enumerate all line subsets or completion orders.

The proposed explorer is therefore an additional protocol-model layer, not a
replacement for `ShadowDurableRegion`.

---

## Target event model

The recorder needs, at minimum, the following ordered events:

```text
STORE(seq, offset, width, value)
CLWB(seq, cacheLine)
SFENCE(seq)
```

The explorer inserts `CRASH` cuts between selected events rather than requiring
the program to emit a crash event. Recording the line image or version visible
after each store is useful when several stores touch the same cache line.

The simulated state contains:

- the current live byte image;
- the durable byte image;
- a version and dirty state for each cache line;
- outstanding writeback requests, including the line version observed when
  each `CLWB` was issued; and
- the event position and any configured crash/recovery bound.

### Store

`STORE` updates the live image and advances the affected line's version. It
does not force durability. The explorer may branch to model an unsolicited
cache eviction that writes a dirty line back before any `CLWB`.

### Cache-line writeback

`CLWB` requests writeback of the addressed line but does not imply that the
writeback has completed when the instruction retires. The explorer must allow
the requested version to reach the durable image immediately, after later
events, or only when a later fence requires completion.

If later stores modify the same line before the writeback completes, the model
must state whether the completion may include a later line version. The first
implementation should record line versions explicitly and explore every
version permitted by the agreed hardware abstraction rather than silently
assuming that `CLWB` captures an immutable snapshot.

### Fence

When `SFENCE` returns, every preceding writeback that the protocol relies on
must have completed according to the selected persistence model. A post-fence
crash image must therefore include the required versions of all preceding
flushed lines. Later dirty versions need not be durable unless they were also
written back.

### Crash

A crash discards the simulated volatile cache and outstanding operations. The
durable image alone is used for reopen and recovery. The model must allow any
pre-fence subset that is reachable through background eviction and completed
writebacks; it must not always force prepared data either to disappear or to
survive as one atomic group.

---

## Agreed baseline persistence profile

The initial model uses the following assumptions, agreed on 2026-08-12. "All
possible outcomes" elsewhere in this document means all outcomes within this
profile and the stated scenario/crash bounds, not every PMEM platform.

| Dimension | Baseline assumption |
|---|---|
| Architecture and writers | x86-64, one logical writer, ordinary temporal stores to write-back memory. Concurrent persistent writers, DMA/device writes, and non-temporal stores are out of scope. |
| Cache line | 64 bytes. This is a production-platform precondition, matching the backend's cache-line iteration and the WAL's 64-byte alignment. |
| Persistence domain | ADR: memory-controller write-pending queues are power-fail protected; CPU caches and store buffers are not. `CLWB` plus `SFENCE` is therefore required. eADR is not part of this baseline. |
| Crash | A fail-safe power loss or system reset for which ADR works as advertised. A crash discards CPU caches, store buffers, and outstanding operations that have not reached ADR, while preserving everything that has reached ADR. Media faults, unsafe/dirty shutdowns in which ADR fails, and process-only crashes are separate failure classes. |
| Scalar-store atomicity | Naturally aligned 1/2/4/8-byte stores are failure-atomic and cannot tear. Unaligned stores, stores wider than 8 bytes, and stores crossing a cache-line boundary are outside the supported contract. The recorder must reject such a trace; production persistent-store call sites must be audited or enforce alignment before evidence is claimed. |
| Store order | The recorded single-writer x86 store order is authoritative. Stores to one cache line become durable in program order; different cache lines may become durable in different orders until constrained by writeback and fencing. |
| Writeback atomicity | A 64-byte cache-line writeback is not assumed failure-atomic. It may leave a causally valid partial line at the granularity of the atomic stores above, while respecting same-line store order. The explorer must not reduce a record-range writeback to an all-or-nothing line or range copy. |
| `CLWB` issue and completion | `CLWB` is asynchronous. A requested writeback may reach ADR immediately, after later trace events, or when a later fence requires it. It must include the same-line stores that precede the `CLWB`; because the instruction is not an immutable snapshot, completion may also include any causally reachable later line version present before completion. The explorer considers every such version. |
| `SFENCE` | When `SFENCE` returns, every preceding `CLWB` on which the protocol relies has completed to the ADR domain. It orders the earlier stores/writebacks before later stores, but does not flush unrelated dirty lines. A store after a `CLWB` is not guaranteed durable merely because that earlier request completed. |
| Background eviction | At every trace-event boundary, any dirty line may be written back without an explicit `CLWB`, with the same tearing and same-line ordering rules. State deduplication and partial-order reduction may remove equivalent schedules but not durable images. |
| Crash cuts | Scalar `STORE` events and a returned `SFENCE` are atomic transitions. `CLWB` remains outstanding until completion. A crash while a fence is waiting is represented by a pre-return cut with any allowed subset of writebacks completed; a post-return cut contains every completion required by the fence. |
| Crash bound | Normal-operation scenarios exhaustively explore one crash. A separate bounded recovery profile permits one additional crash during recovery, for a maximum of two crashes in those scenarios. Claims must state which profile was run. |

An eADR configuration may be added later, but it is a distinct model: globally
visible dirty cache lines are then inside the persistence domain and explicit
cache-line writeback is not required for power-fail safety. Results from eADR,
from process termination, or from a file-backed model must not be presented as
evidence for the ADR baseline.

The architectural basis for the profile is the
[Intel 64 and IA-32 Software Developer's Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html);
the [Intel Persistent Memory FAQ](https://www.intel.com/content/www/us/en/developer/articles/troubleshooting/persistent-memory-faq.html)
summarizes the eight-byte power-fail atomicity and flush-plus-fence contract.

Target-machine configuration and validation are documented separately in
[PMEM Emulation](pmem-emulation.md), so this document remains focused on the
abstract crash and persistence semantics.

---

## Instrumentation seam

Milestone 2 implements a per-region `PersistentOperations` provider with this
interface:

```text
storeU8(offset, value)
storeU16(offset, value)
storeU32(offset, value)
storeU64(offset, value)
clwb(cacheLine)
sfence()
```

`BackendRegion` owns the provider, so dependency injection is explicit and
there is no global trace state. `DualTxnWal` and `PWRegion` both obtain that
exact provider from the backend region through
`X86_64PersistentOps.ensureFor()`. `PmemMmapRegion` uses the same object while
translating `prepareChangedRange()` and persistence boundaries, which gives one
total order across all three event kinds. Sharing a single provider object per
region is what makes that order total: a second, uninstalled provider would
produce events interleaved with, but not ordered against, the writeback and
fence stream.

`X86_64PersistentOperations` is the production implementation. Scalar methods
perform the same `Pointer.store` operations as before; x86-64 supplies the
little-endian byte order. `clwb(cacheLine)` and `sfence()` reach
`MmapRegionUtils.flushCacheLine()` and `storeFence()`. Those native hooks are
still placeholders, so this seam is not evidence of physical PMEM durability.

`RecordingPersistentOperations` works on an ordinary byte range. It executes
the same checked scalar stores against the live image, then appends a typed
event with a monotonically increasing sequence number. It records region-
relative, 64-byte-aligned cache-line starts and every fence requested by the
PMEM backend. `clear()`/`reset()` empties the event vector and restarts sequence
numbering at one. Its stable per-event rendering is:

```text
STORE(seq=N, offset=O, width=W, value=0xV)
CLWB(seq=N, cacheLine=L)
SFENCE(seq=N)
```

The structured representation is `PersistentTraceEvent(seq, kind, offset,
width, value)`: `STORE` uses all fields, `CLWB` uses `offset` as the cache-line
start with zero width/value, and `SFENCE` uses only `seq`. Tests inspect these
fields rather than parsing the rendering.

The active `DualTxnWal` now routes fresh header creation, byte-wise record and
slot zeroing, every record/header/entry/trailer/checksum store, after-image
application, recovery replay, and durable-slot scrubbing through this provider.
Loads remain direct and uninstrumented. Naturally aligned supported stores are
checked before recording, so an invalid internal layout store fails immediately
instead of entering a trace.

The seam now covers the whole active path. `PWRegion.format()` writes the region
header, sentinels, block table, and metadata descriptors through a
`DirectRegionWriter` — a non-transactional writer over the same provider —
before its whole-region `persistRange`, and the non-cached `BlockEntryHandle`
and `ChunkHandle` setters take that writer as an explicit parameter. The
provider is resolved once in the `PWRegion` constructor via
`X86_64PersistentOps.ensureFor()`, which installs the production provider on
regions that lack one (notably `VolatileRegion`) so that one object serves the
whole region; `DualTxnWal` uses the same helper. Normal allocator transactions
continue through `RegionTransaction` to the instrumented `DualTxnWal` for both
their records and their applied after-images.

Two categories remain outside the seam, both deliberately:

- **Immix line marks** (`LineMarkHandle.setMark`, `resetAllLineMarks`) are
  explicitly transient. They bypass the WAL and the persistence boundaries by
  design and must be rebuilt after a crash, so they are not persistent state
  the explorer should model. They are now the only direct stores left in the
  allocator, and `persistent_ops:immix_line_marks_emit_no_events` pins that.
- **`SingleTxnWal` and `MultiTxnWal`** are retained comparison implementations
  that are not wired into the commit path, so their stores can never appear in
  a trace of a running region.

Keeping the direct writer and `RegionTransaction` as separate types with
distinct setter names (`setUsed(w, …)` versus `setUsedCached(txn, …)`) is a
safety property, not just style: an allocator mutation that accidentally
bypassed the WAL would fail to compile rather than silently escape the log.

`PWRegion` validates its geometry before formatting, because the provider
rejects a misaligned or out-of-range store by aborting the process rather than
returning an error. A block size that is not a multiple of 8 (which would
misalign the block table) and a region too small to hold the header, log chunk,
metadata and one free block are both refused up front.

Tracing only `prepareChangedRange()` is not enough: it occurs after the stores,
aggregates ranges, and cannot represent a partially constructed record that
was written back by ordinary cache eviction before its explicit flush.

---

## Scenario capture and artifacts

The recorder's event vector is live and grows for as long as the region is in
use, so it is not itself a scenario. `PersistentTrace`
(`src/engine/x86-64/X86_64PersistentTrace.v3`) is the frozen form:
`RecordingPersistentOperations.snapshot(name)` copies the events recorded so far
into an immutable, named artifact with the region size, and
`PersistentTraces.capture(recorder, name, run)` clears the recorder first so a
captured scenario contains exactly its own events, with sequence numbers
restarting at one, even on a region that was already written to.

A trace supports the four operations the explorer needs:

- `prefix(n)` is the **crash cut**: the trace as it stood after exactly `n`
  events. Cuts clamp at both ends, so a walk over `0..length()` needs no
  special cases, and a cut is itself a trace — it validates, digests, and
  renders on its own.
- `validate()` checks the trace against the baseline profile above and returns
  the first defect with its event index: a non-ascending sequence number, a
  store whose width is not 1/2/4/8, one that leaves the region, one that spans
  two cache lines, one that is not naturally aligned, or a writeback that is
  unaligned or out of region. A trace that fails this check must not be
  explored, because its stores can tear in ways the model does not represent.
  Natural alignment already implies single-line containment at these widths, so
  containment is checked first and the tearing rule stays independently
  reachable rather than becoming dead code.
- `digest()` is a content hash over the region geometry and every event field,
  used to deduplicate schedules that produced an identical trace. It
  deliberately excludes the scenario name: the digest identifies behaviour, not
  the label the run was recorded under.
- `touchedLines()` returns the distinct 64-byte lines written, ascending. This
  is the set of lines the explorer must hold dirty/version state for, so it
  bounds the per-cut state space. A `CLWB` of a line nothing wrote contributes
  no state.

Both artifact renderings are stable, so a failing exploration can be stored and
diffed instead of re-derived from a run that may not repeat. A trace renders as
a header with the geometry and event census, a fixed-width 16-digit digest, one
line per event, and a matching footer:

```text
--- pmem-trace demo
region-bytes=256 cache-line=64 events=3 stores=1 clwbs=1 fences=1 lines=1 digest=0x...
STORE(seq=1, offset=8, width=8, value=0xDEADBEEF)
CLWB(seq=2, cacheLine=0)
SFENCE(seq=3)
--- end pmem-trace demo
```

`PersistentCounterexample` wraps that with the scenario name, the property that
failed, a detail line, and the crash cut, and renders the cut trace inside:

```text
=== pmem-counterexample two_slot_commit
property: acknowledged transaction survives
detail: slot 1 record valid but after-image absent
crash-after-event: 2 of 3
--- pmem-trace demo
...
--- end pmem-trace demo
=== end pmem-counterexample two_slot_commit
```

`withImage()` attaches the durable bytes a crash left behind, so a stored
counterexample carries both the schedule prefix and the state it produced. The
artifact then names the image (`durable-image: bytes=N digest=0x…`) and prints a
window of it, aligned down to 16 bytes and clamped to the region, since dumping
a whole region helps nobody:

```text
durable-image: bytes=256 digest=0x...
durable-window: offset=0 length=16
00000000: 00 00 00 00 00 00 00 00 EF BE AD DE 00 00 00 00
```

A counterexample with no image renders exactly as it did before durable images
existed. `validate()` is also the single definition of the scalar-atomicity
baseline — the store-audit tests over `PWRegion` check the frozen trace through
it rather than restating the rules.

---

## Durable images and cache-line state

`PersistentTrace` says what a scenario stored, flushed and fenced;
`src/engine/x86-64/X86_64PersistentImage.v3` says what that means for
durability. It is the transition system the explorer will search, implemented
and testable before any search exists.

`PersistentCrashMachine` replays a validated trace against volatile per-line
state. Each touched line (exactly `touchedLines()`, so a `CLWB` of a line
nothing wrote carries no state) holds its stores in program order plus two
indices into that list: how many have reached the persistence domain, and how
many an outstanding writeback request obliges the next fence to complete.
Because both are absolute prefix lengths, a completed writeback never has to be
subtracted out of a pending request.

Trace events drive the machine; every durability decision is a separate call,
which is precisely the branching point a schedule enumerator needs:

```text
step()                     execute the next trace event
  STORE                      append to its line; nothing becomes durable
  CLWB                       raise the line's requirement to the stores issued so far
  SFENCE                     complete every outstanding requirement, and nothing else
writeback(line, count)     complete a prefix of a line's pending stores (torn line)
evictLine(line)            background eviction of one line
evictAll()                 background eviction at this event boundary
crash()                    the durable image; caches and outstanding work are discarded
```

A writeback to a count strictly between the durable and pending ends is the
non-atomic 64-byte line: partial, at scalar-store granularity, in program
order. A store issued after a `CLWB` and before the fence stays volatile even
though its line is dirty, while `evictAll()` may still make it durable — the
asymmetry the piggybacked commit boundary relies on.

`PersistentDurableImage` is the resulting immutable byte image, with a
little-endian `read()` for assertions, a `digest()` for state deduplication, and
`sameBytes()`/`firstDifference()` for comparing two schedules' outcomes. A
machine starts from the region's prior durable content, so a scenario can be
explored on an already-formatted region rather than only on a blank one.

`PersistentImages.lazyCrash()` and `eagerCrash()` are the two extremal
schedules — nothing durable but what a fence obliged, and every dirty line
evicted at every boundary. They bracket every image the model permits at a cut,
and where they agree the cut has exactly one image: after a scenario has
flushed and fenced every line it touched, the schedule no longer matters.
`persistent_image:real_wal_after_image_needs_its_flush` pins that on a recorded
production `DualTxnWal` commit/apply/flush trace.

Still absent, and the remainder of milestone 4: enumerating the permitted
schedules between those two extremes, deduplicating the states they reach, and
handing the images to real recovery (milestone 5). Counterexample artifacts
therefore still carry the schedule prefix rather than the bytes it produced.

---

## Enumerating schedules

`src/engine/x86-64/X86_64PersistentExplorer.v3` searches the machine's
transitions for the durable images one crash cut can produce.

A search state is the machine's trace position plus the two per-line prefix
lengths — nothing else. Durable bytes are a function of that state, so
equivalent schedules (the same writebacks completed in a different order, or at
a different event boundary) collapse to one state, and an image is materialized
only for a state that is actually reported. States are bucketed by a hash and
then compared field by field, so a hash collision costs a comparison rather
than a dropped schedule.

`crashImages()` is the full search: from every state it branches on each line's
permitted writeback prefixes — the torn-line and background-eviction rules are
the same branch — and on executing the next trace event, until the cut. Every
visited state at the cut contributes its image, including states reached by
evictions after the last event and before the crash. It is exponential, so it
takes a state budget; exceeding it sets `truncated`, which the result and its
rendering both carry. A truncated exploration is not evidence that no other
image exists.

`reducedCrashImages()` is the same answer without the intermediate schedule
states: replay to the cut with no voluntary writeback, which leaves each line at
its fence-forced floor, then enumerate the per-line prefixes at or above that
floor. The reduction is sound and complete under the baseline profile because

- a durable prefix only ever grows;
- a fence's obligation is fixed by the `CLWB`s preceding it, not by which
  voluntary writebacks happened first; and
- background eviction may complete any pending prefix at the crash boundary
  itself, so no earlier voluntary writeback reaches an image that the boundary
  cannot.

The reachable images at a cut are therefore exactly the product of the per-line
prefix ranges above the floor. That is an argument, so
`persistent_explore:reduction_agrees_with_full_search` checks it executably
instead: at every cut of three traces, the two searches must produce the same
image set.

This is also where the model's shape becomes visible. A completed fence removes
freedom: after the WAL's commit boundary the record is durable on every
schedule, so that cut has exactly one image, while the cut one event later — the
after-image applied but not yet flushed — has two. Independent lines multiply
rather than being decided together, and program order within a line holds in
every image, so a partially constructed record is a state the search produces
rather than one it collapses away.

`checkImages()` runs a `PersistentImageProperty` over every image a cut permits
and turns the first failure into a stored `PersistentCounterexample` carrying
those bytes; `checkAllCuts()` sweeps every cut and reports the earliest failing
one. A property returns `null` when it holds and a detail string when it does
not, so the artifact says what went wrong rather than only that something did,
and it names the window of the region worth printing. `PersistentCheckResult`
keeps truncation beside the verdict: `exhaustive()` requires both that the
property held on every image and that the search which produced them completed,
because a budget-limited search that found nothing has not shown that nothing is
there.

Milestone 5's real recovery run is one such property. Nothing in this layer
assumes it: the property is an arbitrary function of the durable bytes.

---

## Trace exploration and real recovery

A trace can be recorded once up to the first crash because persistence does not
normally affect the program's live-memory reads before that crash. The explorer
then walks the trace and branches whenever a dirty or requested line may become
durable.

For every distinct crash image:

1. Copy the durable bytes into a fresh simulated region or ordinary file.
2. Construct a new `DualTxnWal`/`PWRegion` instance.
3. Invoke the production recovery path.
4. Check the expected acknowledgement contract and structural invariants.
5. Optionally record recovery's own stores, `CLWB`s, and fences and repeat the
   exploration for a bounded second crash.

Running the real recovery implementation is important. Reimplementing recovery
inside the checker could verify a correct model of an incorrect program. A
separate abstract model checker may still prove high-level invariants, but the
trace explorer should produce concrete byte images consumed by production
code.

An ordinary file is adequate as the durable-image container for this stage;
the simulator, not the filesystem, determines which bytes survive. A DAX file
is still required later to test `MAP_SYNC` and the native backend translation.

---

## Running real recovery over an image

`src/engine/x86-64/X86_64PersistentRecovery.v3` closes the loop: it mounts an
enumerated durable image and runs the production `DualTxnWal` recovery path over
it. `PersistentRecoveries.runDualWal()` copies the image into a fresh region, opens
a WAL over it *without* fresh initialization (this is a remount, not a format),
calls `recover()`, and freezes the resulting bytes back into an image before
releasing the region. The run reports what recovery said — its
`DualWalRecovery` outcome, whether it latched recovery-required, and the
sequence numbers it adopted — alongside the bytes it produced.

`PersistentWalRecoveryProperty` expresses the acknowledgement contract as a
property the explorer can check over every image a cut permits:

- every image must mount and recover without reporting `PERSIST_FAILED` or
  leaving the mount recovery-required;
- recovery must be idempotent — recovering the bytes recovery just produced must
  not change the after-image again;
- for a cut at or after the commit boundary, the acknowledged after-image
  **must** be present afterwards; and
- for an earlier cut it may be absent or may replay, but it must never recover
  as a value that was never committed, which is what a torn record accepted as
  valid would look like.

A scenario starts from the region as it already stood: the trace records only
the commit, and the bytes left by the formatted, WAL-initialized mount are the
model's starting durable image. Capturing the fresh initialization inside the
trace instead would add its byte-wise zeroing of the whole log chunk to the
state space for no modelling benefit — those bytes were durable before the
scenario began.

### What this run bounds

A real commit constructs its record byte by byte across three cache lines, so a
mid-record cut permits on the order of 10^5 images (the product of the per-line
prefix ranges) — far more than a unit test should mount and recover. The
committed-boundary cut is the cheap one: every line the record touched has been
flushed and fenced, so it has exactly one image, and
`persistent_recovery:commit_boundary_survives_every_schedule` checks the
must-survive half of the contract exhaustively there. The sweep over every cut
runs under an explicit per-cut budget and asserts that it reports itself as
**not** exhaustive, so it stands as evidence over the images it checked and
nothing more. The unbounded sweep belongs in milestone 8's separate tier.

---

## Properties to check

Each completed recovery run should check, as applicable:

- every acknowledged transaction is reflected in the recovered state;
- an unacknowledged transaction may be absent or may replay if a complete valid
  record reached durability, but it must not produce a malformed partial state;
- invalid/torn records do not pass header, trailer, geometry, and checksum
  validation;
- valid records replay in transaction-sequence order;
- a destroyed slot was not the sole durable copy of required after-images;
- recovery is idempotent;
- recovery-required state prevents unsafe same-instance progress; and
- allocator memory-order links, free-list links, used/list state, and chunk
  metadata are internally consistent.

For allocator tests, checking only whether another allocation succeeds is too
weak. The explorer should reuse or introduce direct invariant walkers for the
block chain and every free list.

---

## Initial scenario matrix

Exhaustive exploration should begin with short scenarios whose state spaces
remain reviewable:

1. fresh WAL/header construction;
2. committed record before after-image application;
3. after-image application before the next piggybacked fence;
4. transaction N data plus transaction N+1 record at their shared fence;
5. third-transaction slot overwrite and its overwrite guard;
6. crash during replay before and after recovery's fence;
7. explicit flush and clean-close slot scrub; and
8. complete allocator split, exact-fit allocation, and left/right free
   coalescing transactions.

The current hand-written shadow and abrupt-process tests provide expected
outcomes and invariants for many of these scenarios.

---

### Which container an image is mounted in

`PersistentImageMounts` offers two, and the choice is a modelling decision
rather than an implementation detail:

| Mount | Container | Boundaries | Use |
|---|---|---|---|
| `openArray()` | byte array | succeed without reaching the writeback/fence hooks | only recovery's effect on the bytes matters; costs no syscalls, which is what makes a sweep over thousands of images affordable |
| `openMapped(record)` | `PmemMmapRegion` | translate into cache-line writebacks and fences on the region's provider | the mounted run must itself be modelled; with `record` set, its stores, `CLWB`s and fences are captured as a trace |

The array mount is sound for a recovery whose *result* is being checked: the
simulator, not the backend, already decided which bytes survived the crash, and
recovery's own persistence boundaries are what the next section models. It
cannot by itself express a crash during recovery — that is what the mapped,
recording mount is for — nor a persistence *failure*, which
`InjectedFailureRegion` adds: an array container whose boundaries fail once, at
a chosen call.

## Crash during recovery

`recordDualWalRecovery()` mounts an image through the recording PMEM container
and runs production recovery on it, returning both the outcome and the trace of
what recovery made durable. That trace, started from the image recovery was
handed, is a persistent scenario like any other — so a second crash is explored
with the same machinery, and `checkCrashDuringRecovery()` is the two-crash
profile: crash once wherever the first exploration says, then crash anywhere
during the recovery that follows.

Recording through the production `PmemMmapRegion` rather than a copy of its
translation is what keeps this evidence about the real seam.
`recordPWRegionRecovery()` does the same for an allocator mount, handing the
recording container to `PWRegion` through `PreparedRegionBackend`, so the whole
mount — WAL recovery plus whatever the allocator publishes — is one trace.

For the canonical case — a commit-boundary crash — replay writes one after-image
and publishes it with one boundary, so the second-crash state space is small
enough to sweep exhaustively, unlike the mid-record cuts of a commit itself. The
acknowledged after-image must survive every one of those images: recovery does
not scrub the record it replayed, and replay is idempotent, so a remount reaches
the same state. The allocator runs the same profile, with the invariant walk as
its property.

### Recovery that cannot persist

`runDualWalWithFailure()` mounts an image in the failure-injecting container and
fails one recovery boundary. `PersistentRecoveryFailureProperty` states what
must then hold, over every image a cut permits:

- a `PERSIST_FAILED` outcome and a latched mount imply each other — recovery may
  neither claim a durability it did not reach nor latch silently; and
- the bytes the failed attempt left behind must still satisfy the ordinary
  contract on a later mount.

The second clause is the one with teeth. A recovery that reclaimed or scrubbed a
record it had not durably replayed would return an honest-looking
`PERSIST_FAILED` and still have destroyed the only durable copy of an
acknowledged transaction.

---

## Allocator scenarios

The same pipeline runs over a whole allocator transaction. `PWRegion` is
formatted on a trace-recording PMEM region, the recorder is cleared, and one
`allocChunk()`/`freeChunk()` is recorded: its WAL record, its commit boundary,
and the after-images it applies afterwards. Every image a crash can leave is
then mounted through `PersistentAllocatorProperty`, which builds a `PWRegion`
over the image (`PersistentImageBackend`, no fresh format), lets the production
mount path run WAL recovery, and walks the resulting structure.

`PersistentAllocatorInvariants.check()` is that walk, returning the first
violation as a string rather than asserting, so one implementation serves both
a unit test and a crash-model property. It requires the memory-order chain to be
acyclic, index-increasing and doubly linked through to the region marker; every
free extent to be classified by its actual span and to appear exactly once on the
matching free list; free extents never to be adjacent; a used entry to be on no
list; and the mount to be neither recovery-required nor left with buffered
writes. `persistent_alloc:walker_detects_a_broken_chain` corrupts one byte of a
durable block table and requires the walk to report it — a walk that cannot fail
would make every other allocator check vacuous.

Checking only whether a later allocation still succeeds would be too weak: a
broken chain can satisfy one request.

### The backend must emit the boundaries

A trace recorded over a volatile region contains no `CLWB` and no `SFENCE`,
because `VolatileRegion`'s persistence boundaries are no-ops. The model then
concludes — correctly, for what it was shown — that nothing the allocator wrote
was ever made durable, and the exploration reports genuine inconsistencies:
after-images evicted without a durable record to replay them. Allocator
scenarios are therefore recorded over a `PmemMmapRegion`, whose
`prepareChangedRange`/`persistChanges` translate into writebacks and fences on
the same provider. Mounting an image for recovery can still use an ordinary
byte-array region, since the simulator, not the backend, decides which bytes
survived.

### Scale

A recorded split allocation is roughly 700 events across 15 cache lines: the
WAL record is written byte by byte, and the after-images touch the block table
in several places. The commit boundary cut and the final cut are cheap, but the
mid-record cuts permit far more images than a unit test should mount, so the
per-cut sweep runs under an explicit budget and asserts that it reports itself
as not exhaustive.

---

## Controlling state explosion

Naively branching after every byte store and every possible writeback is
exponential. The implementation should combine:

- cache-line-level state with store-version tracking;
- hashing and deduplication of equivalent durable states;
- partial-order reduction for independent cache lines;
- bounded transaction and crash counts;
- exhaustive runs for the canonical one/two/three-transaction scenarios; and
- seeded pseudo-random schedules for longer mixed allocator histories.

Reductions must preserve every state relevant to record validation and the
acknowledgement contract. In particular, record construction cannot simply be
collapsed into one atomic write: an early eviction may persist a partially
constructed header, entry set, trailer, or checksum.

Randomized exploration is useful supplementary evidence, but only exhaustive
exploration within a stated bound supports a claim that no failing schedule
exists within that bound.

---

## Specialized explorer versus general model checker

| Option | Strength | Cost/risk |
|---|---|---|
| Specialized trace explorer | Uses actual byte layouts and can invoke production recovery; counterexamples are concrete traces and images | The PMEM transition semantics and reductions must be implemented correctly |
| General model checker over an abstract WAL | Strong high-level reasoning about slots, acknowledgements, replay, and crash states | Usually does not exercise serialization, checksums, pointer stores, or production recovery |
| General model checker consuming traces | May provide mature state exploration once events are formalized | Integration back to concrete crash images and real recovery is still required |

The recommended order is to build the small specialized explorer first, then
decide whether an abstract formal model would add enough assurance to justify a
second representation of the protocol.

---

## Implementation milestones

1. **Completed 2026-08-12:** agree and document the PMEM/persistence-domain
   assumptions above.
2. **Completed 2026-08-13:** introduce the per-region instrumentable persistent
   store/flush/fence interface, its x86-64 production provider, and the typed
   in-memory provider used to pin active-WAL ordering. All active `DualTxnWal`
   persistent stores and PMEM writeback/fence requests share this seam.
   **Store audit completed 2026-08-14:** `PWRegion.format()` and the non-cached
   allocator handle setters now route through the same provider, so a recorded
   trace is a complete description of the active path's persistent writes.
3. **Completed 2026-08-19:** integrate recorded events into deterministic
   counterexample artifacts and scenario capture. `PersistentTrace` freezes a
   named snapshot, cuts it at a crash point, validates it against the baseline
   profile, digests it for deduplication, and renders it; the recorder feeds it
   via `snapshot()`/`PersistentTraces.capture()`, and
   `PersistentCounterexample` is the stored form of a failing exploration. No
   explorer emits those counterexamples yet, and they do not yet carry a
   durable image, because nothing models durable bytes before milestone 4.
4. **First slice completed 2026-08-19:** cache-line state, asynchronous
   writeback completion, fence obligations, background eviction, and crash-image
   generation, in `PersistentCrashMachine`/`PersistentDurableImage`, with the
   lazy/eager extremal schedules and an image digest for deduplication (see
   "Durable images and cache-line state" above). **Second slice completed
   2026-08-19:** the full branching search with state deduplication and a
   reported budget, and an equivalent reduced search justified by the
   monotonicity of durable prefixes and checked against the full search at every
   cut (see "Enumerating schedules" above). **Completed 2026-08-20:**
   counterexamples carry the durable image and a clamped byte window, and
   `checkImages()`/`checkAllCuts()` turn a property over images into a stored
   counterexample with truncation reported beside the verdict.
5. **First slice completed 2026-08-20:** mount an enumerated image and run the
   production `DualTxnWal` recovery over it, with the acknowledgement contract
   (survival, no invented state, no latch, idempotence) as a checkable property
   (see "Running real recovery over an image" above). **Remaining:** allocator
   scenarios beyond a single WAL commit, and the wider scenario matrix.
6. **First slice completed 2026-08-20:** a direct allocator invariant walker
   (`PersistentAllocatorInvariants`) and image mounting for `PWRegion`
   (`PersistentImageBackend`, `PersistentAllocatorProperty`), driven by recorded
   split-allocation and coalescing-free transactions (see "Allocator scenarios"
   above). **Remaining:** the rest of the initial scenario matrix.
7. **First slice completed 2026-08-20:** bounded crash-during-recovery
   exploration — `recordDualWalRecovery()` captures recovery's own stores,
   writebacks and fences, and `checkCrashDuringRecovery()` explores a second
   crash over that trace, the same profile for an allocator mount
   (`recordPWRegionRecovery()`), and recovery-persistence failure injection
   (`InjectedFailureRegion`, `PersistentRecoveryFailureProperty`) — see "Crash
   during recovery" above. **Remaining:** failure injection during an allocator
   mount, and multi-transaction scenarios.
8. Retain exhaustive short tests in the regular suite; run longer seeded
   exploration separately.
9. Independently validate that the production PMEM implementation emits the
   intended native stores, `CLWB`s, and `SFENCE`s.

---

## Evidence claim

Successful exhaustive runs would establish that, within the declared PMEM
model and scenario bounds, every explored ordering of stores, eviction,
writeback completion, fence, and crash recovers to an allowed state. They would
not establish that the production compiler emitted the intended instructions,
that a DAX mapping is configured correctly, or that a particular physical
machine implements the assumed persistence domain. Those claims remain the
responsibility of backend instruction tracing, DAX integration, guest-reset
experiments, and physical power-interruption testing.
