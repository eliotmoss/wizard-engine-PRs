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
`MmapRegionUtils.flushCacheLine()` and `storeFence()`. Those hooks now reach
CPUID-selected `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE` native stubs. This
connects the production seam, while physical PMEM crash testing remains
necessary for a hardware durability claim.

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
Since 2026-10-19 its loads go through a reader over the same provider too (see
[Loads](#loads-2026-10-19) below). Naturally aligned supported stores are
checked before recording, so an invalid internal layout store fails immediately
instead of entering a trace.

The seam now covers the whole active path. `PWRegion.format()` writes the region
header, sentinels, block table, and metadata descriptors through a
`DirectRegionWriter` — a non-transactional writer over the same provider —
before its whole-region `persistRange` (since 2026-10-19 all but the magic,
which it stores after that persist and persists under a fence of its own), and
the non-cached `BlockEntryHandle` and `ChunkHandle` setters take that writer as
an explicit parameter. The
provider is resolved once in the `PWRegion` constructor via
`X86_64PersistentOps.ensureFor()`, which installs the production provider on
regions that lack one (notably `VolatileRegion`) so that one object serves the
whole region; `DualTxnWal` uses the same helper. Normal allocator transactions
continue through `RegionTransaction` to the instrumented `DualTxnWal` for both
their records and their applied after-images.

One category remains outside the seam, deliberately:

- **`SingleTxnWal` and `MultiTxnWal`** are retained comparison implementations
  that are not wired into the commit path, so their stores can never appear in
  a trace of a running region.

**Immix line marks** (`LineMarkHandle.setMark`, `resetAllLineMarks`) cross the
seam but are still transient. Until 2026-10-19 they were stored through a
forged `Ref<LineMark>`, the last direct stores in the allocator; since then
`setMark` takes the region's `DirectRegionWriter`, like the other non-cached
setters, so every mark store is a 1-byte `STORE` in the trace. They still
bypass the WAL and the persistence boundaries by design: marking and resetting
issue no `CLWB` or `SFENCE`, and the marks must be rebuilt after a crash, so
they are not persistent state the explorer should model. In the model a mark
store becomes durable only if its line is written back for another reason:
background eviction, or a writeback of other bytes on the same line.
`persistent_ops:immix_line_marks_cross_the_seam` pins one store per mark, at
the mark's region-relative offset with the reset value, and no `CLWB` or
`SFENCE`.

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

### Loads (2026-10-19)

Until 2026-10-19 loads were direct `Pointer.load`s and the seam saw none of
them, so nothing could tell which bytes of a crash image recovery depends on.
A search that branches only on what recovery reads (Jaaru's constraint
refinement) needs exactly that, so loads now have a seam of their own. It is
not on `PersistentOperations`' list of operations: a production load is still
the same `Pointer.load`. What changed is who issues it.

- **The observer.** `PersistentLoadObserver` (`src/engine/TxnBackend.v3`) has
  one method, `observe(offset, length)`, and `PersistentOperations` carries a
  nullable `loadObserver`, null in production. Offsets are region-relative, as
  a store's are. The contract: `observe()` is called *before* the bytes
  `[offset, offset + length)` are loaded, so the observer may rewrite them in
  the region's mapping and the code loads what it wrote; one call may cover a
  whole layout or a byte loop's range, which the code may then load directly
  and more than once; and a load of bytes the running code stored itself is
  observed like any other, since telling the two apart is the observer's
  business.
- **The reader.** `DirectRegionReader` (`X86_64TxnPWRegion.v3`) is
  `DirectRegionWriter`'s counterpart: it holds the region's provider and its
  start, takes absolute addresses as the writer does, and offers
  `loadU8/U16/U32/U64/I16/I64(addr)` and `loadOffsetU64(offset)`, each of which
  calls `observe()` when an observer is installed and then loads;
  `observe(addr, length)`, for byte loops; and one `forge*` helper per layout
  (`BlockEntry`, `ChunkHeader`, `LineMark`, `MetaDataDesc`, `DualWalHeader`,
  `TxnRecordHeader`, `TxnCommitTrailer`, `LogEntry`), which observes the
  layout's whole byte range and then forges the `Ref`. Every reader of a region
  shares its provider, so an observer installed on the provider before a mount
  sees the mount's first load.
- **What goes through it.** The mount: `init()` reads the magic and `mount()`
  the block size, block count, sentinels, block table and log-chunk offset,
  one field at a time (until then both copied the whole 88-byte header into a
  heap array); `getHeader()` observes all 88 bytes before its copy, and
  `getMetaDataDesc()` and the Immix descriptor scan read `metaDataDescs` and
  `numDescs` alone. The `BlockEntryHandle`, `ChunkHandle` and `LineMarkHandle`
  getters take the reader, `getUsed(r)` as `setUsed(w, …)` takes the writer.
  `DualTxnWal`: header and slot validation, replay, its four `Ref` helpers,
  the transaction's cache misses (`readU8/I16/U64/I64`, so `RegionTransaction`'s
  miss path), and the checksum loop, which observes the two ranges on either
  side of the checksum field it skips. `PersistentAllocatorInvariants` walks
  through `region.reader()`. The workloads: `PWSieve` observes a bitmap before
  its byte loop, and `PWBTree` fetches each node it reaches (in the descents
  of `put()` and `get()`, in `nodeError()`, which both walks call before
  anything else is read from a node, and in `nodeWords()`): it observes the
  node's whole payload once, as a `forge*` helper observes a layout, and then
  loads its words directly.
  Every `Ref` forged over region memory on the active path comes from a
  reader's `forge*`.
- **What stays raw, deliberately.** `PersistentImageMount.freeze()` and the
  copies taken after an allocator check: they run after the code under test,
  and properties read the frozen copy, not the mount.
  `PWRegionUtils.calculateLogChecksum` and the rest of `SingleTxnWal` and
  `MultiTxnWal`, which are not wired in. The backends' own I/O (the direct
  backend reading its file at `create()`, the kernel writing pages back), which
  is not a load the program's logic depends on. And test code that inspects a
  region after the fact.
- **Recording.** `RecordingPersistentOperations.recordLoads()` installs a
  `RecordingLoadObserver` in front of any observer already installed, calling
  it first, and returns it. Each load becomes a
  `PersistentLoadEvent(afterEvents, offset, length, bytes)`: the bytes as the
  code was about to load them, and the number of `STORE`/`CLWB`/`SFENCE`
  events recorded before it, which places it in the same total order. Loads
  are kept in that list and are never `PersistentTraceEvent`s. *Why a separate
  list:* a trace is the crash machine's input, and a `LOAD` kind would have to
  be handled, or skipped, by `validate()`, `digest()`, `render()`, the crash
  machine's `step()` and the explorer, and would renumber and re-digest every
  trace recorded with loads on. Kept apart, a trace is byte-identical whether
  or not loads were recorded, and nothing that consumes traces can see one.
  `clear()` empties both lists.

The audit has five parts, in `PersistentOperationsTest.v3`:

- `persistent_ops:reader_matches_raw`: with no observer, every reader load
  equals the raw load, at every naturally aligned offset of a page for each
  width, and so do fields of every forged layout and of the handles' getters.
- `persistent_ops:load_observer_runs_before_the_load`: an observer that
  rewrites what it is shown changes what a load, and a forged layout's field,
  returns; a recorder in front of it records the rewritten bytes and the
  position after the stores already made; no load enters the trace.
- `persistent_ops:load_audit_covers_fields`, the counterpart of the store
  audit: format a region, allocate twice and free once, and take its bytes
  without `close()`, so both slots hold records to replay; mount that image
  with loads recorded, recover and walk the invariants. The first load is the
  magic, before any store. Structurally: the header fields mount reads are
  observed and the four it does not (`numBytes`, `numDescs`, `metaData`,
  `metaDataDescs`) are not, nor `userRoot` until `getUserRoot()` misses the
  transaction's cache and reads it; the WAL header and both records are
  observed whole, and the 64 bytes past either record are not; every block
  entry in memory order is observed but for its padding, as are both free-list
  heads. Every load lies in the region and in the store order, and the trace
  still validates.
