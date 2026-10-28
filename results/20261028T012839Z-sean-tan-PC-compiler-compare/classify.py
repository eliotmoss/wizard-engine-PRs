# For each benchmark build pair, classify every constant that differs between the
# two compilers' instructions: data addresses (>= 0x100000) and smaller values,
# and list every differing small value with its instruction.
import subprocess, re, sys, collections
def dis(path):
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", path], capture_output=True, text=True).stdout
    fns = {}; cur = None
    for l in out.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", l)
        if m: cur = m.group(1); fns[cur] = []; continue
        if cur and "\t" in l: fns[cur].append(l.split("\t", 1)[1].split("#")[0].strip())
    return fns
for d in sys.argv[1:]:
    prog = d.split("-", 2)[2]
    do = dis(f"{d}-old/bin/{prog}.x86-64-linux"); dn = dis(f"{d}-new/bin/{prog}.x86-64-linux")
    kinds = collections.Counter(); small = []
    for k in sorted(set(do) & set(dn)):
        if k.startswith(".") or len(do[k]) != len(dn[k]): continue
        for a, b in zip(do[k], dn[k]):
            if a == b: continue
            na = re.findall(r"0x[0-9a-f]+", a); nb = re.findall(r"0x[0-9a-f]+", b)
            if len(na) != len(nb) or re.sub(r"0x[0-9a-f]+", "N", a) != re.sub(r"0x[0-9a-f]+", "N", b):
                kinds["other"] += 1; small.append(("other", k, a, b)); continue
            for x, y in zip(na, nb):
                if x == y: continue
                if int(x, 16) >= 0x100000: kinds["data address"] += 1
                else: kinds["small value"] += 1; small.append(("small", k, a, b))
    print(f"== {d}: {dict(kinds)}")
    for s in small: print("  ", *s, sep=" | ")
