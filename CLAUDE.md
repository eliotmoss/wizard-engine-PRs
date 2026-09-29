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
| `TxnBackend.v3` | Pluggable persistence backend interface (`BackendRegion`, `TxnRegionBackend`) used by PWRegion |
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
PWRegion (block allocator)
  └── RegionTransaction (write-behind cache + WAL facade)
        └── DualTxnWal (in-region two-slot redo log, lives in block 1)
              └── BackendRegion (persistence abstraction)
                    ├── VolatileRegion      (Array<byte>, GC-managed)
                    ├── FileMmapRegion      (mmap + msync/fdatasync — block device)
                    ├── PmemMmapRegion      (mmap + clwb/sfence — PMEM/DAX)
                    └── DirectIoRegion      (private staging buffer + pwrite/O_DIRECT + fdatasync — file or raw block device)
```

### Key files (all under `src/engine/x86-64/` unless noted)

| File | Role |
|------|------|
| `src/engine/TxnBackend.v3` | Abstract `BackendRegion` / `TxnRegionBackend` interfaces; `VolatileBackend`; the `PersistentOperations` store/flush/fence seam |
| `X86_64PersistentOperations.v3` | Production + trace-recording `PersistentOperations` providers; `X86_64PersistentOps.ensureFor()` installs one provider per region. Every persistent store on the active path (`PWRegion.format()`, `DirectRegionWriter`, `DualTxnWal`) goes through it, giving one total `STORE`/`CLWB`/`SFENCE` order |
| `X86_64PersistentTrace.v3` | Frozen scenario artifacts over the recorder: `PersistentTrace` (immutable snapshot, crash-cut `prefix()`, baseline `validate()`, content `digest()`, `touchedLines()`, stable rendering), `PersistentCounterexample` (optional durable image + byte window via `withImage()`), `PersistentTraces.capture()` |
| `X86_64PersistentImage.v3` | Durable-byte model over a trace: `PersistentCrashMachine` (per-line store lists, asynchronous writeback completion, fence obligations, background eviction, `crash()`), `PersistentDurableImage` (little-endian `read()`, `digest()`, `sameBytes()`), `PersistentImages.lazyCrash()`/`eagerCrash()` extremal schedules |
| `X86_64PersistentExplorer.v3` | Schedule enumeration over a trace: `PersistentExplorer.crashImages()` (full branching search with state dedup and a reported budget) and `reducedCrashImages()` (fence-forced floor + per-line prefix product); `checkImages()`/`checkAllCuts()`/`checkCutRange()` run a `PersistentImageProperty` over one cut, every cut, or a range of cuts and emit a `PersistentCounterexample`; `PersistentExploration`/`PersistentCheckResult` results and artifacts |
| `X86_64PersistentRecovery.v3` | Production recovery over an enumerated image: `PersistentRecoveries.runDualWal()` (remount + `recover()` + resulting bytes), `PersistentWalRecoveryProperty` (acknowledgement contract as a checkable property) and `PersistentWalHistoryProperty`/`PersistentWalAfterImage` (the same contract over a multi-transaction history in one mount per image), `PersistentImageBackend` + `PersistentAllocatorProperty` (mount an image as a `PWRegion`), `PersistentAllocatorInvariants` (memory-order/free-list/used-state walk returning the first violation); `PersistentImageMounts` (array vs recording-PMEM containers), `recordDualWalRecovery()`/`recordPWRegionRecovery()`/`checkCrashDuringRecovery()` for the bounded two-crash profile; `InjectedFailureRegion` + `PersistentRecoveryFailureProperty`/`PersistentAllocatorFailureProperty` for failed recovery/mount boundaries |
| `X86_64TxnBackend.v3` | `FileMmapRegion`, `PmemMmapRegion`, `FdMmapRegion`; `RegionFileIO`; `X86_64Backends` factory; `MmapRegionUtils` (`flushCacheLine()` issues native `CLWB`, else `CLFLUSHOPT`, else `CLFLUSH`, chosen once by CPUID; `storeFence()` issues `SFENCE`; both Virgil `Target` intrinsics since 2026-08-31) |
| `X86_64DirectIoBackend.v3` | Direct-I/O backend: `DirectIoRegion` (anonymous staging buffer loaded at `create()`; provider `clwb()` marks 4 KiB units, every fence `pwrite`s the marked units then `fdatasync`s once; same trace as `PmemMmapRegion`), `DirectIoOperations`/`DirectIoStagingOperations`, `DirectIoBackend(path, FILE \| BLOCK_DEVICE)` with the O_DIRECT behaviour probe, `O_EXCL` device open and foreign-signature refusal; `DirectIoFileIO`. The elided-writeback mutant works unchanged on it, and a plain `SIGKILL` discriminates it (process death discards unwritten staging data) |
| `X86_64TxnPWRegion.v3` | Layouts, handle types, `RegionTransaction`, `PWRegion`, `ImmixPWRegion` |
| `X86_64SingleTxnWal.v3` | Single-transaction in-region WAL — superseded, **not wired in**; kept as a reference implementation (see `docs/wal-comparison.md`) |
| `X86_64PWRegion.v3` | Thin x86-64 convenience wrappers (`X86_64PWMemRegion`, `X86_64PWNVRegion`, `X86_64PWBlockDeviceRegion`, Immix variants) |
| `X86_64DualTxnWal.v3` | Active two-slot WAL (phase B) — two parity-selected record slots, per-record checksum, poisoning `append()`, `DualWalRecovery` result, piggybacked persistence boundary (one per commit steady-state); batched after-image apply (`storeUpdate()` per after-image, then `prepareApplied()` prepares each line once; drained before every boundary that advances `dataDurableSeq`); drives `PWRegion`/`RegionTransaction` |
| `X86_64MultiTxnWal.v3` | Multi-transaction ring WAL (dual superblock, epoch fencing, checkpoint policy) — superseded, **not wired in**; kept as a comparison implementation |
| `test/unittest/x86-64-linux/TxnPWRegionTest.v3` | PWRegion + backend region unit tests (incl. remount/recovery) |
| `test/unittest/x86-64-linux/RegionTransactionTest.v3` | `RegionTransaction` write-behind cache unit tests |
| `test/unittest/x86-64-linux/DualTxnWalTest.v3` | `DualTxnWal` unit tests (commit/recovery/guard/failure paths) |
| `test/unittest/x86-64-linux/PersistentOperationsTest.v3` | `PersistentOperations` seam tests (typed store/CLWB/SFENCE ordering, store audit over `PWRegion`) |
| `test/unittest/x86-64-linux/PersistentTraceTest.v3` | Trace capture/validation/digest and artifact-rendering tests |
| `test/unittest/x86-64-linux/PersistentImageTest.v3` | Durable-image model tests (volatility, torn writeback, fence completion, eviction, real-WAL trace image) |
| `test/unittest/x86-64-linux/PersistentExplorerTest.v3` | Crash-image enumeration and property-check tests (image counts per cut, reduction agrees with full search, budget truncation, counterexample emission) |
| `test/unittest/x86-64-linux/PersistentRecoveryTest.v3` | Production recovery over enumerated crash images (acknowledged survival, no invented state, idempotence, counterexample emission) |
| `test/unittest/x86-64-linux/PersistentAllocatorTest.v3` | Allocator invariants over enumerated crash images (split alloc, coalescing free, walker self-check) |
| `test/unittest/x86-64-linux/DirectIoRegionTest.v3` | Direct-I/O backend tests: marking/coalescing/drain/failure mechanics, device and size rejections, allocator roundtrip and `SIGKILL` cases (unwritten staging lost; mutant loses an acknowledged commit), trace identity with the PMEM backend, and an exact per-line check that the file after every real `fdatasync` is an image the PMEM crash model admits. Region files go in `/tmp`, falling back to `bin/` when `/tmp` does not honour O_DIRECT |
| `test/unittest/x86-64-linux/MultiTxnWalTest.v3` | `MultiTxnWal` unit tests (comparison implementation) |
| `test/unittest/x86-64-linux/PWSieve.v3` | Resumable segmented Sieve of Eratosthenes over `PWRegion` — the workload driver (not engine code); root chunk at `userRoot`, one chunk per live segment, retirement + leak reclamation, `checkInvariants()` |
| `test/unittest/x86-64-linux/PWSieveTest.v3` | Sieve workload tests (mount/resume, prime counts, invariants, retirement, remount) |
| `test/unittest/x86-64-linux/PersistentSieveTest.v3` | Sieve through the crash-image explorer; `PersistentSieveProperty` mounts an image, recovers, reattaches and checks the workload's invariants |
| `test/pwsieve.main.v3` | Random-timer `SIGKILL` crash loop over the sieve; selectable file, PMEM or direct-I/O backend (`direct`, or `direct-device=<dev>` on a raw device), requires every acknowledged step to survive (the child publishes its acknowledged cursor in a shared page; a shortfall is a `LOST` restart), runs the elided-writeback mutant in the children only, reserves its own region file in a caller-assigned directory (`make pwsieve` / `make pwsieve-pmem`, `PWSIEVE_ARGS` / `PWASM_PMEM_TEST_DIR`) |
| `test/pwsievebench.main.v3` | Sieve-step cost through the production allocator and WAL: rounds of a freshly formatted region, warm-up, then every step the descriptor table has left (159 at 256 × 4 KiB), each round verified against a reference sieve; per step, wall time (mean, median, p90), the five phases PWSieve reports through its `onPhase` hook (compute, alloc, bitmap, publish, retire), boundaries, writeback lines and minor faults. `file`, `pmem` (`writeback=auto|clwb|clflushopt|none`) or `direct`; the timing backends are duplicated from pwbench so pwbench's code layout is untouched (`make pwsievebench-pmem`). `clock=probe` reads the core clock without root at each of the step's six marks (sieve, alloc, bitmap, count, publish, retire) and against busy and 250 µs-sleep references: a pregenerated machine-code stub times 4,096 dependent add/xor register operations between `lfence`-ordered `rdtsc` reads (a Virgil loop would spill to the stack), two probes per point so a cold first probe is reported apart; probe time is removed from every figure |
| `test/pwreboot.main.v3` | Stage 2c warm-reboot harness (also accepts `direct` for setup/arm/verify, where exit is the crash and no reboot is needed): a flushed-against-unflushed cache-line probe, and the sieve armed with the production provider or the elided-writeback mutant, verified after a `sysrq` reboot on a `memmap` host (`make bin/pwreboot.x86-64-linux`); an optional inherited `/proc/sysrq-trigger` descriptor lets `probe-arm`/`arm` reset the machine themselves with no window after the last store, which is the form that discriminates (Stage 2c done 2026-09-24: ordinary `SURVIVED` 3/3, mutant `LOST` 3/3) |
| `scripts/stage2c.sh` | Stage 2c operator script (`doctor`/`probe`/`probe-now`/`sieve`/`sieve-now`/`verify`); refuses to arm while the firmware's memory-overwrite request is set; host setup, runbook and cross-machine hand-off in `docs/stage2c-handoff.md` |
| `scripts/clwb-eviction.sh` | CLWB-eviction experiment (`doctor`/`probe`/`campaign`/`all`/`summary`/`rebuild`): the probe, then pwbench under `perf stat` where permitted, across `pmem-<auto\|clwb\|clflushopt\|clflush\|deferred\|none>[-s<stride>]` and `file-dax[-s<stride>]`, via pwbench's `writeback=`/`stride=` keyword arguments (`-entry` before the stride, the pre-2026-09-28 per-entry apply, is accepted only by `rebuild`/`summary` for the directories that used it; pwbench's `apply=` has been removed); `PWCLWB_CPUS` pins to a CPU list, needed on hybrid CPUs where the two core types may differ (`none` is timing only and never durable; `deferred` writes each distinct line back once before the fence, durability unchanged). The probe summary marks a store row "not discriminating" when its `CLFLUSHOPT` excess is under half the load row's (Raptor Lake). First Magpie campaign 2026-09-28: CLWB evicts, and the writebacks cost 14–43 % of a PMEM commit; on Raptor Lake it does not (`docs/persistent-backends.md`) |
| `scripts/pwsieve-bench.sh` | Sieve-step campaign (`doctor`/`campaign`/`summary`/`rebuild`) over `pmem-<auto\|clflushopt\|none\|clwb>`, `file-dax`, and `file-block`/`direct-block` when `PWSB_BLOCK_DIR` is set; pins with `PWSB_CPUS` (hybrid CPUs) or to the DAX namespace's NUMA node, refuses a non-DAX `PWASM_PMEM_TEST_DIR`, a DAX or network `PWSB_BLOCK_DIR` and a dirty tree; the summary gives medians over repetitions, the repetitions' wall range, the persistence phases' share of a step and the writebacks' cost by removal. Any configuration takes a `+clock` suffix (`clock=probe`); `PWSB_CLOCK=1` makes the default `pmem-auto`, `file-dax` and the block pair each plain and `+clock`, interleaved, writes `clock.csv`, records the frequency driver, EPP and idle states in `provenance.txt`, and summarises the clock at each point and whether it accounts for the computation's slowdown against the configuration that never blocks |
| `scripts/clwbprobe.c` | Engine-independent C probe: re-access cost of a line after no writeback, `CLWB` or `CLFLUSHOPT`, on DRAM and a `MAP_SYNC` DAX mapping |

### On-region layout

```
Block 0:   Region header (PWRegionHeader, 88 bytes, incl. userRoot) + sentinels
Block 1:   WAL log chunk (DualTxnWal: DualWalHeader + two fixed record slots)
Blocks 2…N-2: User data blocks (SMALL_FREE / LARGE_FREE / USED)
Block N-1: Metadata overhead (block table, MetaDataDesc[])
Entry N:   End-of-region marker (no backing data)
```

### WAL commit protocol (two-slot, current — `DualTxnWal`, phase B)

1. Writes buffered in `RegionTransaction` (HashMap-backed write-behind cache)
2. `commit()`: `appendToWal → wal.commit` (write one checksummed record into slot `txnSeq % 2`, then ONE persistence boundary — `prepareChangedRange(record) + persistChanges()` — that persists the record together with the *previous* transaction's applied after-images; the commit point) `→ applyToRegion` (this transaction's after-images, applied write-behind: `storeUpdate()` for each, then `prepareApplied()` writes each touched line back once — on Cascade Lake `CLWB` evicts, so per-entry writeback made the next same-line store miss; only the fence — their persist — rides the next commit's boundary, and every boundary that advances `dataDurableSeq` drains outstanding extents first) `→ clear`
3. Unmount/idle: `wal.close()` (called by `PWRegion.deallocate()`) persists the deferred data and scrubs reclaimable slots so a clean remount is replay-free; `RegionTransaction.flush()` is the explicit idle boundary
4. On mount: validate the `DualWalHeader`, validate both slots, replay the valid records in ascending `txnSeq` (idempotent after-images, so re-replay is harmless), persist, set `nextTxnSeq = max + 1`. `recover()` returns `DualWalRecovery` (`CLEAN`/`REPLAYED`/`CORRUPT`/`PERSIST_FAILED`)

One boundary per commit in steady state (one `SFENCE` on PMEM, one `fdatasync` on file); correctness by induction — a valid record N+1 implies the boundary at its commit completed, so txn N's data is durable. An overwrite guard keeps a slot from being destroyed while it covers not-yet-durable data; a failed commit-point persist retries with the same seq into the same slot (parity), so duplicate-seq records cannot exist. Contract: a committed transaction's entries must be applied before the next commit (`RegionTransaction` guarantees this).

The superseded protocols are retained for comparison, **not wired in** — `SingleTxnWal` (persist entries → `status=1` → apply → fence → `status=0`) and `MultiTxnWal` (ring + superblock + epoch fencing + checkpoint policy) — see `docs/wal-comparison.md`.

### Known gaps and stubs

- WAL overflow in `SingleTxnWal.append` (the superseded reference WAL) silently drops entries when block 1 is full; the active `DualTxnWal` surfaces an oversized transaction via a failed `commit()` instead (per-transaction capacity ≈ half the log chunk minus headers)
- `Backends.getMmap()` declared but not implemented
- `PWRegion.setUserRoot()` commits in its own transaction, and `allocChunk()` commits in its own, so a crash between allocating an extent and publishing it in the root leaks that extent (used, unreachable). A space leak, not an inconsistency; the caller must reclaim it (`PWSieve.open()` shows how)
- `ImmixPWRegion` line marks are explicitly transient: mark/reset bypass the WAL and persistence boundaries, so callers must rebuild them after a crash. They are also the only remaining direct stores in the allocator — every other persistent store on the active path goes through the `PersistentOperations` seam
- `RegionTransaction.clear()` allocates a new `HashMap` on every commit (GC pressure)
- `RegionTransaction` is aligned-access only — mixed-width overlapping reads cause silent cache misses
- `DirectIoRegion` holds the whole region in DRAM, reads it all at mount, and is limited to regions under 2 GiB (`FdMmapRegion` forges its range with `int.!`). Its kill-loop sensitivity is 4 KiB-granular: a missing writeback for a line sharing a unit with a flushed one goes unnoticed
- On Magpie, `/home` (every `file-block`/`direct-block` figure) is behind a MegaRAID SAS3508 that reports write-through: `fdatasync` sends no flush and the boundary is the controller's acknowledgement; whether that is power-safe is not established
- On Magpie, block-storage timings include a clock penalty the OS cannot control: Magpie has no cpufreq driver (the platform sets the frequency) and `intel_idle` offers C1, C1E and C6, so a thread that blocks in `fdatasync` runs its next computation slower. In the sieve the computation itself took 2.6–2.7× its PMEM time on `/home` (not migration, not syscalls or faults; reproduced on sean-tan-PC under `powersave`, absent under `performance`). Observed without root on 2026-09-29 by `pwsievebench clock=probe`: after a block-storage boundary Magpie's core runs at 1.0 GHz against 3.6 GHz busy and reaches only 1.7–1.8 GHz by the end of the sieve, which accounts for the slowdown; a 250 µs sleep does the same, so it is idleness, not storage; on sean-tan-PC the clock follows the governor (`powersave` 29–33 % of busy, `performance` 100 %). Which idle state is entered is not established (`turbostat` needs root). Read any Magpie `file-block`/`direct-block` figure for a workload that computes between boundaries with this in mind; pwbench's back-to-back boundaries barely see it (`docs/persistent-backends.md`, sieve section)
- At 4 KiB blocks the WAL header and both record slots share one 4 KiB write unit, so slot independence on block media rests on the device being old-or-new per 512-byte sector (pinned by `direct_io:record_write_rewrites_whole_log_unit`)
- On Cascade Lake (Magpie) `CLWB` evicts the line, and `DualTxnWal.applyUpdate()` writes each after-image back as soon as it is stored, so consecutive after-images in one line miss to PMEM: the writebacks cost 14–43 % of a PMEM commit, while pwbench's `rdtsc`-bracketed "boundary" shows ~3 % (measured 2026-09-28; with one entry per line the same writebacks cost 7 % at 24 entries, so ~95 % is the within-commit same-line store. Deferring writebacks to the fence helps only where lines are reused). Fixed the same day by the batched apply (`storeUpdate`/`prepareApplied`), measured: 42 % faster at 24 entries, writebacks 3 % of the commit, and the PMEM backend faster than the file backend on DAX at every size again. Its bookkeeping overhead (a compiled `divq`, non-inlined `Vector` calls; 0.2–0.8 µs where nothing coalesces) was then removed and re-measured: 43 % faster than per-entry at 24 entries, the file backend unaffected, 0.34 µs (1.5 %) left at stride 64 from placement. The eviction is Cascade Lake's, the mechanism is not: on a Raptor Lake i7-14700KF (sean-tan-PC, DRAM-emulated PMEM, one performance and one efficiency core, 2026-09-28) `CLWB` leaves the line within reach on both core types (re-load +12–14 ns against +53–54 ns after `CLFLUSHOPT`; the probe's store row does not discriminate there), yet the same-line store is still 76–94 % of the per-entry placement's cost, at ~21–30 ns per store rather than ~775, and the batched apply is 7–8 % faster instead of 43 %. The per-entry A/B switch (`RegionTransaction.perEntryWriteback`, pwbench `apply=entry`) was removed once both comparisons were recorded; `DualTxnWal.applyUpdate()` remains for recovery replay

## Coding Conventions

- All source is **Virgil** (`.v3`). Use 8-space indentation (not tabs) for V3 files.
- Errors are centralised in `WasmErrorGen.v3`; mainline parsing/validation code delegates there rather than constructing error messages inline.
- New Wasm proposals are gated via `Extension.v3` enum values and checked at validation/execution time.
- Monitor tests follow the pattern: add a `.wat`/`.wasm` test case in `test/monitors/`, run `update-expected.sh` to generate the expected output file, then `test/monitors/test.sh <monitor>` to verify.
