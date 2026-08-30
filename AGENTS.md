# Repository Guidelines

## Project Overview

Wizard is a research WebAssembly (Wasm) virtual machine written in Virgil (`.v3`), a fast, garbage-collected systems language. It is designed for teaching, research, and instrumentation rather than peak production performance.

## Project Structure & Module Organization

Core code lives in `src/engine/`: portable execution in `v3/`, the JIT in `compiler/`, and native code in `x86-64/`. Host integrations are in `src/modules/`, instrumentation in `src/monitors/`, and helpers in `src/util/`. Purpose-specific tests live under `test/`; generated executables go to `bin/`.

## Project Direction & Design Documentation

Treat [`docs/ROADMAP.md`](docs/ROADMAP.md) as the source of truth for this branch's work. Consult it before changes, and update it when status, priorities, or open issues change. Use [`docs/persistent-backends.md`](docs/persistent-backends.md) for the allocator/backend design, [`docs/wal-comparison.md`](docs/wal-comparison.md) to distinguish the active WAL from retained alternatives, and [`docs/CRITIQUE.md`](docs/CRITIQUE.md) for known limitations. Crash assumptions and validation environments are documented in [`docs/pmem-crash-model.md`](docs/pmem-crash-model.md) and [`docs/pmem-emulation.md`](docs/pmem-emulation.md). The `doc/` directory covers general Wizard usage and development.

## Build Commands

