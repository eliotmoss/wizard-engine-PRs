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
        └── RegionWal (in-region redo log, lives in block 1)
              └── BackendRegion (persistence abstraction)
                    ├── VolatileRegion      (Array<byte>, GC-managed)
                    ├── FileMmapRegion      (mmap + msync/fdatasync — block device)
                    └── PmemMmapRegion      (mmap + clwb/sfence — PMEM/DAX)
```

### Key files (all under `src/engine/x86-64/` unless noted)

| File | Role |
|------|------|
| `src/engine/TxnBackend.v3` | Abstract `BackendRegion` / `TxnRegionBackend` interfaces; `VolatileBackend` |
| `X86_64TxnBackend.v3` | `FileMmapRegion`, `PmemMmapRegion`, `FdMmapRegion`; `RegionFileIO`; `X86_64Backends` factory |
| `X86_64TxnPWRegion.v3` | Layouts, handle types, `RegionTransaction`, `PWRegion`, `ImmixPWRegion` |
| `X86_64RegionWal.v3` | Concrete single-active-transaction in-region WAL |
| `X86_64PWRegion.v3` | Thin x86-64 convenience wrappers (`X86_64PWMemRegion`, `X86_64PWNVRegion`, `X86_64PWBlockDeviceRegion`, Immix variants) |
| `X86_64MultiTxnWal.v3` | Multi-transaction WAL skeleton — layouts complete, class body all stubs |
| `test/unittest/x86-64-linux/TxnPWRegionTest.v3` | PWRegion + backend region unit tests (incl. remount/recovery) |
| `test/unittest/x86-64-linux/WALCacheTest.v3` | `RegionTransaction` write-behind cache unit tests |

### On-region layout

```
Block 0:   Region header (PWRegionHeader) + sentinels
Block 1:   WAL log chunk (LogHeader + LogEntry[])
Blocks 2…N-2: User data blocks (SMALL_FREE / LARGE_FREE / USED)
Block N-1: Metadata overhead (block table, MetaDataDesc[])
Entry N:   End-of-region marker (no backing data)
```

### WAL commit protocol (single-transaction, current)

1. Writes buffered in `RegionTransaction` (HashMap-backed write-behind cache)
2. `commit()`: append to WAL → persist log entries → set `status=1` → apply to region → fence → `status=0`, persist
3. On mount: if `status==1` and checksum valid, redo all entries then clear status

### Known gaps and stubs

- `MmapRegionUtils.flushCacheLine` / `storeFence` are no-op placeholders — need Virgil inline-asm or intrinsic support for CLWB/SFENCE (`X86_64TxnBackend.v3:88-100`)
- `MultiTxnWal` class body is all stubs; `WalSuperblock` has `generation`, `logEpoch`, `durableAppliedSeq` fields ready for a circular multi-transaction redo log
- WAL overflow in `RegionWal.append` silently drops entries when block 1 is full
- `PWRegionHeader` is missing a pointer to the log chunk (needed for recovery without scanning)
- `Backends.getMmap()` declared but not implemented
- `ImmixPWRegion` line marks bypass the WAL and are not durable
- `RegionTransaction.clear()` allocates a new `HashMap` on every commit (GC pressure)
- `RegionTransaction` is aligned-access only — mixed-width overlapping reads cause silent cache misses

## Coding Conventions

- All source is **Virgil** (`.v3`). Use 8-space indentation (not tabs) for V3 files.
- Errors are centralised in `WasmErrorGen.v3`; mainline parsing/validation code delegates there rather than constructing error messages inline.
- New Wasm proposals are gated via `Extension.v3` enum values and checked at validation/execution time.
- Monitor tests follow the pattern: add a `.wat`/`.wasm` test case in `test/monitors/`, run `update-expected.sh` to generate the expected output file, then `test/monitors/test.sh <monitor>` to verify.
