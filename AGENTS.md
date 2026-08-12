# Repository Guidelines

## Project Structure & Module Organization

Wizard is a WebAssembly research engine written in Virgil (`.v3`). Core parsing, validation, runtime, and persistence abstractions live in `src/engine/`; portable execution is under `src/engine/v3/`, while the JIT and native x86-64 implementation are in `src/engine/compiler/` and `src/engine/x86-64/`. Host integrations belong in `src/modules/`, instrumentation in `src/monitors/`, and shared helpers in `src/util/`. Unit tests mirror these areas in `test/unittest/`; regression fixtures, specification support, monitor tests, and platform integration tests have dedicated subdirectories under `test/`. Documentation is in `doc/` and `docs/`; generated executables go to `bin/`.

## Build, Test, and Development Commands

Install and build the Virgil compiler first, with its `bin/` directory on `PATH`.

- `make -j` builds all standard targets.
- `make x86-64-linux` builds the engine and unit-test binary for the primary native target.
- `./build.sh wizeng x86-64-linux` builds only `bin/wizeng.x86-64-linux`.
- `test/unit.sh` runs internal unit tests; use `TEST_TARGET=x86-64-linux` to select a target.
- `test/regress.sh` runs `.bin.wast` regression cases.
- `test/spec.sh` runs Wasm spec tests after `test/wasm-spec/update.sh` prepares them.
- `test/all.sh` runs the full matrix used by CI.
- `PWASM_PMEM_TEST_DIR=/assigned/fsdax/path make pmem-integration` runs the opt-in DAX persistence test; never point it at an unassigned directory.

## Coding Style & Naming Conventions

Follow nearby Virgil code: indent with tabs, keep braces on the declaration line, and terminate statements with semicolons. Use `PascalCase` for classes, components, and enums; `camelCase` for methods and variables; and `UPPER_SNAKE_CASE` for enum values. Source and test filenames use `PascalCase.v3`, with tests ending in `Test.v3`. Registered test cases generally use descriptive `snake_case` names. No repository-wide formatter or linter is configured, so keep diffs focused and preserve local style.

## Testing Guidelines

Tests use Virgil's `UnitTests` harness plus shell-driven spec and regression suites. Add focused unit coverage for new logic and regression fixtures for fixed Wasm behavior. Persistence changes should exercise failure, crash, remount, and recovery paths. There is no numeric coverage gate; changes are expected to pass the relevant target suite and, where practical, `test/all.sh`.

## Commit & Pull Request Guidelines

Recent commits favor imperative Conventional Commit subjects such as `test(pmem): add safe opt-in fsdax integration runner` and `docs(pmem): record validation environment`. Use a concise type, optional scope, and specific outcome. Pull requests should explain motivation and behavior, identify affected execution targets, link related issues, and list exact verification commands. Include logs or expected-output diffs when CLI, monitor, or recovery behavior changes.
