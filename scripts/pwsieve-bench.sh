#!/usr/bin/env bash
#
# What a sieve step costs through the production allocator and WAL, and how
# much of it is persistence, on each backend (test/pwsievebench.main.v3). The
# workload is PWSieve, whose transactions the harness does not choose: pwbench
# measures one controlled transaction shape, this measures a program's.
#
#   scripts/pwsieve-bench.sh doctor            what this host can run, and why not
#   scripts/pwsieve-bench.sh campaign          the runs, into results/<stamp>-<host>-pwsieve-bench
#   scripts/pwsieve-bench.sh summary <dir>     recompute the summary from runs.csv
#   scripts/pwsieve-bench.sh rebuild <dir>     re-derive runs.csv from the run logs, then
#                                              the summary; the old one is kept as runs.csv.orig
#
# Configurations:
#
#   pmem-auto        PMEM backend on the DAX mount, production writeback (CPUID)
#   pmem-clflushopt  the same with CLFLUSHOPT, which always invalidates the line
#   pmem-clwb        the same with CLWB named explicitly (not in the default)
#   pmem-none        no writeback at all -- timing only, never durable -- so
#                    pmem-auto minus pmem-none is what the writebacks cost a step
#   file-dax         the file backend (msync/fdatasync) on the same DAX mount
#   file-block       the file backend on block storage (PWSB_BLOCK_DIR)
#   direct-block     the direct backend (pwrite + O_DIRECT + fdatasync) on the
#                    same block storage (PWSB_BLOCK_DIR)
#
# The block configurations run only when PWSB_BLOCK_DIR is set, and never on a
# network filesystem, whose fdatasync would measure the network. The default is
# the four DAX configurations, plus the two block ones when PWSB_BLOCK_DIR is set.
#
# Each run is one pwsievebench invocation: PWSB_ROUNDS rounds, each a freshly
# formatted region, PWSB_WARMUP unmeasured steps, then every step the region's
# descriptor table has left (159 at the default geometry), verified against a
# reference sieve after the round. Runs are interleaved, repetition outermost
# and configuration innermost, so a load spike lands on one sample of each.
#
# Pinning. PWSB_CPUS pins every run to a CPU list with taskset (needed on hybrid
# CPUs, whose two core types differ: pick CPUs of one type; doctor lists them).
# Otherwise runs are pinned with numactl to the NUMA node that owns the DAX
# namespace (PWSB_NUMA_NODE=auto, the default; none, or a node number).
#
# Overrides: PWASM_PMEM_TEST_DIR (required: your writable directory on the DAX
# mount), PWSB_BLOCK_DIR, PWSB_REPS (5), PWSB_ROUNDS (20), PWSB_WARMUP (8),
# PWSB_GEOMETRY (256x4096, <blocks>x<blockSize>: 1 MiB, which a DAX file maps
# with 4 KiB entries -- at 2 MiB and above fdatasync on DAX writes back whole
# 2 MiB entries, docs/persistent-backends.md), PWSB_CONFIGS, PWSB_CPUS,
# PWSB_NUMA_NODE, PWSB_OUT (results/<stamp>-<host>-pwsieve-bench[-cpus<list>]),
# PWSB_ALLOW_DIRTY (0).

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

REPS="${PWSB_REPS:-5}"
ROUNDS="${PWSB_ROUNDS:-20}"
WARMUP="${PWSB_WARMUP:-8}"
GEOMETRY="${PWSB_GEOMETRY:-256x4096}"
BLOCK_DIR="${PWSB_BLOCK_DIR:-}"
DEFAULT_CONFIGS="pmem-auto pmem-clflushopt pmem-none file-dax"
[ -n "$BLOCK_DIR" ] && DEFAULT_CONFIGS="$DEFAULT_CONFIGS file-block direct-block"
CONFIGS="${PWSB_CONFIGS:-$DEFAULT_CONFIGS}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CPU_TAG=
[ -n "${PWSB_CPUS:-}" ] && CPU_TAG="-cpus${PWSB_CPUS//,/_}"
OUT="${PWSB_OUT:-$REPO/results/$STAMP-$(hostname -s)-pwsieve-bench$CPU_TAG}"

BENCH_BIN=bin/pwsievebench.x86-64-linux

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rule() { printf -- '---- %s\n' "$*"; }
loadavg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown"; }

