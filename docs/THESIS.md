# Honours Thesis — Scope, Framing and Schedule

> **Status:** planning record, opened 2026-09-18 after a framing discussion with
> Eliot. Submission is due late October 2026. This document fixes what the
> thesis claims, which remaining roadmap items are in scope, and what is
> explicitly cut. It is the scope authority for the rest of the project: where
> it and [Roadmap](ROADMAP.md) disagree about priority, this document wins.
>
> **As of 2026-09-29 every in-scope experiment is complete**, together with
> three that were added after the plan (the direct-I/O backend, the `CLWB`
> eviction work with its batched apply, and the sieve-step cost). What remains
> before the 2026-10-02 freeze is housekeeping; what remains after it is
> writing.

See [Persistent Backends](persistent-backends.md) for the design being written
up, [PMEM Crash Model](pmem-crash-model.md) for the verification method, and
[PMEM Emulation](pmem-emulation.md) for the hardware evidence and its limits.

---

## Origin

Eliot proposed that the thesis revolve around two things: the unifying
interface for persistence, spanning PMEM and file-backed regions, and the
techniques developed to test the write-ahead log.

Both are the right material. The framing below sharpens them in two ways.
First, a unifying storage interface is by itself a well-trodden idea — the
defensible claim is not that one can be built but what it costs and where it
leaks. Second, "WAL testing" undersells what was actually built, which is a
general method for crash-consistency checking of persistent data structures
that happens to have been demonstrated on a WAL.

The emphasis is therefore inverted relative to Eliot's original framing: the
interface is the substrate, and the verification method is the sharper
contribution. **This inversion needs Eliot's agreement before writing starts.**

---

## Thesis statement

> A single persistence seam can serve both byte-addressable and block-backed
> media for a region allocator and its write-ahead log. Because that seam
> concentrates every store, flush and fence at one observable point, it also
> makes exhaustive crash-consistency checking of the *unmodified production*
> code possible. Where the seam cannot unify the media — persistence
> granularity, failure atomicity, boundary cost, and what a crash can be
> observed to lose — those differences are measurable, and they are the real
> cost of the abstraction.

The non-obvious part is the middle sentence: portability and verifiability fall
out of the same design decision. Everything else is evidence for it.

---

## Contributions

**1. A persistence seam spanning byte-addressable and block-backed media, with
a measured account of what it does not unify.**

The seam is `BackendRegion` / `TxnRegionBackend` plus the per-region
`PersistentOperations` provider (`src/engine/TxnBackend.v3`,
`src/engine/x86-64/X86_64PersistentOperations.v3`), carrying one allocator
(`PWRegion`) and one log (`DualTxnWal`) over `VolatileRegion`,
`FileMmapRegion`, `PmemMmapRegion` and `DirectIoRegion` (explicit `pwrite` +
`O_DIRECT` from a private staging buffer, to a file or a raw block device,
added 2026-09-24) without conditionals in the layers above. The direct backend
emits the PMEM backend's `STORE`/`CLWB`/`SFENCE` trace for the same history,
which is the seam's claim made checkable.

**2. A recorded-trace crash-image method that checks production recovery over
every durable image a crash permits.**

Instrument the real store/flush/fence order at the seam, freeze it as an
immutable artifact, enumerate the durable images a crash cut admits under a
stated hardware model, and run the production recovery path over each one as a
checkable property.

The two are bound together: contribution 1 is what makes contribution 2
possible, and contribution 2 is the only thing that makes contribution 1
believable.

---

## Where the unification leaks

This is the analytical core of the thesis and the part that is currently least
written down. Four axes, in increasing order of how much they hurt.

### Persistence granularity

PMEM persists a 64-byte cache line via `CLWB` and orders with `SFENCE`. The
file backend persists a page-aligned range via `msync`, or the whole file via
`fdatasync`. `prepareChangedRange` / `persistChanges` present one interface over
a granularity difference of roughly two to three orders of magnitude.

### Failure atomicity

The PMEM baseline is crisp and is stated in
[PMEM Crash Model](pmem-crash-model.md): naturally aligned 1/2/4/8-byte stores
are failure-atomic, and the recorder rejects any trace that violates it. The
file-backed path has no equivalent contract. Writeback of a dirty page to a
block device tears at sector granularity, and what survives underneath a
journaling filesystem is filesystem-specific. The interface is shared; the
atomicity guarantee beneath it is not, and the weaker side is also the
less precisely specifiable side.

### Boundary cost

Phase B of `DualTxnWal` exists to reduce the protocol to one persistence
boundary per commit in steady state. **Measured on Magpie, 2026-09-18**, the
same design decision is worth 80–99 % of a commit on a file and 3.4 % on PMEM —
the WAL's central optimisation has a completely different value per backend, and
now a number rather than an assertion.

