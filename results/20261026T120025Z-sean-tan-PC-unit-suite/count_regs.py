#!/usr/bin/env python3
"""Count unit-test registrations per file in test/unittest/x86-64-linux at a git revision.

A registration is a call NAME("test_name", fn) where NAME is bound in the same
file by `def NAME = UnitTests.registerT("prefix", _, Tester.new, _);`.
Lines whose first non-blank characters are `//` are ignored, and block
comments /* ... */ are stripped.
Usage: count_regs.py <repo> <rev>
"""
import re, subprocess, sys
repo, rev = sys.argv[1], sys.argv[2]
def git(*a):
    return subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True, text=True).stdout
files = [f for f in git("ls-tree", "--name-only", rev, "test/unittest/x86-64-linux/").split() if f.endswith(".v3")]
bind = re.compile(r'^\s*def\s+(\w+)\s*=\s*UnitTests\.registerT\(\s*"([^"]*)"')
rows = []
for f in sorted(files):
    src = git("show", f"{rev}:{f}")
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    lines = [l for l in src.splitlines() if not l.lstrip().startswith("//")]
    binders = {}
    for l in lines:
        m = bind.match(l)
        if m: binders[m.group(1)] = m.group(2)
    per = {}
    for name, prefix in binders.items():
        call = re.compile(r'(?<![\w.])' + re.escape(name) + r'\(\s*"')
        n = sum(len(call.findall(l)) for l in lines if not bind.match(l))
        per[prefix] = per.get(prefix, 0) + n
    other = sum(1 for l in lines if 'UnitTests.register' in l and not bind.match(l))
    rows.append((f.split("/")[-1], sum(per.values()), per, other))
for name, total, per, other in rows:
    groups = ", ".join(f"{p} {n}" for p, n in per.items())
    note = f"  [+{other} other register call(s)]" if other else ""
    print(f"{name:34s} {total:4d}  {groups}{note}")