Install and build the [Virgil compiler](https://github.com/titzer/virgil) with its `bin/` directory on `PATH`.

```bash
make -j                          # build all standard targets
make x86-64-linux                # build only the primary native target
./build.sh wizeng x86-64-linux   # build one binary for one platform
```

Binaries land in `bin/` with platform suffixes, for example `bin/wizeng.x86-64-linux`.

## Test Commands

```bash
test/unit.sh                          # run internal unit tests
test/spec.sh                          # run Wasm specification tests
test/regress.sh                       # run regression tests
test/monitors/test.sh                 # run all monitor tests
test/monitors/test.sh loops branches  # run selected monitor tests
test/all.sh                           # run the CI-style full matrix
TEST_TARGET=x86-64-linux test/unit.sh # run unit tests for one target
TEST_TARGET=x86-64-linux test/spec.sh # run spec tests for one target
WIZENG_OPTS=-mode=jit test/spec.sh    # pass engine options during tests
```

Prepare the Wasm spec tests with `test/wasm-spec/update.sh`. The optional [`progress`](https://github.com/titzer/progress) utility makes test output easier to read.

To update expected output after changing a monitor, run:

```bash
test/monitors/update-expected.sh <monitor-name>
```

Run `PWASM_PMEM_TEST_DIR=/assigned/fsdax/path make pmem-integration` for the opt-in DAX persistence test. Never point it at an unassigned directory.

## Code Architecture

### Execution Tiers

The engine has three execution tiers under `src/engine/`:

- The V3 interpreter (`v3/V3Interpreter.v3`) is portable, runs on all platforms, and uses a value stack and call stack.
- The fast x86-64 interpreter (`x86-64/`) is handwritten assembly and native-only.
- The single-pass compiler (`compiler/`) contains the JIT compilation infrastructure.

### Core Engine Types

| File | Role |
|---|---|
| `src/engine/Module.v3` | Decoded in-memory Wasm module; preserves declaration order for types, functions, memories, and tables. |
| `src/engine/Instance.v3` | Runtime state of an instantiated module and the primary structure for execution. |
| `src/engine/Instantiator.v3` | Binds imports and constructs instances in declaration order. |
| `src/engine/BinParser.v3` | Push-based incremental binary parser. |
| `src/engine/CodeValidator.v3` | Single-pass abstract-interpretation validator; also produces the control-transfer side table. |
| `src/engine/Opcodes.v3` | Central opcode, immediate, and signature definitions using Virgil enums. |
| `src/engine/Type.v3` | Wasm types, subtyping, assignability, and least-upper-bound logic. |
| `src/engine/Value.v3` | Primitive and reference Wasm values. |
| `src/engine/WasmStack.v3` | Abstract stack interface implemented by `V3Interpreter`. |
| `src/engine/TxnBackend.v3` | Pluggable persistence interfaces (`BackendRegion`, `TxnRegionBackend`) used by `PWRegion`. |
| `src/util/ErrorGen.v3` | Decode, validate, and instantiate error generation kept out of mainline logic. |
| `src/engine/Extension.v3` | Individually enabled Wasm proposals and extensions. |

The control-transfer side table is produced by `CodeValidator` and consumed by the interpreter. It enables O(1) branch dispatch instead of scanning for matching `end` or `else` targets at runtime.

### Host Modules

- `src/modules/wasi/` implements WASI.
- `src/modules/wali/` implements the Wasm-Linux direct syscall bridge.
- `src/modules/wave/` contains the WAVE research module.
- `src/modules/wizeng/` contains the main engine embedding module.

### Monitor System

Monitors are dynamic instrumentation plugins. They implement `Monitor.v3` and receive callbacks through the `Probe` mechanism in `src/engine/Instrumentation.v3`. Monitor tests and inputs live in `test/monitors/`, with expected outputs in `test/monitors/expected/`.

### Entry Points and Bytecode

- `src/wizeng.main.v3` is the main `wizeng` executable.
- `src/WasmMode.v3` is normal Wasm execution mode.
- `src/SpectestMode.v3` is the spec test runner mode.
- `test/unittest.main.v3` is the unit-test executable.
- `src/bytecode/CanonicalDefs.v3` defines the canonical bytecode representation shared across engine components.

## Persistent Region Allocator (`pwregions` Branch)

This branch adds transactional persistent storage for Wasm, targeting byte-addressable PMEM and file-backed block media. Objects are staged from mapped persistent regions into DRAM for manipulation by the engine, and a write-ahead log provides recoverability.

### Layer Structure

```text
PWRegion (block allocator)
  └── RegionTransaction (write-behind cache + WAL facade)
        └── DualTxnWal (in-region two-slot redo log, block 1)
              └── BackendRegion (persistence abstraction)
                    ├── VolatileRegion      (Array<byte>, GC-managed)
                    ├── FileMmapRegion      (mmap + msync/fdatasync)
                    └── PmemMmapRegion      (mmap + clwb/sfence)
```

### Key Persistence Files

Files without a directory prefix below are under `src/engine/x86-64/`.

| File | Role |
|---|---|
| `src/engine/TxnBackend.v3` | Abstract backends, `VolatileBackend`, and the `PersistentOperations` store/flush/fence seam. |
| `X86_64PersistentOperations.v3` | Production and trace-recording operation providers; gives active persistent stores a single total `STORE`/`CLWB`/`SFENCE` order. |
| `X86_64PersistentTrace.v3` | Immutable trace snapshots, validation, crash cuts, digests, touched-line reporting, stable rendering, and counterexample artifacts. |
| `X86_64PersistentImage.v3` | Durable-byte crash model with asynchronous writeback, fence obligations, background eviction, and lazy/eager schedules. |
| `X86_64PersistentExplorer.v3` | Full and reduced crash-image enumeration, state deduplication, budgets, property checks, and counterexample emission. |
| `X86_64PersistentRecovery.v3` | Production recovery over enumerated images, WAL and allocator properties, invariant checks, two-crash profiles, and injected recovery failures. |
| `X86_64TxnBackend.v3` | File and PMEM mapped regions, file I/O, and x86-64 backend factories. |
| `X86_64TxnPWRegion.v3` | Layouts, handle types, `RegionTransaction`, `PWRegion`, and `ImmixPWRegion`. |
| `X86_64PWRegion.v3` | Thin x86-64 convenience wrappers for memory, PMEM, block-device, and Immix regions. |
| `X86_64DualTxnWal.v3` | Active two-slot WAL with parity-selected records, checksums, poisoning, recovery results, overwrite guards, and one steady-state boundary per commit. |
| `X86_64SingleTxnWal.v3` | Superseded, unwired single-transaction WAL retained for comparison. |
| `X86_64MultiTxnWal.v3` | Superseded, unwired multi-transaction ring WAL retained for comparison. |

Focused tests live in `test/unittest/x86-64-linux/`:

- `TxnPWRegionTest.v3` and `RegionTransactionTest.v3` cover allocator, backend, cache, remount, and recovery behavior.
- `DualTxnWalTest.v3` covers the active commit, recovery, guard, and failure paths.
- `PersistentOperationsTest.v3`, `PersistentTraceTest.v3`, `PersistentImageTest.v3`, and `PersistentExplorerTest.v3` cover the persistence seam and crash explorer.
- `PersistentRecoveryTest.v3` and `PersistentAllocatorTest.v3` run production recovery and allocator invariants over enumerated images.
- `MultiTxnWalTest.v3` covers the retained comparison implementation.

### On-Region Layout

```text
Block 0:      Region header (PWRegionHeader) + sentinels
Block 1:      WAL log chunk (DualWalHeader + two fixed record slots)
Blocks 2…N-2: User data blocks (SMALL_FREE / LARGE_FREE / USED)
Block N-1:    Metadata overhead (block table, MetaDataDesc[])
Entry N:      End-of-region marker (no backing data)
```

### Active WAL Commit Protocol

1. `RegionTransaction` buffers writes in a `HashMap`-backed write-behind cache.
2. `commit()` performs `appendToWal → wal.commit → applyToRegion → clear`. `wal.commit` writes one checksummed record to slot `txnSeq % 2`, then uses one persistence boundary to persist that record together with the previous transaction's applied after-images. The current transaction's after-images ride the next boundary.
3. `RegionTransaction.flush()` is the explicit idle boundary. On unmount, `PWRegion.deallocate()` calls `wal.close()` to persist deferred data and scrub reclaimable slots so a clean remount is replay-free.
4. Mount validates `DualWalHeader` and both slots, replays valid records in ascending `txnSeq`, persists the idempotent after-images, and sets `nextTxnSeq` to the maximum plus one. Recovery returns `CLEAN`, `REPLAYED`, `CORRUPT`, or `PERSIST_FAILED`.

A valid record N+1 proves the boundary at its commit completed, so transaction N's data is durable. An overwrite guard protects slots covering not-yet-durable data. A failed commit-point persist retries the same sequence in the same parity slot, preventing duplicate-sequence records. `RegionTransaction` guarantees that a committed transaction's entries are applied before the next commit.

The retained `SingleTxnWal` and `MultiTxnWal` protocols are not wired into the allocator. Consult `docs/wal-comparison.md` before reasoning about or changing WAL behavior.

### Known Limitations

Treat `docs/ROADMAP.md` and `docs/CRITIQUE.md` as authoritative because this list can change:

- `SingleTxnWal.append()` silently drops overflowing entries; this affects only the retained comparison WAL. Active `DualTxnWal` reports oversized transactions through a failed commit.
- `Backends.getMmap()` is declared but not implemented.
- Immix line marks are deliberately transient, bypass the WAL, and must be rebuilt after a crash.
- `RegionTransaction` supports aligned, exact-address accesses only; mixed-width overlapping reads can miss cached writes.

## Coding Style & Naming Conventions

Follow nearby Virgil code: indent with tabs, keep braces on the declaration line, and terminate statements with semicolons. Use `PascalCase` for types and filenames, `camelCase` for methods and variables, and `UPPER_SNAKE_CASE` for enum values. Test files end in `Test.v3`; registered cases use descriptive `snake_case`. No repository-wide formatter or linter is configured, so preserve local style.

Keep errors centralized in `src/util/ErrorGen.v3`; parsing and validation code should delegate there instead of constructing error messages inline. Gate new Wasm proposals through `Extension.v3` and check them during validation and execution.

Monitor tests follow this sequence: add a `.wat` or `.wasm` case in `test/monitors/`, run `test/monitors/update-expected.sh <monitor-name>`, then verify with `test/monitors/test.sh <monitor-name>`.

## Testing Guidelines

Tests use Virgil's `UnitTests` harness plus shell-driven spec and regression suites. Add focused unit coverage for new logic and regression fixtures for fixed Wasm behavior. Persistence changes should exercise failure, crash, remount, and recovery paths. Run the relevant target suite and, where practical, `test/all.sh`; there is no numeric coverage gate.

## Commit & Pull Request Guidelines

Recent commits favor imperative Conventional Commit subjects, for example `test(pmem): add safe opt-in fsdax integration runner`. Use a concise type, optional scope, and specific outcome. Pull requests should explain motivation and behavior, identify affected targets, link issues, and list exact verification commands. Include logs or expected-output diffs when CLI, monitor, or recovery behavior changes.
