# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Wizard is a research WebAssembly (Wasm) virtual machine written in **Virgil** (`.v3` files), a fast, garbage-collected systems language. It is designed for teaching, research, and instrumentation rather than peak production performance.

## Build Commands

Requires the [Virgil compiler](https://github.com/titzer/virgil) on `$PATH` (clone and run `make` there first).

```bash
make -j                          # build all targets (wizeng, unittest, spectest, objdump)
make x86-64-linux                # build for a specific platform only
./build.sh wizeng x86-64-linux   # build a single binary for a single platform
```

Binaries land in `bin/` with platform suffixes (e.g. `bin/wizeng.x86-64-linux`).

## Test Commands

```bash
test/unit.sh                          # run internal unit tests (no compile needed)
test/spec.sh                          # run Wasm specification tests
test/regress.sh                       # run regression tests
test/monitors/test.sh                 # run all monitor tests
test/monitors/test.sh loops branches  # run specific monitor tests
TEST_TARGET=x86-64-linux test/spec.sh # test a single platform
WIZENG_OPTS=-mode=jit test/spec.sh    # pass engine options during tests
```

Spec tests require first running `cd test/wasm-spec && ./update.sh` to clone and build the spec repo. The `progress` utility (from https://github.com/titzer/progress) makes test output readable.

To update expected output for a monitor after changing it:
```bash
test/monitors/update-expected.sh <monitor-name>
```

## Code Architecture

### Execution Tiers

The engine has three execution tiers, all under `src/engine/`:
- **V3 interpreter** (`v3/V3Interpreter.v3`) — portable, runs on all platforms; uses a value stack and call stack
- **Fast x86-64 interpreter** (`x86-64/`) — handwritten assembly, native-only
- **Single-pass compiler** (`compiler/`) — JIT compilation infrastructure

### Core Engine Types (`src/engine/`)

| File | Role |
|------|------|
| `Module.v3` | Decoded in-memory Wasm module (types, functions, memories, tables in declared order) |
| `Instance.v3` | Runtime state of an instantiated module; primary structure for execution |
| `Instantiator.v3` | Binds imports and constructs instances in declaration order |
| `BinParser.v3` | Push-based, incremental binary parser (feed bytes as they arrive) |
| `CodeValidator.v3` | Single-pass abstract interpretation validator; also produces *control transfer* side-table |
| `Opcodes.v3` | Central opcode/immediate/signature definitions using Virgil enums |
| `Type.v3` | All Wasm types; subtyping, assignability, and LUB live here |
| `Value.v3` | All Wasm values (primitives, references) |
| `WasmStack.v3` | Abstract stack interface; `V3Interpreter` implements this |
| `StorageRegion.v3` | Pluggable persistence backend interface (`StorageRegion`, `StorageBackend`) used by RegionAllocator |
| `WasmErrorGen.v3` | All decode/validate/instantiate error generation (kept out of mainline logic) |
| `Extension.v3` | Enumeration of all Wasm proposals/extensions that can be individually enabled |

The **control transfer** side-table (produced by `CodeValidator`, consumed by the interpreter) is the key data structure for O(1) branch dispatch — it avoids scanning for matching `end`/`else` targets at runtime.

### Host Modules (`src/modules/`)

- `wasi/` — WASI (WebAssembly System Interface) implementation
- `wali/` — Wasm-Linux interface (direct Linux syscall bridge)
- `wave/` — WAVE research module
- `wizeng/` — main engine embedding module

### Monitor System (`src/monitors/`)

Monitors are dynamic instrumentation plugins. They implement `Monitor.v3` and receive callbacks via the `Probe` mechanism in `src/engine/Instrumentation.v3`. Each monitor is a `.v3` file (e.g. `HotnessMonitor.v3`, `CoverageMonitor.v3`). The monitor test suite lives in `test/monitors/` with expected outputs in `test/monitors/expected/`.

### Entry Points

- `src/wizeng.main.v3` — main `wizeng` executable
- `src/WasmMode.v3` — normal Wasm execution mode
- `src/SpectestMode.v3` — spec test runner mode
- `test/unittest.main.v3` — unit test executable

### Bytecode Layer (`src/bytecode/`)

`CanonicalDefs.v3` is the large central file defining the canonical bytecode representation shared across engine components.

## Persistent Region Allocator (`pwregions` branch)

This branch extends Wizard with transactional, persistent storage for WASM, targeting both PMEM (byte-addressable) and block-device (file-backed) media. The design stages objects from mapped persistent regions into DRAM for manipulation by the WASM engine, using write-ahead logging to ensure recoverability.

### Layer structure

```
RegionAllocator (block allocator)
  └── TransactionCache (write-behind cache + WAL facade)
        └── TwoSlotWal (in-region two-slot redo log, lives in block 1)
              └── StorageRegion (persistence abstraction)
                    ├── VolatileRegion      (Array<byte>, GC-managed)
                    ├── MappedFileRegion      (mmap + pages marked through the provider, one fdatasync per fence — block device)
                    ├── PmemRegion      (mmap + clwb/sfence — PMEM/DAX)
                    └── DirectIoRegion      (private staging buffer + pwrite/O_DIRECT + fdatasync — file or raw block device)
```

### Key files (all under `src/engine/x86-64/` unless noted)

The persistence code was renamed on 2026-10-26 without changing behaviour. `docs/naming.md` maps the old names, which results and commits before then use, to the new ones.

| File | Role |
|------|------|
| `src/engine/StorageRegion.v3` | Abstract `StorageRegion` / `StorageBackend` interfaces; `VolatileBackend`; the `PersistenceProvider` store/flush/fence seam and its nullable `loadObserver` (`LoadObserver.beforeLoad(offset, length)`, called before a load and free to rewrite the bytes; null in production) |
| `X86_64Providers.v3` | The `PersistenceProvider` implementations: `NativeProvider` (stores, `CLWB`, `SFENCE` through `X86_64CacheControl`), `RecordingProvider` (trace recording), and `MarkingProvider` over `StoreOnlyProvider` with `DirtyUnits` (the mapped-file and direct-I/O backends); `NativeProviders.installIfAbsent()` installs one provider per region. Every persistent store on the active path (`RegionAllocator.format()`, `UnloggedWriter`, `TwoSlotWal`) goes through it, giving one total `STORE`/`CLWB`/`SFENCE` order. `recordLoads()` adds a `RecordingLoadObserver` whose `LoadEvent`s (offset, length, bytes, position in that order) are kept apart from the trace, so a trace never holds a load |
| `X86_64PersistenceTrace.v3` | Frozen scenario artifacts over the recorder: `PersistenceTrace` (immutable snapshot, crash-cut `prefix()`, baseline `validate()`, content `digest()`, `touchedLines()`, stable rendering), `CrashCounterexample` (optional durable image + byte window via `withImage()`), `PersistenceTraces.capture()` |
| `X86_64CrashModel.v3` | Durable-byte model over a trace: `CrashModel` (per-line store lists, read back by `storeInLine()`, asynchronous writeback completion, fence obligations, background eviction, `crash()`), `CrashImageView` (`read()`, `sameBytes()`, `firstDifference()`, shared with the lazy search's views, which decide what they read and compare two marks at one offset as equal) and `CrashImage` (little-endian `read()`, `digest()`, `sameBytes()`), `CrashImages.lazyCrash()`/`eagerCrash()` extremal schedules |
| `X86_64CrashExplorer.v3` | Schedule enumeration over a trace: `CrashExplorer.crashImages()` (full branching search with state dedup and a reported budget) and `reducedCrashImages()` (fence-forced floor, then one of each line's distinct 64-byte contents per line, `CrashLineClasses` from `lineClasses()`, compared byte for byte; since 2026-10-19 every state is a distinct image, so a budget counts distinct images: a cut within its budget is enumerated completely, and one over it takes the lazy image, the eager image, each line alone at its last content, each line one content below its last, then distinct images drawn with a seed from the trace digest and the cut, recorded in the result and rendered; `selectCrashImages()` replays a selection from its seed); `checkImages()`/`checkAllCuts()`/`checkCutRange()` run a `CrashImageProperty` over one cut, every cut, or a range of cuts and emit a `CrashCounterexample`; `CrashExploration`/`CrashCheckResult` results and artifacts, which report each cut's prefix vectors (`product`) and distinct images (`classProduct`), summed over a sweep and rendered as "checked X of Y distinct images (Z prefix states)" |
| `X86_64ReadDrivenExplorer.v3` | The lazy search (2026-10-20): `ReadDrivenExplorer.checkImagesLazily()`/`checkCutRangeLazily()`/`checkAllCutsLazily()` run a `ReadDrivenProperty` (a function of an image view and a `CrashImageMounter`, so a property that is not lazy-safe cannot be passed) once per leaf, branching only on the bytes a load or a view read takes from the crash image: per line the set of possible classes narrows by the loaded bytes the execution did not store; depth-first by re-execution with a replayed, checked decision prefix (`ReadDrivenSearch`, `ReadDrivenDecision`, `ReadDrivenLeaf`); mounts in reused mappings (`ReadDrivenRegion`, `ReadDrivenProvider` marking stored bytes), snapshots that keep unread bytes as marks (`ReadDrivenSnapshot`, `ReadDrivenImage`), copy mounts that fill such bytes when loaded; budget in leaves per cut; `ReadDrivenCheckResult` renders "L leaves cover R of Y distinct images (Z prefix states)"; a failing leaf's least image is the counterexample, re-checked by the property's eager form (`confirmed`) |
| `X86_64CrashRecovery.v3` | Production recovery over an enumerated image: `CrashRecoveries.runTwoSlotWal()` (remount + `recover()` + resulting bytes) and `runTwoSlotWalOn()` (the same through a `CrashImageMounter`: `CrashImageMounters.EAGER`, a recording `CrashEagerMounter` whose `CrashMountLog`s compare runs, or the lazy search's; `CrashRecoveryRun.left` is the mount's `snapshot()`), the WAL properties' `checkOn()`/`lazy()` forms, `WalRecoveryProperty` (acknowledgement contract as a checkable property) and `WalHistoryProperty`/`WalAfterImage` (the same contract over a multi-transaction history in one mount per image), `CrashImageBackend` + `AllocatorProperty` (mount an image as a `RegionAllocator`), `AllocatorInvariants` (memory-order/free-list/used-state walk returning the first violation); `CrashImageMounts` (array vs recording-PMEM containers), `recordWalRecovery()`/`recordAllocatorRecovery()`/`checkCrashDuringRecovery()` for the bounded two-crash profile; `InjectedFailureRegion` + `CrashRecoveryFailureProperty`/`AllocatorFailureProperty` for failed recovery/mount boundaries |
| `X86_64MappedBackends.v3` | `MappedFileRegion` (since 2026-10-13 a restriction of the PMEM model: its provider is the direct backend's `MarkingProvider`, so `writeBackLine()` marks the line's 4 KiB page and every fence `fdatasync`s once if anything is marked; `MappedFileSync.LEGACY_RANGE_MSYNC`/`MSYNC_PER_RUN` keep the old boundary and a per-run `msync` fence for comparison only), `PmemRegion`, `FileBackedRegion`; `BackingFile`; `X86_64Backends` factory; `CacheLines` (`writeBackLines()` splits a range into one provider `writeBackLine()` per 64-byte line); `RegionMapping` (page size, protection flags). The instructions are in `X86_64Providers.v3`'s `X86_64CacheControl` (`writeBackLine()` issues native `CLWB`, else `CLFLUSHOPT`, else `CLFLUSH`, chosen once by CPUID; `fence()` issues `SFENCE`; both Virgil `Target` intrinsics since 2026-08-31) |
| `X86_64DirectIoBackend.v3` | Direct-I/O backend: `DirectIoRegion` (anonymous staging buffer loaded at `open()`; provider `writeBackLine()` marks 4 KiB units, every fence `pwrite`s the marked units then `fdatasync`s once; same trace as `PmemRegion`) (its providers are in `X86_64Providers.v3`), `DirectIoBackend(path, FILE \| BLOCK_DEVICE)` with the O_DIRECT behaviour probe, `O_EXCL` device open and foreign-signature refusal; `DirectIoFileIO`. The elided-writeback mutant works unchanged on it, and a plain `SIGKILL` discriminates it (process death discards unwritten staging data) |
| `X86_64RegionAllocator.v3` | Layouts, handle types, `UnloggedWriter` and `RegionReader` (the direct store and load paths; every load the mount, `TwoSlotWal`, the handle getters, the invariant walk and the workloads make from a region is made or observed through a reader, and every `Ref` over region memory is forged by one), `TransactionCache`, `RegionAllocator`, `ImmixRegionAllocator` |
| `X86_64WalRecord.v3` | The record layout `TwoSlotWal` and `RingWal` share: `WalRecordHeader`, `WalEntry` (one after-image; `SingleTxnWal` uses it too), `WalRecordTrailer` |
| `X86_64SingleTxnWal.v3` | Single-transaction in-region WAL — superseded, **not wired in**; kept as a reference implementation (see `docs/wal-comparison.md`) |
| `X86_64RegionAllocators.v3` | `RegionAllocators`: x86-64 factories that open an allocator over one backend (`inMemory`, `onPmem`, `onMappedFile`, `onDirectIo`, and the Immix `immixInMemory`, `immixOnPmem`) |
| `X86_64TwoSlotWal.v3` | Active two-slot WAL (phase B) — two parity-selected record slots, per-record checksum, poisoning `append()`, `WalRecovery` result, piggybacked persistence boundary (one per commit steady-state); batched after-image apply (`storeAfterImage()` per after-image, then `writeBackAfterImages()` prepares each line once; drained before every boundary that advances `dataDurableSeq`); drives `RegionAllocator`/`TransactionCache`. `WalFaultInjection.skipRecordChecksum` (false; set only by a negative-control test) makes `validateSlot()` skip the record checksum, and `recordLastLineUnflushed` (false; set only while a test records) leaves a record's last line out of the commit-point fence |
| `X86_64RingWal.v3` | Multi-transaction ring WAL (dual superblock, epoch fencing, checkpoint policy) — superseded, **not wired in**; kept as a comparison implementation |
| `test/unittest/x86-64-linux/RegionAllocatorTest.v3` | RegionAllocator + backend region unit tests (incl. remount/recovery) |
| `test/unittest/x86-64-linux/TransactionCacheTest.v3` | `TransactionCache` write-behind cache unit tests |
| `test/unittest/x86-64-linux/TwoSlotWalTest.v3` | `TwoSlotWal` unit tests (commit/recovery/guard/failure paths) |
| `test/unittest/x86-64-linux/ProviderTest.v3` | `PersistenceProvider` seam tests (typed store/CLWB/SFENCE ordering, store audit over `RegionAllocator`) and the load seam: reader equals raw, observer before load, the structural load audit over a mount/recovery/walk, inert-bytes audits over allocator, sieve and B+Tree crash images, and the B+Tree descents' node fetches |
| `test/unittest/x86-64-linux/PersistenceTraceTest.v3` | Trace capture/validation/digest and artifact-rendering tests |
| `test/unittest/x86-64-linux/CrashModelTest.v3` | Durable-image model tests (volatility, torn writeback, fence completion, eviction, real-WAL trace image) |
| `test/unittest/x86-64-linux/CrashExplorerTest.v3` | Crash-image enumeration and property-check tests (image counts per cut, reduction agrees with full search, budget truncation, counterexample emission, and the line classes against the old prefix odometer: the same distinct images byte for byte, each once, at every cut of the small traces and at sampled cuts of a recorded `TwoSlotWal` commit, and an over-budget cut's extremes-then-seeded selection, reproducible from its seed) |
| `test/unittest/x86-64-linux/ReadDrivenExplorerTest.v3` | The lazy search's soundness checks (`read_driven:`): the leaves partition the distinct images (small traces, one-commit trace, every cut) with calibrations at one leaf and at one per image; each image's eager verdict is its leaf's (also over the overwrite guard's 597,079 images); each leaf's least and greatest image make the lazy run's stores and loads byte for byte; nondeterminism reported; snapshots compare marks without deciding; the WAL sweeps run lazily, exhaustive; the record-checksum skip over a reused slot and an unflushed record line caught with eagerly confirmed counterexamples |
| `test/unittest/x86-64-linux/CrashRecoveryTest.v3` | Production recovery over enumerated crash images (acknowledged survival, no invented state, idempotence, counterexample emission); since 2026-10-19 every WAL sweep covers every distinct image of every cut |
| `test/unittest/x86-64-linux/AllocatorCrashTest.v3` | Allocator invariants over enumerated crash images (split alloc, coalescing free, walker self-check) |
| `test/unittest/x86-64-linux/DirectIoRegionTest.v3` | Direct-I/O backend tests: marking/coalescing/drain/failure mechanics, device and size rejections, allocator roundtrip and `SIGKILL` cases (unwritten staging lost; mutant loses an acknowledged commit), trace identity with the PMEM backend, and an exact per-line check that the file after every real `fdatasync` is an image the PMEM crash model admits. Region files go in `/tmp`, falling back to `bin/` when `/tmp` does not honour O_DIRECT |
| `test/unittest/x86-64-linux/MappedFileRegionTest.v3` | The file backend as a restriction of the PMEM model, over a real file at 2 KiB and 4 KiB blocks with both fences: trace identity with the PMEM backend, every page written back before a fence covered by that fence's syncs (from the trace alone), the file after every sync admitted by the model exactly (`dioAdmittedAt`, eager and marked-only images), an `O_DIRECT` re-read of every synced range, no sync under the elided-writeback mutant, the legacy boundary unchanged. The argument and its assumptions (on block storage, B2: each line reaches the device as it stood at one instant) are in `docs/pmem-crash-model.md` |
| `test/unittest/x86-64-linux/RingWalTest.v3` | `RingWal` unit tests (comparison implementation) |
| `test/unittest/x86-64-linux/PWSieve.v3` | Resumable segmented Sieve of Eratosthenes over `RegionAllocator` — the workload driver (not engine code); root chunk at `userRoot`, one chunk per live segment, retirement + leak reclamation, `checkInvariants()` |
| `test/unittest/x86-64-linux/PWSieveTest.v3` | Sieve workload tests (mount/resume, prime counts, invariants, retirement, remount) |
| `test/unittest/x86-64-linux/SieveCrashTest.v3` | Sieve through the crash-image explorer; `SieveProperty` mounts an image, recovers, reattaches and checks the workload's invariants; `unchecked_record_checksum_is_caught` is a recovery negative control (checksum skipped, caught at 12 images per cut) |
| `test/unittest/x86-64-linux/PWOps.v3` | Basic-operation benchmark helpers, shared with `pwopsbench` as `PWSieve.v3` is with `pwsievebench`: `PWOps.latestRecord()` reads the newest valid WAL record back (through a read-only second `TwoSlotWal`) and `PWOpsRecord.commitLines()` gives the lines its commit writes back on PMEM (record lines + distinct after-image lines); `PWOps.commitUnapplied()` leaves a formatted region's log holding one committed, unapplied transaction (`PmemDaxIntegrationTest`'s recipe: append + `commit()`, then the region's `close()` without the log's `close()`) |
| `test/unittest/x86-64-linux/PWOpsTest.v3` | Those helpers checked on the production `PmemRegion` boundary path over anonymous memory with a recording provider: exact `CLWB`/`SFENCE` counts for alloc/free, the steady state alternating alloc/free returns to, the empty commit (no event at all), a clean mount (no boundary), and a recovery (one line per replayed entry, one fence) |
| `test/unittest/x86-64-linux/PWBTree.v3` | Persistent B+Tree of u64 keys and values over `RegionAllocator` — the second workload driver (not engine code): one node per one-block chunk (252 keys at 4 KiB), root chunk at `userRoot` with magic, geometry, root node, height, counts and a monotone mutation count; copy-on-write puts (allocate k nodes, write them directly under one fence, publish the root swap with the old root node's free in one commit, free the other h - 1), so k + h + 1 boundaries; `open()` sweeps leaks; `checkInvariants()`; optional `onPhase` hook (COMPUTE/ALLOC/WRITE/PUBLISH/FREE); no delete, no sibling links |
| `test/unittest/x86-64-linux/PWBTreeTest.v3` | B+Tree tests, over regions in anonymous mappings (`PWBTreeAnonBackend`), not the volatile backend, whose heap array the copying collector moves under `RegionAllocator`'s raw addresses: `pwbtree:` (format/reattach/refusal, splits, seeded histories against a DRAM map, leaks, full region, forced collections, a corrupted or cyclic image refused, k + h + 1 fences and each mark's lines on the counted PMEM path, also at a block size that is not a multiple of a line), `pwbtree_file:` (resume across file-backed remounts, one at 4,104-byte blocks), `pwbtree_dio:` (a child on the direct backend killed at every phase mark of a root split and of an update) |
| `test/pwsieve.main.v3` | Random-timer `SIGKILL` crash loop over the sieve; selectable file, PMEM or direct-I/O backend (`direct`, or `direct-device=<dev>` on a raw device), requires every acknowledged step to survive (the child publishes its acknowledged cursor in a shared page; a shortfall is a `LOST` restart), runs the elided-writeback mutant in the children only, reserves its own region file in a caller-assigned directory (`make pwsieve` / `make pwsieve-pmem`, `PWSIEVE_ARGS` / `PWASM_PMEM_TEST_DIR`) |
| `test/pwbtree.main.v3` | Random-timer `SIGKILL` crash loop over the B+Tree (`file`, `pmem` or `direct`; `ordinary` or `elide-clwb` in the children): remount, invariants, the whole tree against a DRAM map at the durable mutation count, every acknowledged mutation surviving and the one in flight on the side its last phase mark allows; `OK` only if an acknowledgement was checked, else `UNCHECKED` (exit 3) (`make pwbtree`, `pwbtree-pmem`, `pwbtree-direct`, `pwbtree-direct-mutant`) |
| `test/pwsievebench.main.v3` | Sieve-step cost through the production allocator and WAL: rounds of a freshly formatted region, warm-up, then every step the descriptor table has left (159 at 256 × 4 KiB), each round verified against a reference sieve; per step, wall time (mean, median, p90), the five phases PWSieve reports through its `onPhase` hook (compute, alloc, bitmap, publish, retire), boundaries, writeback lines and minor faults. `file`, `pmem` (`writeback=auto|clwb|clflushopt|none`) or `direct`; the timing backends are duplicated from pwbench so pwbench's code layout is untouched (`make pwsievebench-pmem`). `clock=probe` reads the core clock without root at each of the step's six marks (sieve, alloc, bitmap, count, publish, retire) and against busy and 250 µs-sleep references: a pregenerated machine-code stub times 4,096 dependent add/xor register operations between `lfence`-ordered `rdtsc` reads (a Virgil loop would spill to the stack), two probes per point so a cold first probe is reported apart; probe time is removed from every figure |
| `test/pwopsbench.main.v3` | Basic-operation latencies (Corundum Table 5 style) through the production path: `allocChunk(1|8|64)` and `freeChunk` alternating on a single free extent, the empty commit (production commits nothing: no boundary), an `rdtsc` floor, clean mounts at 1 MiB and 64 MiB, and recovery of a 1 MiB region holding one committed, unapplied transaction of 8 or 24 entries (`PWOps.commitUnapplied()`), interleaved sample by sample with the 1 MiB clean mount so replay = recover − mount (not on `direct` over a disk whose read time depends on what preceded it: Magpie's `/home` gives −2.6 ms); per operation median, p90, p99, mean, and the work done, which is checked on every operation (boundaries; lines on `pmem` and `direct`, learned from the record in warm-up; prepares on `file`/`direct`) and fails the run on a mismatch. `file`, `pmem` (`writeback=auto|none`; `none` keeps `SFENCE`, an eADR timing approximation, never durable) or `direct`; 50,000 operations after 2,000 warm-up, 200 mounts after 20 (`make pwopsbench-pmem`) |
| `test/pwbtreebench.main.v3` | B+Tree operation cost through the production allocator and WAL: per round a fresh region, a load of N random keys, then N operations half lookups and half updates; per kind median/p90/p99/mean ns, PWBTree's five phases, boundaries, prepare calls, lines and splits. An audited round 0 checks every mark against the WAL record or the new nodes; every operation must make k + h + 1 boundaries and every measured one its round-0 work. `file`, `pmem` (`writeback=auto\|none`) or `direct` |
| `test/pwreboot.main.v3` | Stage 2c warm-reboot harness (also accepts `direct` for setup/arm/verify, where exit is the crash and no reboot is needed): a flushed-against-unflushed cache-line probe, and the sieve armed with the production provider or the elided-writeback mutant, verified after a `sysrq` reboot on a `memmap` host (`make bin/pwreboot.x86-64-linux`); an optional inherited `/proc/sysrq-trigger` descriptor lets `probe-arm`/`arm` reset the machine themselves with no window after the last store, which is the form that discriminates (Stage 2c done 2026-09-24: ordinary `SURVIVED` 3/3, mutant `LOST` 3/3) |
| `scripts/stage2c.sh` | Stage 2c operator script (`doctor`/`probe`/`probe-now`/`sieve`/`sieve-now`/`verify`); refuses to arm while the firmware's memory-overwrite request is set; host setup, runbook and cross-machine hand-off in `docs/stage2c-handoff.md` |
| `scripts/clwb-eviction.sh` | CLWB-eviction experiment (`doctor`/`probe`/`campaign`/`all`/`summary`/`rebuild`): the probe, then pwbench under `perf stat` where permitted, across `pmem-<auto\|clwb\|clflushopt\|clflush\|deferred\|none>[-s<stride>]` and `file-dax[-s<stride>]`, via pwbench's `writeback=`/`stride=` keyword arguments (`-entry` before the stride, the pre-2026-09-28 per-entry apply, is accepted only by `rebuild`/`summary` for the directories that used it; pwbench's `apply=` has been removed); `PWCLWB_CPUS` pins to a CPU list, needed on hybrid CPUs where the two core types may differ (`none` is timing only and never durable; `deferred` writes each distinct line back once before the fence, durability unchanged). The probe summary marks a store row "not discriminating" when its `CLFLUSHOPT` excess is under half the load row's (Raptor Lake). First Magpie campaign 2026-09-28: CLWB evicts, and the writebacks cost 14–43 % of a PMEM commit; on Raptor Lake it does not (`docs/persistent-backends.md`) |
| `scripts/pwsieve-bench.sh` | Sieve-step campaign (`doctor`/`campaign`/`summary`/`rebuild`) over `pmem-<auto\|clflushopt\|none\|clwb>`, `file-dax`, and `file-block`/`direct-block` when `PWSB_BLOCK_DIR` is set; pins with `PWSB_CPUS` (hybrid CPUs) or to the DAX namespace's NUMA node, refuses a non-DAX `PWASM_PMEM_TEST_DIR`, a DAX or network `PWSB_BLOCK_DIR` and a dirty tree; the summary gives medians over repetitions, the repetitions' wall range, the persistence phases' share of a step and the writebacks' cost by removal. Any configuration takes a `+clock` suffix (`clock=probe`); `PWSB_CLOCK=1` makes the default `pmem-auto`, `file-dax` and the block pair each plain and `+clock`, interleaved, writes `clock.csv`, records the frequency driver, EPP and idle states in `provenance.txt`, and summarises the clock at each point and whether it accounts for the computation's slowdown against the configuration that never blocks |
| `scripts/pwops-bench.sh` | Basic-operation campaign (`doctor`/`campaign`/`summary`/`rebuild`) over `pmem-auto`, `pmem-none`, `file-dax`, and `file-block`/`direct-block` when `PWOB_BLOCK_DIR` is set; pins with `PWOB_CPUS` or to the DAX namespace's NUMA node, refuses a non-DAX `PWASM_PMEM_TEST_DIR`, a DAX or network `PWOB_BLOCK_DIR` and a dirty tree, records the block device chain and its write-cache mode; the summary is operations × configurations (median and p90 of per-run figures over repetitions), the repetitions' spread, the work per operation, replay = recover − mount, the 64 MiB/1 MiB mount ratio, and `pmem-auto − pmem-none` |
| `scripts/pwbtree-bench.sh` | B+Tree campaign (`doctor`/`campaign`/`summary`/`rebuild`) over `pmem-auto`, `pmem-none`, `file-dax`, and `file-block`/`direct-block` when `PWBB_BLOCK_DIR` is set; pins with `PWBB_CPUS` or to the DAX namespace's node; refuses a dirty tree; `runs.csv` and `summary.txt` (per kind: medians, spread, phases, persistence share, work per operation, cost per boundary) in `results/<stamp>-<host>-pwbtree-bench` |
| `scripts/clwbprobe.c` | Engine-independent C probe: re-access cost of a line after no writeback, `CLWB` or `CLFLUSHOPT`, on DRAM and a `MAP_SYNC` DAX mapping |

### On-region layout

```
Block 0:   Region header (RegionHeader, 88 bytes, incl. userRoot) + sentinels
Block 1:   WAL log block (TwoSlotWal: WalHeader + two fixed record slots)
Blocks 2…N-2: User data blocks (SMALL_FREE / LARGE_FREE / USED)
Block N-1: Metadata overhead (block table, MetadataDescriptor[])
Entry N:   End-of-region marker (no backing data)
```

### WAL commit protocol (two-slot, current — `TwoSlotWal`, phase B)

1. Writes buffered in `TransactionCache` (HashMap-backed write-behind cache)
2. `commit()`: `appendToWal → wal.commit` (write one checksummed record into slot `txnSeq % 2`, then ONE persistence boundary — `writeBack(record) + drain()` — that persists the record together with the *previous* transaction's applied after-images; the commit point) `→ applyToRegion` (this transaction's after-images, applied write-behind: `storeAfterImage()` for each, then `writeBackAfterImages()` writes each touched line back once — on Cascade Lake `CLWB` evicts, so per-entry writeback made the next same-line store miss; only the fence — their persist — rides the next commit's boundary, and every boundary that advances `dataDurableSeq` drains outstanding extents first) `→ clear`
3. Unmount/idle: `wal.close()` (called by `RegionAllocator.deallocate()`) persists the deferred data and scrubs reclaimable slots so a clean remount is replay-free; `TransactionCache.flush()` is the explicit idle boundary
4. On mount: validate the `WalHeader`, validate both slots, replay the valid records in ascending `txnSeq` (idempotent after-images, so re-replay is harmless), persist, set `nextTxnSeq = max + 1`. `recover()` returns `WalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`)

One boundary per commit in steady state (one `SFENCE` on PMEM, one `fdatasync` on file); correctness by induction — a valid record N+1 implies the boundary at its commit completed, so txn N's data is durable. An overwrite guard keeps a slot from being destroyed while it covers not-yet-durable data; a failed commit-point persist retries with the same seq into the same slot (parity), so duplicate-seq records cannot exist. Contract: a committed transaction's entries must be applied before the next commit (`TransactionCache` guarantees this).

The superseded protocols are retained for comparison, **not wired in** — `SingleTxnWal` (persist entries → `status=1` → apply → fence → `status=0`) and `RingWal` (ring + superblock + epoch fencing + checkpoint policy) — see `docs/wal-comparison.md`.

### Known gaps and stubs

- WAL overflow in `SingleTxnWal.append` (the superseded reference WAL) silently drops entries when block 1 is full; the active `TwoSlotWal` surfaces an oversized transaction via a failed `commit()` instead (per-transaction capacity ≈ half the log block minus headers)
- `Backends.getMmap()` declared but not implemented
- `RegionAllocator.setUserRoot()` commits in its own transaction, and `allocChunk()` commits in its own, so a crash between allocating an extent and publishing it in the root leaks that extent (used, unreachable). A space leak, not an inconsistency; the caller must reclaim it (`PWSieve.open()` shows how)
- `ImmixRegionAllocator` line marks are explicitly transient: mark/reset bypass the WAL and persistence boundaries, so callers must rebuild them after a crash. Since 2026-10-19 their stores go through the `PersistenceProvider` seam like every other persistent store on the active path (`setMarkUnlogged(w, v)` takes the region's `UnloggedWriter`), so a trace shows each as a store with no writeback or fence of its own; until then they were the allocator's last direct stores
- `TransactionCache.clear()` allocates a new `HashMap` on every commit (GC pressure)
- `TransactionCache` is aligned-access only — mixed-width overlapping reads cause silent cache misses
- `DirectIoRegion` holds the whole region in DRAM, reads it all at mount, and is limited to regions under 2 GiB (`FileBackedRegion` forges its range with `int.!`). Its kill-loop sensitivity is 4 KiB-granular: a missing writeback for a line sharing a unit with a flushed one goes unnoticed
- On Magpie, `/home` (every `file-block`/`direct-block` figure) is on `sda`, which a Dell PERC H740P (Broadcom's SAS3508) in eHBA mode passes through with the drive's own write cache disabled (root sitting, 2026-10-16): Linux sees write-through, so `fdatasync` sends no flush, and a component below Linux, not identified, acknowledges each write before the platter can have it; whether that acknowledgement is power-safe is not established
- On Magpie, block-storage timings include a clock penalty the OS cannot control: Magpie has no cpufreq driver (the platform sets the frequency) and `intel_idle` offers C1, C1E and C6, so a thread that blocks in `fdatasync` runs its next computation slower. In the sieve the computation itself took 2.6–2.7× its PMEM time on `/home` (not migration, not syscalls or faults; reproduced on sean-tan-PC under `powersave`, absent under `performance`). Observed without root on 2026-09-29 by `pwsievebench clock=probe`: after a block-storage boundary Magpie's core runs at 1.0 GHz against 3.6 GHz busy and reaches only 1.7–1.8 GHz by the end of the sieve, which accounts for the slowdown; a 250 µs sleep does the same, so it is idleness, not storage; on sean-tan-PC the clock follows the governor (`powersave` 29–33 % of busy, `performance` 100 %). Magpie's root sitting (2026-10-16) established the cause by intervention: with C1E and C6 disabled on the pinned core, the sieve's clock reads 3.15–3.45 GHz at every mark (89–97 % of busy), its computation falls to 448 µs (`file`) and 503–504 µs (`direct`) from 1,068–1,113 µs, and the persistence share rises from 57 % to 72 %. C1E and C6 were disabled together, so which of the two lowers the clock is not separated; a 250 µs sleep still sometimes comes back at the lowest clock with both disabled; and the B+Tree's core stays at about 1.0 GHz either way, unexplained (`docs/persistent-backends.md`, "The clock after a blocking boundary is the idle states" and "The B+Tree's clock"). Until 2026-10-25 this entry said which idle state is entered is not established. Read any Magpie `file-block`/`direct-block` figure for a workload that computes between boundaries with this in mind; pwbench's back-to-back boundaries barely see it (`docs/persistent-backends.md`, sieve section)
- The file backend is a restriction of the PMEM model on fsdax (baseline profile plus the kernel's `fsync` contract), but on block storage only conditionally: it needs each 64-byte line to reach the device as it stood at one instant (B2), which PCIe does not guarantee and which CPU-copying layers (`dm-crypt`, `swiotlb`, `md` RAID5 without `skip_copy`) break. Stable writes make it hold by construction; sean-tan-PC's NVMe does not request them, nor does any of Magpie's block devices, and no layer on either host copies pages with the CPU (Magpie checked 2026-10-16 by `scripts/magpie-root-checks.sh`; `docs/persistent-backends.md`, "B2 on Magpie"). Its `SIGKILL` loop cannot discriminate flush placement (the page cache survives process death). A warm kernel reset, which needs root, does: on sean-tan-PC on 2026-10-21, one run per build, the ordinary build `SURVIVED` and the elided-writeback mutant `LOST` (`docs/persistent-backends.md`, "A kernel reset separates the file backend's builds"). dm-log-writes images, also root, have not been run; their offline checker is not written (`docs/persistent-backends.md`, the file-backend section). Until 2026-10-25 this entry said Magpie's devices were unchecked and that both discriminating runs were still to do
- At 4 KiB blocks the WAL header and both record slots share one 4 KiB write unit, so slot independence on block media rests on the device being old-or-new per 512-byte sector (pinned by `direct_io:record_write_rewrites_whole_log_unit`)
- On Cascade Lake (Magpie) `CLWB` evicts the line, and `TwoSlotWal.applyAfterImage()` writes each after-image back as soon as it is stored, so consecutive after-images in one line miss to PMEM: the writebacks cost 14–43 % of a PMEM commit, while pwbench's `rdtsc`-bracketed "boundary" shows ~3 % (measured 2026-09-28; with one entry per line the same writebacks cost 7 % at 24 entries, so ~95 % is the within-commit same-line store. Deferring writebacks to the fence helps only where lines are reused). Fixed the same day by the batched apply (`storeAfterImage`/`writeBackAfterImages`), measured: 42 % faster at 24 entries, writebacks 3 % of the commit, and the PMEM backend faster than the file backend on DAX at every size again. Its bookkeeping overhead (a compiled `divq`, non-inlined `Vector` calls; 0.2–0.8 µs where nothing coalesces) was then removed and re-measured: 43 % faster than per-entry at 24 entries, the file backend unaffected, 0.34 µs (1.5 %) left at stride 64 from placement. The eviction is Cascade Lake's, the mechanism is not: on a Raptor Lake i7-14700KF (sean-tan-PC, DRAM-emulated PMEM, one performance and one efficiency core, 2026-09-28) `CLWB` leaves the line within reach on both core types (re-load +12–14 ns against +53–54 ns after `CLFLUSHOPT`; the probe's store row does not discriminate there), yet the same-line store is still 76–94 % of the per-entry placement's cost, at ~21–30 ns per store rather than ~775, and the batched apply is 7–8 % faster instead of 43 %. The per-entry A/B switch (`TransactionCache.perEntryWriteback`, pwbench `apply=entry`) was removed once both comparisons were recorded; `TwoSlotWal.applyAfterImage()` remains for recovery replay, where on Magpie its per-entry writebacks are 51–59 % of the replay (15.9–16.8 µs at 24 entries), so the PMEM backend recovers slower than the file backend on DAX (pwopsbench, 2026-10-13)

## Coding Conventions

- All source is **Virgil** (`.v3`). Use 8-space indentation (not tabs) for V3 files.
- Errors are centralised in `WasmErrorGen.v3`; mainline parsing/validation code delegates there rather than constructing error messages inline.
- New Wasm proposals are gated via `Extension.v3` enum values and checked at validation/execution time.
- Monitor tests follow the pattern: add a `.wat`/`.wasm` test case in `test/monitors/`, run `update-expected.sh` to generate the expected output file, then `test/monitors/test.sh <monitor>` to verify.
