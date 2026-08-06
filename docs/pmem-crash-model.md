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

## Assumptions that must be explicit

"All possible outcomes" is meaningful only relative to a declared machine and
persistence model. Before implementation, record decisions for:

- cache-line size;
- aligned-store and persistence atomicity for 1/2/4/8-byte stores;
- whether cache-line writeback itself may tear at the chosen persistence
  domain;
- x86 store ordering relevant to the trace;
- ADR versus eADR, including whether CPU caches are in the persistence domain;
- the completion guarantee supplied by `SFENCE` for preceding `CLWB`s;
- whether eviction may occur after every store or only at recorded scheduling
  points; and
- the maximum number of crashes, including whether recovery may crash again.

The initial project model should target the persistence domain assumed by the
production `CLWB` + `SFENCE` protocol. Alternative assumptions can be separate
configurations; results from one configuration must not be presented as proof
for another.

---

## Instrumentation seam

The backend currently learns about persistent writes only after direct pointer
stores have happened. That is sufficient for range preparation but cannot
produce the store-level trace required here. Persistent accesses should be
routed through a narrow interface such as:

```text
storeU8(offset, value)
storeU16(offset, value)
storeU32(offset, value)
storeU64(offset, value)
clwb(cacheLine)
sfence()
```

The production implementation performs the real store or native instruction.
The recorder implementation mutates the live image and appends an event. The
same WAL and allocator code must drive both implementations so the recorded
trace corresponds to the production ordering.

`DualTxnWal` already centralizes most record loads/stores and after-image
writes, which is a useful starting point. Formatting and allocator handle
writes must also be audited so every store to the persistent region is visible
to scenarios that exercise those paths.

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

1. Agree and document the PMEM/persistence-domain assumptions.
2. Introduce the instrumentable persistent store/flush/fence interface.
3. Add a deterministic trace recorder and a human-readable counterexample
   format.
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