The headline for this chapter: on *identical* DAX media, with identical workload
and geometry, the two boundary primitives differ by **≈2,000×** (455 ns against
927 µs per commit) for a region the kernel maps with 2 MiB DAX entries — the
normal case for any region of 2 MiB or more. One interface, three orders of
magnitude underneath it, and the size of the gap set by a kernel mapping
decision the backend never sees (11× with 4 KiB entries, measured at a matched
1 MiB geometry; see below).

Two findings that arrived unplanned and are better material than the headline:

- **The file backend on DAX pays the kernel's flush granularity** — at 2 MiB
  regions it is 4.7–7.1× slower than the same backend on block storage, while
  also forgoing the `SFENCE` path, and a caller who unified on the file backend
  "because it works everywhere" and deployed on PMEM pays ~70× per commit,
  silently. **The cause is not the media** (region-size sweep, 2026-09-23):
  `fdatasync` writes back the whole 2 MiB DAX entry a commit dirtied, 32,768
  cache lines at ~65 cycles each. At a 1 MiB region, which the kernel must map
  with 4 KiB entries, the same boundary on the same media is ~5 µs, ~187×
  cheaper; from 2 to 8 MiB it is flat at 927 µs. A matched-geometry campaign
  (all three configurations at 1 and 2 MiB, one sitting) confirms the reversal:
  at 1 MiB the file backend on DAX is **31–33× faster** than on block storage,
  and only **1.27× slower per commit** than the PMEM backend at eight entries
  (71× at 2 MiB). This was first read as "the
  worst of both worlds" on the media; the corrected reading is a stronger
  statement of the thesis, because the abstraction hides not just the medium
  but a mapping granularity the backend neither chooses nor observes. Inferred
  from timing and `filefrag`; kernel-side confirmation
  (`fs_dax:dax_writeback_one`) needs root and is pending.
- **Whole commits, not boundaries, decide the comparison once the boundary is
  small.** At 1 MiB and 24 entries the file backend on DAX committed *faster*
  than the PMEM backend (28.9 µs against 37.3 µs) — **an artefact of the PMEM
  backend's writeback placement, corrected 2026-09-28**: with the batched apply
  the PMEM backend is faster at every size again (21.6 against 29.3 µs at 24
  entries, 1.4×). The crossover arose because the PMEM backend's
  non-boundary work grows about twice as fast per entry on the same media and
  the same record-construction code. **Cause found in part (2026-09-28):** on
  Cascade Lake `CLWB` evicts the line exactly as `CLFLUSHOPT` does (probe:
  ~620 ns re-access on PMEM after either), and removing the PMEM backend's
  writebacks brings its slope from 1,444 to 762 ns per entry, the file
  backend's 724. The first candidate, misses on the *next* commit, is not
  supported: the file backend's lines are written back between commits too and
  it pays nothing per entry. The mechanism is within the commit, **established
  by intervention** (timing only; no counters without root): each after-image
  is written back as soon as it is stored, so the next entry's store into the
  same line misses. With one entry per line and the same 38 writebacks, the
  excess falls from 678 to 37 ns per entry, and the writebacks cost 7 % of a
  24-entry commit instead of 43 %. Deferring every writeback to the fence
  recovers 27–34 % of the commit at 8–24 entries but loses 11–22 % where there
  is no reuse, so placement matters as much as count. Writing each line back
  once at the end of the apply loop is now production (2026-09-28), covered by
  crash-explorer and mutation-checked tests, and measured: 31 % and 43 % faster
  at 8 and 24 entries, the writebacks down from 43 % to under 4 % of a
  24-entry commit, the slope equal to no writeback's. A first version's
  0.2–0.8 µs regression where nothing coalesces was CPU bookkeeping (a
  compiled 64-bit divide, non-inlined vector calls); removing it cleared the
  file backend entirely and left 0.34 µs (1.5 %) at stride 64 and 24 entries,
  which is placement — writebacks issued back to back — not software.
  **The eviction is Cascade Lake's; the mechanism is not (2026-09-28).** On
  both core types of a Raptor Lake i7-14700KF, with DRAM standing in for PMEM,
  `CLWB` does not evict: a re-load costs +12–14 ns after it against +53–54 ns
  after `CLFLUSHOPT`. The same-line store is still 76–94 % of the per-entry
  placement's writeback cost there (the stride-64 split), at ~21–30 ns per
  store against ~775 ns on Magpie, so the batched apply is 7–8 % faster
  instead of 43 %. Caveats: emulated media, so the price of a miss is DRAM's,
  and one core of each type of a hybrid CPU.
  Worth a paragraph in Chapter 6: the same instruction, on the same media,
  costs 7 % or 43 % of a commit depending on where the protocol issues it and
  how the caller lays out its writes, which the abstraction neither shows nor
  controls — and whether it evicts at all depends on the core it runs on.
