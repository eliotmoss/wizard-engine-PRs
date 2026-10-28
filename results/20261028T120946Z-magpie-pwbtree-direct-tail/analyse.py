#!/usr/bin/env python3
"""Summary of the 2026-10-28 direct-backend tail check (see run.sh).

    python3 analyse.py <this directory> > summary.txt

Reads the run logs, the two strace traces and the diskstats samples; for the
comparison it also reads the two Magpie B+Tree campaigns' runs.csv beside it.
"""
import collections, csv, datetime, lzma, os, re, statistics, sys

D = sys.argv[1] if len(sys.argv) > 1 else "."
RESULTS = os.path.dirname(os.path.abspath(D))
CAMPAIGNS = ["20261014T111205Z-magpie-pwbtree-bench", "20261027T072331Z-magpie-pwbtree-bench"]
RUNS = [("plain.log", "direct, alone"),
        ("order/1-direct.log", "direct, alone"),
        ("order/2-direct-after-direct.log", "direct, after a direct run"),
        ("order/3-file.log", "file"),
        ("order/4-direct-after-file.log", "direct, after the file run"),
        ("strace.log", "direct, under strace"),
        ("diskstats/strace.log", "direct, under strace")]
TAIL_P99_NS = 10_000_000      # a run "has the tail" if its update p99 exceeds this
SLOW_MS = 10.0                # a "slow" pwrite64
AEDT = datetime.timezone(datetime.timedelta(hours=11))   # Magpie's local time, for strace -tt


def ms(ns):
    return ns / 1e6


def ops(path):
    out = {}
    for line in open(os.path.join(D, path)):
        if line.startswith("op "):
            t = line.split()
            out[t[1]] = dict(zip(t[2::2], map(int, t[3::2])))
    return out


def trace(path, epoch):
    """[(start epoch s, syscall, bytes, offset, latency ms)] for pwrite64 and fdatasync."""
    rx = re.compile(r'^\d+ (\S+) (pwrite64|fdatasync)\((.*)\)\s+= (-?\d+)(?: \w+ \(.*\))? <([\d.]+)>$')
    rows = []
    with lzma.open(os.path.join(D, path), "rt") as f:
        for line in f:
            m = rx.match(line.rstrip("\n"))
            if not m:
                continue
            ts, call, args, ret, lat = m.groups()
            if epoch:
                t = float(ts)
            else:
                h, mi, s = ts.split(":")
                t = datetime.datetime(2026, 10, 28, int(h), int(mi), tzinfo=AEDT).timestamp() + float(s)
            n = off = 0
            if call == "pwrite64":
                a = args.rsplit(", ", 2)
                n, off = int(a[1]), int(a[2])
                if int(ret) < 0:
                    continue          # the startup probe that O_DIRECT refuses
            rows.append((t, call, n, off, float(lat) * 1e3))
    return rows


print("Direct-backend B+Tree tail on Magpie's /home, 2026-10-28 (run.sh, analyse.py)")
print()
print("---- per run, ms: each run's own statistics (single runs; strace runs inflated)")
print(f"{'run':34} {'kind':6} {'median':>7} {'p90':>7} {'p99':>7} {'max':>7} {'mean':>6} {'alloc':>6} {'free':>6}")
stats = {}
for path, what in RUNS:
    s = ops(path)
    stats[path] = s
    for k in ("insert", "update"):
        d = s[k]
        print(f"{path:34} {k:6} {ms(d['median_ns']):7.2f} {ms(d['p90_ns']):7.2f} {ms(d['p99_ns']):7.2f} "
              f"{ms(d['max_ns']):7.1f} {ms(d['mean_ns']):6.2f} {ms(d['alloc_ns']):6.2f} {ms(d['free_ns']):6.2f}  {what}")
print()
print("---- the campaigns' direct-block updates, per repetition (runs.csv), ms")
for c in CAMPAIGNS:
    rows = [r for r in csv.DictReader(open(os.path.join(RESULTS, c, "runs.csv")))
            if r["config"] == "direct-block" and r["kind"] == "update"]
    rng = lambda key: f"{min(ms(int(r[key])) for r in rows):.2f}-{max(ms(int(r[key])) for r in rows):.2f}"
    print(f"{c}: {len(rows)} reps; median {rng('median_ns')}, p90 {rng('p90_ns')}, p99 {rng('p99_ns')}")
print()

plain = [p for p, w in RUNS if w.startswith("direct") and "strace" not in w]
tail = [p for p in plain if stats[p]["update"]["p99_ns"] > TAIL_P99_NS]
calm = [p for p in plain if p not in tail]
print(f"---- the tail: direct runs without strace whose update p99 exceeds {ms(TAIL_P99_NS):.0f} ms")
print(f"{len(tail)} of {len(plain)}: {', '.join(tail)}")
p90s = [ms(stats[p]['update']['p90_ns']) for p in plain]
print(f"update p90 over all {len(plain)}: {min(p90s):.2f}-{max(p90s):.2f} ms")
base = {k: statistics.mean(stats[p]["update"][k] for p in calm) for k in ("mean_ns", "alloc_ns", "free_ns")}
for p in tail:
    u = stats[p]["update"]
    ex = u["mean_ns"] - base["mean_ns"]
    af = (u["alloc_ns"] - base["alloc_ns"]) + (u["free_ns"] - base["free_ns"])
    print(f"{p}: mean update {ms(ex):.2f} ms above the calm direct runs' ({', '.join(calm)}); "
          f"alloc + free hold {ms(af):.2f} ms of it ({100 * af / ex:.0f} %)")
