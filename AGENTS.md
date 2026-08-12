# Repository Guidelines

## Project Structure & Module Organization

Wizard is a WebAssembly research engine written in Virgil (`.v3`). Core code lives in `src/engine/`: portable execution in `v3/`, the JIT in `compiler/`, and native code in `x86-64/`. Host integrations are in `src/modules/`, instrumentation in `src/monitors/`, and helpers in `src/util/`. Purpose-specific tests live under `test/`; generated executables go to `bin/`.

## Project Direction & Design Documentation

Treat [`docs/ROADMAP.md`](docs/ROADMAP.md) as the source of truth for this branch's work. Consult it before changes, and update it when status, priorities, or open issues change. Use [`docs/persistent-backends.md`](docs/persistent-backends.md) for the allocator/backend design, [`docs/wal-comparison.md`](docs/wal-comparison.md) to distinguish the active WAL from retained alternatives, and [`docs/CRITIQUE.md`](docs/CRITIQUE.md) for known limitations. Crash assumptions and validation environments are documented in [`docs/pmem-crash-model.md`](docs/pmem-crash-model.md) and [`docs/pmem-emulation.md`](docs/pmem-emulation.md). The `doc/` directory covers general Wizard usage and development.

## Build, Test, and Development Commands

Install and build the Virgil compiler with its `bin/` directory on `PATH`.

- `make -j` builds all standard targets; `make x86-64-linux` limits the build to the primary native target.
- `./build.sh wizeng x86-64-linux` builds only the native engine.
- `test/unit.sh` runs internal unit tests; use `TEST_TARGET=x86-64-linux` to select a target.
- `test/regress.sh` runs `.bin.wast` regression cases.
- `test/spec.sh` runs Wasm spec tests after `test/wasm-spec/update.sh` prepares them.
- `test/all.sh` runs the CI-style full matrix.
- `PWASM_PMEM_TEST_DIR=/assigned/fsdax/path make pmem-integration` runs the opt-in DAX persistence test; never point it at an unassigned directory.

## Coding Style & Naming Conventions

Follow nearby Virgil code: indent with tabs, keep braces on the declaration line, and terminate statements with semicolons. Use `PascalCase` for types and filenames, `camelCase` for methods and variables, and `UPPER_SNAKE_CASE` for enum values. Test files end in `Test.v3`; registered cases use descriptive `snake_case`. No repository-wide formatter or linter is configured, so preserve local style.

## Testing Guidelines

Tests use Virgil's `UnitTests` harness plus shell-driven spec and regression suites. Add focused unit coverage for new logic and regression fixtures for fixed Wasm behavior. Persistence changes should exercise failure, crash, remount, and recovery paths. Run the relevant target suite and, where practical, `test/all.sh`; there is no numeric coverage gate.

## Commit & Pull Request Guidelines

Recent commits favor imperative Conventional Commit subjects, for example `test(pmem): add safe opt-in fsdax integration runner`. Use a concise type, optional scope, and specific outcome. Pull requests should explain motivation and behavior, identify affected targets, link issues, and list exact verification commands. Include logs or expected-output diffs when CLI, monitor, or recovery behavior changes.
