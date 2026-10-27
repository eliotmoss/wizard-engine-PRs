#!/usr/bin/env bash
# Run the full x86-64-linux unit suite and the opt-in PMEM DAX suite on Magpie
# at one engine revision, the revision of the desktop's unit-suite run
# (results/20261026T120025Z-sean-tan-PC-unit-suite), and record both in one
# results directory.
#
# Usage, on Magpie, from a clean pwregions checkout:
#   bash scripts/magpie-test-suites.sh [DAX_DIR]      (default /mnt/pmem0.0/sean)
#
# The suites run in a detached worktree at REV, so the checkout itself stays on
# pwregions, where the results are committed. Nothing is committed or pushed:
# the script prints the commands for that at the end.
#
# Environment overrides, for testing the script elsewhere:
#   REPO=<checkout> (default: this script's repository), SKIP_DAX=1,
#   SYNC=0 to skip fetching origin and fast-forwarding pwregions (for a host
#   that cannot reach GitHub, whose checkout was brought up to date otherwise).
set -euo pipefail

REV=95e055faff802e8c179c608ef775a02c99072c09
SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
PREGEN_FIX=8b4dc856      # the pregen buffer's fix must be in REV
DESKTOP_RUN=results/20261026T120025Z-sean-tan-PC-unit-suite
DAX_DIR=${1:-/mnt/pmem0.0/sean}
REPO=${REPO:-$(cd "$(dirname "$SCRIPT")/.." && pwd)}
SKIP_DAX=${SKIP_DAX:-0}
SYNC=${SYNC:-1}
WT="$HOME/wizard-engine-wt-${REV:0:8}"

die() { echo "magpie-test-suites: $*" >&2; exit 1; }
now() { date -u -Iseconds; }

# ---- Preflight: refuse anything that would make the record ambiguous.
cd "$REPO"
[ "$(git rev-parse --abbrev-ref HEAD)" = pwregions ] || die "check out pwregions in $REPO first"
[ -z "$(git status --short)" ] || die "$REPO has uncommitted changes; commit or remove them first"
if [ "$SYNC" = 1 ]; then
	git fetch -q origin
	git merge -q --ff-only origin/pwregions || die "pwregions cannot fast-forward to origin/pwregions"
fi
git cat-file -e "$REV^{commit}" || die "revision $REV not found"
git merge-base --is-ancestor "$PREGEN_FIX" "$REV" || die "$REV lacks the pregen fix $PREGEN_FIX"
[ -d "$DESKTOP_RUN" ] || die "$DESKTOP_RUN not found; pull pwregions"
[ ! -e "$WT" ] || die "$WT already exists; remove it with: git -C $REPO worktree remove --force $WT"
V3C=$(command -v v3c-x86-64-linux || command -v v3c || true)
[ -n "$V3C" ] || die "no v3c-x86-64-linux or v3c on PATH"
if [ "$SKIP_DAX" != 1 ]; then
	[ -d "$DAX_DIR" ] && [ -w "$DAX_DIR" ] || die "$DAX_DIR is not a writable directory"
	findmnt -no OPTIONS -T "$DAX_DIR" | grep -q 'dax' || die "$DAX_DIR is not on a DAX mount"
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
R="$REPO/results/$STAMP-$(hostname -s)-test-suites"
mkdir -p "$R"
cp "$DESKTOP_RUN/count_regs.py" "$DESKTOP_RUN/summarise.py" "$R/"
cp "$SCRIPT" "$R/magpie-test-suites.sh"

git worktree add -q --detach "$WT" "$REV"
cleanup() { git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true; }
trap cleanup EXIT

