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

### Scripted workflow

`scripts/pmem-vm.sh` performs this entire setup, and the guest configuration
in the sections below, on any supported host:

```bash
scripts/pmem-vm.sh doctor   # report host support and missing host tools
scripts/pmem-vm.sh setup    # one-time: fetch image, make VM, set up DAX
scripts/pmem-vm.sh sync     # rebuild bin/pmemtest.x86-64-linux and copy it in
scripts/pmem-vm.sh test     # run the integration tests in the guest
scripts/pmem-vm.sh stop     # clean shutdown; `start` resumes where it left off
```

`setup` is idempotent and reformats nothing that already holds a filesystem.
The VM is stored outside the repository, by default in
`~/.local/share/wizard-pmem-vm`; `PMEMVM_DIR` relocates it, and
`PMEMVM_SSH_PORT` allows more than one VM on a host. `kill` terminates QEMU
abruptly for the Stage 2 experiments, `console` tails the guest boot log, and
`destroy` removes the VM directory after confirmation.

`reseed` rebuilds the cloud-init seed and reboots into it, which is the repair
for a VM that boots but never answers ssh. Two first-boot faults produce that,
both observed on the Ubuntu 24.04 cloud image with cloud-init 26.1:

- **No sshd host keys.** The image ships without them and cloud-init writes them
  part way through the boot. Under emulation the first connection arrives
  earlier, the socket-activated `ssh.service` exits with `sshd: no hostkeys
  available`, and systemd allows a unit only five restarts before it stops
  trying -- so sshd stays down for the rest of that boot however long the host
  waits.
- **No sudo for the guest user.** cloud-init left
  `/etc/sudoers.d/90-cloud-init-users` empty, so `sudo -l -U ubuntu` reported
  the user was not allowed to run sudo at all. A clean first boot of the same
  seed has since written that file correctly, so this is a first-boot race
  rather than a certainty -- but the users module runs once per instance, so a
  VM that lands wrong never repairs itself, and provisioning is all `sudo`
  (`ndctl`, `mkfs`, `mount`).

The seed's `bootcmd` closes both, and runs on every boot rather than once per
instance, so `reseed` repairs an existing VM without a fresh `setup`. Nothing in
it may block on a systemd job: `bootcmd` runs inside `cloud-init.service`, which
`sysinit.target` waits for, so a plain `systemctl start` deadlocks the boot --
use `--no-block`. `start` and `setup` now stop waiting a few minutes
(`PMEMVM_LOGIN_GRACE`) after the guest reaches its login prompt and report the
fault, rather than sitting out the full emulated-boot timeout.

The guest is always x86-64 Linux, because the backend under test is
x86-64-specific. Only the acceleration differs by host:

| Host | Acceleration | Notes |
|---|---|---|
| x86-64 Linux, including WSL2 | KVM | Requires `/dev/kvm` access; add the user to the `kvm` group. WSL2 needs nested virtualization, which recent WSL2 kernels enable on Intel hosts |
| Intel Mac | HVF | Guest and host architectures match |
| Apple-silicon Mac | TCG | Whole-CPU emulation of a foreign architecture: correct, but boots take minutes rather than seconds. The script raises its own boot timeout accordingly |

Building the test binary is a separate concern from running it. The binary is
statically linked and needs no toolchain inside the guest, but the Virgil
compiler must run on the host and emit an x86-64 Linux ELF. The Virgil
distribution ships x86-64 macOS binaries, so on Apple silicon `v3c` requires
Rosetta 2 (`softwareupdate --install-rosetta`). Where that is unavailable,
build `bin/pmemtest.x86-64-linux` on another machine and copy it to the
guest's home directory; `scripts/pmem-vm.sh test` then runs it unchanged.

Reserving DRAM with the Linux `memmap` parameter is not an option under WSL2:
its kernel is built without `CONFIG_X86_PMEM_LEGACY`, so a type-12 range would
have no driver, and Hyper-V exposes no NFIT table to the WSL2 VM. Keep the
NVDIMM backing file on a native Linux filesystem inside WSL2 rather than on a
Windows drive mounted through `/mnt/c`.

The remaining sections document what the script automates, and are the
reference for doing it by hand or diagnosing a failure.

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