# ------------------------------------------------------------ host facts
# The helpers below are the same as scripts/clwb-eviction.sh's.

source_of() { findmnt -no SOURCE -T "$1" 2>/dev/null || echo unknown; }
fstype_of() { findmnt -no FSTYPE -T "$1" 2>/dev/null || echo unknown; }
options_of() { findmnt -no OPTIONS -T "$1" 2>/dev/null || echo unknown; }

numa_node_of() {
    local src dev f
    src=$(source_of "$1"); dev=${src##*/}
    for f in "/sys/block/$dev/device/numa_node" "/sys/bus/nd/devices/region${dev#pmem}/numa_node"; do
        if [ -r "$f" ]; then cat "$f"; return; fi
    done
    echo unknown
}

hybrid_topology() {
    local t out=
    for t in cpu_core cpu_atom; do
        [ -r "/sys/devices/$t/cpus" ] && out="$out$t=$(cat "/sys/devices/$t/cpus") "
    done
    echo "${out:-not hybrid}"
}

expand_cpus() {
    local part
    local -a parts
    IFS=, read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then seq "${part%-*}" "${part#*-}"; else echo "$part"; fi
    done
}

core_types_of() {
    local t cpu members found=
    for t in cpu_core cpu_atom; do
        [ -r "/sys/devices/$t/cpus" ] || continue
        members=" $(expand_cpus "$(cat "/sys/devices/$t/cpus")" | tr '\n' ' ')"
        for cpu in $(expand_cpus "$1"); do
            if [[ "$members" == *" $cpu "* ]]; then found="$found${found:+ + }$t"; break; fi
        done
    done
    echo "${found:-not hybrid}"
}

PIN=()
PIN_DESC=none
resolve_pinning() {
    local want=${PWSB_NUMA_NODE:-auto} node
    if [ -n "${PWSB_CPUS:-}" ]; then
        [[ "$PWSB_CPUS" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] ||
            die "PWSB_CPUS is not a CPU list such as 2 or 16-19,24: $PWSB_CPUS"
        have taskset || die "PWSB_CPUS needs taskset (util-linux)"
        local types; types=$(core_types_of "$PWSB_CPUS")
        [[ "$types" == *" + "* ]] && warn "PWSB_CPUS=$PWSB_CPUS spans both core types; the timings will mix two microarchitectures"
        PIN=(taskset -c "$PWSB_CPUS")
        PIN_DESC="cpus $PWSB_CPUS ($types)"
        return
    fi
    if [ "$want" = none ]; then PIN_DESC="disabled"; return; fi
    have numactl || { PIN_DESC="unavailable (no numactl)"; return; }
    if [ "$want" = auto ]; then node=$(numa_node_of "$PWASM_PMEM_TEST_DIR"); else node=$want; fi
    case "$node" in ''|*[!0-9]*) PIN_DESC="undetermined ($node)"; return ;; esac
    PIN=(numactl "--cpunodebind=$node" --)
    PIN_DESC="node $node"
}

is_dax_dir() {
    local opts; opts=$(findmnt -no OPTIONS -T "$1" 2>/dev/null) || return 1
    [[ ",$opts," == *",dax,"* || ",$opts," == *",dax=always,"* ]]
}

is_network_fs() {
    case "$(fstype_of "$1")" in nfs|nfs4|cifs|smb3|smbfs|fuse.sshfs|9p|ceph|glusterfs|lustre) return 0 ;; esac
    return 1
}

# The configurations that need each directory.
uses_dax()   { [[ " $CONFIGS " == *" pmem-"* || " $CONFIGS " == *" file-dax "* ]]; }
uses_block() { [[ " $CONFIGS " == *" file-block "* || " $CONFIGS " == *" direct-block "* ]]; }

