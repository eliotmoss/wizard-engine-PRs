#!/usr/bin/env bash
#
# Is CLWB evicting written-back lines the reason the PMEM backend's non-boundary
# commit work grows about twice as fast per entry as the file backend's on the
# same DAX media (docs/persistent-backends.md, "Whole commits tell a different
# story")? Three steps, each able to refute the lead on its own:
#
#   scripts/clwb-eviction.sh doctor     what this host can run, and why not
#   scripts/clwb-eviction.sh probe      1. instruction level: does a line survive
#                                          CLWB? (scripts/clwbprobe.c)
#   scripts/clwb-eviction.sh campaign   2+3. pwbench under perf stat: misses to
#                                          PMEM per commit, and what changes when
#                                          the writeback is swapped or removed
#   scripts/clwb-eviction.sh all        probe, then campaign, in one directory
#   scripts/clwb-eviction.sh summary <results-dir>
#                                       recompute the summary from a finished run
#   scripts/clwb-eviction.sh rebuild <results-dir>
#                                       re-derive runs.csv from the run logs (and
#                                       .perf files), then the summary; the old
#                                       runs.csv is kept as runs.csv.orig
#
# Campaign configurations, all on the DAX mount (PWASM_PMEM_TEST_DIR):
#
#   pmem-auto        the production path (CPUID selects CLWB on Cascade Lake)
#   pmem-clflushopt  the same, with CLFLUSHOPT, which always invalidates
#   pmem-deferred    each distinct line written back once, at the next fence
#                    (durability unchanged): no entry stores into a line the
#                    previous entry's writeback just evicted
#   pmem-none        no writeback at all -- timing only, never durable
#   file-dax         the file backend; its fdatasync writes back in the kernel
#   <config>-s64     any of the above with one entry per cache line (pwbench
#                    stride=64): the same writebacks, no same-line store after one
#
# The first campaign (results/20260928T001505Z-magpie-clwb-eviction) ran
# "pmem-auto pmem-clflushopt pmem-none file-dax" and established that CLWB
# evicts and that the writebacks account for the whole per-entry gap. The
# default is now the follow-up, which asks whether the cost is the store into a
# just-evicted line within the commit (see the reading guide in the summary).
#
# Every configuration runs at two commit counts, and a perf counter's value per
# commit is the difference between the two runs divided by the difference in
# commits, which cancels format, calibration and warmup. Counters are user-space
# only (:u): the gap under study is outside the boundary, and the file backend's
# boundary is kernel work. pwbench's own figures cover only the measured commits
# and need no differencing. Runs are interleaved (rep outermost, configuration
# innermost) and pinned to the DAX namespace's node, as in pmem-experiments.sh.
#
# perf is optional: without it (or with perf_event_paranoid above 2) the
# campaign still runs and reports timing; the counter columns are then absent,
# and the summary says so.
#
# Overrides: PWASM_PMEM_TEST_DIR (required), PWCLWB_REPS (3), PWCLWB_SIZES
# ("1 8 24"), PWCLWB_GEOMETRY (512x2048, the geometry of the finding),
# PWCLWB_COMMITS ("20000 120000"), PWCLWB_WARMUP (2000), PWCLWB_CONFIGS (all
# the follow-up set), PWCLWB_NUMA_NODE (auto | none | <n>), PWCLWB_OUT (results/<stamp>-
# <host>-clwb-eviction), PWCLWB_ALLOW_DIRTY (0), PWCLWB_CC (cc), PWCLWB_EVENTS
# (a comma-separated perf event list replacing the discovered one).

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

REPS="${PWCLWB_REPS:-3}"
SIZES="${PWCLWB_SIZES:-1 8 24}"
GEOMETRY="${PWCLWB_GEOMETRY:-512x2048}"
COMMITS="${PWCLWB_COMMITS:-20000 120000}"
WARMUP="${PWCLWB_WARMUP:-2000}"
CONFIGS="${PWCLWB_CONFIGS:-pmem-auto pmem-deferred pmem-none file-dax pmem-auto-s64 pmem-deferred-s64 pmem-none-s64 file-dax-s64}"
CC_BIN="${PWCLWB_CC:-cc}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${PWCLWB_OUT:-$REPO/results/$STAMP-$(hostname -s)-clwb-eviction}"