- `persistent_ops:load_audit_unobserved_bytes_inert`, and the same for the
  sieve's and the B+Tree's reattach (`load_audit_sieve_reattach_inert`,
  `load_audit_btree_reattach_inert`): mount a crash image, recover and run the
  check with loads recorded, then three times more with every byte the run
  neither observed nor stored set to 0x00, to 0xFF and to a hash of its
  offset. The loads (offset, length and bytes), the stores, writebacks and
  fences, the recovery outcome and the verdict must not change. The images
  are the lazy and the eager one at every cut of a two-allocation scenario
  (1,471 cuts, 2,942 images, both `CLEAN` and `REPLAYED` recoveries) and of
  one sieve step (1,457 cuts, 2,914 images, through `PWSieve.open()` and its
  invariants), and at every fourth cut of a B+Tree update at height 3 (743 of
  2,968 cuts, 1,486 images, through `PWBTree.open()` and its invariants).
  On average 96 % of an allocator image and 92 % of a sieve image is neither
  observed nor stored, and so varied (at least 90 % and 78 %).
- `persistent_ops:load_audit_btree_descents_fetch_the_path`: the B+Tree's
  descents, which no reattach can exercise, since `open()` has walked, and so
  observed, every node before `get()` or `put()` could run. On a tree of
  height 3 with loads recorded from then on, a lookup observes exactly three
  whole nodes, the root first, all different, and a `put()` of the same key
  observes the same three, in the same order, before its first store.

Neither half alone would do. The structural test names fields, so a load it
does not name can escape; the inert test catches an escape only if the bytes
behind it change what the run does on these scenarios, and only if nothing
else in the run observed those bytes, at any point. Nine planted escapes were
each caught: a raw `getUsed()`, an unobserved checksum loop and a raw
record-field load by the field audit and all three inert-bytes audits; a raw
cache-miss read by the field audit and the sieve's and the B+Tree's (the
allocator's walk never misses the transaction's cache); an unobserved sieve
bitmap by the sieve's inert-bytes audit, the only one that runs that code;
a B+Tree walk whose fetch skips the observation, and a fetch that observes
only a node's tag and key count, by the B+Tree's; and a lookup's or a put's
descent that skips its fetch by the descent test alone. The B+Tree's
inert-bytes audit passes those two, because `open()` has observed every node
before either descent runs; that is why the descent test exists.

