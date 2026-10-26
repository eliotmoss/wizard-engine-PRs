#!/usr/bin/env python3
"""The medium-word search of docs/persistent-backends.md, "Audit (2026-10-19)",
rerun on the allocator's and the log's files at a git revision.

Comments are set aside; string literals are kept but reported apart. For each
word, every identifier or literal that contains it (case-insensitive) is
listed. Also listed: type tests or casts to a capitalised type (Type.? /
Type.!), the backend and region classes the code names, and the members used
on a region (region.X / backendRegion.X).
Usage: audit.py <engine repo> <rev>
"""
import re, subprocess, sys
repo, rev = sys.argv[1], sys.argv[2]
FILES = ["src/engine/x86-64/X86_64RegionAllocator.v3", "src/engine/x86-64/X86_64TwoSlotWal.v3"]
WORDS = "pmem dax mmap msync fdatasync direct fsync clwb sfence file volatile".split()
CLASSES = ["StorageRegion", "StorageBackend", "FileBackedRegion", "PmemRegion", "MappedFileRegion",
           "DirectIoRegion", "PmemBackend", "MappedFileBackend", "DirectIoBackend", "VolatileRegion",
           "VolatileBackend", "X86_64Backends", "Backends"]

def segments(src):
    out, i, n, start = [], 0, len(src), 0
    while i < n:
        c = src[i]
        if src.startswith("//", i) or src.startswith("/*", i):
            out.append(("code", src[start:i]))
            j = src.find("\n", i) if src.startswith("//", i) else src.find("*/", i + 2) + 2
            j = n if j <= 0 else j
            i = start = j
            continue
        if c in "\"'":
            out.append(("code", src[start:i])); j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(("string", src[i:j + 1])); i = start = j + 1
            continue
        i += 1
    out.append(("code", src[start:]))
    return out

for f in FILES:
    src = subprocess.run(["git", "-C", repo, "show", f"{rev}:{f}"], check=True, capture_output=True, text=True).stdout
    segs = segments(src)
    code = "".join(t for k, t in segs if k == "code")
    strings = "".join(t for k, t in segs if k == "string")
    print(f"== {f} at {rev}")
    for w in WORDS:
        c = sorted(set(re.findall(r"\w*" + w + r"\w*", code, re.I)))
        s = sorted(set(re.findall(r"\w*" + w + r"\w*", strings, re.I)))
        print(f"  {w:10s} code: {', '.join(c) or '-'}; strings: {', '.join(s) or '-'}")
    print("  type tests/casts to a capitalised type:", ", ".join(sorted(set(re.findall(r"\b([A-Z]\w*)\.[!?]", code)))) or "-")
    print("  backend/region classes named:", ", ".join(n for n in CLASSES if re.search(r"\b" + n + r"\b", code)) or "-")
    print("  region members used:", ", ".join(sorted(set(re.findall(r"\b(?:backendRegion|region)\.(\w+)", code)))) or "-")
