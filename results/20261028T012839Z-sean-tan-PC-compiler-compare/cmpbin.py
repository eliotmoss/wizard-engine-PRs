import subprocess, re, sys
def syms(path):
    out = subprocess.run(["nm", "-S", path], capture_output=True, text=True).stdout
    d = {}
    for line in out.splitlines():
        p = line.split(None, 3)
        if len(p) == 4 and p[2] in "Tt":
            d[p[3]] = (int(p[0], 16), int(p[1], 16))
    return d
def dis(path):
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", path], capture_output=True, text=True).stdout
    fns = {}; cur = None
    for l in out.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", l)
        if m: cur = m.group(1); fns[cur] = []; continue
        if cur and "\t" in l:
            fns[cur].append(re.sub(r"0x[0-9a-f]+|\b[0-9a-f]{4,}\b", "N", l.split("\t", 1)[1]))
    return fns
for d in sys.argv[1:]:
    prog = d.split("-", 2)[2]
    o = f"{d}-old/bin/{prog}.x86-64-linux"; n = f"{d}-new/bin/{prog}.x86-64-linux"
    so, sn = syms(o), syms(n)
    common = set(so) & set(sn)
    resized = sorted(k for k in common if so[k][1] != sn[k][1])
    moved = sum(1 for k in common if so[k][0] != sn[k][0])
    do, dn = dis(o), dis(n)
    shape = sorted(k for k in set(do) & set(dn) if do[k] != dn[k] and not k.startswith("."))
    print(f"{d}: {len(sn)} functions (+{len(set(sn)-set(so))} -{len(set(so)-set(sn))}); resized {len(resized)}; at a new address {moved}; instructions differ beyond constants {len(shape)}: {shape}")
    if resized: print("   resized:", resized)
