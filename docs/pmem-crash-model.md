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
3. Integrate recorded events into deterministic counterexample artifacts and
   scenario capture. The in-memory recorder and stable per-event rendering
   exist, but no explorer/counterexample artifact or durable-state trace format
   exists yet, so this milestone remains pending.
4. Implement cache-line state, background eviction, asynchronous writeback,
   fence completion, crash-image generation, and state deduplication.
5. Feed every generated image into real WAL recovery and assert the core
   acknowledgement properties.
6. Add direct allocator invariant walkers and the initial scenario matrix.
7. Add bounded crash-during-recovery exploration.
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
