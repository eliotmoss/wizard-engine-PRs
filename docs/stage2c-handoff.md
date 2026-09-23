# Stage 2c Hand-off: Warm-Reboot Cache-Loss Test

This page is the runbook for Stage 2c and the hand-off between machines. The
argument for the experiment is in [PMEM Emulation](pmem-emulation.md#stage-2c--cache-loss-sensitivity-on-reserved-dram);
its place in the thesis is in [Honours Thesis](THESIS.md). The code freeze and
the Stage 2c timebox are both **2026-10-02**. If Stage 2c is not producing a
reading by then, it is dropped and the flush-placement negative control stands
alone. **It produced its reading on 2026-09-24: the experiment discriminates**
(see [Results](#results)).

## Status (2026-09-24)

| Piece | State |
|---|---|
| `test/pwreboot.main.v3` — probe, setup, arm, verify | Built. Dry-run tested on WSL with the file backend. The optional reset descriptor (2026-09-24) works in `probe-arm` and `arm` on the test host (dry runs, probe run 3, sieve pairs 1–3). |
| `scripts/stage2c.sh` — operator script | Built. Dry-run tested on WSL. Guards tested: it refuses WSL, VMs, hosts without `memmap=`, non-DAX directories, a results directory on the DAX filesystem, a second armed run, and a verify in the same boot. Since 2026-09-23 it also refuses to arm while the firmware's memory-overwrite request is set, which it did on the test host. `probe-now` and `sieve-now` (2026-09-24) work on the test host. Since pair 2 the clean check ignores staged results, and any other dirty path is listed in `provenance.txt`. |
| Verifier outcomes | Checked by editing images by hand: SURVIVED, LOST (steps rolled back, WAL corrupt), INVALID (header zeroed, file missing). The image is never reformatted. |
| Host setup on the Ubuntu dual boot | Done (2026-09-23). i7-14700KF, Ubuntu 26.04.1, kernel 7.0.0-31; `memmap=1G!8G`, ext4 `dax=always` on `/mnt/pmem0`; `doctor` says `runnable`. |
| Runs on real hardware | Done (2026-09-23/24): three probe runs and three `sieve-now` pairs. The experiment discriminates: ordinary build `SURVIVED` 3 of 3, mutant `LOST` 3 of 3. See [Results](#results). |

## Results

All on the test host (i7-14700KF, Gigabyte Z790 A PRO X WIFI7 BIOS F4, Ubuntu
26.04.1, kernel 7.0.0-31, `memmap=1G!8G`), 512 x 4096 = 2 MiB regions and 2 MiB
probe files. Directories are under `results/`, stamped in UTC; dates below are
local.

| Run | Directory | Reading |
|---|---|---|
| Probe 1 (2026-09-23) | `20260923T124723Z-…-stage2c-probe` | **No verdict.** The whole reserved range came back zeroed: the firmware's memory-overwrite wipe ([below](#the-memory-overwrite-request)). See `operator-notes.txt`. |
| Probe 2 (2026-09-24), request cleared | `20260923T140245Z-…-stage2c-probe` | `NOT-SENSITIVE`: 16,384 of 16,384 unflushed lines intact, with the operator's window of seconds before the reset. |
| Probe 3, `probe-now` | `20260923T143744Z-…-stage2c-probe-now` | **`SENSITIVE`**: 15,563 of 16,384 unflushed lines lost (all read as zero), every flushed line intact, none torn. The 821 survivors were all among the first 40 % stored. |
| Sieve pairs 1–3, `sieve-now` | `20260923T145439Z` … `20260923T152938Z`, `…-sieve-now-{ordinary,elide-clwb}` | **Discriminates, 3 of 3.** Ordinary: `SURVIVED`, `REPLAYED`, cursor 162,560 = acknowledged, raw image `a11b9b16…` in every run, byte-identical to a crash-free run. Mutant: `LOST`, `every acknowledged step was lost`, `CLEAN`, cursor back at setup's 65,024, raw image `6ffc3b3a…` in every run, byte-identical to setup's. |

Pair 1's mutant run reads `dirty YES` only because the ordinary run's results
were staged first; its `operator-notes.txt` says so. The reading and its limits
(one crash point per run) are written up in
[PMEM Emulation](pmem-emulation.md#flush-placement-negative-control).

## The machines

| Machine | Role |
|---|---|
| This PC, Windows + WSL | Where the harness was written. It cannot run Stage 2c: a WSL guest reset never discards the host's cache. |
| This PC, booted into native Ubuntu | **The test host.** It reboots during every run, so do not run the controlling Claude session here. |
| Mac | **The control machine.** It runs Claude Code and pulls from GitHub. It cannot drive the Ubuntu boot over SSH on the ANU campus Wi-Fi (checked 2026-09-23): connections reach `sshd`, which answers locally, but the PC's replies are lost on the way back, so the banner arrives late or never. The runbook is run by hand at the PC and its output pasted to the Mac session. |

Context moves between machines through this repository, not through chat
history. Claude's memory is per machine. Two things a new session needs to know:

- The user wants no `Co-Authored-By` Claude line in commits or PRs.
- Reboots are typed by hand for the first runs. A narrow passwordless `sudo`
  rule for the reboot was discussed and deferred; see
  [Optional: passwordless reboot](#optional-passwordless-reboot).

## What the experiment does

Reserved DRAM (`memmap=<size>!<start>`) survives a warm reboot, because power is
never removed, provided the firmware has not been asked to wipe memory: see
[The memory-overwrite request](#the-memory-overwrite-request), which the first
run on real hardware ran into. A CPU reset throws the cache away without
writing it back. So a
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
   acknowledged step in a state file that is fsynced after every step. Then it
   exits **without closing**, as a crash would.
3. Reboot. With `sieve-now`, `arm` resets the machine itself instead of
   exiting, straight after the fsync that makes its last acknowledgement
   durable. On the test host this is the form that counts: see
   [Eviction before the reset](#open-risks-to-watch).
4. `verify` copies the raw image, checks the header before mounting anything,
   then mounts, recovers, and checks what survived. It checks that the
   acknowledged cursor was reached, that the allocator and sieve invariants
   hold, and that the prime count matches an independent sieve.

| Sieve verdicts | Reading |
|---|---|
| ordinary `SURVIVED`, mutant `LOST` | **The experiment discriminates.** Flush placement is confirmed against real cache loss, at the one crash point the harness reaches (straight after the last acknowledgement). **Observed 3 of 3 on the test host.** |
| both `SURVIVED` | No sensitivity on this host. The probe should already have said so. |
| ordinary `LOST` | A real flush-placement defect, or an invalid host. Compare with a probe run. |
| any `INVALID` | Setup's flushed state is gone, so the reserved memory did not survive. The run says nothing about flush placement. |

The mutant is expected to fail **differently from the explorer's
counterexample**. The explorer found `free block is on the wrong list (block 4)`
at one crash point. On hardware, most likely all three steps are lost at once
(`every acknowledged step was lost`), because a 2 MiB region fits in the cache.
That still fills the "mutant loses data" cell. **Observed in all three pairs**,
with the mutant's surviving image byte-identical to the state setup left. Reproducing the explorer's exact
counterexample would need a mutant that skips `CLWB` only for the last step,
which is not planned before the freeze.

## The memory-overwrite request

The TCG reset-attack mitigation lets an operating system ask the firmware to
zero all of RAM before the next boot, so that secrets left in memory cannot be
read after a forced reset. The request is the EFI variable
`MemoryOverwriteRequestControl`. Ubuntu's kernel is built with
`CONFIG_RESET_ATTACK_MITIGATION=y`, so its EFI stub sets the variable to `0x01`
on every boot (`drivers/firmware/efi/libstub/tpm.c`,
`efi_enable_reset_attack_mitigation`). That value leaves the DisableAutoDetect
bit clear, which lets the firmware recognise a clean shutdown and skip the
wipe (EDK2, `MdePkg/Include/Guid/MemoryOverwriteControl.h`).

On the test host (Gigabyte Z790 A PRO X WIFI7, BIOS F4) the first runs showed
exactly that:

| Reset | Reserved range afterwards |
|---|---|
| Clean `sudo reboot` | Kept: ext4 remounted with the same UUID |
| `sysrq` reset, request set (probe run 1) | **Zeroed**: all 1 GiB read back as zero bytes |
| `sysrq` reset, request cleared (probe run 2) | Kept: ext4 remounted, all 16,384 flushed probe lines intact |
| Power off for a cold boot | Lost: 99.6 % of bytes non-zero, and zero bytes at 0.382 %, close to the 0.391 % of uniform noise |

The last row is the control for reading the second: memory that loses power
comes back as noise on this platform, so an all-zero range was actively
cleared.

A `sysrq` reset is never a clean shutdown, so every Stage 2c run needs the
request cleared first. The lock variable (`MemoryOverwriteRequestControlLock`)
reads `00` on this host, so Linux may clear it. It has to be cleared again in
every boot, because the kernel sets it on every boot; clearing it switches the
mitigation off for that one reset only. `doctor` and arming refuse while it is
set, and `provenance.txt` records its value at the moment of arming
(`mor_at_arm`). Clearing it prevents the wipe: probe run 2 cleared it, and the
range survived the `sysrq` reset.

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

On a dual boot, the firmware must also start Ubuntu first. A `sysrq` reboot
follows the firmware's boot order, and if that starts Windows, Windows reuses
the reserved RAM. `BootOrder` in `efibootmgr` must begin with the Ubuntu entry
(`sudo efibootmgr -o <ubuntu>,<windows>`), and after an unattended reboot
`BootCurrent` must be that entry. Windows updates can put Windows Boot Manager
first again. Booting Windows at all counts as a cold boot.

The kernel's EFI stub turns off physical KASLR when `memmap=` is on the command
line (`drivers/firmware/efi/libstub/x86-stub.c`), so the kernel image loads at
16 MiB rather than at a random address that could fall inside the range. After
the first boot, check `sudo grep -E 'Persistent|Kernel code' /proc/iomem`:
`Persistent Memory (legacy)` must be exactly the chosen range, and `Kernel code`
must be below 4 GiB.

**4. Create the filesystem and the mount.** No `ndctl create-namespace` is
needed, and none should be run. The kernel makes every `memmap=` range
DAX-capable on every boot (`drivers/nvdimm/e820.c` sets `ND_REGION_PAGEMAP`,
and the pmem driver then builds page structures in ordinary RAM for the whole
range). ndctl calls this native memory mode, and
`sudo ndctl list -Nu --idle` already shows `namespace0.0` as `"mode":"fsdax"`,
`"map":"mem"`, at the full size of the range. Converting it with
`create-namespace` would write an info block into the reserved range, which
every warm reboot would then also have to preserve. Confirm the mode without
root:

```bash
cat /sys/bus/nd/devices/namespace0.0/mode      # memory
cat /sys/bus/nd/devices/namespace0.0/holder    # empty: nothing claims it
cat /sys/block/pmem0/queue/dax                 # 1
```

Once, after the first boot with `memmap`:

```bash
sudo mkdir -p /mnt/pmem0
echo '/dev/pmem0 /mnt/pmem0 ext4 dax=always,nofail,x-systemd.device-timeout=10 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
```

After the first boot with `memmap`, and again after every **cold** boot (power
off):

```bash
sudo mkfs.ext4 -F -b 4096 /dev/pmem0
sudo mount /mnt/pmem0
sudo mkdir -p /mnt/pmem0/stage2c && sudo chown "$USER": /mnt/pmem0/stage2c
```

Only the filesystem is stored in the reserved memory. The namespace mode is
set by the kernel and comes back on every boot, including a cold one. The
filesystem survives a clean warm reboot, and a `sysrq` reset once the
memory-overwrite request is cleared; it does not survive a `sysrq` reset while
the request is set, or a cold boot (all observed 2026-09-23/24; see above).
**Never run `mkfs` after a warm reboot**: that destroys the evidence. If the
mount is missing after a warm reboot, stop and investigate. `nofail` keeps a
missing filesystem from blocking boot.

**5. Check.**

```bash
STAGE2C_DAX_DIR=/mnt/pmem0/stage2c scripts/stage2c.sh doctor
```

The last section must say `runnable`.

## Runbook

Set `STAGE2C_DAX_DIR=/mnt/pmem0/stage2c` in every shell. Commit before arming:
the script refuses a dirty tree, so every result names a revision.

```bash
# 0. Before EVERY arm, in the boot you arm in: clear the memory-overwrite request.
MOR=/sys/firmware/efi/efivars/MemoryOverwriteRequestControl-e20939be-32d4-41be-a150-897f85d49829
sudo chattr -i $MOR && printf '\x07\x00\x00\x00\x00' | sudo tee $MOR > /dev/null && sudo chattr +i $MOR
od -A n -t x1 $MOR                # 07 00 00 00 00
scripts/stage2c.sh doctor         # runnable

# 1. The probe, first.
scripts/stage2c.sh probe          # arms, then offers to run the reboot via sudo
#    ... reboot; log in; confirm /mnt/pmem0 is mounted (if not: no mkfs, see step 4) ...
scripts/stage2c.sh verify

# 1b. If the probe said NOT-SENSITIVE: the zero-window probe, to tell why.
sudo -v                           # so the command below does not stop at a password prompt
scripts/stage2c.sh probe-now      # records the run, then offers to store and reset in one command
#    ... it resets by itself; log in; confirm /mnt/pmem0 is mounted ...
scripts/stage2c.sh verify

# 2. Only if a probe said SENSITIVE: the sieve, alternating providers. Use the
#    form of the probe that did: on the test host that is sieve-now.
sudo -v; scripts/stage2c.sh sieve-now ordinary     # resets by itself ; scripts/stage2c.sh verify
sudo -v; scripts/stage2c.sh sieve-now elide-clwb   # resets by itself ; scripts/stage2c.sh verify
#    repeat the pair at least three times (step 0 before each)

# 3. Commit the results.
git add results/*-stage2c-*
git commit -m "results(pmem): Stage 2c warm-reboot runs on <host>"
```

Between `ARMED` and the reboot, **do nothing else on the machine**. In
particular, do not run `sync`: it could write back the very lines under test.
Reboot within seconds; the script records the time between arming and the next
boot. With `probe-now` and `sieve-now` there is no such interval: `ARMED` is
printed before anything is stored, and the command it offers stores and resets
in one go.

Each run leaves `results/<stamp>-<host>-stage2c-<kind>/` containing
`provenance.txt` (revision, kernel command line, CPU and cache sizes, mount
options, boot IDs before and after), the state files, the logs, the raw image
taken before recovery, `images.sha256`, and `verify.log` with the verdict.
`status` shows the armed run; `abandon` forgets it without verifying.

## Open risks to watch

- **Firmware may clear or retrain memory on a warm reset.** It did on the
  first run, through the memory-overwrite request (above). Clearing of any kind
  shows up the same way: the mount is missing after the reboot, and `verify`
  stops with `the probe file is gone` before printing a verdict. A raw copy of
  `/dev/pmem0` (`sudo dd`, read-only) then says whether the range came back as
  zeros (actively cleared) or as noise (decayed or scrambled). Firmware
  settings for fast boot and memory testing may also matter; none has been
  changed on the test host.
- **Eviction before the reset.** Anything that pushes the test lines out of
  the cache writes them back, and the probe measures how much. Keep the machine
  idle and reboot immediately. `probe` leaves a window of seconds between its
  last store and the reset: the script's own work, the wait for Enter, and
  `sudo`. `probe-now` leaves none. Root opens `/proc/sysrq-trigger`, `setpriv`
  drops to the ordinary user and keeps that descriptor open, and the probe
  writes `b` to it straight after its last store: no other process runs, and
  the CPU never idles. **On the test host the window was the cause:** `probe`
  read `NOT-SENSITIVE` (run 2) and `probe-now` read `SENSITIVE` (run 3). The
  reset itself does not write the cache back. So the sieve runs use
  `sieve-now`, whose `arm` resets the machine straight after the one fsync
  that makes its last acknowledgement durable. In run 3 the 821 unflushed
  lines that did survive were all among the first 40 % stored, scattered in
  ones and twos, never a whole page. That is the pattern eviction by the
  probe's own later stores would leave. The probe stores in ascending address
  order, so store order and address order cannot be told apart.
- **Kernel writeback of DAX data.** The harness never syncs the DAX
  filesystem after arming. The production mapping uses `MAP_SYNC`, and as far
  as is known the kernel does not track dirty pages on `MAP_SYNC` mappings, so
  periodic writeback should never write back these lines. That is not verified
  here. If it happened, the probe would report `NOT-SENSITIVE`, so no false
  positive can result. `provenance.txt` records the `vm.dirty_*` settings.
- **Reboot method.** `sysrq` `b` restarts at once through the platform's reset
  path. Keep the default `reboot=` behaviour, so a result can be tied to one
  reset method.

## After Stage 2c: restoring the host

Only once no re-run can be needed, and by hand, as root. None of this touches
the results, which live in the repository.

- GRUB: remove `memmap=1G!8G` from `GRUB_CMDLINE_LINUX_DEFAULT` (and set
  `GRUB_TIMEOUT_STYLE=hidden`, `GRUB_TIMEOUT=0` back if wanted), then
  `sudo update-grub`.
- `/etc/fstab`: remove the `/dev/pmem0` line, then `sudo systemctl daemon-reload`
  and `sudo rmdir /mnt/pmem0`.
- SSH: `sudo systemctl disable --now ssh.socket ssh.service` (or remove
  `openssh-server`), delete `/etc/ssh/sshd_config.d/10-stage2c.conf`, and remove
  the Mac's key from `~/.ssh/authorized_keys`.
- `~/.bashrc`: remove `clearmor` and the `STAGE2C_DAX_DIR` export.
- Boot order: keep Ubuntu first, or put Windows back first with
  `sudo efibootmgr -o 0000,0002`.
- The memory-overwrite request needs nothing: the kernel sets it again on every
  boot.
- `gh auth logout` if the GitHub CLI token is no longer wanted.

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