# Refused rather than warned about, as in clwb-eviction.sh: off a DAX mount
# the pmem configurations fail, but file-dax would run on whatever filesystem
# this is and be recorded as a DAX result.
require_dirs() {
    if uses_dax; then
        [ -n "${PWASM_PMEM_TEST_DIR:-}" ] || die "PWASM_PMEM_TEST_DIR must name your writable directory on the fsdax mount"
        [ -d "$PWASM_PMEM_TEST_DIR" ] && [ -w "$PWASM_PMEM_TEST_DIR" ] ||
            die "PWASM_PMEM_TEST_DIR is not a writable directory: $PWASM_PMEM_TEST_DIR"
        is_dax_dir "$PWASM_PMEM_TEST_DIR" ||
            die "PWASM_PMEM_TEST_DIR ($PWASM_PMEM_TEST_DIR) is on $(source_of "$PWASM_PMEM_TEST_DIR"), options '$(options_of "$PWASM_PMEM_TEST_DIR")': not a dax or dax=always mount"
    fi
    if uses_block; then
        [ -n "$BLOCK_DIR" ] || die "file-block and direct-block need PWSB_BLOCK_DIR, a writable directory on block storage"
        [ -d "$BLOCK_DIR" ] && [ -w "$BLOCK_DIR" ] || die "PWSB_BLOCK_DIR is not a writable directory: $BLOCK_DIR"
        is_dax_dir "$BLOCK_DIR" && die "PWSB_BLOCK_DIR ($BLOCK_DIR) is on a DAX mount; the block configurations need block storage"
        is_network_fs "$BLOCK_DIR" && die "PWSB_BLOCK_DIR ($BLOCK_DIR) is on $(fstype_of "$BLOCK_DIR"), a network filesystem: fdatasync would measure the network"
    fi
    return 0
}

require_clean_tree() {
    [ "${PWSB_ALLOW_DIRTY:-0}" = 1 ] && return 0
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && return 0
    die "working tree is dirty; commit first so the results name a revision, or set PWSB_ALLOW_DIRTY=1"
}

# config -> "<backend> <directory> [writeback=<w>]"
config_args() {
    case "$1" in
        pmem-auto|pmem-clwb|pmem-clflushopt|pmem-none)
                      echo "pmem ${PWASM_PMEM_TEST_DIR:-.} writeback=${1#pmem-}" ;;
        file-dax)     echo "file ${PWASM_PMEM_TEST_DIR:-.}" ;;
        file-block)   echo "file ${BLOCK_DIR:-.}" ;;
        direct-block) echo "direct ${BLOCK_DIR:-.}" ;;
        *) die "unknown configuration: $1" ;;
    esac
}

write_provenance() {
    {
        rule "revision"
        git -C "$REPO" log -1 --pretty='commit %H%nsubject  %s'
        printf 'dirty    %s\n' "$(git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && echo no || echo YES)"
        rule "host"
        printf 'hostname %s\nkernel   %s\nstarted  %s\nload     %s\n' \
            "$(hostname -f 2>/dev/null || hostname)" "$(uname -srmo)" "$(date -uIseconds)" "$(loadavg)"
        rule "cpu"
        if have lscpu; then lscpu | grep -Ei 'model name|^model:|stepping|^cpu\(s\)|thread|l1d|l2|l3' || true; fi
        grep -m1 -E '^microcode' /proc/cpuinfo 2>/dev/null || true
        printf 'hybrid   %s\n' "$(hybrid_topology)"
        printf 'governor %s\n' "$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';' || true)"
        rule "directories"
        if uses_dax; then
            printf 'dax      %s\n  source  %s\n  options %s\n  node    %s\n' "$PWASM_PMEM_TEST_DIR" \
                "$(source_of "$PWASM_PMEM_TEST_DIR")" "$(options_of "$PWASM_PMEM_TEST_DIR")" "$(numa_node_of "$PWASM_PMEM_TEST_DIR")"
        fi
        if uses_block; then
            printf 'block    %s\n  source  %s\n  fstype  %s\n  options %s\n' "$BLOCK_DIR" \
                "$(source_of "$BLOCK_DIR")" "$(fstype_of "$BLOCK_DIR")" "$(options_of "$BLOCK_DIR")"
        fi
        printf 'pinned   %s\n' "$PIN_DESC"
        rule "parameters"
        printf 'reps %s\nrounds %s\nwarmup %s\ngeometry %s\nconfigs %s\n' "$REPS" "$ROUNDS" "$WARMUP" "$GEOMETRY" "$CONFIGS"
    } > "$OUT/provenance.txt"
}

# ------------------------------------------------------------ runs

CSV=
csv_header() {
    CSV=$OUT/runs.csv
    echo "config,rep,tsc_per_us,steps,wall_ns_per_step,step_ns_mean,step_ns_median,step_ns_p90,compute_ns,alloc_ns,bitmap_ns,publish_ns,retire_ns,boundaries_x1000,prepare_x1000,clwb_lines_x1000,faults_x1000,load1" > "$CSV"
}

