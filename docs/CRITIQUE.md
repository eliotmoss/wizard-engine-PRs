# Design Critique

Tensions between the stated goals (persistent, recoverable region allocator for WASM, targeting both PMEM and block-device media, WAL-based crash consistency) and the current implementation.

---

## 1. Transaction granularity is too fine

The current design commits one WAL transaction per `allocChunk`/`freeChunk` call (`PWRegion.performCommit()`). A single logical WASM operation will likely span many allocator calls. If the system crashes mid-sequence, recovery produces a state where some allocations committed and others did not — which may be structurally incoherent from the WASM program's perspective even if the allocator itself is internally consistent.

`RegionTransaction` is well-positioned to support multi-operation transactions, but `performCommit()` at the end of every alloc/free prevents this. There needs to be a way for a caller to open a transaction, perform several allocator operations, and commit them atomically as one WAL record.

---

## 2. WAL depth does not provide transaction concurrency

The stack now routes through `DualTxnWal`, a two-slot redo log chosen because at most one transaction's applied data is deferred while the next record commits. `RegionTransaction` still exposes exactly one active transaction at a time, so the allocator serialises operations regardless of how many recovery records the WAL can hold. If WASM needs *concurrent* transactions (for example, multiple WASM threads each with an in-flight allocation), the current design has no ownership, isolation, conflict detection or externally visible ordering model. `MultiTxnWal` and `SingleTxnWal` are retained comparison implementations only; neither changes that transaction-layer limitation.

---

## 3. PMEM and block-device durability semantics are conflated

`BackendRegion.prepareChangedRange` means different things for the two backends:

- `PmemMmapRegion`: issues a cache-line flush immediately — side-effectful and ordering-sensitive
- `FileMmapRegion`: sets `hasDirtyChanges = true` — deferred and batched

Similarly, `persistChanges()` issues a store fence for PMEM but an `fdatasync` for file-backed storage. The WAL commit protocol calls the same sequence in both cases, but the ordering guarantees between log commit and data application differ between backends in ways that are invisible to the WAL layer. This needs to be explicitly specified and verified, not just structurally similar code.

The verification plan now treats this as a layered argument rather than asking
one test to prove everything: a shadow durable-memory model checks the WAL
protocol under the abstract `BackendRegion` contract; backend tests check the
translation to syscalls or cache instructions; abrupt process/VM tests check
software crash recovery; and only controlled real-media interruption can
support physical-durability claims. See `docs/persistent-backends.md`.

---

## 4. Log-chunk location is explicit, but format validation remains narrow

This original concern is resolved: `PWRegionHeader.logChunk` now stores the region-relative WAL location, and mount uses it with a defensive block-1 fallback for older headers where the field is zero. The remaining risk is validation: there are no dedicated tests for the zero-field fallback, stored block-size/num-block mismatch, or a nonzero log offset that points outside the mapped region.

---

## 5. Oversized transactions fail safely but lack recovery-required enforcement

`RegionTransaction` can still accumulate more `(addr, value)` pairs than one `DualTxnWal` slot can hold. The active path now fails safely: `DualTxnWal.commit()` returns `0`, `RegionTransaction.commit()` returns `false`, allocator operations propagate failure, and the dirty cache is retained instead of acknowledging a partial record.

`DualTxnWal.requiresRecovery()` now distinguishes commit persistence failure
from definite validation/capacity rejection. `RegionTransaction` and
`PWRegion` do not yet propagate that distinction, however, so their public
`false` must conservatively be treated as recovery-required. The caller must
abandon the mount, thereby discarding this volatile cache, then reopen and
recover. A later operation on the same `PWRegion` can currently still observe
and extend the dirty transaction; existing tests that use a second independent
`RegionTransaction` therefore describe an enforcement gap, not a supported
retry path.

---

## 6. Aligned-only cache access interacts badly with WAL replay

The cache is keyed by exact address — a write to `addr` at width 8 and a subsequent read at `addr` at width 1 will miss the cache and return stale data. If a caller uses that stale value in a subsequent write, it is that stale-derived value that gets logged and replayed on recovery. The invariant "WAL replay produces the same region state as the original execution" holds only if callers never perform mixed-width accesses at overlapping addresses. This constraint is documented but not enforced, and the consequence of violating it is silent data corruption that only manifests after a crash.

---

## 7. ImmixPWRegion line marks are not durable

`resetAllLineMarks()` writes directly to memory, bypassing the WAL. After a crash, the region remounts with whatever line marks were in memory at the time of the crash, which may not correspond to the live/dead state of objects. Whether this is safe depends on whether the GC is designed to rebuild line marks from a full heap scan on remount — that is not currently specified or implemented. Until it is, the Immix extension cannot be considered crash-consistent.

---

## 8. No integration with the WASM execution model

The allocator is self-contained but has no connection to WASM execution. There is no `Memory` subclass, no `Instance` hook, and no mechanism for a WASM instruction to trigger a transactional allocation or for a WASM trap to roll one back. The allocator needs an integration point into `Instance.v3` or `Memory.v3` before it can be exercised from WASM programs or evaluated against the project's core goal.

---

## 9. A failed phase-B commit can leave an apparently valid record

`DualTxnWal.appendCommittedRecord()` builds the complete record and checksum
before calling `prepareChangedRange(record)` and `persistChanges()`. If either
boundary operation fails, `commit()` returns `0` and does not advance the
in-memory sequence state, but the record magic and checksum remain in the
mapped slot. The older regression retries into the same parity slot before
reopening, which proves duplicate sequences cannot occupy different slots. The
new shadow durable-memory regression covers the missing immediate crash:
when persistence copies the complete record and then reports failure, recovery
validates and replays it even though `commit()` returned `0`.

The chosen contract treats this result as **unacknowledged**, not definitely
aborted. The mount becomes recovery-required and must accept no retry, new
transaction, flush, or clean close. Reopen plus successful recovery determines
the durable state: a complete valid record may be replayed, while an absent or
torn record is ignored. That is safe at the byte level because every redo entry
is an idempotent `(offset, width, after-image)` store; durable invalidation is
not required.

The test-only shadow durable-memory backend is now implemented with separate
live and durable byte arrays. Its fail-before-copy, copy-then-fail and
partial-copy modes reproduce this ambiguity deterministically, including an
immediate crash before the same-slot retry masks the record. The completed core
fault matrix now covers fresh-header initialization and after-image range
preparation as well: `applyUpdate()` returns `false` and latches before any
later boundary can advance `dataDurableSeq`, and recovery reports
`PERSIST_FAILED` without issuing `persistChanges()`. `DualTxnWal` rejects
same-instance work after any fresh-init, commit, apply, recovery, flush or close
persistence failure, while `requiresRecovery()` distinguishes those failures
from definite validation/capacity rejection. Propagation through
`RegionTransaction`/`PWRegion` remains open; until that propagation exists,
higher layers must conservatively treat every `false` as recovery-required.
The shadow supplies protocol-level evidence only; syscall, process/VM crash and
physical-media evidence remain separate outer layers.
