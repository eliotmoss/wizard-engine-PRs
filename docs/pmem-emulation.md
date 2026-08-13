# PMEM Emulation for Development and Validation

This document assesses how to exercise Wizard's `PmemMmapBackend` on a
machine without physical persistent memory. The recommended development
environment is an x86-64 Linux guest with a QEMU-emulated NVDIMM backed by a
host file. Reserving DRAM as PMEM with the Linux `memmap` kernel parameter is
an alternative for native x86-64 Linux systems.

Both approaches reproduce the Linux PMEM/DAX programming interface. Neither
turns volatile DRAM or an ordinary host file into media that survives host
power loss.

Deterministic cache/persistence simulation does not require DAX: an ordinary
file or byte array can hold simulated live and durable images while a model
decides when stores and cache-line writebacks reach persistence. That separate
plan is specified in [PMEM Crash Model](pmem-crash-model.md).

## What the project requires

`PmemMmapBackend.create()`:

1. opens or creates a path as a regular file;
2. checks its length and uses `ftruncate()` when it must be resized; and
3. maps it with `MAP_SHARED_VALIDATE | MAP_SYNC`.

`MAP_SYNC` is supported only for files with DAX mappings. A regular file on
the host filesystem, a file in `/tmp`, or a tmpfs file will normally fail the
mapping with `EOPNOTSUPP`. The supported path for this project is therefore:

```text
QEMU file-backed NVDIMM
  → guest /dev/pmem0 block device
    → ext4 or XFS mounted with filesystem DAX
      → regular file such as /mnt/pmem/wizard-region
        → PmemMmapBackend
```

Do not pass `/dev/pmem0` directly to the current backend. An fsdax namespace's
block device is intended to host a DAX-capable filesystem, and direct access
to the raw block device does not provide filesystem DAX. The backend's
`ftruncate()`-based sizing also assumes a regular file.

Device DAX exposes `/dev/daxX.Y` as a character device and supports direct
mapping without a filesystem. It has strict alignment and fixed-capacity
semantics, so supporting it would require a separate backend that does not
create, truncate, or resize its path.

References:

