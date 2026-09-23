# Honours Thesis — Scope, Framing and Schedule

> **Status:** planning record, opened 2026-09-18 after a framing discussion with
> Eliot. Submission is due late October 2026. This document fixes what the
> thesis claims, which remaining roadmap items are in scope, and what is
> explicitly cut. It is the scope authority for the rest of the project: where
> it and [Roadmap](ROADMAP.md) disagree about priority, this document wins.

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
`FileMmapRegion` and `PmemMmapRegion` without conditionals in the layers above.

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
  small.** At 1 MiB and 24 entries the file backend on DAX commits *faster*
  than the PMEM backend (28.9 µs against 37.3 µs), because the PMEM backend's
  non-boundary work grows about twice as fast per entry on the same media and
  the same record-construction code. The cause is not established; a candidate
  is `CLWB` evicting the written-back lines on Cascade Lake. Worth a paragraph
  in Chapter 6 as an open finding, not a claim.
- **On PMEM the boundary is not the cost.** Byte-at-a-time `zeroBytes` and
  `computeRecordChecksum` outweigh the entire durability boundary by 28×, so the
  protocol-level optimisation the WAL is built around is, on that medium,
  optimising 3 % of the problem.
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

### Verifiability

The two media are not interchangeable for validation, and this is the axis that
matters most because it is the one that connects to contribution 2.

- On a `MAP_SYNC` DAX mapping, the memory *is* the media, so a killed process
  loses nothing still sitting in cache.
- On a file, the page cache is kernel-side and shared, so a killed process
  loses nothing either; only a host crash or power loss discards it.

Neither hardware crash loop can discriminate correct flush placement. That is
not a gap in the experiments — it is a property of the media, and it is the
reason the correctness evidence has to come from the model. The
flush-placement negative control makes this demonstrable rather than argued.

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
already — 260 implementation tests across thirteen files, a working crash-image
explorer, and validation on real fsdax hardware. The risk from here is an
unwritten thesis, not a thin contribution. Experiments are triaged accordingly.

### In scope

Ranked by value per hour. The first three run in week 1 because Chapter 6
cannot be written around missing numbers.

| Item | Estimate | Why it survives triage |
|---|---|---|
| ~~Flush-placement negative control~~ | done 2026-09-18 | **Complete, both predictions held.** The mutant passes on Magpie with a bit-identical durable answer while the explorer rejects it. The thesis spine is now demonstrated. Figure 7 is ready to draw. |
| ~~Persistence-boundary cost characterisation~~ | done 2026-09-18 | **Complete, 72 runs committed in `results/`, all claims verified against the CSVs.** ~3 orders of magnitude between the boundary primitives on identical media; exactly 1.000 boundaries per commit everywhere. Findings: the file backend on DAX is 7–8.6× slower than on block storage at 2 MiB — caused by whole-2 MiB-entry flushing, not the media (region-size sweep 2026-09-23: ~5 µs at 1 MiB) — on PMEM record construction outweighs the boundary by 29×, `SFENCE` flat in transaction size while `CLWB` is linear at 72–73.5 cycles/line — and `fdatasync`-on-DAX is bimodal, so quote ratios as orders of magnitude, never to 3 s.f. |
| File-backed crash model, stated | ~half day, analysis | Chapter 4 and 5 both need the file backend's model written down; see below. No code. |
| Stage 2c — reserved-DRAM warm reboot | ~2–3 days, risky | Real cache loss on a DAX-faithful stand-in. Bare-metal host is available (confirmed 2026-09-18). **Hard timebox: if it is not working by 2026-10-02, drop it** and present the negative control as the sole flush-placement evidence. **Probe readings 2026-09-24:** `NOT-SENSITIVE` with a seconds-long window before the reset, after the firmware's memory-overwrite wipe was found and cleared; **`SENSITIVE`** (95 % of unflushed lines lost) with the reset issued from inside the probe. The host can lose a cache line; the sieve pairs run with the same in-process reset. See `docs/stage2c-handoff.md`. |

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
  backend, so the existing `SIGKILL` evidence is process-crash consistency on
  both, and host power loss is the only event that discriminates.

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
| 1 | Sep 18–25 | Skeleton; Ch.3 Design | Negative control; cost measurement; begin Stage 2c host setup |
| 2 | Sep 26–Oct 2 | Ch.5 Verification | Stage 2c run; **code freeze Oct 2**; related-work reading (2 days, hard stop) |
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
   `BackendRegion` → the three backends.
2. On-region layout.
3. Phase B commit timeline, showing the piggybacked boundary.
4. **One trace cut fanning out into its permitted durable images.** The
   signature figure of the thesis.
5. The reduction — fence-forced floor plus per-line prefix product, against
   full branching search.
6. Boundary cost — three configurations, separating the boundary primitive from
   the media. **Data in hand (2026-09-18, four runs each):** `SFENCE` 11 ns,
   `fdatasync` on the same DAX media 927 µs, `fdatasync` on block storage
   148 µs. Plot on a log axis; a linear one cannot show 2,000× and 6.3× on the
   same figure. State the 2 MiB region geometry on the figure: the
   `fdatasync`-on-DAX bar is conditional on it (see 6c). Better: draw it as
   two panels, 1 MiB and 2 MiB, from the matched campaign
   (`results/20260923T043535Z-magpie-bs2048-4096`), so the reversal of the
   DAX-versus-block direction is visible in the figure itself.
6b. Boundary cost against transaction size, measured at 1/8/32/56 entries on
   both PMEM and file-on-DAX. `SFENCE` flat at 11 ns, `fdatasync` flat at
   ~928 µs (0.17 % over a 56× size change), `CLWB` linear at ~31.7 ns per cache
   line. Log y-axis, entries on x. The figure's point is that the *gap* closes
   from 6,675× to 340× purely because `CLWB` scales — so the headline ratio is
   never quotable without a transaction size.
6c. `fdatasync` on DAX against region size (1/2/4/8 MiB, 2026-09-23): ~5 µs at
   1 MiB, flat at ~927 µs from 2 to 8 MiB, with the H1/H2/H3 predictions (whole
   2 MiB entry / proportional to mapping / fixed per call) overlaid. Log y-axis.
   The step at 2 MiB is the mechanism behind figure 6's DAX-versus-block
   direction.
7. **Negative control, 2×2** — {ordinary build, elided-writeback mutant} ×
   {Magpie crash loop, layer-1b explorer}. **Data in hand as of 2026-09-18:**
   the mutant reports `OK` on Magpie with a durable answer bit-identical to the
   ordinary run, and is rejected by the explorer at event 710 of 1401 with
   `free block is on the wrong list (block 4)`. Draw the cells with those
   numbers, not with ticks and crosses — the identical prime count is the part
   that makes the top row persuasive.

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
