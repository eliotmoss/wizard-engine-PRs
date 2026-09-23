# Stage 2c Hand-off: Warm-Reboot Cache-Loss Test

This page is the runbook for Stage 2c and the hand-off between machines. The
argument for the experiment is in [PMEM Emulation](pmem-emulation.md#stage-2c--cache-loss-sensitivity-on-reserved-dram);
its place in the thesis is in [Honours Thesis](THESIS.md). The code freeze and
the Stage 2c timebox are both **2026-10-02**. If Stage 2c is not producing a
reading by then, it is dropped and the flush-placement negative control stands
alone.

## Status (2026-09-23)

| Piece | State |
|---|---|
| `test/pwreboot.main.v3` — probe, setup, arm, verify | Built. Dry-run tested on WSL with the file backend. |
| `scripts/stage2c.sh` — operator script | Built. Dry-run tested on WSL. Guards tested: it refuses WSL, VMs, hosts without `memmap=`, non-DAX directories, a results directory on the DAX filesystem, a second armed run, and a verify in the same boot. |
| Verifier outcomes | Checked by editing images by hand: SURVIVED, LOST (steps rolled back, WAL corrupt), INVALID (header zeroed, file missing). The image is never reformatted. |
| Host setup on the Ubuntu dual boot | **Not started** |
| Any run on real hardware | **None yet** |

## The machines

| Machine | Role |
|---|---|
| This PC, Windows + WSL | Where the harness was written. It cannot run Stage 2c: a WSL guest reset never discards the host's cache. |
| This PC, booted into native Ubuntu | **The test host.** It reboots during every run, so do not run the controlling Claude session here. |
| Mac | **The control machine.** It runs Claude Code, pulls from GitHub, and can reach the Ubuntu boot over SSH on the ANU network once that is checked. |

Context moves between machines through this repository, not through chat
history. Claude's memory is per machine. Two things a new session needs to know:

- The user wants no `Co-Authored-By` Claude line in commits or PRs.
- Reboots are typed by hand for the first runs. A narrow passwordless `sudo`
  rule for the reboot was discussed and deferred; see
  [Optional: passwordless reboot](#optional-passwordless-reboot).

## What the experiment does

Reserved DRAM (`memmap=<size>!<start>`) survives a warm reboot, because power is
never removed. A CPU reset throws the cache away without writing it back. So a
line that was stored but never written back (`CLWB`) is lost, and a line that
was written back and fenced survives. Magpie's crash loop cannot tell these
apart, because killing a process never clears the cache.

There are two kinds of run.

**The probe** comes first and needs no allocator or WAL. It writes one file.
Even cache lines are stored, written back and fenced; odd lines are only
stored. Every line carries a per-run random value, so old contents cannot pass
as survivors. After the reboot:

| Probe verdict | Meaning |
|---|---|
| `SENSITIVE` | Flushed lines all survived and some unflushed lines were lost. The host can lose a cache line. Go on to the sieve runs. |
| `NOT-SENSITIVE` | Every line survived. The reset wrote the cache back, or the lines were evicted before it. The sieve runs cannot discriminate on this host. That is a reportable negative result, and the Stage 2c timebox should probably be invoked. |
| `INVALID` | Flushed lines were lost too. The reserved memory itself did not survive: the firmware cleared it, or the `memmap` range changed. |

The verifier also reports how many lost lines came back as zeros, and how many
were torn (partly old, partly new).

**The sieve runs** are the experiment itself: the negative control, run on
hardware that can lose a cache line.

1. `setup` formats a fresh region with the production provider, runs 2 sieve
   steps, and closes cleanly. This state is durable before the experiment
   starts, and it doubles as the flushed control.
2. `arm` remounts with either the production provider (`ordinary`) or the
   elided-writeback mutant (`elide-clwb`). It runs 3 more steps, recording each
   acknowledged step in a state file that is fsynced after every line. Then it
   exits **without closing**, as a crash would.
3. Reboot.
4. `verify` copies the raw image, checks the header before mounting anything,
   then mounts, recovers, and checks what survived. It checks that the
   acknowledged cursor was reached, that the allocator and sieve invariants
   hold, and that the prime count matches an independent sieve.

| Sieve verdicts | Reading |
|---|---|
| ordinary `SURVIVED`, mutant `LOST` | **The experiment discriminates.** Flush placement is confirmed against real cache loss. |
| both `SURVIVED` | No sensitivity on this host. The probe should already have said so. |
| ordinary `LOST` | A real flush-placement defect, or an invalid host. Compare with a probe run. |
| any `INVALID` | Setup's flushed state is gone, so the reserved memory did not survive. The run says nothing about flush placement. |

The mutant is expected to fail **differently from the explorer's
counterexample**. The explorer found `free block is on the wrong list (block 4)`
at one crash point. On hardware, most likely all three steps are lost at once
(`every acknowledged step was lost`), because a 2 MiB region fits in the cache.
That still fills the "mutant loses data" cell. Reproducing the explorer's exact
counterexample would need a mutant that skips `CLWB` only for the last step,
which is not planned before the freeze.

## One-time host setup (Ubuntu, by hand, as root)

Nothing in this section should be run by Claude.

**1. Toolchain and repository.**

```bash
sudo apt-get install -y git build-essential ndctl
git clone https://github.com/titzer/virgil ~/virgil && (cd ~/virgil && make)
export PATH="$HOME/virgil/bin:$PATH"           # add to ~/.bashrc
git clone git@github.com:eliotmoss/wizard-engine-PRs.git ~/wizard-engine-PRs
cd ~/wizard-engine-PRs && git checkout pwregions && make bin/pwreboot.x86-64-linux
```

GitHub needs an SSH key on this OS too; follow the same steps as on Magpie.

**2. Choose a `memmap` range.** Read the firmware memory map for the running
boot:

```bash
sudo dmesg | grep -i -E 'e820|BIOS-e820'
```

Choose a range that lies **entirely inside one `usable` entry**, above 4 GiB,
and leaves plenty of ordinary RAM. 1 GiB is ample, since the runs use 2 MiB
files. Follow the [kernel's guide](https://nvdimm.docs.kernel.org/memmap_kernel_params.html);
do not copy an address from anywhere else. A wrong range can stop the machine
booting.

**3. Put it in the default boot entry.** This is required. A `sysrq` reboot
goes back through the firmware and GRUB. If the next boot does not reserve the
same range, the kernel uses it as ordinary RAM and the evidence is overwritten.
Edit `/etc/default/grub`:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash memmap=1G!8G"   # your range, not this one
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
```

Then run `sudo update-grub`. Put the range in `_DEFAULT`, not
`GRUB_CMDLINE_LINUX`: GRUB's recovery entries use only the latter, so they boot
without the reservation if the range turns out to be wrong. Remove it after
Stage 2c.

**4. Create the namespace, the filesystem and the mount.** Do this once, after
the first boot with `memmap`:

```bash
sudo ndctl list -Nu --idle                      # the reserved range, as a raw namespace
sudo ndctl create-namespace -f -e namespace0.0 --mode=fsdax --map=mem
sudo mkfs.ext4 -F -b 4096 /dev/pmem0
sudo mkdir -p /mnt/pmem0 && sudo mount -o dax=always /dev/pmem0 /mnt/pmem0
sudo mkdir -p /mnt/pmem0/stage2c && sudo chown "$USER": /mnt/pmem0/stage2c
echo '/dev/pmem0 /mnt/pmem0 ext4 dax=always,nofail,x-systemd.device-timeout=10 0 0' | sudo tee -a /etc/fstab
```

The `fsdax` setting and the filesystem are stored in the reserved memory
itself. They survive a warm reboot and are lost on a **cold** boot (power off),
after which this step must be repeated. **Never run `mkfs` or
`create-namespace` after a warm reboot**: that destroys the evidence. If
`/dev/pmem0` or the mount is missing after a warm reboot, stop and
investigate. `nofail` keeps a missing device from blocking boot.

**5. Check.**

```bash
STAGE2C_DAX_DIR=/mnt/pmem0/stage2c scripts/stage2c.sh doctor
```

The last section must say `runnable`.

## Runbook

Set `STAGE2C_DAX_DIR=/mnt/pmem0/stage2c` in every shell. Commit before arming:
the script refuses a dirty tree, so every result names a revision.

```bash
# 1. The probe, first.
scripts/stage2c.sh probe          # arms, then offers to run the reboot via sudo
#    ... reboot; log in; confirm /mnt/pmem0 is mounted ...
scripts/stage2c.sh verify

# 2. Only if the probe said SENSITIVE: the sieve, alternating providers.
scripts/stage2c.sh sieve ordinary     ; # reboot ; scripts/stage2c.sh verify
scripts/stage2c.sh sieve elide-clwb   ; # reboot ; scripts/stage2c.sh verify
#    repeat the pair at least three times

# 3. Commit the results.
git add results/*-stage2c-*
git commit -m "results(pmem): Stage 2c warm-reboot runs on <host>"
```

Between `ARMED` and the reboot, **do nothing else on the machine**. In
particular, do not run `sync`: it could write back the very lines under test.
Reboot within seconds; the script records the time between arming and the next
boot.

Each run leaves `results/<stamp>-<host>-stage2c-<kind>/` containing
`provenance.txt` (revision, kernel command line, CPU and cache sizes, mount
options, boot IDs before and after), the state files, the logs, the raw image
taken before recovery, `images.sha256`, and `verify.log` with the verdict.
`status` shows the armed run; `abandon` forgets it without verifying.

## Open risks to watch

- **Firmware may clear or retrain memory on a warm reset.** The probe reports
  this as `INVALID`. Disabling fast boot or memory tests in the firmware
  settings may help.
- **Eviction before the reset.** Anything that pushes the test lines out of
  the cache writes them back, and the probe measures how much. Keep the machine
  idle and reboot immediately.
- **Kernel writeback of DAX data.** The harness never syncs the DAX
  filesystem after arming. The production mapping uses `MAP_SYNC`, and as far
  as is known the kernel does not track dirty pages on `MAP_SYNC` mappings, so
  periodic writeback should never write back these lines. That is not verified
  here. If it happened, the probe would report `NOT-SENSITIVE`, so no false
  positive can result. `provenance.txt` records the `vm.dirty_*` settings.
- **Reboot method.** `sysrq` `b` restarts at once through the platform's reset
  path. Keep the default `reboot=` behaviour, so a result can be tied to one
  reset method.

## Optional: passwordless reboot

Deferred for the first runs. If repetitions become tedious, add a root-owned
wrapper script and one `sudoers` rule for exactly that script, with no
arguments (`NOPASSWD: /usr/local/sbin/pwasm-sysrq-reboot ""`). Never add a rule
for a script in the repository or the home directory, because anyone who can
edit it would get root. Also harden SSH (key-only login, firewall it to the
Mac's address, stop `sshd` when not in use), and keep Claude Code's approval
prompt on for the reboot. Remove both files after Stage 2c.

## Pointers for a new session

- The argument: `docs/pmem-emulation.md`, Stage 2c, and the flush-placement
  negative control.
- Scope, schedule and freeze: `docs/THESIS.md`. Task list: `docs/ROADMAP.md`,
  Stage 2c item.
- Code: `test/pwreboot.main.v3` (harness modes), `scripts/stage2c.sh`
  (operator), `test/unittest/x86-64-linux/ElidedWritebackOps.v3` (the mutant),
  `test/unittest/x86-64-linux/PWSieve.v3` (the workload).
- A local dry run needs no reboot and works anywhere, including WSL:

  ```bash
  mkdir -p /tmp/s2c
  export STAGE2C_BACKEND=file STAGE2C_DAX_DIR=/tmp/s2c STAGE2C_OUT_ROOT=/tmp/s2c-out STAGE2C_ALLOW_DIRTY=1
  scripts/stage2c.sh sieve elide-clwb && scripts/stage2c.sh verify    # SURVIVED: a file cannot lose a line
  ```