BENCH_BIN=bin/pwbench.x86-64-linux
PROBE_SRC=scripts/clwbprobe.c
PROBE_BIN=bin/clwbprobe.x86-64-linux

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rule() { printf -- '---- %s\n' "$*"; }
loadavg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown"; }

# ------------------------------------------------------------ host facts

source_of() { findmnt -no SOURCE -T "$1" 2>/dev/null || echo unknown; }

# The same lookup pmem-experiments.sh makes: the node owning the namespace.
numa_node_of() {
    local src dev f
    src=$(source_of "$1"); dev=${src##*/}
    for f in "/sys/block/$dev/device/numa_node" "/sys/bus/nd/devices/region${dev#pmem}/numa_node"; do
        if [ -r "$f" ]; then cat "$f"; return; fi
    done
    echo unknown
}

# Two prefixes: pwbench is pinned by CPU only, like every earlier campaign, so
# its figures stay comparable with theirs; the probe also binds its memory,
# so its DRAM row is a local-DRAM miss rather than a coin toss.
PIN_BENCH=()
PIN_PROBE=()
PIN_NODE=none
resolve_pinning() {
    local want=${PWCLWB_NUMA_NODE:-auto} node
    if [ "$want" = none ]; then PIN_NODE="disabled"; return; fi
    have numactl || { PIN_NODE="unavailable (no numactl)"; return; }
    if [ "$want" = auto ]; then node=$(numa_node_of "$PWASM_PMEM_TEST_DIR"); else node=$want; fi
    case "$node" in ''|*[!0-9]*) PIN_NODE="undetermined ($node)"; return ;; esac
    PIN_BENCH=(numactl "--cpunodebind=$node" --)
    PIN_PROBE=(numactl "--cpunodebind=$node" "--membind=$node" --)
    PIN_NODE=$node
}

require_dax_dir() {
    [ -n "${PWASM_PMEM_TEST_DIR:-}" ] || die "PWASM_PMEM_TEST_DIR must name your writable directory on the fsdax mount"
    [ -d "$PWASM_PMEM_TEST_DIR" ] && [ -w "$PWASM_PMEM_TEST_DIR" ] ||
        die "PWASM_PMEM_TEST_DIR is not a writable directory: $PWASM_PMEM_TEST_DIR"
}

require_clean_tree() {
    [ "${PWCLWB_ALLOW_DIRTY:-0}" = 1 ] && return 0
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && return 0
    die "working tree is dirty; commit first so the results name a revision, or set PWCLWB_ALLOW_DIRTY=1"
}

# ------------------------------------------------------------ perf events

# Named events only. A raw encoding typed from memory is a way to publish a
# mislabelled counter; an event this perf does not know is skipped and said so.
#   mem_load_retired.local_pmm  retired loads served by local Optane (a miss)
#   ocr.demand_rfo.*local_pmm*  store-side (RFO) requests served by local Optane
#   resource_stalls.sb          cycles stalled on a full store buffer, which is
#                               how serialised RFO misses show up in byte stores
# Three general-purpose counters, plus cycles and instructions: Cascade Lake has
# four general counters per hyperthread and the NMI watchdog may hold one, and a
# multiplexed count is refused. Add more through PWCLWB_EVENTS if the host has
# room (e.g. l2_rqsts.rfo_miss:u).
PERF_OK=0
PERF_WHY=
EVENTS=
EVENT_NOTES=
perf_usable() {
    have perf || { PERF_WHY="perf is not installed"; return 1; }
    local paranoid; paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)
    if ! perf stat -x, -e cycles:u -o /dev/null true >/dev/null 2>&1; then
        PERF_WHY="perf cannot count this user's own events (perf_event_paranoid=$paranoid; needs 2 or lower)"
        return 1
    fi
    return 0
}