Drop the `pmem=` parameter entirely on a QEMU that was not built against
libpmem (PMDK). The property is registered only under `CONFIG_LIBPMEM`, and
PMDK is Linux-only, so Homebrew's macOS QEMU rejects the whole `-object`
argument with `Invalid parameter 'pmem'` rather than ignoring the unknown
setting. Omitting it is equivalent to `pmem=off`: such a build has no
`pmem_persist` to call and flushes the backing file with `msync`. Check with

```text
qemu-system-x86_64 -machine none -object memory-backend-file,help | grep pmem=
```

`scripts/pmem-vm.sh` performs this probe itself and reports the result in
`doctor` output; the emulated NVDIMM and its NFIT table reach the guest either
way.

References:

- [Linux NVDIMM QEMU simulation guide](https://nvdimm.docs.kernel.org/pmem_in_qemu.html)
- [QEMU NVDIMM ACPI interface](https://www.qemu.org/docs/master/specs/acpi_nvdimm.html)
- [QEMU warning for non-persistent backing with `pmem=on`](https://www.qemu.org/docs/master/about/deprecated.html#using-non-persistent-backing-file-with-pmem-on-since-6-1)

### Configure filesystem DAX in the guest

Confirm first that the guest kernel actually provides the PMEM block-device
and DAX drivers. Minimal guest kernels frequently do not: an Ubuntu cloud
image installs `linux-image-virtual`, whose base module set omits `nd_pmem`
and `dax_pmem`. Those drivers ship in `linux-modules-extra`. Without them the
guest still loads `nfit` and reports `region0`, but no namespace can be
enabled and `/dev/pmem0` never appears:

```text
libndctl: ndctl_namespace_enable: namespace0.0: failed to enable
  Error: namespace0.0: failed to enable
```

A follow-up `ndctl create-namespace` then fails with `No space left on
device`, which is a consequence rather than a second fault: the existing
disabled namespace already claims the whole region, so no capacity remains to
carve. `modprobe nd_pmem` reporting `Module nd_pmem not found` confirms the
diagnosis. Install the drivers for the running kernel and enable the
namespace:

```bash
sudo apt-get install -y linux-modules-extra-$(uname -r) linux-image-generic
sudo modprobe nd_pmem dax_pmem
sudo ndctl enable-namespace namespace0.0
```

`linux-modules-extra` is pinned to an exact kernel version, so the drivers
disappear again the first time unattended upgrades install a new kernel and
the guest reboots into it. Installing the `linux-image-generic` meta package
prevents the recurrence: it depends on the matching
`linux-modules-extra-<version>-generic` and therefore pulls the NVDIMM
drivers forward across future kernel upgrades. The cloud image's
`linux-image-virtual` does not. Once the modules are present for the running
kernel, `nfit` autoloads them on later boots and any `/etc/fstab` entry for
the DAX mount succeeds.

A guest that boots with the drivers missing is easy to misdiagnose, because a
bare `ndctl list` reports only enabled namespaces and therefore prints
nothing at all. Query the idle ones explicitly, and read the result
carefully:

```bash
sudo ndctl list -Nu --idle
```

With no driver bound, this reports the namespace as `"mode":"raw"` with a
freshly generated UUID. That is a synthesized fallback view, not evidence of
lost configuration: the namespace labels live on the device and are still
intact, and the previously configured `fsdax` namespace reappears with its
original UUID as soon as `nd_pmem` loads. Do not run `mkfs` while
diagnosing a missing `/dev/pmem0`; the filesystem is almost certainly
unharmed behind an unbound driver, and reformatting would destroy it. The
recovery sequence is:

```bash
sudo ndctl list -Nu --idle      # namespace state: disabled?
modprobe nd_pmem                # "Module not found" confirms the cause
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo modprobe nd_pmem
sudo mount -a                   # an fstab entry does the rest
```

Then inspect what the guest discovered:

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
2026-08-12, successfully ran the opt-in Stage 1 integration on 2026-08-31, and
ran the Stage 2 abrupt-termination crash loop over the resumable sieve on
2026-09-01. Its observed configuration is:

| Namespace | Mode | PFN map | Alignment | Block device | Filesystem mount |
|---|---|---|---:|---|---|
| `namespace0.0` | `fsdax` | `dev` | 2 MiB | `/dev/pmem0` | ext4 at `/mnt/pmem0.0`, `rw,relatime,dax=always` |
| `namespace1.0` | `fsdax` | `dev` | 2 MiB | `/dev/pmem1` | ext4 at `/mnt/pmem1.0`, `rw,relatime,dax=always` |

Both namespaces report 799,063,146,496 usable bytes and 512-byte sectors, and
the host reports `x86_64`. Here `"map":"dev"` means that the namespace's PFN
metadata resides on the PMEM device; it does **not** mean device-DAX. The
decisive field is `"mode":"fsdax"`, which is compatible with this project's
regular-file backend.

The persistence-profile audit recorded on 2026-08-12 and updated by the
2026-08-31 integration, the 2026-09-01 crash-loop run, and the
administrator-privileged DIMM health query of 2026-09-01 is:

| Check | Observed result | Status |
|---|---|---|
| Architecture | `x86_64` | Matches the baseline |
| Cache coherency line | 64 bytes for L1 data, L1 instruction, L2 unified, and L3 unified caches | Matches the 64-byte production precondition |
| Cache writeback instructions | CPU flags include `clflush`, `clflushopt`, and `clwb` | `CLWB` baseline supported |
| Region persistence domain | `region0` and `region1` both report `memory_controller` | Matches the selected ADR model; this is not eADR |
| DIMM health/shutdown state | `sudo ndctl list -DH` on 2026-09-01: all 12 DIMMs (`nmem0`-`nmem11`) report `health_state: ok`, `shutdown_state: clean`, `shutdown_count: 0`, 100% spares against a 50% threshold, no alarms, and media/controller temperatures of 29-35 °C / 31-38 °C against 82 °C / 98 °C thresholds | Healthy media; no dirty shutdown has ever occurred on this host, so the failure class the crash model excludes has not been entered |
| `MAP_SYNC` on an assigned test file | `pmem_dax:backend_accepts_map_sync` passed under `/mnt/pmem0.0/sean` | Production fsdax path confirmed |
| Emitted `CLWB`/`SFENCE` instructions | Exact encoding and native production-path smoke tests passed on Magpie before the DAX run | Physical-target execution confirmed; power-loss persistence remains untested |
| `MAP_SYNC` under a resumable workload | `make pwsieve-pmem` mapped `/mnt/pmem0.0/sean` and asserted a `PmemMmapRegion`, not its `FileMmapRegion` sibling | No silent fallback to an ordinary shared mapping |
| WAL protocol under abrupt termination on DAX media | 13 `SIGKILL` restarts, every one reporting `DualWalRecovery.REPLAYED`; workload invariants held after each; 376,256 primes below 5,429,504 matched an independent sieve | Software crash consistency on physical PMEM |
| Correct *placement* of `CLWB`/`SFENCE` | Not discriminated by any run to date — see the note below | Requires Stage 3 power interruption |

### What the 2026-09-01 crash loop does and does not discriminate

`make pwsieve-pmem` ran 13 iterations at 512 x 4096 = 2 MiB before the sieve's
167-segment descriptor table filled. Every restart replayed a WAL record rather
than finding a clean log, so every kill landed mid-transaction; the workload's
cross-object invariants held after each recovery; progress never went backwards;
three leaked extents were reclaimed at mount, the alloc-then-publish leak
appearing on physical media exactly as it does on a file; and the durable answer
matched an independent in-process sieve. The same geometry on the file backend
reaches the identical 5,429,504 / 376,256 result, so the two backends agree.

**This run is not sensitive to where the flushes are.** On a `MAP_SYNC` DAX
mapping the memory *is* the media, so when the child is killed its dirty cache
lines are still in the CPU's caches and the CPU keeps running: nothing is lost,
and the lines reach the DIMM through ordinary cache pressure or a later flush.
Removing every `CLWB` from the persist path would leave this test still
reporting `OK`. Since `region0`/`region1` report `memory_controller` — ADR, not
eADR — ADR drains the memory controller's write-pending queue but **not** the CPU
caches, so only a real power interruption can lose an un-written-back line and
thereby discriminate a correct `CLWB` from a missing one.

That sentence used to read "would *very likely* leave this test still reporting
`OK`", which was an assertion about the experiment's own blind spot with nothing
behind it. It is now measured; see
[the flush-placement negative control](#flush-placement-negative-control) below
for what has been run and what has not.

What this run therefore establishes is that the production writeback/fence path
executes against real PMEM without corrupting anything, and that the WAL
protocol and the workload's invariants survive abrupt process termination on
physical DAX media. It does not establish that the flushes are correctly placed.

That sensitivity is what layer 1b supplies instead: `PersistentExplorer`
enumerates the durable images a crash permits *given* the recorded
`STORE`/`CLWB`/`SFENCE` order, so a missing or misplaced flush shows up there as
an enumerated image that production recovery cannot repair. The model is
sensitive where this hardware test is not, and the hardware test executes the
real instructions where the model only assumes them. Neither alone closes
Stage 3.

### Flush-placement negative control

The layering claim above — that the hardware run cannot discriminate flush
placement and the layer-1b explorer can — is measured with an elided-writeback
mutant: a `PersistentOperations` provider whose `clwb()` does nothing, with
stores and `SFENCE` untouched, so a commit still returns success and the
transaction is still acknowledged. It is installed by wrapping the real backend
(`ElidedWritebackBackend`, `test/unittest/x86-64-linux/ElidedWritebackOps.v3`),
so the production `PmemMmapBackend` still opens the real file and takes the real
`MAP_SYNC` mapping and only the provider differs. The swap happens inside
`create()` because `PWRegion` and `DualTxnWal` each resolve their provider once
at construction; installing it later would elide the data-range writebacks and
leave the log's intact.

|  | Magpie crash loop (layer 3) | Explorer sweep (layer 1b) |
|---|---|---|
| Ordinary build | `OK` (2026-09-01) | property holds |
| Elided-writeback mutant | **not yet run** | **counterexample** |

**Model half — done.** The four `persistent_control:` unit tests record the same
sieve `step()` as `persistent_sieve:step_images_satisfy_sieve` and sweep it with
the same `PersistentSieveProperty`, changing only the provider. The mutant trace
is still modelable (it validates against the baseline), carries zero `CLWB`
events while its `STORE` and `SFENCE` counts match the ordinary recording
exactly, and is rejected: a crash 710 events into a 1401-event scenario leaves a
durable image whose *allocator* invariants already fail, with `free block is on
the wrong list (block 4)`. The ordinary provider holds over every cut of the
same scenario. So the model is sensitive to flush placement, and sensitive
enough that the structural check alone catches it without the workload's
cross-object invariants being reached.

**Hardware half — outstanding.** `make pwsieve-pmem-mutant` runs the identical
crash loop with `elide-clwb` appended, gated on `PWASM_PMEM_TEST_DIR` exactly as
`pwsieve-pmem` is. Until that has run on Magpie, the prediction in the top of
this section is still a prediction. A mutant run that *failed* there would be
the more interesting result: it would mean the hardware test is more sensitive
than this document claims, and the surrounding argument would need rewriting
rather than confirming.

The mutant is deliberately vacuous on the file backend: `FileMmapRegion` never
calls `clwb()` at all, since its persist path is `msync`/`fdatasync`. A
file-backed mutant run therefore exercises the wiring and nothing else, and must
not be reported as a result. That the same mutation is meaningful on one backend
and empty on the other is itself an instance of the granularity difference the
unified interface hides.

The topology, cache geometry, and CPU flags are readable without elevated
privileges. The health query is not: `/dev/nmem*` is root-only, so the
2026-08-12 audit recorded every health field as `unknown` — a permission limit,
not evidence of unhealthy media. An administrator ran `sudo ndctl list -DH` on
2026-09-01, and the result is the table row above: twelve Intel DIMMs
(`nmem0`-`nmem5` on socket 0, `nmem6`-`nmem11` on socket 1, six per socket
across `region0` and `region1`), all healthy, all with a dirty-shutdown count
of zero. Every DIMM backing both namespaces is covered, so the audit has no
gaps.

That reading also establishes the Stage 3 control. The dirty-shutdown counter
increments when a module loses power without completing its buffer flush — that
is, precisely when ADR did *not* work as advertised, which is the failure class
the crash model excludes (see `docs/pmem-crash-model.md`). It reads `0` on every
DIMM now, so after a power interruption it discriminates directly: still
`clean`/`0` means ADR completed, the run is inside the model, and any recovery
failure is a real protocol or flush-placement defect; `dirty` or a raised count
means ADR did not complete, the run falls outside the baseline, and it is not
evidence about the WAL in either direction. Without that pre-run zero a single
Stage 3 failure would be uninterpretable. Stage 3 should therefore capture
`ndctl list -DH` immediately before and after every interruption, which needs
either an administrator present for each run or a standing read grant on
`/dev/nmem*`. The exact dirty-shutdown-count semantics should be pinned against
the vendor's documentation before the campaign, since this counter becomes the
discriminator.

Use only a writable scratch directory explicitly assigned by the server
administrator. Do not pass `/dev/pmem0`, `/dev/pmem1`, either mount root, or an
existing region file to the test, and do not format, reconfigure, disable, or
unmount either namespace. The Stage 1 integration has a 4 MiB peak region file
and the crash loop a 2 MiB one; up to 1 GiB of scratch space provides headroom
for planned multi-image crash tests and retained traces. `/mnt/pmem0.0/sean` is
the assigned directory; the runners may create and remove only their own
`wizard-pmem-*.region` and `wizard-pwsieve-*.region` files there. Both reserve a
uniquely named file with `O_CREAT|O_EXCL` and remove only that file; a failed
crash-loop run deliberately keeps its region image and prints the path, so an
occasional `wizard-pwsieve-*.region` artifact is evidence awaiting inspection
rather than litter, and no run will overwrite it.

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

Reserved DRAM remains volatile, so this setup cannot establish power-loss
durability. It does, however, have one property neither QEMU nor a shared PMEM
host provides: the reserved range survives a warm reboot while the CPU caches do
not, which makes flush *placement* observable. Stage 2c below is built on
exactly that. For ordinary DAX API and software-recovery work QEMU remains
preferred, being isolated, repeatable, and free of host boot configuration
changes.

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
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean make pmem-integration
```

This exact command passed both `pmem_dax:backend_accepts_map_sync` and
`pmem_dax:clean_remount_and_wal_replay` on Magpie on 2026-08-31. The native
instruction encoding and production-path smoke tests also passed on that host
before the DAX suite.

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

The successful Magpie run establishes functional DAX mapping, execution of the
native writeback/fence path against a real PMEM mapping, clean remount, and
software WAL replay. It is still a controlled same-host reopen: it does not
establish survival of abrupt process termination, host reset, or power loss.

### Stage 2 — abrupt termination on physical PMEM (done, 2026-09-01)

The resumable-sieve crash loop runs over the production PMEM backend:

```bash
PWASM_PMEM_TEST_DIR=/mnt/pmem0.0/sean make pwsieve-pmem
```

A child forks, mounts the region with `MAP_SYNC`, and sieves while the parent
sleeps a seeded pseudo-random 50 us - 20 ms interval and sends `SIGKILL`; the
parent then remounts from a fresh mapping, runs production WAL recovery, lets
`PWSieve` reattach through the durable root, and checks its cross-object
invariants and that progress never went backwards. The backend is named
explicitly rather than inferred from the path, an unrecognised mode is rejected
instead of defaulted, and the run asserts it received a `PmemMmapRegion` and not
its `FileMmapRegion` sibling before doing any work — so a silent fallback to an
ordinary shared mapping cannot be reported as a PMEM result. Because
`PmemMmapBackend.create()` has no non-`MAP_SYNC` mapping mode, a run that starts
at all is a run on filesystem DAX.

This command passed on Magpie on 2026-09-01: 13 iterations at 512 x 4096 = 2 MiB
before the sieve's 167-segment descriptor table filled, every restart reporting
`DualWalRecovery.REPLAYED`, invariants holding after each recovery, three leaked
extents reclaimed at mount, and 376,256 primes below 5,429,504 matching an
independent in-process sieve. See the discrimination note in the Magpie section
above: this establishes software crash consistency on physical media and clean
execution of the production writeback/fence path, but it is **not** sensitive to
whether the `CLWB`s are correctly placed, because killing a process on a DAX
mapping loses nothing that is still in cache.

### Stage 2b — guest crash and restart testing

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

### Stage 2c — cache-loss sensitivity on reserved DRAM

Stage 2 runs on real media but cannot lose a cache line; Stage 3 can lose one
but is unavailable. This stage takes the remaining combination: a real CPU cache
that is really discarded, over media that is only a stand-in.

On a machine reserved with `memmap=<size>!<start>` (see the alternative above),
the two properties that matter are:

- reserved DRAM **survives a warm reboot**, because power is never removed; and
- a CPU RESET **invalidates caches without writing them back**.

So a line stored and never written back is lost across
`echo b > /proc/sysrq-trigger`, while a line that was `CLWB`-ed and fenced
survives. That is exactly the discrimination the Stage 2 crash loop lacks, and
it needs no privileged access to a shared host. It must be a physical machine:
a guest reset does not reset the host CPU, so a VM's dirty lines are never lost,
which is the same reason QEMU guest reset is useless for this.

What it does **not** establish: the DRAM is volatile, ADR is not involved, and a
true power cycle erases the range entirely. This is cache-loss sensitivity on a
DAX-API-faithful stand-in, not physical durability. It narrows the Stage 3 gap
to the media and the firmware persistence domain; it does not close it.

**The negative control is also the validity check.** Run the ordinary build and
the elided-writeback mutant (see the flush-placement negative control in
`docs/ROADMAP.md`) through the same reboot experiment:

| Outcome | Reading |
|---|---|
| Mutant loses data, ordinary build recovers | The experiment discriminates. Flush placement is confirmed against real cache loss |
| Both recover | The experiment has no sensitivity on this host — firmware flushed caches on reset, or ordinary eviction wrote the lines back before the reset landed. A cheap negative result, reportable as such |
| Ordinary build loses data | A real defect in flush placement, or the reservation is not surviving reboot; distinguish by checking whether a known-flushed control value also vanished |

This matters because the honest caveats are real: some firmware zeroes or
retrains memory on reboot, some flushes caches on reset, and incidental eviction
during the reboot path can write lines back regardless. The mutant detects every
one of those as "no sensitivity", so the experiment never rests on an
unverifiable claim about what a warm reset does.

Prerequisite: root on a physical x86-64 Linux host that can be rebooted freely,
which means a Linux installation on a machine outside the shared infrastructure.
**A suitable bare-metal host was confirmed available on 2026-09-18**, so this
stage is in scope for the Honours thesis, timeboxed to the 2026-10-02 code
freeze: if it is not producing a reading by then it is dropped, and the
flush-placement negative control stands as the sole evidence for flush
placement. Tracked in `docs/ROADMAP.md`; scope in [Honours Thesis](THESIS.md).

### Stage 3 — real PMEM durability

Final durability validation requires a machine with real persistent memory,
an fsdax namespace, and controlled crash or power-interruption experiments.
`MmapRegionUtils.flushCacheLine()` and `storeFence()` now emit the required
CPUID-selected cache writeback and `SFENCE` instructions, so the remaining work
is to validate that production path and the persistence protocol on the
physical target.

#### Mechanism: what can actually lose a cache line

With a `memory_controller` (ADR) persistence domain, ADR drains the memory
controller's write-pending queue but not the CPU caches. The Stage 3 event is
therefore any event that loses cache contents, and every such event takes the
whole machine down.

**Not attainable on Magpie (assessed 2026-09-01).** Magpie carries concurrent
work from many users, so an interruption window is not available — and this is a
structural constraint, not a scheduling difficulty to be revisited. Physical
presence was never the blocker; a BMC-initiated power cycle would serve
perfectly well on a machine that could be taken down, and none of the mechanisms
below can be scoped to one process or one namespace. Stage 3 is therefore
recorded as an open limitation of this work rather than as pending work, and
Stage 2c above supplies the sensitivity it was there to supply. The mechanisms,
for a host where the event *is* available:

| Mechanism | Loses CPU caches? | Verdict |
|---|---|---|
| BMC hard power-off or power cycle (`ipmitool chassis power off`/`cycle`, or Redfish) | Yes — board power is removed and ADR fires | The practical Stage 3 mechanism. Unambiguous, remote, schedulable |
| `sysrq` reboot (`echo b > /proc/sysrq-trigger`), `kexec` | Firmware-dependent — the platform may run the ADR flow on a warm reset | Same disruption, ambiguous result. Not worth using when the window allows a real power cycle |
| QEMU guest reset / restart | No — the emulated NVDIMM is an ordinary host file and QEMU models no cache | Not a substitute at any strength. Useful only as further Stage 2 software-crash evidence |
| Any user-space action | No | Nothing reachable without root can discard a dirty line |

Nothing in software substitutes for the real event, which is the point of the
layering: layer 1b supplies sensitivity to flush *placement* by enumerating the
images a crash permits, and Stage 3 supplies the hardware that can actually
produce one. With Stage 3 unavailable, the correct response is to state the gap
precisely — the production instruction path is confirmed on physical media, the
placement is confirmed against the model and, via Stage 2c, against real cache
loss on volatile media — rather than to accumulate more Stage 2 runs, which are
insensitive to placement no matter how many are run.

Whichever mechanism is used, capture `sudo ndctl list -DH` immediately before and
after each interruption. The dirty-shutdown counter is baselined at `0` on every
DIMM (see the audit above), so an unchanged counter says ADR completed and the
run is inside the crash model, while a raised one says the run fell into the
excluded failure class and is not evidence about the WAL in either direction.

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