- **On PMEM the fence is not the cost — but the writebacks are (corrected
  2026-09-28).** The earlier form of this finding, "byte-at-a-time `zeroBytes`
  and `computeRecordChecksum` outweigh the durability boundary by 28×, so the
  WAL's protocol-level optimisation is optimising 3 % of the problem", counted
  only the cycles inside `rdtsc`-bracketed `CLWB` calls. `rdtsc` is not ordered
  with `CLWB`, and measured by removing them the writebacks cost 14 %, 36 % and
  43 % of a commit at 1, 8 and 24 entries. Those are Cascade Lake's figures
  with the per-entry placement, where `CLWB` evicts. The batched apply brings
  them to 3.6 % at 24 entries there. On Raptor Lake, where `CLWB` does not
  evict, the batched apply's writebacks cost at most 3.6 % at any size
  (DRAM-emulated media). `SFENCE` is still 11–13 ns, so
  removing a *boundary* is still noise; what the protocol decides about *when*
  to write lines back is not.
- **The headline ratio is size-dependent and must never be quoted bare.** Both
  boundary primitives are flat in transaction size; only PMEM's `CLWB` loop
  scales, which moves the gap from ~6,700× at one entry to ~340× at fifty-six.
  Relatedly, batching is worth 54× on a file and 3× on PMEM — the same
  optimisation, one interface, an eighteen-fold difference in what it buys.
- **Cross-socket access costs 23.9 % on the `fdatasync` boundary.** Unpinned
  runs came out bimodal (927 µs / 1,147 µs, 12 each over 72); `numactl` pinning
  separates the modes completely and identifies NUMA locality as the cause. This
  earns a section, not a footnote. It is the sharpest instance of the thesis's
  theme because it is not about the interface at all: **CPU-to-media locality is
  a cost dimension byte-addressable persistent memory has and a block device
  does not**, and a unified interface cannot expose a knob it has no concept of.
  The PMEM backend is immune because nothing on its path blocks on media
  latency, so the same hardware penalty is invisible through one backend and
  24 % through the other. Confirmed as a full factorial: the penalty is constant
  at +23.6–24.0 % across every transaction size, `pmem-dax` is 0.0 % and
  `file-block` 0.1–0.7 %. **It is the same mechanism as the region-size
  finding** (2026-09-23): at a 1 MiB region the absolute penalty falls from
  ~220 µs to ~1 µs, in proportion to the lines flushed (~6.7 ns per line
  cross-socket). Locality prices each line, and the 2 MiB entry decides how
  many lines there are. Present the two findings together in Chapter 6.
- **The block-media comparison is not a controlled measurement on this host**
  and Chapter 6 must say so. `file-block` moved 27–48 % between sittings and
  changed shape in transaction size; the two DAX configurations reproduce to
  0.1 % once pinned. On 2026-09-23 the 2 MiB block figure switched regime
  (196 → 170 µs falling, to 133 µs flat) within an hour, while a 1 MiB file
  stayed within 1.5 % across three campaigns. That withdrew an apparent 8–14 %
  geometry effect, whose sign reversed. The media *direction* at 1 MiB (DAX
  31–33× faster) survives both regimes. The headline result rests on the two reproducible
  configurations, which is worth stating explicitly rather than leaving an
  examiner to notice that one column is shakier than the others.

  Worth narrating honestly in Chapter 6, because the route to it is the
  methodological lesson: four tightly-agreeing runs read as "robust to three
  significant figures", then as a between-session drift blamed on host load,
  which the provenance files disproved (load `0.00` at both campaign starts).
  Only a pinning experiment settled it. Quote ratios as orders of magnitude,
  never to 3 s.f.

Full numbers, the isolation of primitive from media, and the stated limits are
in [persistent-backends.md](persistent-backends.md).

### Where the persistence point is

Measured 2026-09-27 with the direct backend, whose timing splits each boundary
into its `pwrite` and its `fdatasync`. The same seam call, the same single
boundary per commit, and the cost lands in a different system call on each host:

| Host | Device as Linux sees it | Boundary | `pwrite` | `fdatasync` |
|---|---|---|---|---|
| Magpie `/home` | MegaRAID SAS3508 volume, `write through`, no FUA | 129 µs | ~144 µs | ~1.7 µs |
| sean-tan-PC `$HOME` | Solidigm NVMe, volatile write cache, FUA | 241 µs | ~23 µs | ~233 µs |

On Magpie the barrier is empty — Linux sees a write-through device and sends no
flush — and the write carries 99 % of the boundary; on the PC the flush carries
91 %. This is the thesis's theme at its sharpest: the interface hides not only
the medium and its mapping granularity but *where the persistence point is*,
and whether the barrier does anything at all.

It also corrects the block-media column of everything above. `/home` reports a
7,200 rpm drive, and a write acknowledged in ~130 µs has not reached a platter:
every `file-block` figure is the latency to a RAID controller's acknowledgement.
Whether that acknowledgement is power-safe depends on the controller's
configuration and is not established (it needs `storcli` and an administrator).
Chapter 6 must say so where it quotes a block figure, and should present the PC
as the host where the flush demonstrably reaches a device with a volatile cache.