parse_bench() {
    awk '
        function last() { t = $NF; sub(/[,:]+$/, "", t); return t }
        /^tsc cycles per microsecond/   { tsc = last() }
        /^steps measured/               { steps = last() }
        /^wall ns per step/             { wall = last() }
        /^step ns: mean/                { mean = last() }
        /^step ns: min/                 { for (i = 1; i <= NF; i++) { if ($i == "median") med = $(i + 1); if ($i == "p90") p90 = $(i + 1) } }
        /^phase compute ns per step/    { compute = last() }
        /^phase alloc ns per step/      { alloc = last() }
        /^phase bitmap ns per step/     { bitmap = last() }
        /^phase publish ns per step/    { publish = last() }
        /^phase retire ns per step/     { retire = last() }
        /^boundaries per step x1000/    { bpc = last() }
        /^prepare calls per step x1000/ { prep = last() }
        /^clwb lines per step x1000/    { lines = last() }
        /^minor faults per step x1000/  { faults = last() }
        END { print tsc "," steps "," wall "," mean "," med "," p90 "," compute "," alloc "," bitmap "," publish "," retire "," bpc "," prep "," lines "," faults }' "$1"
}

# Check one finished run's log against its configuration and append its row.
# Shared by the campaign and by rebuild, so both apply the same checks.
record_run() {
    local config=$1 rep=$2 load=$3 log=$4 dir=${5:-}
    local args; read -r -a args <<< "$(config_args "$config")"
    local backend=${args[0]} wb=
    [ "${#args[@]}" -gt 2 ] && wb=${args[2]#writeback=}
    local want='^OK$'
    [ "$wb" = none ] && want='^OK timing-only: writeback=none'
    grep -qE "$want" "$log" || { warn "    no expected final line in $log"; return 1; }
    grep -q "^backend $backend " "$log" || { warn "    $log does not name backend $backend"; return 1; }
    # pwsievebench prints the label (CLFLUSHOPT), not the argument: match
    # case-insensitively up to the label's end.
    if [ -n "$wb" ]; then
        grep -qiE "^writeback $wb([ ,]|$)" "$log" || { warn "    $log does not name writeback $wb"; return 1; }
    fi
    grep -q 'reference sieve agrees' "$log" || { warn "    $log has no reference check"; return 1; }
    # Only a fresh run knows its directory; a rebuild elsewhere cannot.
    if [ -n "$dir" ]; then
        grep -qxF "directory $dir" "$log" || { warn "    $log does not name directory $dir"; return 1; }
    fi
    local row; row=$(parse_bench "$log")
    [[ "$row" != *,,* && "$row" != ,* && "$row" != *, ]] ||
        { warn "    could not parse $log -- pwsievebench's output format has moved: $row"; return 1; }
    printf '%s,%s,%s,%s\n' "$config" "$rep" "$row" "$load" >> "$CSV"
}

run_one() {
    local config=$1 rep=$2 blocks=${GEOMETRY%%x*} bs=${GEOMETRY#*x}
    local log="$OUT/run-$config-r$rep.log"
    local args; read -r -a args <<< "$(config_args "$config")"
    local load; load=$(loadavg | cut -d' ' -f1)
    say "  $config rep=$rep"
    "${PIN[@]}" "$BENCH_BIN" "${args[1]}" "${args[0]}" "$ROUNDS" "$WARMUP" "$blocks" "$bs" "${args[@]:2}" > "$log" 2>&1 ||
        { warn "    FAILED -- see $log"; tail -3 "$log" >&2; return 1; }
    record_run "$config" "$rep" "$load" "$log" "${args[1]}"
}

campaign() {
    local c; for c in $CONFIGS; do config_args "$c" >/dev/null; done
    require_dirs
    require_clean_tree
    case "$GEOMETRY" in *x*) ;; *) die "PWSB_GEOMETRY is not <blocks>x<blockSize>: $GEOMETRY" ;; esac
    make "$BENCH_BIN" >/dev/null || die "could not build $BENCH_BIN"
    resolve_pinning
    mkdir -p "$OUT"
    write_provenance
    csv_header
    say "results -> $OUT (pinned $PIN_DESC)"
    local failures=0 rep
    for rep in $(seq 1 "$REPS"); do
        for c in $CONFIGS; do
            run_one "$c" "$rep" || failures=$((failures + 1))
        done
    done
    printf 'finished %s\nload     %s\n' "$(date -uIseconds)" "$(loadavg)" >> "$OUT/provenance.txt"
    summary "$OUT" | tee "$OUT/summary.txt"
    [ "$failures" -eq 0 ] || die "$failures run(s) failed or were rejected; see above"
}