# Where pregen_buffer sits in a binary and where the stubs' rounded mprotect
# ends (the crash of results/20261026T014838Z-magpie-pmem-dax-suite). Header
# 232 bytes and code 90,826 bytes were measured for 8b4dc856's stubs, which
# REV does not change; the buffer is 92 KiB plus two pages since 8b4dc856.
layout() {
	python3 -I - "$1" <<'PY'
import struct, sys
HDR, CODE, BUF = 232, 90826, 92 * 1024 + 2 * 4096
d = open(sys.argv[1], 'rb').read()
phoff, = struct.unpack_from('<Q', d, 0x20); es, n = struct.unpack_from('<HH', d, 0x36)
loads = [struct.unpack_from('<IIQQQQQQ', d, phoff + i * es) for i in range(n)]
off = d.find(struct.pack('<Q', 0x7ACEBEEF778899AA))
va = next(v + off - o for t, f, o, v, _, fs, ms, _ in loads if t == 1 and o <= off < o + fs)
po = va & 4095; k = (po + 8 + HDR + 4095) // 4096
start = va - po + 4096 * k; end = start + (CODE + 4095) // 4096 * 4096
print(f"{sys.argv[1].split('/')[-1]}: pregen_buffer at 0x{va:x} (page offset {po}); "
      f"code from page boundary {k} (0x{start:x}); mprotect to 0x{end:x}; buffer to 0x{va + BUF:x}: "
      + ("OVERRUN" if end > va + BUF else "inside the buffer"))
PY
}

# ---- Provenance.
{
	echo "---- revision"
	echo "commit   $(git -C "$WT" rev-parse HEAD)"
	echo "subject  $(git -C "$WT" log -1 --format=%s)"
	echo "run in   a detached worktree $WT at that commit; the checkout $REPO is at $(git rev-parse --short HEAD) (pwregions)"
	echo "dirty    $(git -C "$WT" status --short | wc -l) changed files in the worktree before the build"
	echo "same as  the desktop run $DESKTOP_RUN (revision $(sed -n 's/^commit *//p' "$DESKTOP_RUN/provenance.txt"))"
	echo "---- host"
	echo "hostname $(hostname)"
	echo "kernel   $(uname -srvm)"
	echo "boot_id  $(cat /proc/sys/kernel/random/boot_id)"
	echo "cmdline  $(cat /proc/cmdline)"
	echo "cpu      $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'), $(nproc) CPUs online"
	echo "user     $(id -un); sudo -n: $(sudo -n true 2>&1 && echo yes || true)"
	echo "load     $(cat /proc/loadavg) ($(now), before the builds)"
	echo "/tmp     $(findmnt -no FSTYPE,SOURCE -T /tmp)"
	echo "bin      $(findmnt -no FSTYPE,SOURCE -T "$WT") (the worktree, whose bin/ the O_DIRECT tests use if the backend refuses /tmp)"
	if [ "$SKIP_DAX" != 1 ]; then
		echo "dax      $DAX_DIR on $(findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS -T "$DAX_DIR")"
	fi
	echo "---- toolchain"
	echo "v3c      $V3C"
	VDIR=$(cd "$(dirname "$(readlink -f "$V3C")")" && git rev-parse --show-toplevel 2>/dev/null || true)
	echo "virgil   ${VDIR:-?}: $( [ -n "$VDIR" ] && git -C "$VDIR" log -1 --format='%H %cd' --date=short) $( [ -n "$VDIR" ] && [ -n "$(git -C "$VDIR" status --short)" ] && echo DIRTY)"
	echo "version  $("$V3C" -version 2>&1 | head -1)"
	echo "tools    $(make --version | head -1); $(bash --version | head -1); $(git --version); $(python3 --version)"
} > "$R/provenance.txt" 2>&1

# ---- Unit suite: build, check the stubs' layout, run as on the desktop.
cd "$WT"
echo "---- unit suite" >> "$R/provenance.txt"
echo "build    started $(now)" >> "$R/provenance.txt"
st=0; make bin/unittest.x86-64-linux > "$R/unit-build.log" 2>&1 || st=$?
echo "build    finished $(now), exit $st" >> "$R/provenance.txt"
[ $st = 0 ] || die "the unit binary did not build; see $R/unit-build.log"
sha256sum bin/unittest.x86-64-linux >> "$R/provenance.txt"
layout bin/unittest.x86-64-linux > "$R/pregen-layout.txt"
echo "run      started $(now): env TEST_TARGET=x86-64-linux test/unit.sh" >> "$R/provenance.txt"
TIMER=(); if [ -x /usr/bin/time ]; then TIMER=(/usr/bin/time -v -o "$R/unit-time.txt"); fi
RAW="/tmp/$USER/wizeng-test/unit/x86-64-linux/unit.sh.log"
rm -f "$RAW"
st=0; ${TIMER[@]+"${TIMER[@]}"} env TEST_TARGET=x86-64-linux test/unit.sh > "$R/unit-stdout.log" 2>&1 || st=$?
echo "run      finished $(now), unit.sh exit $st (tee's status; the outcome is read from unit.log)" >> "$R/provenance.txt"
[ -s "$RAW" ] || die "unit.sh wrote no log; see $R/unit-stdout.log"
cp "$RAW" "$R/unit.log"
echo "dirty    $(git status --short | wc -l) changed files in the worktree after the unit run" >> "$R/provenance.txt"

