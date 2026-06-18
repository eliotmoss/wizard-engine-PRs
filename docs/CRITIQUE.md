# Design Critique

Tensions between the stated goals (persistent, recoverable region allocator for WASM, targeting both PMEM and block-device media, WAL-based crash consistency) and the current implementation.

---

## 1. Transaction granularity is too fine

The current design commits one WAL transaction per `allocChunk`/`freeChunk` call (`PWRegion.performCommit()`). A single logical WASM operation will likely span many allocator calls. If the system crashes mid-sequence, recovery produces a state where some allocations committed and others did not — which may be structurally incoherent from the WASM program's perspective even if the allocator itself is internally consistent.

`RegionTransaction` is well-positioned to support multi-operation transactions, but `performCommit()` at the end of every alloc/free prevents this. There needs to be a way for a caller to open a transaction, perform several allocator operations, and commit them atomically as one WAL record.

---

## 2. Single-transaction WAL does not match the multi-transaction goal

The `MultiTxnWal` skeleton exists, but the entire stack routes through `RegionWal`, which allows exactly one active transaction at a time. If WASM needs concurrent transactions (e.g. multiple WASM threads each with an in-flight allocation), the current design serialises them at the allocator level with no visibility into ordering or isolation. The `WalSuperblock` layout anticipates this with `logEpoch` and `durableAppliedSeq`, but nothing connects it to the allocator yet.

---

## 3. PMEM and block-device durability semantics are conflated

`BackendRegion.prepareChangedRange` means different things for the two backends:

- `PmemMmapRegion`: issues a cache-line flush immediately — side-effectful and ordering-sensitive
- `FileMmapRegion`: sets `hasDirtyChanges = true` — deferred and batched

Similarly, `persistChanges()` issues a store fence for PMEM but an `fdatasync` for file-backed storage. The WAL commit protocol calls the same sequence in both cases, but the ordering guarantees between log commit and data application differ between backends in ways that are invisible to the WAL layer. This needs to be explicitly specified and verified, not just structurally similar code.

---

## 4. Recovery assumes block 1 is always the log chunk

Format hardwires block 1 as the log chunk; mount rediscovers it by index. If the log ever needs to move (e.g. for a multi-segment WAL or format evolution), recovery will silently operate on the wrong block. The `PWRegionHeader` should carry the log offset from day one. There is a TODO acknowledging this (`X86_64TxnPWRegion.v3:31`) but it is an architectural risk, not a minor cleanup.

---

## 5. Unbounded cache accumulation can produce incomplete WAL records

`RegionTransaction` accumulates an unlimited number of `(addr, value)` pairs before committing. Each becomes a 32-byte `LogEntry`. A large transaction can silently overflow the log chunk; the current overflow path in `RegionWal.append` drops the entry without signalling an error. The committed WAL record is then incomplete — recovery replays a partial state that differs from the pre-crash intent. This is a correctness hole, not a performance issue.

---

## 6. Aligned-only cache access interacts badly with WAL replay

The cache is keyed by exact address — a write to `addr` at width 8 and a subsequent read at `addr` at width 1 will miss the cache and return stale data. If a caller uses that stale value in a subsequent write, it is that stale-derived value that gets logged and replayed on recovery. The invariant "WAL replay produces the same region state as the original execution" holds only if callers never perform mixed-width accesses at overlapping addresses. This constraint is documented but not enforced, and the consequence of violating it is silent data corruption that only manifests after a crash.

---

## 7. ImmixPWRegion line marks are not durable

`resetAllLineMarks()` writes directly to memory, bypassing the WAL. After a crash, the region remounts with whatever line marks were in memory at the time of the crash, which may not correspond to the live/dead state of objects. Whether this is safe depends on whether the GC is designed to rebuild line marks from a full heap scan on remount — that is not currently specified or implemented. Until it is, the Immix extension cannot be considered crash-consistent.

---

## 8. No integration with the WASM execution model

The allocator is self-contained but has no connection to WASM execution. There is no `Memory` subclass, no `Instance` hook, and no mechanism for a WASM instruction to trigger a transactional allocation or for a WASM trap to roll one back. The allocator needs an integration point into `Instance.v3` or `Memory.v3` before it can be exercised from WASM programs or evaluated against the project's core goal.