rebuild() {
    local dir=$1 f name config rep load
    [ -d "$dir" ] || die "not a directory: $dir"
    ls "$dir"/run-*.log >/dev/null 2>&1 || die "no run logs in $dir"
    [ -f "$dir/runs.csv" ] && [ ! -f "$dir/runs.csv.orig" ] && cp "$dir/runs.csv" "$dir/runs.csv.orig"
    OUT=$dir
    csv_header
    local failures=0
    for f in "$dir"/run-*.log; do
        name=${f##*/run-}; name=${name%.log}
        [[ "$name" =~ ^(.+)-r([0-9]+)$ ]] || { warn "    unrecognised log name: $f"; failures=$((failures + 1)); continue; }
        config=${BASH_REMATCH[1]} rep=${BASH_REMATCH[2]} load=NA
        [ -f "$dir/runs.csv.orig" ] && load=$(awk -F, -v k="$config,$rep" 'index($0, k ",") == 1 { print $NF; exit }' "$dir/runs.csv.orig")
        record_run "$config" "$rep" "${load:-NA}" "$f" || failures=$((failures + 1))
    done
    say "rebuilt $CSV from $(ls "$dir"/run-*.log | wc -l | tr -d ' ') logs ($failures rejected)"
    summary "$dir" | tee "$dir/summary.txt"
    [ "$failures" -eq 0 ] || die "$failures log(s) rejected; see the messages above"
}

# Medians over repetitions per configuration, the repetitions' spread, and the
# writebacks' cost by removal. Wall time is the measure throughout.
summary() {
    local csv=$1/runs.csv
    [ -f "$csv" ] || die "no runs.csv in $1"
    awk -F, '
        NR == 1 { next }
        { c = $1; if (!(c in seen)) { seen[c] = 1; order[++n] = c }
          for (k = 3; k <= 17; k++) v[c, k] = v[c, k] " " $k; reps[c]++ }
        function med(s,   a, m, i, j, t) { m = split(s, a, " ")
            for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
            if (m == 0) return ""; if (m % 2) return a[(m + 1) / 2]; return (a[m / 2] + a[m / 2 + 1]) / 2 }
        function lo(s,   a, m, i, r) { m = split(s, a, " "); r = a[1]; for (i = 2; i <= m; i++) if (a[i] + 0 < r + 0) r = a[i]; return r }
        function hi(s,   a, m, i, r) { m = split(s, a, " "); r = a[1]; for (i = 2; i <= m; i++) if (a[i] + 0 > r + 0) r = a[i]; return r }
        END {
            print "---- per step, median over repetitions (ns unless noted; steps per run in the log)"
            printf "%-16s %4s %9s %13s %9s %8s %8s %8s %8s %8s %8s %6s %7s %6s\n", "config", "reps", "wall", "wall range", "median", "compute", "alloc", "bitmap", "publish", "retire", "persist", "bound", "lines", "faults"
            for (i = 1; i <= n; i++) { c = order[i]
                w = med(v[c, 5]); p = med(v[c, 10]) + med(v[c, 11]) + med(v[c, 12]) + med(v[c, 13])
                persist[c] = p; wall[c] = w
                printf "%-16s %4d %9.0f %6.0f-%-6.0f %9.0f %8.0f %8.0f %8.0f %8.0f %8.0f %8.0f %6.2f %7.1f %6.2f\n", c, reps[c], w, lo(v[c, 5]), hi(v[c, 5]), med(v[c, 7]),
                    med(v[c, 9]), med(v[c, 10]), med(v[c, 11]), med(v[c, 12]), med(v[c, 13]), p,
                    med(v[c, 14]) / 1000, med(v[c, 16]) / 1000, med(v[c, 17]) / 1000 }
            print ""
            print "---- shares"
            for (i = 1; i <= n; i++) { c = order[i]
                if (wall[c] > 0) printf "%-16s persistence phases (alloc+bitmap+publish+retire) %5.1f %% of a step\n", c, 100 * persist[c] / wall[c] }
            if (("pmem-auto" in wall) && ("pmem-none" in wall) && wall["pmem-auto"] > 0) {
                d = wall["pmem-auto"] - wall["pmem-none"]
                printf "writebacks by removal: pmem-auto - pmem-none = %.0f ns per step (%.1f %% of pmem-auto)\n", d, 100 * d / wall["pmem-auto"]
            }
            if (("pmem-auto" in wall) && ("pmem-clflushopt" in wall) && wall["pmem-auto"] > 0) {
                d = wall["pmem-clflushopt"] - wall["pmem-auto"]
                printf "instruction: pmem-clflushopt - pmem-auto = %.0f ns per step (%.1f %%)\n", d, 100 * d / wall["pmem-auto"]
            }
            print ""
            print "Columns: wall = wall ns per step (clock_gettime over the measured steps); median = the median"
            print "step (rdtsc); the phases are means; persist = the four persistence phases; bound = persistence"
            print "boundaries per step; lines = cache-line writebacks per step (pmem only); faults = minor faults"
            print "per step. A difference of a few percent is real only outside the wall range of both."
        }' "$csv"
}

doctor() {
    rule "revision"
    git -C "$REPO" log -1 --oneline
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && say "tree clean" || warn "tree DIRTY (the campaign refuses unless PWSB_ALLOW_DIRTY=1)"
    rule "cpu"
    if have lscpu; then lscpu | grep -Ei 'model name|^model:|stepping' || true; fi
    local topo; topo=$(hybrid_topology)
    if [ "$topo" != "not hybrid" ]; then
        say "hybrid $topo"
        warn "hybrid CPU: set PWSB_CPUS to CPUs of one core type (cpu_core = performance, cpu_atom = efficiency)"
    fi
    say "governor $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';' || echo unknown)"
    rule "dax directory (PWASM_PMEM_TEST_DIR)"
    if [ -z "${PWASM_PMEM_TEST_DIR:-}" ]; then
        warn "unset: the pmem-* and file-dax configurations cannot run"
    else
        say "$PWASM_PMEM_TEST_DIR"
        say "  source  $(source_of "$PWASM_PMEM_TEST_DIR")"
        say "  options $(options_of "$PWASM_PMEM_TEST_DIR")"
        say "  node    $(numa_node_of "$PWASM_PMEM_TEST_DIR")"
        [ -w "$PWASM_PMEM_TEST_DIR" ] && say "  writable yes" || warn "  NOT writable"
        is_dax_dir "$PWASM_PMEM_TEST_DIR" || warn "  NOT a DAX mount: the campaign will refuse it"
    fi
    rule "block directory (PWSB_BLOCK_DIR)"
    if [ -z "$BLOCK_DIR" ]; then
        say "unset: file-block and direct-block are skipped"
    else
        say "$BLOCK_DIR"
        say "  source  $(source_of "$BLOCK_DIR")"
        say "  fstype  $(fstype_of "$BLOCK_DIR")"
        say "  options $(options_of "$BLOCK_DIR")"
        [ -w "$BLOCK_DIR" ] && say "  writable yes" || warn "  NOT writable"
        is_dax_dir "$BLOCK_DIR" && warn "  a DAX mount: the block configurations would refuse it"
        is_network_fs "$BLOCK_DIR" && warn "  a network filesystem: the block configurations would refuse it"
    fi
    rule "tools"
    printf 'taskset          %s\n' "$(have taskset && echo present || echo 'absent -- PWSB_CPUS unavailable')"
    printf 'numactl          %s\n' "$(have numactl && echo present || echo 'absent -- runs are unpinned')"
    printf 'pwsievebench     %s\n' "$([ -x "$BENCH_BIN" ] && echo present || echo 'absent (campaign builds it)')"
    rule "configurations"
    say "$CONFIGS"
    rule "load"
    say "$(loadavg)"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

case "${1:-doctor}" in
    doctor)   doctor ;;
    campaign) campaign ;;
    rebuild)  [ -n "${2:-}" ] || die "rebuild needs a results directory"
              rebuild "$2" ;;
    summary)  [ -n "${2:-}" ] || die "summary needs a results directory"
              summary "$2" ;;
    help|-h|--help) usage ;;
    *)        usage; exit 2 ;;
esac