Two smaller results from the same runs. Bypassing the page cache changes the
boundary by under 8 % on either host, in opposite directions, so the page cache
is not where block cost lives. And the mmap backends take one write-protect
fault per dirtied page per commit (none for the direct backend); on DAX it is
one per commit at 2 MiB but two at 1 MiB, because both dirtied pages sit under a
single 2 MiB entry — root-free corroboration of the region-size mechanism above.

### What a program pays

Every figure above is pwbench's: one transaction shape, boundaries back to back.
Measured 2026-09-28, `pwsievebench` times the resumable sieve instead, through
the production allocator and WAL. A step computes a segment in DRAM, allocates a
chunk, persists its 4 KiB bitmap, publishes it and retires an old segment: four
boundaries per step on every backend, as designed. Wall time per step, median
over repetitions, 1 MiB regions (256 × 4 KiB):

| Configuration | Raptor Lake P-core, step (persistence share) | Magpie, step (persistence share) |
|---|---|---|
| `pmem`, production | 167 µs (9 %) | 479 µs (11 %) |
| `file` on DAX | 182 µs (15 %) | 521 µs (18 %) |
| `file` on block storage | 1,097 µs (86 %), NVMe | 2,446 µs (55 %), `/home` |
| `direct` on block storage | 1,125 µs (86 %), NVMe | 2,675 µs (57 %), `/home` |

The P-core's repetition ranges are 0.3–0.5 % wide, Magpie's PMEM and DAX ranges
under 0.7 %. On the Raptor Lake E-core the shares are 8 %, 14 % and 79 %; its
~6 % spread is almost all in computation. Raptor Lake's PMEM is DRAM under
`memmap`, as in every Raptor Lake figure.

- **On byte-addressable media a step is computation.** Optane makes the
  persistence phases 3.6× Raptor Lake's (54 against 15 µs), but Magpie's cores
  also compute 2.8× slower, so the share moves only from 9 % to 11 %. Between
  the two DAX configurations the step differs by 1.05–1.09×; block storage costs
  4–7×. The sieve's region is 1 MiB, so the file backend on DAX is in its cheap
  4 KiB-entry regime, and its figures carry that geometry just as figure 6 does.
- **With the batched apply, the writeback instructions are under 1 % of a
  step.** Removing them makes the Raptor Lake P-core step 0.8 % *slower* (the
  persistence phases lose 0.57 µs, the computation gains 1.9 µs, in every
  repetition) and Magpie's 0.9 % faster. The per-entry placement is gone, so
  the sieve cannot show what the batched apply bought on this workload.
- **On block storage, blocking costs clock speed, and no boundary figure shows
  it.** The computation is the same DRAM work on every backend, yet on Magpie's
  `/home` it takes 2.6–2.7× its PMEM time, in every repetition. It is not
  migration (unchanged pinned to one CPU), and not the system calls or faults:
  the file backend on DAX makes the same calls, takes the same write-protect
  faults and computes normally. Raptor Lake reproduces it under `powersave`
  (3.0–3.3×) and not under `performance` (1.04×). Magpie has no cpufreq driver,
  so its clock is set by the platform, and a core idle in `fdatasync` can reach
  C1E or C6. The frequency policy is the likely cause, **inferred, not
  observed**: confirming it needs `turbostat`, which needs root.

The last finding belongs beside the NUMA one, and it has the same shape. The
PMEM backend is immune because nothing on its path blocks, and the cost falls
outside the persistence path altogether, in the computation after a boundary. So the 55–57 % persistence share on `/home` understates what
durability costs the program, and pwbench cannot see it. Chapter 6 must say so
wherever it quotes a Magpie block figure for a workload that computes between
boundaries, and should take Raptor Lake's block figures from the `performance`
runs. One pattern is still open and should be stated as open: on `/home` the
sieve's boundaries cost 180–680 µs against pwbench's 150–176 µs, with
boundaries that follow computation ~1.7× the others. That points at LVM and
the write-through controller, and is untested.