# ---- DAX suite.
if [ "$SKIP_DAX" != 1 ]; then
	echo "---- DAX suite" >> "$R/provenance.txt"
	st=0; make bin/pmemtest.x86-64-linux > "$R/dax-build.log" 2>&1 || st=$?
	[ $st = 0 ] || die "the DAX test binary did not build; see $R/dax-build.log"
	sha256sum bin/pmemtest.x86-64-linux >> "$R/provenance.txt"
	layout bin/pmemtest.x86-64-linux >> "$R/pregen-layout.txt"
	echo "run      started $(now): PWASM_PMEM_TEST_DIR=$DAX_DIR make pmem-integration" >> "$R/provenance.txt"
	st=0; PWASM_PMEM_TEST_DIR="$DAX_DIR" make pmem-integration > "$R/dax.log" 2>&1 || st=$?
	echo "exit $st" >> "$R/dax.log"
	echo "run      finished $(now), exit $st" >> "$R/provenance.txt"
	# The runner removes its own region file only on success.
	left=$(sed -n 's/^Using temporary PMEM region: //p' "$R/dax.log")
	if [ -n "$left" ] && [ -e "$left" ]; then rm -f -- "$left"; echo "removed  the leftover region file $left" >> "$R/provenance.txt"; fi
fi

# ---- Summaries.
cd "$R"
python3 -I count_regs.py "$REPO" "$REV" > registrations.txt
python3 -I summarise.py unit.log registrations.txt > summarise-out.txt
grep '^##+' unit.log | sort > /tmp/names-magpie.$$
grep '^##+' "$REPO/$DESKTOP_RUN/unit.log" | sort > /tmp/names-desktop.$$
diff /tmp/names-desktop.$$ /tmp/names-magpie.$$ > names-vs-desktop.diff || true
rm -f /tmp/names-magpie.$$ /tmp/names-desktop.$$
python3 -I - unit.log "$REPO/$DESKTOP_RUN/unit.log" > outcomes-vs-desktop.txt <<'PY'
import sys
def outcomes(p):
    res, cur = {}, None
    for l in open(p, errors="replace"):
        l = l.rstrip("\n")
        if l.startswith("##+"): cur = l[3:]
        elif l.startswith("##-") and cur:
            res[cur] = "ok" if l == "##-ok" else "expected-fail" if l.startswith("##-ok (ignored") else "FAIL"
            cur = None
    return res
m, d = outcomes(sys.argv[1]), outcomes(sys.argv[2])
diff = sorted(n for n in set(m) | set(d) if m.get(n) != d.get(n))
print(f"tests whose result differs from the desktop run: {len(diff)}")
for n in diff: print(f"  {n}: desktop {d.get(n)!r}, here {m.get(n)!r}")
PY

{
	echo
	echo "==== outcome ($R)"
	grep -m1 '^##>' unit.log || echo "no '##>' header in unit.log"
	tail -2 summarise-out.txt
	echo "names vs desktop: $( [ -s names-vs-desktop.diff ] && echo DIFFER, see names-vs-desktop.diff || echo identical)"
	head -1 outcomes-vs-desktop.txt
	cat pregen-layout.txt
	[ "$SKIP_DAX" = 1 ] || grep -E '^##[-+]|^exit' dax.log || true
} | tee summary-head.txt
echo
echo "If every line above is as expected, commit and push the results:"
echo "  cd $REPO && git add results/$(basename "$R") && git commit -m \"results: the unit and DAX suites on $(hostname -s) at ${REV:0:8}\" && git push origin pwregions"