print()

print(f"---- the strace runs: per syscall, ms; slow = over {SLOW_MS:.0f} ms")
traces = {"strace.txt.xz": trace("strace.txt.xz", epoch=False),
          "diskstats/strace.txt.xz": trace("diskstats/strace.txt.xz", epoch=True)}
for name, rows in traces.items():
    print(name)
    for call in ("pwrite64", "fdatasync"):
        v = sorted(r[4] for r in rows if r[1] == call)
        print(f"  {call:9} {len(v):7} calls; median {v[len(v) // 2]:.3f}, p99 {v[int(len(v) * .99)]:.3f}, "
              f"max {v[-1]:.1f}; slow {sum(x > SLOW_MS for x in v)}")
    w = [r for r in rows if r[1] == "pwrite64"]
    slow = [r for r in w if r[4] > SLOW_MS]
    unit = lambda r: f"{r[3] // 4096}" + (f"+{r[2] // 4096}" if r[2] != 4096 else "")
    alln = collections.Counter(map(unit, w))
    slown = collections.Counter(map(unit, slow))
    print("  slow pwrite64s by target (4 KiB block[+blocks]): share of slow / share of all writes")
    for k, n in slown.most_common(5):
        print(f"    {k:7} {100 * n / len(slow):5.1f} % / {100 * alln[k] / len(w):5.1f} %")
    phase = collections.Counter(round(r[0] % 10, 1) for r in slow)
    p0, _ = phase.most_common(1)[0]
    near = [r for r in slow if abs(((r[0] % 10) - p0 + 5) % 10 - 5) <= 0.1]
    periods = {int(r[0] // 10) for r in near}
    span = int(w[-1][0] // 10) - int(w[0][0] // 10) + 1
    print(f"  slow pwrite64s within 0.1 s of {p0:.1f} s past a 10 s mark of the epoch: {len(near)} of {len(slow)}, "
          f"in {len(periods)} of the {span} 10 s periods the run spans")
    rest = sorted((r for r in slow if r not in near), key=lambda r: -r[4])
    print("  the other slow pwrite64s, longest first (s after the first write, ms): "
          + ", ".join(f"{r[0] - w[0][0]:.2f} {r[4]:.0f}" for r in rest[:8]))
print()

print("---- /proc/diskstats, sampled every 50 ms around the second strace run")
samples = collections.defaultdict(list)
with lzma.open(os.path.join(D, "diskstats/diskstats.txt.xz"), "rt") as f:
    for line in f:
        t, dev, rd, wr, *_ = line.split()
        samples[dev].append((float(t), int(rd), int(wr)))
rows = traces["diskstats/strace.txt.xz"]
w = [r for r in rows if r[1] == "pwrite64"]
first, last = rows[0][0], rows[-1][0] + rows[-1][4] / 1e3


def activity(dev, lo, hi):
    """(interval start, interval end, reads, writes) for each sample interval ending in [lo, hi] with I/O."""
    s = samples[dev]
    return [(a[0], b[0], b[1] - a[1], b[2] - a[2]) for a, b in zip(s, s[1:])
            if lo <= b[0] <= hi and (b[1] - a[1] or b[2] - a[2])]


idle_lo = samples["sda"][0][0]
print(f"idle, {first - 1 - idle_lo:.0f} s before the run: sample intervals with I/O")
for dev, what in (("dm-0", "/"), ("dm-1", "/var/log"), ("dm-2", "/home")):
    a = activity(dev, idle_lo, first - 1)
    print(f"  {dev} ({what}): {len(a)}, at s " + ", ".join(f"{b - idle_lo:.1f}" for _, b, _, _ in a))
print(f"during the run ({last - first:.0f} s):")
for dev, what in (("dm-0", "/"), ("dm-1", "/var/log")):
    a = activity(dev, first, last)
    print(f"  {dev} ({what}): {len(a)} intervals with I/O, at s after the first write "
          + ", ".join(f"{b - first:.2f} ({r} r, {x} w)" for _, b, r, x in a))
reads = activity("dm-2", first, last)
print(f"  dm-2 (/home): {sum(r for _, _, r, _ in reads)} reads")
foreign = [(a, b) for dev in ("dm-0", "dm-1") for a, b, _, _ in activity(dev, first, last)]
foreign += [(a, b) for a, b, r, _ in reads if r]
slow = [r for r in w if r[4] > SLOW_MS]
hit = [r for r in slow if any(a - 0.05 <= r[0] + r[4] / 1e3 and r[0] <= b + 0.05 for a, b in foreign)]
print(f"  slow pwrite64s overlapping (within 50 ms) an interval with I/O on / or /var/log or a read on /home: "
      f"{len(hit)} of {len(slow)}: " + ", ".join(f"{r[0] - first:.2f} s {r[4]:.0f} ms" for r in hit))
longest = sorted(slow, key=lambda r: -r[4])[:6]
print("  of the six longest: " + ", ".join(f"{r[0] - first:.2f} s {r[4]:.0f} ms{' (overlaps)' if r in hit else ''}"
                                         for r in longest))