discover_events() {
    EVENTS=cycles:u,instructions:u
    EVENT_NOTES=
    if [ -n "${PWCLWB_EVENTS:-}" ]; then EVENTS=$PWCLWB_EVENTS; EVENT_NOTES="events from PWCLWB_EVENTS"; return; fi
    local list; list=$(perf list --no-desc 2>/dev/null | tr -s ' \t' '\n' | tr 'A-Z' 'a-z' | sort -u)
    local want ev
    for want in 'mem_load_retired\.local_pmm$' \
                'ocr\.demand_rfo\..*local_pmm.*any_snoop$|ocr\.demand_rfo\..*local_pmm' \
                'resource_stalls\.sb$'; do
        ev=$(grep -E "^($want)" <<< "$list" | head -1 || true)
        if [ -n "$ev" ] && perf stat -x, -e "$ev:u" -o /dev/null true >/dev/null 2>&1; then
            EVENTS="$EVENTS,$ev:u"
        else
            EVENT_NOTES="$EVENT_NOTES missing:${want%%\\*}"
        fi
    done
}

# ------------------------------------------------------------ provenance

write_provenance() {
    local f=$OUT/provenance.txt
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
        rule "dax"
        printf '%s\n  source  %s\n  options %s\n  node    %s\n' "$PWASM_PMEM_TEST_DIR" \
            "$(source_of "$PWASM_PMEM_TEST_DIR")" \
            "$(findmnt -no OPTIONS -T "$PWASM_PMEM_TEST_DIR" 2>/dev/null || echo unknown)" \
            "$(numa_node_of "$PWASM_PMEM_TEST_DIR")"
        printf 'pinned to node %s\n' "$PIN_NODE"
        rule "perf"
        if [ "$PERF_OK" = 1 ]; then
            printf 'version  %s\nparanoid %s\nevents   %s\nnotes   %s\n' "$(perf --version 2>/dev/null)" \
                "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" "$EVENTS" "${EVENT_NOTES:- none}"
        else
            printf 'unavailable: %s\n' "$PERF_WHY"
        fi
        rule "parameters"
        printf 'reps %s\nsizes %s\ngeometry %s\ncommits %s\nwarmup %s\nconfigs %s\n' \
            "$REPS" "$SIZES" "$GEOMETRY" "$COMMITS" "$WARMUP" "$CONFIGS"
    } > "$f"
}

# ------------------------------------------------------------ 1. probe

build_probe() {
    have "$CC_BIN" || die "no C compiler ($CC_BIN); set PWCLWB_CC"
    mkdir -p bin
    "$CC_BIN" -O2 -Wall -mclwb -mclflushopt -o "$PROBE_BIN" "$PROBE_SRC" || die "could not build $PROBE_SRC"
}

probe() {
    require_dax_dir
    require_clean_tree
    build_probe
    resolve_pinning
    mkdir -p "$OUT"
    [ -f "$OUT/provenance.txt" ] || write_provenance
    local log=$OUT/probe.log rep
    : > "$log"
    for rep in $(seq 1 "$REPS"); do
        rule "probe rep $rep, load $(loadavg | cut -d' ' -f1)" | tee -a "$log"
        "${PIN_PROBE[@]}" "$PROBE_BIN" "$PWASM_PMEM_TEST_DIR/.clwbprobe-$$-$rep" 2>&1 | tee -a "$log" ||
            die "the probe failed; see $log"
    done
    probe_summary "$log" | tee "$OUT/probe-summary.txt"
}

# Median over repetitions of each row's median, then the verdict: CLWB counts
# as evicting when its re-access is closer to CLFLUSHOPT's than to no
# writeback's. The raw rows are in probe.log for anyone who disagrees.
probe_summary() {
    awk '
        $2 == "load" || $2 == "store" { key = $1 " " $2; v[key " " $3] = v[key " " $3] " " $7; keys[key] = 1 }
        function med(s,   a, n, i, j, t) { n = split(s, a, " ")
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
            return n ? a[int((n + 1) / 2)] : "" }
        END {
            print "---- step 1: median re-access cycles (median over repetitions)"
            printf "%-12s %8s %8s %11s   %s\n", "medium/op", "none", "clwb", "clflushopt", "CLWB leaves the line"
            n = split("dram load|pmem load|dram store|pmem store", order, "|")
            for (i = 1; i <= n; i++) { k = order[i]; if (!(k in keys)) continue
                a = med(v[k " none"]); b = med(v[k " clwb"]); c = med(v[k " clflushopt"])
                d1 = b - a; d2 = c - b; if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2
                verdict = (c - a < 20) ? "undecided (clflushopt is no slower than none)" : (d2 < d1 ? "EVICTED (clwb ~ clflushopt)" : "cached (clwb ~ none)")
                split(k, kk, " "); printf "%-12s %8s %8s %11s   %s\n", kk[1] "/" kk[2], a, b, c, verdict }
        }' "$1"
}