- [Linux `mmap(2)` and `MAP_SYNC`](https://man7.org/linux/man-pages/man2/mmap.2.html)
- [ndctl namespace modes](https://pmem.io/ndctl/ndctl/ndctl-create-namespace.html)
- [Linux filesystem DAX configuration](https://docs.kernel.org/filesystems/dax.html)

## Recommended setup: QEMU NVDIMM

QEMU can map a host file into an x86-64 guest as an ACPI NVDIMM. With the
guest's `libnvdimm` and PMEM drivers loaded, Linux discovers the emulated
capacity and can expose it as `/dev/pmem0`.

### Prerequisites

The host needs:

- `qemu-system-x86_64`;
- an x86-64 Linux guest image; and
- enough disk and memory for the guest and NVDIMM backing file.

The guest needs a kernel with ACPI NFIT, libnvdimm, PMEM block-device, DAX,
and filesystem-DAX support, plus `ndctl` and ext4 or XFS administration tools.
Distribution kernels commonly build these facilities as modules.

On an x86-64 Linux host, use KVM and a host CPU model when available. On an
Apple-silicon Mac, use QEMU's x86-64 TCG emulation and a QEMU CPU model; this
is slower but sufficient for a small functional test.

### Create the virtual NVDIMM

Create a dedicated backing file:

```bash
truncate -s 4G /path/to/wizard-pmem.img
```

A representative QEMU memory/device configuration is:

```text
-machine pc,nvdimm=on
-m 4G,slots=2,maxmem=8G
-object memory-backend-file,id=pmem0,share=on,mem-path=/path/to/wizard-pmem.img,size=4G,align=128M,pmem=off
-device nvdimm,id=nvdimm0,memdev=pmem0,label-size=2M
```

Merge these values into any existing `-machine` and `-m` options rather than
specifying those options twice.

Use `-accel kvm -cpu host` on a compatible Linux host or
`-accel tcg -cpu max` when cross-architecture emulation is required.

Keep `pmem=off` when the backing file is on ordinary storage. QEMU warns that
claiming `pmem=on` for a non-DAX or non-persistent host file can lead to data
loss or corruption after a host crash. The guest still receives an emulated
NVDIMM with `pmem=off`; the setting only avoids claiming host persistence
semantics that the backing file cannot provide.

References:

- [Linux NVDIMM QEMU simulation guide](https://nvdimm.docs.kernel.org/pmem_in_qemu.html)
- [QEMU NVDIMM ACPI interface](https://www.qemu.org/docs/master/specs/acpi_nvdimm.html)
- [QEMU warning for non-persistent backing with `pmem=on`](https://www.qemu.org/docs/master/about/deprecated.html#using-non-persistent-backing-file-with-pmem-on-since-6-1)

### Configure filesystem DAX in the guest

First inspect what the guest discovered:

```bash
sudo ndctl list --regions --namespaces
lsblk
```

Create a new fsdax namespace from available capacity:

```bash
sudo ndctl create-namespace --force --mode=fsdax --map=mem
```

QEMU configurations without a usable label area may initially expose a raw
namespace. On a disposable, first-time setup, reconfigure it:

```bash
sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=fsdax --map=mem
```

Reconfiguring a namespace destroys its existing namespace contents. Confirm
the namespace name with `ndctl list` and use this command only on the
dedicated test device.

The resulting JSON reports a block device, normally `pmem0`. Create and mount
a filesystem with DAX enabled:

```bash
sudo mkfs.ext4 -F -b 4096 /dev/pmem0
sudo mkdir -p /mnt/pmem
sudo mount -o dax=always /dev/pmem0 /mnt/pmem
sudo touch /mnt/pmem/wizard-region
```

Use the regular-file path `/mnt/pmem/wizard-region` with
`X86_64PWNVRegion`, `X86_64ImmixPWNVRegion`, or
`X86_64Backends.getPersistent()`. A successful
`PmemMmapBackend.create()` is the definitive project-level check that the
file accepts `MAP_SYNC`.

## Available real-PMEM host: magpie

The ANU School of Computing research server `magpie` was inspected on
2026-08-12 and is the current target for the opt-in Stage 1 run. Its observed
configuration is:

| Namespace | Mode | PFN map | Alignment | Block device | Filesystem mount |
|---|---|---|---:|---|---|
| `namespace0.0` | `fsdax` | `dev` | 2 MiB | `/dev/pmem0` | ext4 at `/mnt/pmem0.0`, `rw,relatime,dax=always` |
| `namespace1.0` | `fsdax` | `dev` | 2 MiB | `/dev/pmem1` | ext4 at `/mnt/pmem1.0`, `rw,relatime,dax=always` |

Both namespaces report 799,063,146,496 usable bytes and 512-byte sectors, and
the host reports `x86_64`. Here `"map":"dev"` means that the namespace's PFN
metadata resides on the PMEM device; it does **not** mean device-DAX. The
decisive field is `"mode":"fsdax"`, which is compatible with this project's
regular-file backend.

The persistence-profile audit recorded on 2026-08-12 is:

| Check | Observed result | Status |
|---|---|---|
| Architecture | `x86_64` | Matches the baseline |
| Cache coherency line | 64 bytes for L1 data, L1 instruction, L2 unified, and L3 unified caches | Matches the 64-byte production precondition |
| Cache writeback instructions | CPU flags include `clflush`, `clflushopt`, and `clwb` | `CLWB` baseline supported |
| Region persistence domain | `region0` and `region1` both report `memory_controller` | Matches the selected ADR model; this is not eADR |
| DIMM health/shutdown state | `ndctl list -DH` could not open `/dev/nmem*`; every health state was therefore `unknown` | Pending an administrator-privileged query |
| `MAP_SYNC` on an assigned test file | Not yet run | Pending an assigned writable directory |
| Emitted `CLWB`/`SFENCE` instructions | Backend functions remain placeholders | Pending backend implementation and disassembly/tracing |

The topology, cache geometry, and CPU flags are readable without elevated
privileges. The health query requires an administrator to run
`ndctl list -DH` or grant the necessary read access; `unknown` in the captured
output is a permission-limited result, not evidence of unhealthy media.

Use only a writable scratch directory explicitly assigned by the server
administrator. Do not pass `/dev/pmem0`, `/dev/pmem1`, either mount root, or an
existing region file to the test, and do not format, reconfigure, disable, or
unmount either namespace. The current test has a 4 MiB peak region file; up to
1 GiB of scratch space provides headroom for planned multi-image crash tests
and retained traces. A positive hardware run remains pending assignment of
that directory.

## Alternative: reserve native Linux DRAM

On an x86-64 Linux machine without NVDIMM hardware, the kernel parameter

```text
memmap=<size>!<physical-start>
```

marks an existing physical RAM range as type-12 persistent memory. With the
legacy PMEM and DAX drivers available, Linux exposes the reserved range as
`/dev/pmem0`. It can then be formatted, mounted with filesystem DAX, and used
through a regular file exactly like the QEMU device.

This approach requires root access, a bootloader change, and a reboot. The
physical range must be fully contained in a usable RAM entry from the
firmware memory map. An incorrect range can overlap firmware, kernel, or
device memory and prevent the system from booting correctly. Follow the
kernel guide to derive the address from `dmesg` rather than copying an example
address:

- [Kernel `memmap` parameter](https://docs.kernel.org/admin-guide/kernel-parameters.html)
- [Choosing a PMEM `memmap` range](https://nvdimm.docs.kernel.org/memmap_kernel_params.html)

Reserved DRAM remains volatile. This setup is suitable for DAX API and
software-recovery experiments, not power-loss validation. QEMU is preferred
for this project because it is isolated, repeatable, and does not alter the
host boot configuration.

## Validation stages

The PMEM stages are the outer parts of the project's layered correctness
argument. They do not replace deterministic WAL protocol testing:

```text
abstract shadow durable-memory model
  → store/CLWB/SFENCE trace exploration
    → backend syscall/instruction integration
      → abrupt process/guest crash recovery
        → physical-media power-loss durability
```

The complete layer definitions and their evidence boundaries are documented in
`docs/persistent-backends.md`.

### Stage 0 — deterministic protocol models

#### Stage 0a — abstract persistence-boundary model

The direct active-`DualTxnWal` tests now use a test-only shadow durable-memory
backend. It keeps separate live and durable byte arrays, makes
`persistRange`/`persistChanges` copy into the durable shadow, restores live
bytes from that shadow on simulated crash, and injects fail-before-copy,
copy-then-fail and partial-copy outcomes. The `DualTxnWal` commit and recovery
paths now latch persistence failures, reject further same-instance work, and
require a fresh instance to recover. Fresh initialization, after-image
preparation, flush, close, transaction-facade, and allocator propagation are
covered as well. The remaining Stage-0a work is a `ShadowTxnBackend` factory
for complete allocator transactions.

Stage 0a answers whether the WAL is correct under the abstract `BackendRegion`
persistence contract. It is fast, deterministic and suitable for the default
unit suite. It cannot establish that `MAP_SYNC`, cache-line write-back
instructions, Linux, QEMU or physical media implement that contract; those are
the purposes of Stages 1–3.

#### Stage 0b — store/CLWB/SFENCE trace exploration

The current shadow model deliberately makes ordinary stores live-only and
copies prepared ranges at an abstract persistence call. A more faithful PMEM
model must also allow dirty cache lines to be written back without `CLWB`, a
`CLWB` to complete immediately or later, arbitrary permitted subsets of lines
to survive before a fence, and an `SFENCE` to complete the earlier writebacks
on which the protocol relies.

The first code milestone now records the production `DualTxnWal` ordering of
persistent `STORE`, `CLWB`, and `SFENCE` actions through a per-region operation
provider. It covers record construction, after-image apply/replay, slot scrub,
and PMEM range/fence translation on ordinary memory. The remaining work explores every distinct durable image
for short bounded scenarios, and invokes the real WAL/allocator recovery code
against each image. An ordinary file or byte array is sufficient because the
simulator—not DAX or the host page cache—defines durability. Exhaustive short
scenarios should be supplemented, not replaced, by seeded randomized schedules
for longer allocator histories. See
[PMEM Crash Model](pmem-crash-model.md) for the event semantics, explicit
hardware assumptions, state-space reductions, recovery integration, and
evidence limits.

The current recorder does not model durable bytes, eviction, asynchronous
writeback completion, crash cuts, or recovery schedules. Stage 0b also cannot
prove that the compiler and native backend emit the intended instructions.
Instruction tracing and DAX/hardware integration remain separate validation
layers.

### Stage 1 — DAX and recovery integration

The opt-in `PmemDaxIntegrationTest.v3` proves that the intended Linux
interface and the current backend are connected correctly:

- the host exposes an fsdax block device;
- a file on the mounted filesystem accepts `MAP_SYNC`;
- `PmemMmapBackend.create()` formats and maps the requested region;
- allocation and transaction commits work through `X86_64PWNVRegion`; and
- a clean close and remount preserve allocator state; and
- a controlled reopen with a committed record exercises WAL replay.

Run it on the prepared x86-64 Linux machine with an assigned writable scratch
directory on the fsdax mount:

```bash
make pmem-integration PWASM_PMEM_TEST_DIR=/mnt/pmem/assigned-directory
```

The target builds a separate `bin/pmemtest.x86-64-linux` binary. Its two tests
are not registered in the default unit suite or run by CI. The runner never
unlinks a caller-selected filename: it atomically reserves a new `0600` file in
the supplied directory using `O_CREAT|O_EXCL`, adds the UID, PID, and a bounded
collision suffix to its name, and removes only that file after a normal run.
An interrupted runner may leave a clearly named `wizard-pmem-*.region` artifact
for later manual cleanup, but a subsequent run will not overwrite it. A
directory on an ordinary filesystem is expected to fail at
`PmemMmapBackend.create()` because the backend has no non-`MAP_SYNC` fallback.

The existing `txn_backend:pmem_region_tracks_pending_writeback` unit test does
not provide this coverage. It wraps an anonymous `Mmap.reserve()` mapping
directly in `PmemMmapRegion`, bypassing `PmemMmapBackend.create()`,
`MAP_SYNC`, filesystem DAX, and `/dev/pmem0`.

This stage establishes functional DAX mapping, clean remount, and software WAL
replay. Because `flushCacheLine()` and `storeFence()` are still placeholders,
it does not establish cache-line persistence or host power-loss durability.

### Stage 2 — guest crash and restart testing

After Stage 1, automate interruption at WAL protocol boundaries, then reopen
the same region file and check allocator and WAL invariants. Useful scenarios
include:

- process termination after the log record is committed but before all
  after-images are applied;
- termination after apply but before the next piggybacked persistence
  boundary; and
- guest reset or QEMU restart with the same NVDIMM backing file.

These experiments strengthen evidence for software crash consistency. They
do not prove survival of host power loss: QEMU's fake NVDIMM is backed by
ordinary host storage, and host caching or emulator behavior can differ from
physical PMEM. The analogous file-backend experiment should use a child writer
terminated with `_exit`/`SIGKILL` at the same WAL boundaries and a separate
verifier process. Neither experiment substitutes for the deterministic
fail-before/fail-after/torn outcomes in Stage 0.

### Stage 3 — real PMEM durability

Final durability validation requires a machine with real persistent memory,
an fsdax namespace, and controlled crash or power-interruption experiments.
It must also wait until `MmapRegionUtils.flushCacheLine()` and `storeFence()`
emit real `CLWB`/`CLFLUSHOPT`/`CLFLUSH` and `SFENCE` instructions.

Those functions are currently no-op placeholders. Until they are
implemented, neither QEMU nor physical hardware can make the project's PMEM
persist operations correct: the environment may support DAX and `MAP_SYNC`,
but the process does not issue the cache write-back and ordering instructions
needed by its own persistence protocol.

## Alternatives not selected

| Approach | Why it is not the primary workflow |
|---|---|
| Ordinary file or tmpfs | No filesystem DAX; `MAP_SYNC` should fail with `EOPNOTSUPP` |
| QEMU virtio-pmem | Persists through `fsync()`/`msync()` but explicitly does not support `MAP_SYNC`; it matches file-backend semantics, not `PmemMmapBackend` |
| `/dev/daxX.Y` | Direct DAX mapping is possible, but the current backend's regular-file sizing and alignment assumptions do not fit |
| Kernel `nfit_test` | A libnvdimm/ACPI NFIT unit-test module, not a stable application development environment |
| Native `memmap` | Valid alternative, but invasive and less reproducible than a disposable VM |

See the [QEMU virtio-pmem documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-pmem.html)
and [Linux libnvdimm test-device documentation](https://docs.kernel.org/driver-api/nvdimm/nvdimm.html)
for the rejected virtual-device alternatives.
