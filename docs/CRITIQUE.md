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

---

## 4. Log-chunk location is explicit, but format validation remains narrow

This original concern is resolved: `PWRegionHeader.logChunk` now stores the region-relative WAL location, and mount uses it with a defensive block-1 fallback for older headers where the field is zero. The remaining risk is validation: there are no dedicated tests for the zero-field fallback, stored block-size/num-block mismatch, or a nonzero log offset that points outside the mapped region.

---

## 5. Oversized transactions fail safely but lack retry/abort orchestration

`RegionTransaction` can still accumulate more `(addr, value)` pairs than one `DualTxnWal` slot can hold. The active path now fails safely: `DualTxnWal.commit()` returns `0`, `RegionTransaction.commit()` returns `false`, allocator operations propagate failure, and the dirty cache is retained instead of acknowledging a partial record.

What remains unspecified is how the caller should recover. There is no split, abort or rollback operation, and a failed allocator mutation remains in the shared transaction cache. A later operation on the same `PWRegion` can therefore observe and extend that dirty state. Tests cover the failure sentinel and prove a second independent `RegionTransaction` can still use the WAL, but do not cover retry/abort behavior through the allocator's shared transaction.

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

`DualTxnWal.appendCommittedRecord()` builds the complete record and checksum before calling `prepareChangedRange(record)` and `persistChanges()`. If either boundary operation fails, `commit()` returns `0` and does not advance the in-memory sequence state, but the record magic and checksum remain in the mapped slot. The existing regression retries into the same parity slot before reopening, which proves duplicate sequences cannot occupy different slots; it does not prove that a crash immediately after the failed call cannot replay the unacknowledged attempt.

The required failure contract needs to be explicit. If `0` means the transaction was not acknowledged, recovery must not make that attempt visible later; that may require a durable invalidation/publication mechanism even though parity already solves the duplicate-location problem. This is the highest-priority test-audit follow-up in `docs/ROADMAP.md`.
