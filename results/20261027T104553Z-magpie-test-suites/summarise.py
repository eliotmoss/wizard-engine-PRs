#!/usr/bin/env python3
"""Group a unit-suite log by registering file, using the prefix -> file map
from count_regs.py's static count. Usage: summarise.py <log> <static-count-file>"""
import re, sys
log, static = sys.argv[1], sys.argv[2]
NONPERSIST = {"SpcTest.v3", "WasiTest.v3", "X86_64LinuxExeTest.v3"}
pfile, scount = {}, {}
for line in open(static):
    parts = line.split()
    if len(parts) < 2: continue
    f = parts[0]; scount[f] = int(parts[1])
    for m in re.finditer(r'(\S+:) (\d+)', line):
        pfile[m.group(1)] = f
res = {}
cur = None
for line in open(log, errors="replace"):
    line = line.rstrip("\n")
    m = re.search(r'##\+(.*)$', line)
    if m: cur = m.group(1); continue
    if line.startswith("##-") and cur:
        res[cur] = ("ok" if line == "##-ok" else "expected-fail" if line.startswith("##-ok (ignored") else "FAIL")
        cur = None
byfile = {}
for name, r in res.items():
    pre = name.split(":")[0] + ":"
    f = pfile.get(pre, "(other)")
    d = byfile.setdefault(f, {"ok": 0, "expected-fail": 0, "FAIL": 0})
    d[r] += 1
tot = {"ok": 0, "expected-fail": 0, "FAIL": 0}; ptot = dict(tot); pfiles = 0; pstatic = 0
print(f"{'file':34s} {'static':>6s} {'ran':>5s} {'pass':>5s} {'xfail':>5s} {'fail':>5s}")
for f in sorted(byfile, key=lambda f: (f == "(other)", f in NONPERSIST, f)):
    d = byfile[f]; ran = sum(d.values())
    st = scount.get(f, "-")
    print(f"{f:34s} {str(st):>6s} {ran:5d} {d['ok']:5d} {d['expected-fail']:5d} {d['FAIL']:5d}")
    for k in tot: tot[k] += d[k]
    if f != "(other)" and f not in NONPERSIST:
        pfiles += 1; pstatic += scount[f]
        for k in ptot: ptot[k] += d[k]
print(f"persistence files: {pfiles}, static registrations {pstatic}, ran {sum(ptot.values())}, pass {ptot['ok']}, expected-fail {ptot['expected-fail']}, fail {ptot['FAIL']}")
print(f"whole binary: ran {sum(tot.values())}, pass {tot['ok']}, expected-fail {tot['expected-fail']}, fail {tot['FAIL']}")