Full numbers, per-phase splits and result directories are in
[persistent-backends.md](persistent-backends.md#a-real-workload-what-a-sieve-step-costs-and-how-much-is-persistence).

### Verifiability

The two media are not interchangeable for validation, and this is the axis that
matters most because it is the one that connects to contribution 2.

- On a `MAP_SYNC` DAX mapping, the memory *is* the media, so a killed process
  loses nothing still sitting in cache.
- On a file, the page cache is kernel-side and shared, so a killed process
  loses nothing either; only a host crash or power loss discards it.

Neither of those crash loops can discriminate correct flush placement, and the
flush-placement negative control makes this demonstrable rather than argued.
This section used to call that "a property of the media". **That was wrong as
stated**: it is a property of where those two backends keep dirty data. The
direct backend keeps it in the process, so process death discards whatever was
never written back, and its kill loop does discriminate: the elided-writeback
mutant loses every acknowledged step at random crash points (8 of 8 on Magpie,
19 of 19 on the PC, 2026-09-27) while the ordinary build loses none. That
discrimination is coarse (4 KiB units, drain-all fences) and tests the
placement of write-back requests, not what `CLWB` and `SFENCE` do on PMEM, so
the fine-grained evidence still comes from the model.

A warm reset over reserved DRAM (Stage 2c) is the one hardware event available
here that does discard the CPU cache, and there the two builds separate: the
mutant loses every acknowledged step and the ordinary build loses nothing,
three times out of three. That corroborates the model on real cache loss, but
at a single crash point per run, straight after the last acknowledgement. The
direct backend's kill loop adds many random crash points on real hardware, but
at 4 KiB granularity; the claim that the placement is correct at *every* crash
point, line by line, still rests on the explorer alone.

---

## Chapter structure

| # | Chapter | Principal source material |
|---|---|---|
| 1 | Introduction — problem, thesis statement, contributions | new |
| 2 | Background and related work | **new, and the only real gap** |
| 3 | Design: the persistence seam | [persistent-backends.md](persistent-backends.md), [wal-comparison.md](wal-comparison.md) |
| 4 | Where unification leaks | this document, plus the cost measurement |
| 5 | Verifying through the seam | [pmem-crash-model.md](pmem-crash-model.md) |
| 6 | Evaluation and evidence boundary | [ROADMAP.md](ROADMAP.md), [pmem-emulation.md](pmem-emulation.md) |
| 7 | Conclusion and future work | new |

Chapters 3, 5 and 6 largely exist already as prose in `docs/`. They need
restructuring, figures and a consistent voice, not fresh research. Chapter 5 is
the centrepiece and should be drafted first among them.

Chapter 6 must report what the method actually *found*, not only that it
passed. The two defects the `SIGKILL` crash loop surfaced are the strongest
available evidence that the workload-level invariants are not vacuous:

- the alloc-then-publish leak is real, at 8–18 extents per run, and without
  reclamation a small region stops making progress after about six crashes; and
- a crash between a segment's publication and the retirement that follows it
  leaves one extra live segment, so the instantaneous invariant is
  `live <= window + 1` rather than `live <= window`.

---

## Scope triage

Six weeks to submission. The implementation is over-delivered for Honours
already — 293 implementation tests across fifteen files (260 at the
2026-09-01 audit, then the negative control's 4, the direct backend's 22 and
the batched apply's 7), a working crash-image
explorer, and validation on real fsdax hardware. The risk from here is an
unwritten thesis, not a thin contribution. Experiments are triaged accordingly.

### In scope

Ranked by value per hour. The first three run in week 1 because Chapter 6
cannot be written around missing numbers.

| Item | Estimate | Why it survives triage |
|---|---|---|
| ~~Flush-placement negative control~~ | done 2026-09-18 | **Complete, both predictions held.** The mutant passes on Magpie with a bit-identical durable answer while the explorer rejects it. The thesis spine is now demonstrated. Figure 7 is ready to draw. |
| ~~Persistence-boundary cost characterisation~~ | done 2026-09-18 | **Complete, 72 runs committed in `results/`, all claims verified against the CSVs.** ~3 orders of magnitude between the boundary primitives on identical media; exactly 1.000 boundaries per commit everywhere. Findings: the file backend on DAX is 7–8.6× slower than on block storage at 2 MiB — caused by whole-2 MiB-entry flushing, not the media (region-size sweep 2026-09-23: ~5 µs at 1 MiB) — on PMEM record construction outweighs the boundary by 29× (**corrected 2026-09-28**: an in-window figure; the writebacks cost 14–43 % of a commit once `CLWB`'s eviction on Cascade Lake is counted), `SFENCE` flat in transaction size while `CLWB` is linear at 72–73.5 cycles/line — and `fdatasync`-on-DAX is bimodal, so quote ratios as orders of magnitude, never to 3 s.f. |
| ~~File-backed crash model, stated~~ | done 2026-09-18 | **Complete, no code.** Written in [PMEM Crash Model](pmem-crash-model.md#the-file-backed-model-is-simpler-but-not-trivial): pre-boundary cuts still fan out, the asynchronous-flush dimension disappears, the unit is a page, the atomicity contract names the filesystem. The direct backend's model, a checked restriction of the PMEM one, followed on 2026-09-24. See below. |
| ~~Third backend: direct I/O~~ | done 2026-09-24, hardware 2026-09-27 | **Added after the plan, before the freeze.** `DirectIoRegion`: private staging buffer, `pwrite` + `O_DIRECT`, one `fdatasync` per boundary, to a file or a raw block device. Same trace as the PMEM backend; every post-`fdatasync` file image checked exactly against the PMEM model; kill-loop mutant `LOST` / ordinary `OK` on Magpie and the PC; and the finding that Magpie's block storage is a write-through RAID controller, so every `file-block` figure is a controller round trip. See "Where the persistence point is" above. |
| ~~Stage 2c — reserved-DRAM warm reboot~~ | done 2026-09-24 | **Complete, the experiment discriminates.** Ordinary build `SURVIVED` and mutant `LOST` (every acknowledged step) in 3 of 3 pairs, with the reset issued from inside the process. On the way, two host facts that the write-up needs: the firmware wipes RAM after a `sysrq` reset unless the kernel's memory-overwrite request is cleared, and a seconds-long window before the reset lets every unflushed line reach memory. |
| ~~`CLWB` eviction and the batched apply~~ | done 2026-09-28 | **Added after the plan, before the freeze; the one production change since the triage.** Follows up the PMEM backend's unexplained per-entry slope. On Cascade Lake `CLWB` evicts, and the within-commit store into a just-written-back line was ~95 % of the writebacks' cost (established by intervention, timing only). Writing each after-image line back once at the end of the apply is now production, with 7 new tests and four mutants each caught: 43 % faster at 24 entries on Magpie, 7–8 % on Raptor Lake, where `CLWB` does not evict. See "Boundary cost" above. |
| ~~Sieve-step cost (`pwsievebench`)~~ | done 2026-09-28 | **Added after the plan, before the freeze.** The only cost measurement of a program rather than a harness-chosen transaction: persistence is 9–11 % of a step on PMEM and 55–86 % on block storage, and blocking costs the computation after it clock speed. See "What a program pays" above. |

### Out of scope for the thesis

Each gets one sentence in future work, no more.

- WASM guest integration. `PWSieve` is a Virgil workload with no guest and no
  host module, so there is currently no runtime story. Wizard is motivation and
  context, not a contribution — **Eliot should be told this explicitly now**
  rather than discovering it in the draft.
- Closing the `ImmixPWRegion` line-mark hole in the seam. It must instead be
  *stated* in Chapter 3, since the verification argument rests on the seam
  being complete and this is the one acknowledged exception.
- Crash-model milestones 8–9 (regular/seeded test tiers, emitted-instruction
  validation).
- Any further `MultiTxnWal` or `SingleTxnWal` work; they appear in Chapter 3 as
  design comparison only.
- Hardware-only backend integration facts (non-granule alignment, large
  regions, `MAP_SYNC`-refusal control). Cheap, but low intellectual yield per
  page.
- Stage 3 real power interruption. Not attainable on Magpie, already recorded
  as a limitation rather than as pending work.

### Code freeze

**2026-10-02.** After that date, changes are limited to fixing defects in
behaviour the thesis already describes. No new features, no new test
categories, no refactoring.

---

## The file-backed crash model

Chapter 4 claims the media differ in what a crash can lose, and Chapter 5
presents a model that is entirely PMEM-shaped. The file backend therefore needs
its model written down, if only to show what changes.

An earlier sketch of this argument claimed the file backend's permitted image
set collapses to `{before, after}` at every cut. **That is wrong** and should
not appear in the thesis. The kernel may write back any subset of dirty pages
at any time, so pre-boundary cuts still fan out, exactly as background
cache-line eviction makes them fan out on PMEM.

What genuinely changes, and belongs in the thesis:

- **The asynchronous-flush dimension disappears.** `CLWB` is a request whose
  completion may land at many later points, so the explorer must interleave
  completions and track outstanding writebacks. `msync` and `fdatasync` are
  synchronous: on return the range or file is durable, so a crash cut falls
  either before or after the call and there is no outstanding-writeback state
  to enumerate. One whole dimension of the state space is removed.
- **The unit is far coarser.** A 4 KiB page against a 64-byte line. A 2 KiB WAL
  record spans one page but thirty-two cache lines, so the per-unit prefix
  product that dominates the PMEM state space is dramatically smaller.
- **The atomicity contract is weaker and vaguer**, as described under failure
  atomicity above. The PMEM model can state its baseline precisely; the file
  model cannot, and has to name the filesystem.
- **The crash class differs.** Process termination loses nothing on either
  mmap backend, so their `SIGKILL` evidence is process-crash consistency on
  both, and host power loss is the only event that discriminates.

The direct backend has a third model, and it is a *restriction* of the PMEM
one: every image it can leave is one the PMEM model admits for the same trace,
provided the device never tears a 64-byte-aligned span (512-byte sector
atomicity suffices) and a completed flush makes completed writes durable. There
is no background eviction, so a `SIGKILL` samples roughly the model's lazy
schedule — which is why its kill loop discriminates. The claim is checked, not
only argued: `direct_io:boundary_images_are_model_images` compares the real
file after every `fdatasync` with the model, line by line and exactly. Recorded
in [PMEM Crash Model](pmem-crash-model.md#the-direct-backend-is-a-restriction-of-the-pmem-model),
together with the layout assumption it exposes: at 4 KiB blocks the WAL header
and both slots share one 4 KiB write unit.

Whether to *implement* a file-backed explorer is out of scope; stating the
model and its relationship to the PMEM one is in scope, and is the analysis
half of the item in the triage table. Recorded in full in
[PMEM Crash Model](pmem-crash-model.md).

---

## Related work

This is the only genuine gap in the thesis, and Honours examiners weight it
heavily. Two days of focused reading, hard stop.

Positioning to establish, with the closest ancestors being prior crash-state
enumeration work:

- **Crash-consistency testing for persistent memory** — Yat, `pmemcheck` and
  `pmreorder` from PMDK, PMTest, XFDetector, Agamotto, Jaaru, Witcher, Vinter,
  Hippocrates.
- **Persistent-memory programming interfaces** — PMDK / `libpmemobj`,
  Mnemosyne, NV-Heaps, Atlas, Twizzler; durable transactional memory with redo
  logging (Romulus, OneFile) for the WAL design comparison.
- **Persistent-memory filesystems**, for the block-backed comparison — NOVA,
  SplitFS.
- **Block-level crash testing and the buffer-pool question**, for the direct
  backend — CrashMonkey (OSDI '18) and dm-log-writes/replay-log record block
  writes with their FLUSH/FUA flags and replay the crash states they permit, the
  block-level counterpart of the explorer; Pillai et al., "All File Systems Are
  Not Created Equal" (OSDI '14); Crotty, Leis and Pavlo, "Are You Sure You Want
  to Use MMAP in Your DBMS?" (CIDR '22), the mmap-versus-buffer-pool argument
  this backend demonstrates within one seam; Rebello et al., "Can Applications
  Recover from fsync Failures?" (ATC '20), against which `DualTxnWal`'s
  latch-and-reopen contract should be positioned.

Claimed differentiators, to be stated only after the closest work is read
properly rather than assumed:

1. Traces are recorded from **production code** through a seam that exists for
   portability reasons anyway, so there is no separately maintained model to
   drift from the implementation.
2. The property checked is **production recovery**, not a reimplementation of
   it.
3. Properties climb to **workload-level cross-object invariants**
   (`PersistentSieveProperty`), not only internal structural ones.

Jaaru in particular performs constraint-based reduction, so the reduction
result — fence-forced floor plus per-line prefix product, shown to agree with
full branching search at every cut of three traces — must be positioned
against it honestly rather than claimed as novel outright.

### The Optane objection

Intel discontinued Optane in 2022, so "persistent memory is dead" is the
obvious examiner question and it belongs in the introduction rather than being
left for the viva.

The answer is a direct consequence of Eliot's framing. A thesis whose central
claim is that the interface must span byte-addressable *and* block-backed media
is precisely a thesis that declines to bet on one medium surviving, and CXL
persistent devices are the live successor to the byte-addressable side. Optane's
discontinuation strengthens the unification argument rather than weakening it,
and the thesis should say so explicitly.

---

## Schedule

| Week | Dates | Writing | Experiments |
|---|---|---|---|
| 1 | Sep 18–25 | Skeleton; Ch.3 Design | ~~Negative control~~; ~~cost measurement~~; ~~Stage 2c host setup~~ (all done) |
| 2 | Sep 26–Oct 2 | Ch.5 Verification | ~~Stage 2c run~~ (done 2026-09-24); **code freeze Oct 2**; related-work reading (2 days, hard stop) |
| 3 | Oct 3–9 | Ch.2 Background and related work; Ch.4 Leaks | — |
| 4 | Oct 10–16 | Ch.6 Evaluation; Ch.1 Introduction | — |
| 5 | Oct 17–23 | Ch.7; **complete draft to supervisors** | — |
| 6 | Oct 24–30 | Revision on feedback; figures; submission | — |

The end of week 5 is non-negotiable. Supervisors need a week to read a full
draft. A polished Chapter 5 attached to a missing Chapter 2 fails; a rough
complete draft passes.

---

## Figures

Seven, and they need real hours budgeted.

1. Layer stack — `PWRegion` → `RegionTransaction` → `DualTxnWal` →
   `BackendRegion` → the four backends (volatile, mmap file, PMEM, direct I/O).
2. On-region layout.
3. Phase B commit timeline, showing the piggybacked boundary.
4. **One trace cut fanning out into its permitted durable images.** The
   signature figure of the thesis.
5. The reduction — fence-forced floor plus per-line prefix product, against
   full branching search.
6. Boundary cost — three configurations, separating the boundary primitive from
   the media. **Data in hand (2026-09-18, four runs each):** `SFENCE` 11 ns,
   `fdatasync` on the same DAX media 927 µs, `fdatasync` on block storage
   148 µs. A fourth bar since 2026-09-27: `direct-block`, 129 µs against
   `file-block`'s 137 µs in the same campaign; label both block bars as a
   write-through RAID controller, which is what they measure.
   Plot on a log axis; a linear one cannot show 2,000× and 6.3× on the
   same figure. State the 2 MiB region geometry on the figure: the
   `fdatasync`-on-DAX bar is conditional on it (see 6c). Better: draw it as
   two panels, 1 MiB and 2 MiB, from the matched campaign
   (`results/20260923T043535Z-magpie-bs2048-4096`, or its 2026-09-27 rerun
   `results/20260927T080050Z-magpie-bs2048-4096`, which has all four
   configurations), so the reversal of the
   DAX-versus-block direction is visible in the figure itself.
6b. Boundary cost against transaction size, measured at 1/8/32/56 entries on
   both PMEM and file-on-DAX. `SFENCE` flat at 11 ns, `fdatasync` flat at
   ~928 µs (0.17 % over a 56× size change), `CLWB` linear at ~31.7 ns per cache
   line. Log y-axis, entries on x. The figure's point is that the *gap* closes
   from 6,675× to 340× purely because `CLWB` scales — so the headline ratio is
   never quotable without a transaction size.
6d. Where the boundary's time goes, per host (2026-09-27): the direct backend's
   boundary split into `pwrite` and `fdatasync`, Magpie (~144 µs / ~1.7 µs,
   write-through RAID controller) beside sean-tan-PC (~23 µs / ~233 µs, NVMe
   with a volatile cache), with the mmap file backend's single `fdatasync` on the
   same filesystems (137 µs, 237 µs) as a reference bar. Stacked bars, linear
   axis. The figure's point is that the persistence point, not the interface,
   decides which call pays.
6c. `fdatasync` on DAX against region size (1/2/4/8 MiB, 2026-09-23): ~5 µs at
   1 MiB, flat at ~927 µs from 2 to 8 MiB, with the H1/H2/H3 predictions (whole
   2 MiB entry / proportional to mapping / fixed per call) overlaid. Log y-axis.
   The step at 2 MiB is the mechanism behind figure 6's DAX-versus-block
   direction.
6e. What a sieve step costs (2026-09-28): one stacked bar per configuration,
   computation beneath the four persistence phases, Raptor Lake P-core
   (`results/20260928T100258Z-sean-tan-PC-pwsieve-bench-cpus2`) beside Magpie
   (`results/20260928T102833Z-magpie-pwsieve-bench`). Linear axis. The figure
   has two points. On PMEM the persistence segment is a sliver (9–11 %). On
   Magpie's block storage the *computation* segment is 2.6–2.7× taller than on
   PMEM, which is the clock-speed cost no boundary figure shows. State the 1 MiB
   geometry on the figure, as for figure 6.
7. **Negative control, 2×3** — {ordinary build, elided-writeback mutant} ×
   {Magpie crash loop, layer-1b explorer, Stage 2c warm reset}. **Data in hand
   as of 2026-09-24:** the mutant reports `OK` on Magpie with a durable answer
   bit-identical to the ordinary run, and is rejected by the explorer at event
   710 of 1401 with `free block is on the wrong list (block 4)`. Under the warm
   reset the mutant is `LOST` 3 of 3 (durable cursor back at the setup value,
   65,024, raw image byte-identical to setup's) while the ordinary build
   `SURVIVED` 3 of 3 (cursor 162,560, image byte-identical to a crash-free run).
   Draw the cells with those numbers, not with ticks and crosses — the
   identical prime count is the part that makes the top row persuasive, and
   the byte-identical images are the part that makes the third column so.
   **Since 2026-09-27 it is 2×4**: a fourth column, the kill loop on the
   direct backend, where the ordinary build loses 0 of 8 acknowledged steps on
   Magpie and 0 of 17 on the PC and the mutant loses 8 of 8 and 19 of 19. It is
   the only hardware column with random crash points; say in the caption that it
   is 4 KiB-granular. `pwreboot` on the same backend reproduces the third
   column's cursor values (162,560 against 65,024) without a reboot.

Figure 7 is the whole argument in one picture.

---

## To raise with supervisors

- Confirm the emphasis inversion: interface as substrate, verification method
  as the sharper contribution. Eliot's original framing weighted them roughly
  equally.
- State plainly that the WASM angle is motivation only, with no guest
  integration, so it cannot carry a contribution chapter.
- Agree the code freeze date, so that late suggestions arrive as future work
  rather than as implementation.
- Report the direct-I/O backend, added before the freeze, and what it found:
  the flush-placement mutant is caught by a plain kill loop, and Magpie's
  `/home` is a write-through RAID controller, so the `file-block` figures
  already shown are controller round trips. Ask whoever administers Magpie for
  `storcli /c0/v0 show all` and the cache module's status, which decide whether
  those acknowledgements are power-safe.
- Make every root request one `sudo` sitting on Magpie.
  [`scripts/magpie-root-checks.sh`](../scripts/magpie-root-checks.sh) already
  collects the controller and drive queries, a block trace of `fdatasync` on
  `/home`, and the `fs_dax:dax_writeback_one` granularity. It does not yet run
  `turbostat` during a sieve run on `/home`, which is what would turn the
  clock-speed finding from inferred to observed.