**What the reader does and does not show.** Since 2026-10-20 the lazy search
prunes by loads for the WAL properties ([The lazy search](#the-lazy-search-2026-10-20));
the allocator, format, sieve and B+Tree properties are still checked image by
image. Observation is
coarser than a load in four places, which can only make such a search branch
more, never miss a dependence: `getHeader()` observes all 88 bytes, a forged
layout all of its bytes, a B+Tree fetch the node's whole payload whatever
words are then read, and a checksum loop all of its record but the checksum
field. The inert-bytes audits show that every byte loaded was observed at
some point in the run, not that it was observed before it was loaded. That
order is tested for the reader itself (`load_observer_runs_before_the_load`),
and since 2026-10-20 for the scenarios `persistent_lazy:representatives_agree`
runs (see the lazy search); elsewhere it rests on the code's shape: the
reader's loads and `forge*` helpers observe first, a byte loop is observed
before it starts, and a B+Tree fetch returns the node only after observing it.

**Cost.** In production a load through the reader is a call, a read of the
provider's `loadObserver` and a branch that is never taken, and a B+Tree node
costs one such call when it is fetched. On sean-tan-PC (2026-10-19, file
backend on tmpfs, so that `fdatasync` costs almost nothing and the CPU path
dominates; `powersave`; 21 interleaved runs per build, pinned to CPU 2, a
performance core, and then to CPU 20, an efficiency core; against pwregions at
9f11eb6e, before the line-content explorer and the record-checksum control):

- The sieve step was unchanged on CPU 2 (162.2 µs, −0.02 %) and 1.2 % slower
  on CPU 20, where the wall-clock time per step stayed within the spread.
- Mounts and recoveries were 2–11 % faster on both cores, the recoveries on
  CPU 2 within the spread (*inference:* `mount()` no longer copies the header
  into a heap array twice).
- A B+Tree mutation was 0.6–0.7 % faster on CPU 2 and 2.3–2.5 % slower on
  CPU 20; a lookup stayed within the spread on both. A reader call on each node
  word had cost a lookup 3.7 % and a mutation 2.1–2.6 % on CPU 2, which is why
  a node is observed once, when it is fetched.
- An allocation or free was 2.9–3.5 % (100–155 ns) slower on CPU 2. On CPU 20 a
  one-block allocation or free was 8.2–8.5 % *faster*, and the larger ones were
  within the spread.

*Inference:* code placement, not the seam, sets the allocator's difference.
Adding one statement that never runs to the top of `PWRegion.deallocate()`,
which moves all the code placed after it, made the old code's one-block
allocation 5.7 % faster on CPU 2; adding two made it 1.9 % slower. With the
same additions, the branch was 4.7 % and 0.5 % slower than the old code.
Builds of the branch that drop the checksum loop's two `observe()` calls, or
that replace `DualTxnWal`'s reader calls with an inline check of the observer,
measured within 2 % of the old code on both cores. Two calls per commit cannot
cost 100–155 ns. Virgil's `#inline` hint on the reader's methods changes
nothing: the build with it is byte-identical, since `build.sh` does not turn on
v3c's early inliner (`-O3` or `-inline`). The variants and their runs are kept outside the
repository (`thesis-reviews/2026-10-19/stage-b/variants2`). Magpie's DAX mount
is not yet measured.

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
its fence-forced floor, then enumerate the images that the per-line prefixes at
or above that floor give. The reduction is sound and complete under the baseline
profile because

- a durable prefix only ever grows;
- a fence's obligation is fixed by the `CLWB`s preceding it, not by which
  voluntary writebacks happened first; and
- background eviction may complete any pending prefix at the crash boundary
  itself, so no earlier voluntary writeback reaches an image that the boundary
  cannot.

The reachable images at a cut are therefore exactly the images of the product
of the per-line prefix ranges above the floor. That is an argument, so
`persistent_explore:reduction_agrees_with_full_search` checks it executably
instead: at every cut of four traces, the two searches must produce the same
image set, compared byte for byte. The fourth trace, added on 2026-10-19,
rewrites bytes its lines already hold, so on it the two counts below differ.

**One image per distinct content of each line (2026-10-19).** Many prefix
vectors give the same image: a store that rewrites the bytes its line already
holds adds a prefix but no content. A validated store never leaves its cache
line, so a line's durable bytes depend on its own prefix length alone, and lines
are disjoint; two prefix vectors give the same image exactly when they give
every line the same 64 bytes. The reduced search therefore groups each line's
prefixes by exact content (`PersistentLineClasses`, from `lineClasses()`; a hash
is only the bucket key), represents each content by the least prefix that gives
it, and takes one content per line, so every state it visits is a distinct image.
Each exploration reports both sizes of its cut: `product`, the prefix vectors,
and `classProduct`, the distinct images; both saturate at 2^62. In the one-commit
WAL trace of `persistent_recovery:` the commit's first 192 stores zero its
record slot one byte at a time over bytes that are already zero, so its 215 cuts
admit 15,969,521 prefix vectors but 1,404 distinct images, and cut 192 alone
has 274,625 vectors and one image. Until 2026-10-19 the search enumerated the
prefix vectors themselves, least significant line first, and kept an image
once by its 64-bit digest, so a budget counted vectors and not images: at
budgets 12 and 24 that sweep checked 215 distinct images, one per cut.
`persistent_explore:line_classes_equal_distinct_images` keeps that enumeration
as a reference and requires the same images, byte for byte, each once, at every
cut of the small traces and at sampled cuts of a recorded `DualTxnWal` commit.

**Budgets, and what an over-budget cut checks (2026-10-19).** A budget counts
distinct images. A cut whose distinct images number at most the budget is
enumerated completely, the lazy image first and the lowest-addressed line's
contents changing fastest, and the exploration is not truncated. A cut with more
is truncated, and its budget goes to a stated selection, in this order:

1. the lazy image (every line at its floor content) and the eager image (every
   line at its last content);
2. for each line with more than one content, in ascending address order, that
   line alone at its last content with every other line at its floor;
3. for each such line, that line one content below its last with every other
   line at its last;
4. class vectors drawn uniformly at random without replacement from a SplitMix64
   stream, skipping any already taken. Below 2^62 vectors the draw is a sparse
   Fisher–Yates shuffle of the vector indices; at 2^62 or more each line's
   content is drawn independently, which is still uniform, and a repeat is
   skipped.

Repeats among the extremes are dropped, and the budget may stop the list at any
point. The seed is `selectionSeed()`, a function of the trace's digest and the
cut, so a run is reproducible; a truncated exploration records and renders it,
and a counterexample's `selection:` line gives the failing image's place among
the images checked and the seed. `selectCrashImages()` reruns a cut with a
given seed. Where the distinct images fit the budget this is exhaustive; elsewhere it
is the extremes plus a seeded sample, and evidence over the images it checked.
The extremes come first because a single line at one end of its range with the
rest at the other is a corner the prefix odometer reached only when the budget
covered the whole range of every lower line: it varied the lowest line first,
so a small budget left every higher line at its floor.
`persistent_explore:over_budget_selection_takes_extremes_then_seeded_random`
pins the order, the dedupe, and the replay from a seed.

**A recovery that skips the record checksum (2026-10-19).** The flag
`DualTxnWalMutants.skipRecordChecksum`, which only a test sets, makes
`validateSlot()` accept a record whose stored checksum does not match its bytes,
so recovery replays a torn record whose header, trailer and entries happen to be
well formed. `persistent_sieve:unchecked_record_checksum_is_caught` sweeps every
cut of a sieve step at 12 images per cut with the flag set and must fail. The
first failing image is at cut 385, one of its 4,147,200 distinct images: the
ninth the selection takes there, with the line at offset 3456 of the WAL's log
block alone at its last content and the cut's six other changeable lines at
their floor. Its mount reports `used block is linked into a free list (block
2)`. With the checksum compared, that image recovers into a consistent sieve,
and the sweep passes over cuts 0 to 385. The catch depends on the budget. On
2026-10-19 the same sweep passed at 2, 3 and 4 images per cut, and 4 was the
sieve tests' own budget until 2026-10-20; it failed at cut 660 at 6 and 8, at cut 385 at 10 and
12, and at cut 289 at 16 and 64. The prefix odometer, run on 2026-10-20 on the
pre-change explorer with the same flag, passed at 4, 12, 64 and 256 vectors per cut,
checking 5,776, 14,927, 36,605 and 126,076 distinct images. The selection
therefore reaches an image the odometer did not, but at the budget the sieve
tests then used it did not catch this mutant either (for the budget since, see
the next paragraph).

**What each budget catches, and what it costs (2026-10-20).** Apart from the
checksum skip's 12, the budgets were set in their tests with no recorded
reason. On 2026-10-20 a scratch harness, not on this branch
(`results/20261020T010508Z-sean-tan-PC-budget-sensitivity`), reran every
planted bug's sweep at 1, 2, 4, 8, 12, 16, 32 and 64 distinct images per
cut, and at 3, 6, 10, 13, 14 and 15. Each sweep ran as its test runs it,
stopping at the first failing cut. While a cut's budget covers no more than its
extremes the selection is fixed; wherever a sweep checked a random draw, it was
rerun under nine more seeds, a salt XORed into the per-cut seed derivation (salt
0 is the suite's seed). Two mutants from the 2026-10-19 selection study were
ported as test-only flags onto the split allocation, the only planted bugs on
an allocator scenario: `RegionTransaction` storing and preparing its
after-images before `wal.commit()`, and its 8-byte link fields stored in place,
unlogged. Both still fail on this code. The smallest budget that catches each
bug, under all ten seeds where seeds apply:

- the elided-writeback control, 15. It passes at 1 to 14 (no seed of ten
  catches it at 4 to 14). From 15 on it is caught at cut 708 by the fifteenth
  image the selection takes there, an extreme, so the seed does not matter;
- the record-checksum skip, 6, as above (no seed of ten catches it at 4). From
  14 on the seed decides the cut: the suite's seed fails at 289, as above, but
  at 16 eight of the ten seeds fail at 385 and the other two earlier, and at 64
  the cuts range from 258 to 385;
- the B+-tree's removed node writebacks, 1: the lazy image alone fails at event
  4,207. At 32 and 64 the sweep fails earlier, at 4,199, with `the tree's value
  for a key differs from the reference`;
- the early magic, 3: the third image at the magic's cut;
- after-images applied before the commit, 2, at cut 4; and
- the unlogged link store, 1, at cut 437 (from 2, at cut 3).

So the sieve step needs 15 to catch both of its planted bugs, the B+-tree split
insert 1, the split allocation 2 and the format 3. The suite runs the sieve's
two controls at 64 and 12 and its ordinary sweeps at 4, the B+-tree at 4, the
split allocation at 8 and the format at 8. Thirteen sweeps of unmutated code
from twelve suite tests, each planted bug's twin and the suite's other budgeted
sweeps, passed at every budget and under every seed tried: 1,334 runs, none
failing. The ordinary sweeps were timed on one P-core of sean-tan-PC under
the powersave governor, three runs each. At budgets 1, 4, 16 and 64 the
medians were 0.31, 0.50, 1.23 and 3.70 s for the sieve step (1,457, 5,798,
22,659 and 85,055 images) and 2.49, 4.77, 13.90 and 49.47 s for the B+-tree
split insert (4,602, 18,330, 72,584 and 283,420 images). The split allocation
took 0.13, 0.15, 0.20 and 0.40 s, and the format before its magic 0.07, 0.14,
0.39 and 1.32 s. Time grows close to linearly with the images checked, and at
15 the sieve step took 1.17 s (21,329 images). At each bug's smallest budget
the failing image is an extreme, the same under every seed, so each threshold
is that image's place in the selection's fixed order (the control's fifteenth
at cut 708, the early magic's third at cut 339), and a change to the order
moves it. These are six planted bugs, one or two per scenario, and a budget
that catches them is not shown to catch any other bug.

Since 2026-10-20 the sieve's ordinary sweeps run at 16 images per cut, the
smallest of the budgets measured at which a step's sweep catches both of the
sieve's planted bugs; at 4 it caught neither. The ordinary step's sweep checks
22,659 images, the retiring step's 30,740. The record-checksum test keeps its
12, which pins the catch at cut 385; at 16 the suite's seed fails at cut 289.
The other budgets already sit at or above their scenarios' smallest catching
budget and are unchanged.

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
there. Since 2026-10-19 it also sums `product` and `classProduct` over the cuts
it reached, and its artifact ends with the line `checked X of Y distinct images
(Z prefix states)`, followed by `, truncated` when a budget stopped some cut.

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

A real commit constructs its record across three cache lines, starting by
zeroing its slot one byte at a time, so a mid-record cut permits up to 357,408
per-line prefix vectors. Most of them repeat an image: the zeroing stores write
zeroes over zeroes. The 215 cuts of the one-commit trace admit 1,404 distinct
images in all: one at each of cuts 0 to 192 and at the commit point, and 1,210
over the 21 cuts that catch the record partly written, at most 168 at one cut.
The committed-boundary cut has exactly one image, since every line the record
touched has been flushed and fenced, and
`persistent_recovery:commit_boundary_survives_every_schedule` checks the
must-survive half of the contract there. Since 2026-10-19 the sweep over every
cut (`torn_record_images_never_invent_state`) mounts every one of the 1,404
images and asserts that it is exhaustive; until then it ran under a budget of 24
prefix vectors per cut, which reached 215 distinct images, one per cut, and
asserted that it was not. On sean-tan-PC it takes 0.06–0.09 s.

### Histories, and the slot that gets reclaimed

One commit exercises the contract only where the record still exists. With two
record slots, transaction N+2 commits into transaction N's slot, so the log copy
that proved N is destroyed while the WAL is still running. The only reason that
is safe is that N's after-image became durable *data* at transaction N+1's
boundary — which is what the overwrite guard in `appendCommittedRecord()`
verifies before it zeroes the slot. Two transactions can never reach that state,
so the scenario needs a third.

`PersistentWalHistoryProperty` is the same acknowledgement contract stated over
several after-images at once, each one marked acknowledged or not
(`PersistentWalAfterImage`). It mounts each image once for the whole history
rather than once per after-image, which is what makes it affordable in a sweep.

The claim is a suffix claim: transactions 1 and 2 are acknowledged only from the
third commit's first event onward, so `PersistentExplorer.checkCutRange()`
checks exactly those cuts instead of weakening the property to one that every
cut of the whole history can satisfy. Over that range — including the cuts that
catch slot 1 zeroed, where transaction 1 exists nowhere in the log at all —
production recovery must still produce both after-images.
`persistent_recovery:overwrite_guard_keeps_acknowledged_data` runs that sweep
over every distinct image of every cut in the range, 597,079 of them (exhaustive
since 2026-10-19; until then it was budgeted), checks that the same property
*fails* when the
unacknowledged third transaction is also required to survive — a property that
holds because it asks nothing is not evidence — and checks the history's final
cut exhaustively. That cut is one event past the third commit point, after the
third after-image is applied but not yet flushed (the commit point itself has
one image; see above). It is cheap for the same reason: each line the new
record touched was flushed and fenced, leaving only the third after-image's own
line, applied write-behind and not yet persisted. Two images, and both must
recover all three transactions. (Until 2026-10-19 this paragraph called the
final cut "the third commit point".) The test then sweeps the whole history,
with nothing required to survive, over all 601,294 distinct images of its 649
cuts. No cut of the history admits more than 14,256 (cut 642), which is the
budget both sweeps take, so a WAL change that let a cut leave more would make
them report truncation. On sean-tan-PC (2026-10-19) the range sweep took 15.4 s
and the whole-history sweep 15.7 s, the test 31.0–31.3 s.

The batched-apply history (`persistent_recovery:batched_apply_keeps_acknowledged_data`)
is exhaustive in the same way since 2026-10-19: its 728 cuts admit 393,342
distinct images, at most 10,868 at one cut (721). Its sweeps take 63 images over
the batched apply's cuts, 16,841 over the second commit, 353,649 over the
reclaiming third, and all 393,342 over the whole history with nothing required;
on sean-tan-PC they took 5 ms, 0.48 s, 9.2 s and 10.1 s, the test 20.1–21.0 s.
Before, the last three ran under budgets of 8, 8 and 4 prefix vectors per cut.

The two-crash profile runs over the same history in
`persistent_recovery:crash_during_three_commit_recovery_recovers`: crash at the
history's final cut (its lazy image), then crash again anywhere during the
mount that recovers it. The test asserts that second-crash sweep exhaustive:
replay writes two after-images and publishes them with one boundary.

---

## The lazy search (2026-10-20)

`src/engine/x86-64/X86_64PersistentLazyExplorer.v3` runs a property once for
each set of crash images it cannot tell apart, and branches only on the bytes
recovery and the property actually load. It is Jaaru's constraint refinement
(Gorjiara et al., ASPLOS '21: BuildMayReadFrom, Fig. 9; DoRead, Fig. 10;
Explore, Fig. 11) over the line classes of the reduced search, by re-execution
rather than by fork.

**The algorithm.** At a cut, each line the trace wrote can hold any of its
distinct contents (`PersistentLineClasses`, see
[Enumerating schedules](#enumerating-schedules)), independently of the other
lines. `PersistentLazySearch` keeps, for each such line i, the set S_i of
classes it may still hold, initially all of them, and one reused mapping that
starts each execution holding the lazy image (class 0 everywhere). The crash
image's mount gets a provider (`PersistentLazyOperations`) that performs and
records its stores and marks every byte a store covers, and a
`PersistentLoadObserver` installed before anything is constructed over it.
When the code under test is about to load `[offset, offset + length)`, the
observer splits the range by line and, for each line with |S_i| > 1, takes
the bytes this execution has not stored and on which S_i's classes are not
all equal. None, nothing happens. Otherwise S_i's classes fall into groups by
their exact bytes there, numbered by their least class, and that is a
decision point: the execution takes one group, S_i narrows to it, and the
line's unstored bytes in the mapping are rewritten from the least class left,
so the load reads bytes every class in the group agrees on. A load of the
execution's own stores never branches. The search is depth-first over
decision prefixes: an execution replays the prefix, takes group 0 at each new
decision and records it, and the next execution takes the next untried group
at the deepest decision that has one. Replaying checks that each decision
falls on the same line with the same partition (`PersistentLazyDecision`); if
not, the search stops and reports the property nondeterministic. An execution
that ends is a leaf (`PersistentLazyLeaf`), and stands for every image whose
line i holds a class in its final S_i, for every i: ∏|S_i| images.

**Frozen copies.** The WAL properties freeze the mount after recovery and
read the frozen copy, and the idempotence check mounts that copy and recovers
it again. On a lazy mount `snapshot()` returns a `PersistentLazySnapshot`
that keeps every byte recovery neither stored nor loaded, and the crash image
has not decided, as a mark standing for the crash image's byte at the same
offset. `PersistentImageView` is the interface both kinds of image share:
`read()` decides the marked bytes it reads (which can branch), and
`sameBytes()`/`firstDifference()` treat two marks at one offset, from one
execution, as the same byte, so comparing two snapshots decides only bytes
one of them knows. Mounting a snapshot, or the crash image a second time,
gives a copy mount in a pooled mapping of its own, which fills a byte the
view did not know from the crash image when it is first loaded. `freeze()`
on a lazy mount decides every byte: correct, but it branches on all of them.

**Lazy-safe properties.** A property runs lazily only as a
`PersistentLazyProperty`, a function of an image view and a
`PersistentImageMounter`: it mounts only through the mounter and reads frozen
copies only through the view. A `PersistentImageProperty` cannot be passed by
mistake. The same function, given a durable image and the eager mounter
(`PersistentImageMounters.EAGER`, `openMapped()` per image, as `runDualWal()`
always mounted), is the property's eager form, so the eager and lazy checks
run one body of code. `PersistentWalHistoryProperty.checkOn()` and
`PersistentWalRecoveryProperty`, idempotence included, are lazy-safe
(`lazy()`); `runDualWalOn()` runs recovery over whatever the mounter gives,
and `PersistentRecoveryRun.left` is the snapshot (`recovered` stays the
durable image for an eager run). The failure-injection and two-crash
properties, the allocator, format, sieve and B+Tree properties stay on the
reduced search.

**Entry points and results.** `PersistentLazyExplorer.checkImagesLazily()`,
`checkCutRangeLazily()` and `checkAllCutsLazily()` mirror the eager ones; the
budget counts leaves per cut, and a cut is truncated when the budget is spent
with alternatives left. `PersistentLazyCheckResult` reports `leaves`,
`represented` (the distinct images the leaves stand for, ∏|S_i| summed over
leaves and saturating at 2^62), `classProduct` and `product`, rendered as
"L leaves cover R of Y distinct images (Z prefix states)"; `exhaustive()` is
`ok() && !truncated`. A failing leaf's counterexample is its least image
(every line at the least class in S_i), built with the crash machine and
attached with `withImage()`; its selection line gives the decisions and the
classes still possible, and the image is re-checked with the property's eager
form, which must give the same detail (`confirmed`, and "eager re-check: same
detail" in the artifact).

**Why a leaf's verdict holds for every image it stands for.** By induction
over the execution: every image in the leaf's product makes the same loads
with the same bytes, and so the same stores and the same verdict, provided
every load of crash-image bytes is observed before it happens. Each loaded
byte is stored by the execution itself (the same in every image), or one that
every class in the line's current S_i agrees on, or one the decision just
made them agree on, and S_i only narrows, so a byte once agreed on stays
agreed on. The leaves partition the cut's images: the groups at a decision
partition S_i, two leaves part at their first differing decision, and
depth-first search takes every group. Three things this rests on are
checked, in `persistent_lazy:` (`test/unittest/x86-64-linux/PersistentLazyExplorerTest.v3`),
rather than assumed:

- *The leaves partition the images.* `leaves_partition_classes`: at every cut
  of the four reduction traces (with a property whose reads depend on what it
  read, and one that mounts three times) and of the one-commit WAL trace, every
  image Stage A enumerates lies in exactly one leaf and `represented ==
  classProduct`. `reading_nothing_is_one_leaf` (one leaf per cut) and
  `reading_everything_is_every_image` (`classProduct` leaves; 1,404 for the
  one-commit sweep) calibrate the two ends.
- *A leaf's verdict is each of its images' verdict.* `verdicts_agree`: each
  image's eager verdict equals its leaf's, detail for detail, at every cut of
  the small traces and of the one-commit trace under both halves of the
  contract (requiring survival fails before the commit point, so both verdicts
  occur); `three_commit_verdicts_agree` does the same for the 597,079 images
  of the overwrite guard's range.
- *No load escaped the seam or ran before its observation.*
  `representatives_agree`: each leaf, run lazily with every mount recorded, and
  run eagerly at its least and at its greatest image, must make the same
  stores, writebacks, fences and loads (offset, length and bytes), in every
  mount, and reach the same verdict: on the small traces, at every cut of the
  one-commit trace, and over the overwrite guard's range.
  `replay_detects_nondeterminism` checks the replay check with a property that
  reads its two lines in alternating order.
  `snapshots_compare_marks_without_deciding` checks that two snapshots of one
  execution compare without a decision, and that a clean recovery's snapshot
  equals the crash image without one.

Five planted bugs, each applied alone and the four agreement tests run
(`thesis-reviews/2026-10-20/stage-c/escapes`): an unobserved checksum loop is
caught only by `representatives_agree`, over the three-commit range (77 loads
against 75 at a leaf's least image; it passes the one-commit trace, and
*we infer* that the record's field loads there decide its bytes before the loop
runs); a raw load of the record's `txnSeq` by
`verdicts_agree` and `representatives_agree`; a search that narrows S_i
without rewriting the mapping, and a copy mount that never fills what its
view lacked, by both as well (the second only through the property that
mounts three times). A raw load of a replayed entry's value is caught by
none, and is harmless: the checksum loop has already decided those bytes.
*We infer* that the search needs a byte decided before it is loaded, not an
observation at every load; with the checksum skipped that load would escape.
`leaves_partition_classes` passes all five, as it should: the partition is a
property of the decisions, whatever the loads.

**What it costs and saves (2026-10-20).** On sean-tan-PC (i7-14700KF,
`powersave`, unpinned), the WAL sweeps, each run three times by Stage A's
exhaustive search and lazily; medians
(`thesis-reviews/2026-10-20/stage-c/measure-wal.txt`):

| Sweep | Cuts | Distinct images | Leaves | Most at a cut | Stage A | Lazy |
|---|---|---|---|---|---|---|
| One commit, nothing required | 215 | 1,404 | 377 | 13 | 43 ms | 27 ms |
| Three commits, the overwrite guard's range | 217 | 597,079 | 5,202 | 77 | 15.85 s | 0.23 s |
| Three commits, nothing required | 649 | 601,294 | 5,958 | 77 | 15.93 s | 0.33 s |
| Batched apply, the apply | 8 | 63 | 8 | 1 | 1.8 ms | 0.7 ms |
| Batched apply, the second commit | 217 | 16,841 | 379 | 13 | 0.45 s | 31 ms |
| Batched apply, the reclaiming commit | 217 | 353,649 | 12,572 | 272 | 9.40 s | 0.66 s |
| Batched apply, nothing required | 728 | 393,342 | 14,058 | 272 | 10.54 s | 0.72 s |

Every lazy sweep is exhaustive and its leaves cover exactly the distinct
images. Recovery's checksum loop, which reads a whole record, runs only once
the record's header and trailer fields are well formed (`validateSlot()`), and
*we infer* that replay storing each after-image before anything reads it is why
the batched apply's own cuts are one leaf each. `persistent_lazy:wal_sweeps_are_exhaustive` runs
the first, second, third, sixth and seventh rows in 2.1 s. The suite keeps the
eager sweeps in `persistent_recovery:` as they were; switching them is a later
stage.

**The planted bugs.** `DualTxnWalMutants.skipRecordChecksum` is harmless over
one commit into an empty slot, and both searches say so (373 leaves, and 1,404
images): a record validates only once every field but the checksum is
durable, and then it is the committed record. Over a reused slot it is not.
In the rewrite history of `unchecked_record_checksum_is_caught`, transaction 2
rewrites transaction 1's after-image and transaction 3 commits into
transaction 1's slot; an image whose new header and trailer are durable while
the entry line still holds transaction 1's entry is well formed but for its
checksum, and replaying it after transaction 2 puts transaction 1's value back.
With the checksum compared, 5,202 leaves cover the range's 597,079 images and
the contract holds. With it skipped, the lazy search fails at cut 640 after
4,797 leaves, in 0.24 s, with "acknowledged after-image absent after recovery
... durable=0x8877665544332211", and the eager re-check gives the same detail;
Stage A's sweep fails at the same cut after 525,837 images, in 13.2 s
(`measure-mutants.txt`). `DualTxnWalMutants.recordLastLineUnflushed` (new,
test-only) leaves the record's last line out of the commit-point fence; a
commit recorded with it fails `unflushed_record_line_is_caught` at the commit
point in the first leaf, the lazy image, with recovery `CLEAN`, confirmed
eagerly.

**A preview of the other properties (not converted).** Lazy-safe forms of the
allocator and sieve properties take a few lines (mount through the mounter,
check, deallocate), and were run outside the suite
(`measure-preview.txt`, `measure-preview-reps.txt`). The split allocation's
busiest cut (703, 145,212,480 distinct images) was truncated at 200,000
leaves, which cover 139,361,949 of them; cut 685's 987,840 images took 8
leaves. At 2,000 leaves per cut the whole sweep's 27,131 leaves cover
2,190,532,385 of its 2,263,112,768 images. The sieve step's cut 385 does not
prune at all: each of 200,000 leaves is one of its 4,147,200 images. Yet with
the checksum skipped the lazy search reaches the image
`persistent_sieve:unchecked_record_checksum_is_caught` finds there in its
second leaf, confirmed eagerly. Its busiest cut (870, at least 2^62 images) is
one leaf. `representatives_agree`'s check passes at allocator cuts 685, 700,
720 and 736 and sieve cuts 870, 1,000 and 1,456. The format property reads its
image before mounting it, the allocator property returns a raw copy of the
region, and idempotence over an allocator uses `sameBytes()`; those, and the
agreement tests over those scenarios, are what converting them needs.

**Limits.**

- Soundness rests on every load of crash-image bytes being decided first. The
  load audits and `representatives_agree` show it for the scenarios they run,
  and the latter only where an escaped byte differs between a leaf's least and
  greatest image; `verdicts_agree` runs every image of the scenarios it covers.
- Lazy-safety is a convention the type makes explicit, not a checked one: a
  property that read a mount's bytes raw, or a frozen copy other than through
  the view, would escape the same way.
- Re-execution needs a deterministic property. The replay check catches a
  divergence in the decisions; a nondeterministic verdict over the same reads
  would show only in the agreement tests.
- Coarse observation (a whole record for a checksum, a whole layout when
  forged) costs leaves, never soundness.
- The failure-injection, two-crash, allocator, format, sieve and B+Tree checks
  remain on the reduced search, budgeted where they were. The numbers above
  are from one desktop; Magpie was not used.

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

`PersistentImageMounts` offers three; the choice is a modelling decision
rather than an implementation detail:

| Mount | Container | Boundaries | Use |
|---|---|---|---|
| `openArray()` | anonymous mapping (`AnonMappedRegion`), which does not move; until 2026-10-19 a byte array on Virgil's heap, which the collector moves (below) | succeed without reaching the writeback/fence hooks | only recovery's effect on the bytes matters; costs an `mmap` and a `munmap` per image |
| `openFailing(failAt)` (2026-10-19) | the same mapping (`InjectedFailureRegion`) | as `openArray()`'s, except that boundary number `failAt` fails | a persistence failure during the mount (below) |
| `openMapped(record)` | `PmemMmapRegion` | translate into cache-line writebacks and fences on the region's provider | the mounted run must itself be modelled; with `record` set, its stores, `CLWB`s and fences are captured as a trace |

The tests' `PersistentAnonMounts.openRegion()` opens an image through
`PersistentImageBackend`, that is `openArray()`; until that moved, it opened
it in the tree explorer's mapping (`PWBTreeAnonRegion`).

**The array moves (2026-10-19).** `openArray()`'s byte array was an ordinary
heap object, and Virgil's semispace collector moves it, while `PWRegion` and
`DualTxnWal` keep the region's start as a raw address. A collection during a
mount leaves them reading the old copy, while their stores, which go through
the region's range, reach the moved one; the next collection reuses the old
copy's memory. The same hazard, in the volatile backend's array, aborted a
full test run in `pwbtree:` on 2026-10-14 (`docs/ROADMAP.md`,
`PWBTreeTest.v3`). The tree's explorer mounted its images
in an anonymous mapping from the start, and
since 2026-10-19 so do the sieve's (`persistent_sieve:`, and
`persistent_control:` through the same property) and the format scenario
(`persistent_alloc:crash_during_format_opens_consistent`). The mapping's
boundaries are the array's, so what a check concludes is unchanged; it costs
an `mmap` and a `munmap` per image, which took the six `persistent_sieve:`
tests it had before (19,394 images) from 3.08 s to 3.23 s, medians of nine
interleaved runs on sean-tan-PC. `persistent_sieve:mounted_image_survives_a_collection`
forces a collection under a mounted image, and fails on the array. Later the
same day `openArray()` itself moved to an anonymous mapping, and
`InjectedFailureRegion` with it (`openFailing()`), so neither
`PersistentImageBackend`, and with it `PersistentAllocatorProperty` and every
`persistent_alloc:` sweep, nor `runDualWalWithFailure()` and
`runPWRegionWithFailure()` mount an image in a heap array any more.
`persistent_alloc:mounted_image_survives_a_collection` and
`persistent_recovery:failing_mount_survives_a_collection` force a collection
under each, and fail on the array. Without their address check, over the
array, two allocations made after the collection returned the same block, so
the image handed on held one used extent too few, while the invariant walk,
which reads through `regionStart`, found nothing wrong; and a complete record
written after the collection did not replay on a remount, because the WAL
computes its checksum by reading the record back through the raw address. The move gives
an `mmap` and a `munmap` to each of the 9,594 images the twelve
`persistent_alloc:` tests it had before mounted in heap arrays, which took them
from 2.03 s to 2.15 s, and to the 218 the thirteen `persistent_recovery:`
tests mounted in them, which stayed at 0.59 s; `persistent_sieve:` and
`persistent_control:`, already on mappings, did not change (medians of nine
interleaved runs pinned to one core of sean-tan-PC). No crash-image property
mounts an image in a heap array now; `pwsieve:` and the `pwregion:` groups
still run on the volatile backend's (`docs/ROADMAP.md`).

The plain mount is sound for a recovery whose *result* is being checked: the
simulator, not the backend, already decided which bytes survived the crash, and
recovery's own persistence boundaries are what the next section models. It
cannot by itself express a crash during recovery — that is what the mapped,
recording mount is for — nor a persistence *failure*, which
`InjectedFailureRegion` adds (`openFailing()`): the same container, with
boundaries that fail once, at a chosen call.

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
enough to sweep exhaustively, as, since 2026-10-19, are the mid-record cuts of
the commit itself. The
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
acknowledged transaction. `persistent_recovery:failed_replay_persist_never_loses_a_record`
checks it over all 1,404 distinct images of the one-commit trace's 215 cuts and
asserts the sweep exhaustive (since 2026-10-19; before, a budget of 12 prefix
vectors per cut reached 215 of them); on sean-tan-PC it takes 0.06–0.07 s.

The allocator has the same shape in `runPWRegionWithFailure()` /
`PersistentAllocatorFailureProperty`, with one extra distinction. The invariant
walk is split: `checkStructure()` is the on-region structure alone, and
`check()` adds the mount-state clauses (not recovery-required, no buffered
writes). A mount whose boundary failed is *expected* to be latched, but its
structure must still be walkable — refusing further work is not a licence to
leave a half-applied transaction on the region — and reopening without injection
must produce a fully consistent allocator that has the allocation.

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

### The file-backed model is simpler, but not trivial

This document models PMEM. The same seam also carries `FileMmapRegion`, whose
boundaries reach the file as `fdatasync` (until 2026-10-13 also as `msync` of a
`persistRange`'s own pages), so the question of what a crash can leave behind
has a second answer that the thesis has to state.

It is tempting to claim the file backend admits only two images at any cut —
the state before the boundary and the state after it. **That is wrong.** The
kernel may write back any subset of dirty pages at any time, so a cut taken
before a boundary fans out for exactly the reason background cache-line
eviction makes a PMEM cut fan out. Nothing about a file makes the pre-boundary
state singular.

What genuinely differs:

| Dimension | PMEM (this document) | File-backed |
|---|---|---|
| Flush | `CLWB` is a request; completion may land at many later points and is forced by `SFENCE` | `msync` / `fdatasync` are synchronous — on return the range or file is durable |
| Outstanding state | The explorer must track requested-but-incomplete writebacks | None; a crash cut falls either before or after the call |
| Unit | 64-byte cache line | 4 KiB page |
| Scalar atomicity | Naturally aligned 1/2/4/8-byte stores are failure-atomic, and the recorder rejects traces that violate it | Writeback to a block device tears at sector granularity, and what survives beneath a journaling filesystem is filesystem-specific |
| Discriminating crash | Host power loss or system reset | Host power loss or kernel panic; the page cache is kernel-side, so process termination loses nothing |

The practical consequences are that one whole dimension of the state space —
asynchronous flush completion — disappears, and that the per-unit prefix
product that dominates the PMEM search shrinks sharply, since a 2 KiB WAL
record spans one page but thirty-two cache lines.

Two things get *worse* rather than better. The atomicity contract is weaker and
cannot be stated without naming the filesystem, so the file-backed model has no
equivalent of the crisp baseline above. And because neither mmap backend loses
anything on process termination, the `SIGKILL` evidence is process-crash
consistency on both, and neither of their crash loops discriminates flush
placement — which is the reason the correctness evidence rests on this model
and on the flush-placement negative control. That is a property of where those
two backends keep dirty data, not of block storage: the direct backend below
keeps it in the process, and its crash loop does discriminate.

A file-backed explorer is not needed. Since 2026-10-13 the file backend emits
the PMEM backend's trace, and under stated assumptions every image it can
leave is one this model admits for that trace, so the explorer's results carry
over to it: see [the file backend is a restriction of the PMEM model](#the-file-backend-is-a-restriction-of-the-pmem-model-on-block-storage-only-conditionally)
below. What this section says about the file backend's *own* image set stays
true; the restriction shows that set is inside the model's.

### The direct backend is a restriction of the PMEM model

The direct-I/O backend (`DirectIoRegion`, see
[Persistent Backends](persistent-backends.md#the-direct-io-backend-added-2026-09-24-measured-2026-09-27))
keeps the region in a private DRAM staging buffer and writes it back itself:
the provider's `clwb()` marks the line's 4 KiB unit, and at each fence the
region `pwrite`s every marked unit from the staging buffer on an `O_DIRECT`
descriptor and then calls `fdatasync`. Its trace is the PMEM backend's for the
same history (`direct_io:trace_matches_pmem_region`), so the question is only
which durable images each admits.

**Claim.** Every durable image the direct backend can leave on the device is an
image this model admits for the same trace, provided the device

1. never tears a naturally aligned 64-byte span — which any device whose
   power-fail atomic unit is at least a 512-byte sector satisfies — and
2. makes every completed write durable once a flush (or FUA) completes.

A crash inside a boundary's write-back is admitted at the cut *just before*
that boundary's `SFENCE`, which is recorded before the I/O is issued.

**Why.** A written unit carries the staging buffer's current contents, which
for each line in it is the full prefix of that line's stores so far — the
model's eviction of that line. Nothing reaches the device unless it is written,
so a line never CLWB-ed and never sharing a unit with one stays at its initial
value — the model's "no eviction". A fence drains every marked unit before
returning, so every line whose CLWB preceded it is durable with at least its
content at the CLWB — the model's fence-forced floor. Lines are independent in
the model, so the unit-wise mix of old and new that a crash mid-write-back can
leave is admitted whenever both the old and the new file are admitted line by
line at that cut.

**Checked, not only argued.** `direct_io:boundary_images_are_model_images`
records a format, two allocations, a free and a clean close over a real
`O_DIRECT` file, snapshots the file's bytes after every real `fdatasync`, and
checks each snapshot against this model exactly: for each touched line, some
prefix of its stores at or above the floor must equal the file's 64 bytes, and
every untouched byte must be the initial one. The new file must be admitted
after the fence, and both the previous and the new file before it. It runs at
4 KiB and 2 KiB blocks; at 2 KiB the WAL shares its unit with the region header,
so the check sees a file that differs from the lazy image, which exercises the
rounding. It rejects a flipped header byte, and a deliberately broken write-back
(only the first run written) was rejected at the fifth boundary. No explorer
enumeration and no budget are involved, so the check is exact for the scenario.

**What changes against the PMEM model.** There is no background eviction and no
asynchronous writeback completion inside the process: state that was never
handed to the kernel is discarded by process death. A `SIGKILL` of the direct
backend therefore samples, on real hardware and at a random cut, roughly the
model's *lazy* schedule — the weakest image recovery must cope with — which is
why the direct backend's kill loop separates the elided-writeback mutant from
the ordinary build (`LOST` against `OK`, both hosts, 2026-09-27) while the same
loop on DAX cannot. The sensitivity is coarser than the model's: 4 KiB units and
drain-all fences hide a missing request for a line that shares a unit with a
requested one. The device's own cache is never lost to a `SIGKILL`, so none of
this says anything about power loss.

**The atomicity contract becomes statable, and exposes a layout assumption.**
Assumption 1 is a property a device reports: sean-tan-PC's NVMe reports an
atomic write unit of 512 B (`atomic_write_unit_max_bytes`, AWUPF 0, i.e. one
LBA). The two-slot WAL's argument, though, rests on the *slots* failing
independently, and at 4 KiB blocks the WAL header and both slots share one
4 KiB unit (`[4096, 8192)`; pinned by `direct_io:record_write_rewrites_whole_log_unit`),
so every commit rewrites all three. On a device that is old-or-new per 512-byte
sector this is harmless — slot 1 starts on a sector boundary (6144) and the
rewritten neighbours are byte-identical — but a device that can leave a torn
sector *unreadable* rather than old-or-new could take out the slot holding the
only durable copy of acknowledged data. The same holds for the mmap file
backend, whose writeback is page-granular. The layout, not the interface, has to
know the device's write unit to rule it out.

### The file backend is a restriction of the PMEM model, on block storage only conditionally

Since 2026-10-13 the mapped-file backend (`FileMmapRegion`, see
[Persistent Backends](persistent-backends.md#implementations)) sits on the seam
as the direct backend does. `prepareChangedRange` issues one `clwb()` per
64-byte line through the region's provider, which is the direct backend's
`DirectIoOperations` and marks the line's 4 KiB page instead of executing
`CLWB`; `persistChanges` and `persistRange` issue one `sfence()` and then sync
every marked page, with one `fdatasync` of the file when any page is marked and
nothing otherwise. `persistRange` syncs every marked page, not only its own,
because the `SFENCE` that ends a PMEM `persistRange` completes every
outstanding `CLWB`. Its trace is the PMEM backend's for the same history
(`file_mmap:trace_matches_pmem_region`), so, as for the direct backend, the
question is only which durable images each admits. Before the change the file
backend issued no writeback request at all, so its trace said nothing was ever
made durable and the model could not speak for it.

**Which fence.** One `fdatasync`, chosen against two alternatives. An
`msync(MS_SYNC)` per run of marked pages syncs exactly what was asked, but on
ext4 each call is an `fsync` of its range with its own journal commit or device
flush (`ext4_sync_file()`), so a fence over several runs pays several flushes:
in the sieve, 7.67 syncs a step instead of 4.00 and a step 78 % slower on
sean-tan-PC's NVMe ([measured](persistent-backends.md#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)).
`sync_file_range()` writes no metadata and sends the device no flush, so it
covers neither a page's first allocation nor the device's cache, and cannot be
a fence at all. `fdatasync` makes durable every page of the file dirty when it
is called, marked or not, with one flush; an unmarked dirty page holds each of
its lines' full prefix, the model's eviction, so the superset is admitted.

**Claim.** Every durable image the file backend can leave is an image this
model admits for the same trace, provided the assumptions below hold for its
medium. A crash anywhere inside a fence's sync is admitted at the cut just
before that fence's `SFENCE`, which is recorded before the sync is issued. On
fsdax the assumptions are the baseline profile's own plus the kernel's `fsync`
contract. On block storage they include one, B2, that no specification
guarantees, and that holds by construction only when the filesystem has stable
writes, which sean-tan-PC's NVMe does not request. Magpie's devices are not
yet checked; `scripts/magpie-root-checks.sh` collects their `stable_writes`
with the device-mapper table below.

**On fsdax.** There is no page cache. The mapping is the media, stores reach it
through the CPU cache, and dirty lines are evicted when the CPU chooses: the
model's background eviction, under the baseline profile unchanged. The kernel
adds no writeback of its own between fences: `dax_writeback_mapping_range()`
returns at once unless the writeback is `WB_SYNC_ALL` (`fs/dax.c`, Linux v7.0),
so the background flusher writes nothing. At a fence, `fdatasync` writes back
every line of every entry dirtied since its last writeback (`dax_writeback_one()`
issues `CLWB` over the whole 4 KiB or 2 MiB entry and write-protects it), and
the filesystem's cache flush reaches the pmem driver, whose `nvdimm_flush()`
ends in `wmb()`, an `SFENCE`. The next store to a cleaned entry faults and
re-dirties it. A fence therefore writes back a superset of the lines requested
before it, and the extra lines are eviction, which the model admits. Beyond the
baseline profile this needs:

- **X1.** `fdatasync` on a DAX file returns only once every line of every entry
  dirtied since that entry's last writeback is in the persistence domain,
  together with the block allocations needed to read it back. The region is
  mapped without `MAP_SYNC`, so the first store to a hole allocates a block,
  and that mapping is metadata. *Argued from the kernel source above; not
  checked.*
- **X2.** Until that allocation is durable, the page reads as zeros, the file's
  initial content, which the model admits for every line no fence has covered
  yet; the fence that covers a line commits its page's allocation. *Argued from
  the ext4 and XFS allocation paths (B5 below); not checked.*

**On block storage, through the page cache.** The kernel writes any dirty page
back at any time with its current contents. For that to be the model's
eviction of every dirty line in the page, and a fence's `fdatasync` the
model's fence, the backend needs:

| | Assumption | Status |
|---|---|---|
| B1 | One writer, and every persistent store through the provider | Checked: the store audit (milestone 2), and the file after every sync is the trace's full image (`file_mmap:boundary_images_are_model_images`) |
| B2 | Each 64-byte line the device receives holds the line as it stood at one instant | **Argued only; not guaranteed.** Below |
| B3 | Each naturally aligned 512-byte sector holds, after a crash, the data of one write issued to it or its earlier content: never a mixture, never unreadable | A device property, reported and not checked: sean-tan-PC's NVMe gives `atomic_write_unit_max_bytes` 512 |
| B4 | A completed flush, or FUA write, makes durable what a read would then return, and the filesystem issues one in every `fdatasync` | Not checked. ext4 issues one per call (`ext4_sync_file()` → `blkdev_issue_flush()`); a write-through device, such as Magpie's controller, is sent none, and its acknowledgement is the boundary |
| B5 | Data is overwritten in place, and a block not yet durably part of the file reads as zeros | Argued for ext4 `data=ordered` and `data=writeback` with delayed allocation, and XFS without reflinked extents; exclusions below |

Two kernel facts complete it, both confirmed in the Linux v7.0 source and the
second also checked: a page is never written twice at once (background
writeback skips a page under writeback, and `fdatasync` waits for it, so a
background write already in flight also completes before `fdatasync`
returns); and `fdatasync` writes back every page of the file that is dirty
when it is called (`file_mmap:synced_pages_reach_the_device`).

*Can a page be written back while the program is still storing to it?* Yes,
unless the filesystem requires stable writes. Writeback write-protects the page
(`folio_clear_dirty_for_io()` → `folio_mkclean()`), and the next store faults
into `ext4_page_mkwrite()` (XFS: `iomap_page_mkwrite()`), whose
`folio_wait_stable()` waits for the writeback only when the mapping has stable
writes. Otherwise the store proceeds while the device may still be reading the
page. Stable writes are taken from the block device at mount
(`setup_bdev_super()`), and only integrity checksums, `md` RAID5 with
`skip_copy` and a few network block devices request them; sean-tan-PC's NVMe
reports `stable_writes` 0. btrfs waits whatever the device says.

*Does each 64-byte line then still hold a prefix of its stores?* Only if B2
holds. With one writer, x86's store order makes a line's contents at any
instant a prefix of the stores to it, so a device that reads each line at one
instant receives a prefix. Intel documents that on its 4th and 5th Generation
Xeon Scalable processors a device's partial read of a line fetches the whole
line from coherent memory (Taylor and Tkachuk, "Introduction to Intel Data
Direct I/O Technology (Intel DDIO) Analysis with Performance Monitoring",
Intel, 2024, §3.1.1, Table 1: "Even if the I/O agent requests a partial
cache-line read, a full cache-line is read from coherent memory"). A
full-line coherent read returns the line as it stood at one instant, which
suggests B2 holds in practice for DMA straight from the page cache on those
processors. Neither host here has one: Magpie's is a Cascade Lake Xeon Gold
6252N and sean-tan-PC's a Raptor Lake Core i7-14700KF. The article says only
that "many of the concepts apply to previous Intel® Xeon® class processor
generations" (§1), without saying which. Until 2026-10-20 this paragraph
said "x86 servers service a device read with one coherent request per 64-byte
line", which is broader than the source. No document promises B2. The PCI
Express Base Specification puts it
outside its scope (§2.4.2, "Update Ordering and Granularity Observed by a Read
Transaction"): under concurrent CPU updates "the Requester may observe an
updated value in location B and an old value in location A, regardless of the
placement of locations A and B within the data block", even a QWORD may be seen
half-updated, and only DWORD granularity is recommended. B2 is *false* wherever
the CPU copies the page piecewise while the program stores to it: `swiotlb`
bounce buffering, `dm-crypt`, `md` RAID5 without `skip_copy`. A copy that reads
a line's first half, then its second, can catch a later store to the second
half and miss an earlier store to the first, which is no prefix. With stable
writes the page cannot change while it is written, and B2 holds by
construction. sean-tan-PC's storage path (ext4 on an NVMe partition) copies no
pages, so there B2 is the platform's DMA read granularity. Magpie's (ext4 on an
LVM volume on `sda`, a disk the RAID controller passes through) copies none
either: `scripts/magpie-root-checks.sh`, run on 2026-10-16, found `/home`'s
volume a single `linear` target with an `LVM-` uuid, no `crypt` target
anywhere, and no block device on the host requesting stable writes
(`results/20261016T004310Z-magpie-root-checks/block-stack.txt`;
[Persistent Backends](persistent-backends.md#b2-on-magpie)). So on both hosts
B2 is the platform's DMA read granularity, and on neither does it hold by
construction.

*Sector atomicity, flushes, filesystems.* A 512-byte sector holds eight whole
lines, so under B3 every line is old or new. The model admits either, line by
line, when both are prefixes at or above the line's floor. The old content is a
prefix because writes of one page never overlap. The floor rises only at a
fence, and the fence's flush (B4) leaves each sector at least as new as its
last write before the flush. B5 excludes three configurations:

- ext4 `data=journal`, where data goes through the journal and jbd2 copies
  pages modified during a commit;
- copy-on-write placement (btrfs's default, XFS reflinked extents, ZFS,
  bcachefs), whose per-page versions this argument does not cover;
- ext4 `data=writeback` without delayed allocation or without `dioread_nolock`,
  which can expose stale data in a block allocated before its data is written.

The region file is created sparse (`O_TRUNC`, then `ftruncate`), so the first
write-back of each page allocates. With ext4's defaults (delayed allocation,
`dioread_nolock`) and on XFS the new block is an unwritten extent until the
write completes and its conversion commits, and until then the page reads as
zeros: the initial content, which the model admits until a fence covers the
page. `fdatasync` commits the conversion, because it is metadata needed to read
the data (ext4 advances `i_datasync_tid` for it). `fallocate`'s unwritten
extents behave the same way.

**Checked, not only argued.** `FileMmapRegionTest.v3` records a format, an
allocation, user data made durable with `persistRange` while that allocation's
after-images still wait (the sieve's step, and the one place a fence must
drain more than its own range), a second allocation, a free and a clean close,
over a real file, with both fences, at 2 KiB and 4 KiB blocks:

- `file_mmap:fences_sync_every_requested_page` replays the trace alone, not the
  region's marks: every page holding a line written back before a fence must be
  covered by the syncs that fence issues, and every sync must follow an
  `SFENCE`.
- `file_mmap:boundary_images_are_model_images` checks, after each fence, two
  images with the direct backend's exact check (`dioAdmittedAt()`): the file as
  the page cache holds it, which is every page written back (the eager
  extreme), and the *marked-only* image, the initial file overwritten at each
  sync by the pages that were marked, which is the least those syncs guarantee
  (the lazy extreme). Any page the kernel writes beyond that holds each line's
  full prefix, admitted line by line. Every image during a fence is checked at
  the cut just before its `SFENCE`.
- `file_mmap:synced_pages_reach_the_device` re-reads each synced range with
  `O_DIRECT` right after the sync and requires the page cache's bytes. The
  range is clean, so the read writes nothing back first. This checks, on the
  test host's filesystem and device, that a fence's sync wrote what it was
  asked for; it runs where the direct backend's tests run (`bin/` on
  sean-tan-PC, since `/tmp` is tmpfs).

The checks can fail. A deliberately broken `msync` fence that syncs only its
first run of pages fails both the coverage and the image check. As mutations
of production code, run once and reverted: a `persistRange` that syncs only its
own pages fails both, and a `persistRange` without its writeback requests fails
the trace check.

**What remains argued.** The device's image *between* fences. Reading the file
through the page cache shows memory, not the device, and an `O_DIRECT` read of
a range holding dirty pages makes the kernel write them back first, which
perturbs the state under test. So B2–B5, X1 and X2 are argued, and B2 is the
weak one. Three follow-ups would check more; all need root:

1. **A kernel crash on block storage.** `pwreboot` already runs the file
   backend (`setup`/`arm`/`verify` with `file`), and `arm` with an inherited
   `/proc/sysrq-trigger` descriptor resets the machine straight after the
   last acknowledgement. A warm reset loses the page cache but not, on most
   machines, the device's cache, so the ordinary build must give `SURVIVED`
   and the elided-writeback mutant, whose fences now sync nothing, `LOST`:
   the discrimination the kill loop cannot make (commands in
   [Persistent Backends](persistent-backends.md#the-file-backend-a-restriction-of-the-pmem-model-2026-10-13)).
2. **Block-level images.** dm-log-writes logs every write and flush beneath
   the filesystem; `replay-log` (xfstests) rebuilds the device at every entry,
   and each image, once its filesystem is mounted on a copy, can be compared
   with the trace by the same check. The log copies each write's data with the
   CPU when the write is submitted, so it checks B3–B5 over the writes the
   kernel issued, not B2. Commands in the same section.
3. **Stable writes.** `echo 1 > /sys/block/<dev>/queue/stable_writes` before
   mounting makes B2 hold by construction; the setting is read only at mount.

**What changes against the PMEM model.** Process death loses nothing: the page
cache is the kernel's. A `SIGKILL` therefore samples the eager image, and the
crash loop cannot discriminate flush placement on this backend, before or after
the change. On 2026-10-13, after it, on sean-tan-PC's NVMe: `pwsieve` with the
ordinary provider `OK` over 20 kills (20 acknowledged-step checks, 0 lost); with
the elided-writeback mutant, whose fences sync nothing, also `OK`. The mutant
never waits for the device, so at the default delay it fills the sieve's table
after 4 kills (4 checks, 0 lost); with the kill delay capped at 2,000 µs it
takes all 20 (6 checks, 0 lost). As on DAX, the evidence for the file backend is the model plus
the checks above.

### Scale

A recorded split allocation is roughly 700 events across 15 cache lines: the
WAL record is written byte by byte, and the after-images touch the block table
in several places. The commit boundary cut and the final cut are cheap, but the
mid-record cuts admit far more distinct images than a unit test should mount
(145,212,480 at cut 703, and 2,263,112,768 over the 737 cuts), so the per-cut
sweep runs under an explicit budget and asserts that it reports itself as not
exhaustive. Since 2026-10-19 the budget counts distinct images and an
over-budget cut takes its extremes first (see "Enumerating schedules"): at
budget 8 the sweep checks 1,360 distinct images, where the prefix odometer at
budget 8 reached 845.

---

## Controlling state explosion

Naively branching after every byte store and every possible writeback is
exponential. The implementation should combine:

- cache-line-level state with store-version tracking;
- hashing and deduplication of equivalent durable states;
- partial-order reduction for independent cache lines;
- bounded transaction and crash counts;
- exhaustive runs for the canonical one/two/three-transaction scenarios;
- seeded pseudo-random schedules for longer mixed allocator histories; and
- since 2026-10-20, for lazy-safe properties, one execution per set of images
  that recovery's loads cannot tell apart
  ([The lazy search](#the-lazy-search-2026-10-20)).

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
   counterexample with truncation reported beside the verdict. **2026-10-19:**
   the reduced search takes one of each line's distinct contents per line, so a
   budget counts distinct images; a cut within its budget is enumerated
   completely, and one over it checks the extremes, then a seeded random sample
   (see "Enumerating schedules" above); the one-commit, three-commit and
   batched-apply WAL sweeps are exhaustive at every cut.
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
   during recovery" above. **Later slices completed 2026-08-20:** failure
   injection during an allocator mount (`runPWRegionWithFailure()`,
   `PersistentAllocatorFailureProperty`), a two-transaction allocator scenario,
   and the three-transaction history whose third commit reclaims the first
   transaction's slot (`PersistentWalHistoryProperty`, `checkCutRange()`; see
   "Histories, and the slot that gets reclaimed" above). **Remaining:** the
   explicit-flush and clean-close scrub scenarios.
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