# ------------------------------------------------------------ 2+3. campaign

# config -> "<backend> stride=<n> [writeback=...]". A trailing -s<n> sets the
# stride; without one it is pwbench's default of 8, one u64 after another.
config_args() {
    local base=$1 stride=8
    if [[ "$base" =~ ^(.*)-s([0-9]+)$ ]]; then base=${BASH_REMATCH[1]}; stride=${BASH_REMATCH[2]}; fi
    case "$base" in
        pmem-auto|pmem-clwb|pmem-clflushopt|pmem-clflush|pmem-deferred|pmem-none)
                  echo "pmem stride=$stride writeback=${base#pmem-}" ;;
        file-dax) echo "file stride=$stride" ;;
        *) die "unknown configuration: $1" ;;
    esac
}

CSV=
# One row per pwbench run. The counter columns are the raw perf totals for the
# whole process; the summary differences them across the two commit counts.
csv_header() {
    CSV=$OUT/runs.csv
    printf 'config,entries,commits,rep,tsc_per_us,clwb_lines,boundaries_per_commit_x1000,total_boundary_cycles,total_prepare_cycles,wall_ns,wall_ns_per_commit,minor_faults,load1,events\n' > "$CSV"
}

parse_bench() {
    awk '
        function nums(  i, t) { delete v; n = 0
            for (i = 1; i <= NF; i++) { t = $i; sub(/[,:]+$/, "", t); if (t ~ /^[0-9]+$/) v[++n] = t } }
        /boundaries per commit/      { nums(); bpc = v[1]; clwb = v[2] }
        /tsc cycles per microsecond/ { nums(); tsc = v[1] }
        /total boundary cycles/      { nums(); tbc = v[1] }
        /total prepare cycles/       { nums(); tpc = v[1] }
        /measured wall ns/           { nums(); wall = v[1] }
        /wall ns per commit/         { nums(); wpc = v[1] }
        /^minor faults/              { nums(); mf = v[1] }
        END { print tsc "," clwb "," bpc "," tbc "," tpc "," wall "," wpc "," mf }' "$1"
}

# perf -x, lines are value,unit,event,run-time,percent,... Emit event=value;...
# and refuse a multiplexed count: differencing two scaled estimates is noise.
parse_perf() {
    awk -F, '
        /^#/ || NF < 3 { next }
        { ev = $3; sub(/:u$/, "", ev)
          if ($1 !~ /^[0-9]+$/) { bad = bad " " ev "=" $1; next }
          if ($5 != "" && $5 + 0 < 99.9) { bad = bad " " ev "=multiplexed(" $5 "%)"; next }
          out = out (out == "" ? "" : ";") ev "=" $1 }
        END { if (bad != "") { print "BAD" bad; exit 1 } print out }' "$1"
}

run_one() {
    local config=$1 entries=$2 commits=$3 rep=$4 blocks=${GEOMETRY%%x*} bs=${GEOMETRY#*x}
    local log="$OUT/run-$config-e$entries-c$commits-r$rep.log" perf_out="$OUT/run-$config-e$entries-c$commits-r$rep.perf"
    local args; read -r -a args <<< "$(config_args "$config")"
    local load; load=$(loadavg | cut -d' ' -f1)
    local cmd=("$BENCH_BIN" "$PWASM_PMEM_TEST_DIR" "${args[0]}" "$commits" "$entries" "$WARMUP" "$bs" "$blocks" "${args[@]:1}")
    say "  $config entries=$entries commits=$commits rep=$rep"
    if [ "$PERF_OK" = 1 ]; then
        "${PIN_BENCH[@]}" perf stat -x, -e "$EVENTS" -o "$perf_out" -- "${cmd[@]}" > "$log" 2>&1 ||
            { warn "    FAILED -- see $log"; tail -3 "$log" >&2; return 1; }
    else
        "${PIN_BENCH[@]}" "${cmd[@]}" > "$log" 2>&1 || { warn "    FAILED -- see $log"; tail -3 "$log" >&2; return 1; }
    fi
    record_run "$config" "$entries" "$commits" "$rep" "$load" "$log" "$perf_out"
}

# Check one finished run's log against what its configuration must produce and
# append its row. Shared by the campaign and by rebuild, so a rebuilt runs.csv
# applies exactly the checks a fresh one does.
record_run() {
    local config=$1 entries=$2 commits=$3 rep=$4 load=$5 log=$6 perf_out=$7
    local args; read -r -a args <<< "$(config_args "$config")"
    local stride=${args[1]#stride=} wb=${args[2]:-}
    # writeback=none ends on its own labelled line, never a bare OK; accept
    # exactly the line its configuration must produce.
    local want='^OK$'
    [ "$wb" = writeback=none ] && want='^OK timing-only: writeback=none'
    grep -qE "$want" "$log" || { warn "    no expected final line in $log"; return 1; }
    # pwbench prints the instruction's label (CLFLUSHOPT), not the argument
    # (clflushopt): match case-insensitively, up to the label's end, so clflush
    # cannot pass for CLFLUSHOPT.
    if [ -n "$wb" ]; then
        grep -qiE "^writeback ${wb#writeback=}([ ,]|$)" "$log" ||
            { warn "    $log does not name writeback ${wb#writeback=}"; return 1; }
    fi
    # Logs from before stride= existed name no stride; they ran at 8.
    if grep -q '^entry stride' "$log"; then
        grep -q "^entry stride $stride bytes" "$log" || { warn "    $log does not name stride $stride"; return 1; }
    elif [ "$stride" != 8 ]; then
        warn "    $log names no stride but $config needs $stride"; return 1
    fi

    local bench; bench=$(parse_bench "$log")
    [[ "$bench" != *,,* && "$bench" != ,* && "$bench" != *, ]] ||
        { warn "    could not parse $log -- pwbench's output format has moved: $bench"; return 1; }
    local events=
    if [ -f "$perf_out" ]; then
        events=$(parse_perf "$perf_out") ||
            { warn "    unusable counters in $perf_out: $events"
              warn "    (multiplexed: set PWCLWB_EVENTS to fewer events, or ask for the NMI watchdog to be off)"; return 1; }
    fi
    printf '%s,%s,%s,%s,%s,%s,"%s"\n' "$config" "$entries" "$commits" "$rep" "$bench" "$load" "$events" >> "$CSV"
}

campaign() {
    require_dax_dir
    require_clean_tree
    make "$BENCH_BIN" >/dev/null || die "could not build $BENCH_BIN"
    grep -q 'writeback=' "$BENCH_BIN" 2>/dev/null || die "$BENCH_BIN predates the writeback= argument; rebuild it (make $BENCH_BIN)"
    case "$GEOMETRY" in *x*) ;; *) die "PWCLWB_GEOMETRY is not <blocks>x<blockSize>: $GEOMETRY" ;; esac
    local c; for c in $CONFIGS; do config_args "$c" >/dev/null; done
    local lo hi; read -r lo hi _ <<< "$COMMITS"
    [ -n "${hi:-}" ] && [ "$hi" -gt "$lo" ] || die "PWCLWB_COMMITS needs two counts, the second larger: $COMMITS"
    resolve_pinning
    if perf_usable; then PERF_OK=1; discover_events; else PERF_OK=0; warn "perf counters off: $PERF_WHY"; fi
    mkdir -p "$OUT"
    write_provenance
    csv_header
    say "results -> $OUT (node $PIN_NODE, perf $([ $PERF_OK = 1 ] && echo "$EVENTS" || echo off))"

    local failures=0 rep entries n
    for rep in $(seq 1 "$REPS"); do
        for entries in $SIZES; do
            for c in $CONFIGS; do
                for n in $lo $hi; do
                    run_one "$c" "$entries" "$n" "$rep" || failures=$((failures + 1))
                done
            done
        done
    done
    printf 'finished %s\nload     %s\n' "$(date -uIseconds)" "$(loadavg)" >> "$OUT/provenance.txt"
    campaign_summary "$OUT" | tee "$OUT/campaign-summary.txt"
    [ "$failures" -eq 0 ] || die "$failures run(s) failed; the logs are retained in $OUT"
}

# Re-derive runs.csv from a finished directory's logs. The load average is not
# in the logs, so it is carried over from the old runs.csv where that has the
# row, and written as NA where it does not.
rebuild() {
    local dir=$1 f name config entries commits rep load
    [ -d "$dir" ] || die "not a directory: $dir"
    ls "$dir"/run-*.log >/dev/null 2>&1 || die "no run logs in $dir"
    [ -f "$dir/runs.csv" ] && [ ! -f "$dir/runs.csv.orig" ] && cp "$dir/runs.csv" "$dir/runs.csv.orig"
    OUT=$dir
    csv_header
    local failures=0
    for f in "$dir"/run-*.log; do
        name=${f##*/run-}; name=${name%.log}
        [[ "$name" =~ ^(.+)-e([0-9]+)-c([0-9]+)-r([0-9]+)$ ]] ||
            { warn "    unrecognised log name: $f"; failures=$((failures + 1)); continue; }
        config=${BASH_REMATCH[1]} entries=${BASH_REMATCH[2]} commits=${BASH_REMATCH[3]} rep=${BASH_REMATCH[4]}
        load=NA
        [ -f "$dir/runs.csv.orig" ] && load=$(awk -F, -v k="$config,$entries,$commits,$rep" \
            'index($0, k ",") == 1 { print $13; exit }' "$dir/runs.csv.orig")
        record_run "$config" "$entries" "$commits" "$rep" "${load:-NA}" "$f" "${f%.log}.perf" ||
            failures=$((failures + 1))
    done
    say "rebuilt $CSV from $(ls "$dir"/run-*.log | wc -l | tr -d ' ') logs ($failures rejected)"
    [ -f "$dir/provenance.txt" ] && printf 'rebuilt  %s from the run logs by scripts/clwb-eviction.sh at %s; runs.csv.orig is the campaign'"'"'s own\n' \
        "$(date -uIseconds)" "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" >> "$dir/provenance.txt"
    campaign_summary "$dir" | tee "$dir/campaign-summary.txt"
    [ "$failures" -eq 0 ] || die "$failures log(s) rejected; see the messages above"
}

# Per configuration and size, the median over repetitions of:
#   wall     ns per measured commit
#   bound    boundary ns per commit (every CLWB plus the SFENCE, or fdatasync)
#   outside  wall - bound: the non-boundary work the finding is about
#   <event>  counter per commit, (count at hi - count at lo) / (hi - lo)
# then each quantity's slope per entry between the smallest and largest size.
campaign_summary() {
    local dir=$1
    [ -f "$dir/runs.csv" ] || die "no runs.csv in $dir"
    awk -F, '
        NR == 1 { next }
        { cfg = $1; e = $2; c = $3; r = $4; tsc = $5; clw = $6; bpc = $7; tbc = $8; tpc = $9; wpc = $11
          ev = $0; sub(/^.*,"/, "", ev); sub(/"$/, "", ev)
          if (!(cfg in seenc)) { seenc[cfg] = 1; corder[++nc] = cfg }
          if (!(e in seene)) { seene[e] = 1; eorder[++ne] = e }
          if (c + 0 > hi + 0) hi = c; if (lo == "" || c + 0 < lo + 0) lo = c
          k = cfg SUBSEP e SUBSEP r
          wallv[k, c] = wpc; boundv[k, c] = (tbc + tpc) * 1000 / tsc / c; lines[k, c] = clw / c; bnd[k, c] = bpc
          n = split(ev, pairs, ";")
          for (i = 1; i <= n; i++) { split(pairs[i], kv, "="); if (kv[1] == "") continue
              cnt[k, c, kv[1]] = kv[2]; if (!(kv[1] in seenv)) { seenv[kv[1]] = 1; vorder[++nv] = kv[1] } }
          reps[cfg SUBSEP e] = reps[cfg SUBSEP e] " " r }
        function med(s,   a, n, i, j, t) { n = split(s, a, " ")
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
            if (!n) return ""; return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
        function short(v) { sub(/^mem_load_retired\./, "load.", v); sub(/^ocr\.demand_rfo\..*/, "rfo.pmm", v)
            sub(/^resource_stalls\./, "stall.", v); sub(/^l2_rqsts\./, "l2.", v); return v }
        END {
            # numeric sort of sizes
            for (i = 1; i <= ne; i++) for (j = i + 1; j <= ne; j++)
                if (eorder[j] + 0 < eorder[i] + 0) { t = eorder[i]; eorder[i] = eorder[j]; eorder[j] = t }
            printf "---- steps 2+3: per commit, median over repetitions (commits %s and %s differenced for counters)\n", lo, hi
            printf "%-16s %4s %9s %9s %9s %6s", "config", "ent", "wall_ns", "bound_ns", "outside", "lines"
            for (x = 1; x <= nv; x++) printf " %12s", short(vorder[x]); printf "\n"
            for (ci = 1; ci <= nc; ci++) { cfg = corder[ci]
                for (ei = 1; ei <= ne; ei++) { e = eorder[ei]; key = cfg SUBSEP e
                    split(reps[key], rr, " "); delete used; sw = sb = so = sl = ""; for (x = 1; x <= nv; x++) sv[x] = ""
                    for (ri in rr) { r = rr[ri]; if (r in used) continue; used[r] = 1; k = cfg SUBSEP e SUBSEP r
                        if ((k, hi) in wallv) { sw = sw " " wallv[k, hi]; sb = sb " " boundv[k, hi]
                            so = so " " (wallv[k, hi] - boundv[k, hi]); sl = sl " " lines[k, hi] }
                        for (x = 1; x <= nv; x++) { v = vorder[x]
                            if (((k, hi, v) in cnt) && ((k, lo, v) in cnt)) sv[x] = sv[x] " " (cnt[k, hi, v] - cnt[k, lo, v]) / (hi - lo) } }
                    W[cfg, e] = med(sw); B[cfg, e] = med(sb); O[cfg, e] = med(so); L[cfg, e] = med(sl)
                    printf "%-16s %4s %9.0f %9.0f %9.0f %6.1f", cfg, e, W[cfg, e], B[cfg, e], O[cfg, e], L[cfg, e]
                    for (x = 1; x <= nv; x++) { V[cfg, e, x] = med(sv[x]); printf " %12.2f", V[cfg, e, x] }
                    printf "\n" } }
            e0 = eorder[1]; e1 = eorder[ne]
            if (ne < 2) exit
            printf "\n---- slope per entry, %s -> %s entries\n", e0, e1
            printf "%-16s %9s %9s %9s", "config", "wall_ns", "bound_ns", "outside"
            for (x = 1; x <= nv; x++) printf " %12s", short(vorder[x]); printf "\n"
            for (ci = 1; ci <= nc; ci++) { cfg = corder[ci]; d = e1 - e0
                printf "%-16s %9.1f %9.1f %9.1f", cfg, (W[cfg, e1] - W[cfg, e0]) / d, (B[cfg, e1] - B[cfg, e0]) / d, (O[cfg, e1] - O[cfg, e0]) / d
                for (x = 1; x <= nv; x++) printf " %12.3f", (V[cfg, e1, x] - V[cfg, e0, x]) / d; printf "\n" }
            if (nv == 0) print "\n(no perf counters in this run: only the timing half of steps 2+3 is available)"
        }' "$dir/runs.csv"
    local cfgs; cfgs=$(awk -F, 'NR > 1 { print $1 }' "$dir/runs.csv" | sort -u | tr '\n' ' ')
    if [[ " $cfgs" == *" pmem-clflushopt "* ]]; then cat <<'EOF'

---- how to read it (docs/persistent-backends.md: outside-slope ~1440 ns/entry pmem, ~740 file)
 A. pmem-clflushopt ~ pmem-auto in every column  -> CLWB behaves as an evicting
    writeback in the real workload (agrees with step 1 if step 1 said EVICTED).
 B. pmem-none's outside-slope falls toward file-dax's, and its load.local_pmm /
    rfo.pmm per commit fall toward 0 -> the writebacks' side effect on the next
    commit is the cause. If B's slope does not fall, the writeback is not the cause.
 C. file-dax's rfo.pmm / load.local_pmm slope per entry is close to pmem-auto's
    -> both backends' lines are evicted (the kernel's fdatasync on DAX writes back
    with CLWB too), so eviction cannot be what separates them, even if B holds.
 Eviction explains the gap only if A, B and not-C all hold.
EOF
    fi
    if [[ " $cfgs" == *" pmem-deferred"* || " $cfgs" == *"-s64 "* ]]; then cat <<'EOF'

---- how to read the follow-up (first campaign: pmem-auto ~1440 ns/entry, pmem-none ~760, file-dax ~720)
 D. pmem-auto-s64 ~ pmem-none-s64 (slope): with every entry on its own line the
    writebacks are the same in number (compare "lines") but no store lands in a
    line just written back, and the excess is gone -> the cost is the store into
    a just-evicted line within the commit. If pmem-auto-s64 stays well above
    pmem-none-s64, the cost is per writeback (write traffic) or the next
    commit's misses, not the same-line store.
 E. pmem-deferred ~ pmem-none (slope) at stride 8 -> writing each line back once
    at the fence removes the cost; a candidate production change (durability is
    unchanged: every writeback still precedes its fence). Its "lines" is lower
    than pmem-auto's because each distinct line is written back once, so E alone
    cannot separate "fewer writebacks" from "no same-line store after one": D can.
 F. pmem-deferred-s64 ~ pmem-auto-s64 -> where in the commit the writebacks are
    issued does not matter once no same-line store follows one.
EOF
    fi
}

# ------------------------------------------------------------ doctor

doctor() {
    rule "revision"
    git -C "$REPO" log -1 --pretty='%h %s'
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && say "tree clean" ||
        warn "tree DIRTY -- campaign refuses without PWCLWB_ALLOW_DIRTY=1"
    rule "cpu"
    if have lscpu; then lscpu | grep -Ei 'model name|^model:|stepping' || true; fi
    printf 'clwb %s, clflushopt %s\n' \
        "$(grep -qw clwb /proc/cpuinfo 2>/dev/null && echo yes || echo NO)" \
        "$(grep -qw clflushopt /proc/cpuinfo 2>/dev/null && echo yes || echo NO)"
    rule "dax directory"
    if [ -z "${PWASM_PMEM_TEST_DIR:-}" ]; then warn "PWASM_PMEM_TEST_DIR unset -- nothing here can run"
    else
        printf '%s\n  source  %s\n  options %s\n  node    %s\n  writable %s\n' "$PWASM_PMEM_TEST_DIR" \
            "$(source_of "$PWASM_PMEM_TEST_DIR")" "$(findmnt -no OPTIONS -T "$PWASM_PMEM_TEST_DIR" 2>/dev/null)" \
            "$(numa_node_of "$PWASM_PMEM_TEST_DIR")" "$([ -w "$PWASM_PMEM_TEST_DIR" ] && echo yes || echo NO)"
    fi
    rule "tools"
    printf 'C compiler (%s)  %s\n' "$CC_BIN" "$(have "$CC_BIN" && echo present || echo 'ABSENT -- probe unavailable')"
    printf 'numactl          %s\n' "$(have numactl && echo present || echo 'absent -- runs are unpinned')"
    printf 'pwbench          %s\n' "$([ -x "$BENCH_BIN" ] && { grep -q 'writeback=' "$BENCH_BIN" && echo 'present, has writeback=' || echo 'present but STALE -- rebuild'; } || echo 'absent (campaign builds it)')"
    rule "perf"
    if perf_usable; then
        PERF_OK=1; discover_events
        say "usable; events: $EVENTS"
        [ -z "$EVENT_NOTES" ] || warn "not found:$EVENT_NOTES (see 'perf list | grep -iE \"pmm|rfo|resource_stalls\"')"
    else
        warn "unavailable: $PERF_WHY -- the campaign will report timing only"
    fi
    rule "load"
    say "$(loadavg)"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

case "${1:-doctor}" in
    doctor)   doctor ;;
    probe)    probe ;;
    campaign) campaign ;;
    all)      probe; campaign ;;
    rebuild)  [ -n "${2:-}" ] || die "rebuild needs a results directory"
              rebuild "$2" ;;
    summary)  [ -n "${2:-}" ] || die "summary needs a results directory"
              { [ -f "$2/probe.log" ] && probe_summary "$2/probe.log"; } || true
              campaign_summary "$2" ;;
    help|-h|--help) usage ;;
    *)        usage; exit 2 ;;
esac
