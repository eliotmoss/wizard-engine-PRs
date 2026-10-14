#!/usr/bin/env bash
#
# What a persistent B+Tree's operations cost through the production allocator
# and WAL, and how much of each is persistence, on each backend
# (test/pwbtreebench.main.v3). The workload is PWBTree: a freshly formatted
# region per round, a load of random keys (each insert timed), then a YCSB-A-like
# mix of lookups and updates of uniformly chosen loaded keys, half each, each
# kind timed apart; the tree is verified against a DRAM map after every round,
# and the benchmark fails a run in which any operation does other persistence
# work than it did in the audited round 0. The sieve (scripts/pwsieve-bench.sh)
# is the compute-bound workload; this is the persistence-bound one.
#
#   scripts/pwbtree-bench.sh doctor            what this host can run, and why not
#   scripts/pwbtree-bench.sh campaign          the runs, into results/<stamp>-<host>-pwbtree-bench
#   scripts/pwbtree-bench.sh summary <dir>     recompute the summary from runs.csv
#   scripts/pwbtree-bench.sh rebuild <dir>     re-derive runs.csv from the run logs, then
#                                              the summary; the old one is kept as runs.csv.orig
#
# Configurations:
#
#   pmem-auto        PMEM backend on the DAX mount, production writeback (CPUID)
#   pmem-none        the same with no writeback instruction and the fence kept:
#                    an approximation of an eADR platform's timing, never durable,
#                    and not an eADR measurement (an ADR host stays ADR)
#   file-dax         the file backend (mmap + fdatasync) on the same DAX mount
#   file-block       the file backend on block storage (PWBB_BLOCK_DIR)
#   direct-block     the direct backend (pwrite + O_DIRECT + fdatasync) on the
#                    same block storage (PWBB_BLOCK_DIR)
#
# The block configurations run only when PWBB_BLOCK_DIR is set, and never on a
# network filesystem, whose fdatasync would measure the network. The default is
# the three DAX configurations, plus the two block ones when PWBB_BLOCK_DIR is
# set; PWBB_CONFIGS="file-block direct-block" runs block storage alone.
#
# Each run is one pwbtreebench invocation: an audited, unmeasured round 0 and
# PWBB_ROUNDS measured rounds, each of PWBB_KEYS inserts and PWBB_OPS mixed
# operations on a PWBB_GEOMETRY region, all from seed PWBB_SEED. Runs are
# interleaved, repetition outermost and configuration innermost, so a load spike
# lands on one sample of each.
#
# Pinning. PWBB_CPUS pins every run to a CPU list with taskset (needed on hybrid
# CPUs, whose two core types differ: pick CPUs of one type; doctor lists them).
# Otherwise runs are pinned with numactl to the NUMA node that owns the DAX
# namespace (PWBB_NUMA_NODE=auto, the default; none, or a node number).
#
# Overrides: PWASM_PMEM_TEST_DIR (your writable directory on the DAX mount;
# required by the pmem and file-dax configurations), PWBB_BLOCK_DIR, PWBB_REPS
# (5), PWBB_ROUNDS (3), PWBB_KEYS (5000), PWBB_OPS (5000), PWBB_GEOMETRY
# (256x4096, <blocks>x<blockSize>: 1 MiB, the sieve's), PWBB_SEED (1),
# PWBB_CONFIGS, PWBB_CPUS, PWBB_NUMA_NODE, PWBB_TAG (appended to the directory
# name), PWBB_OUT (results/<stamp>-<host>-pwbtree-bench[-cpus<list>][-<tag>]),
# PWBB_ALLOW_DIRTY (0).

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

REPS="${PWBB_REPS:-5}"
ROUNDS="${PWBB_ROUNDS:-3}"
KEYS="${PWBB_KEYS:-5000}"
OPS="${PWBB_OPS:-5000}"
GEOMETRY="${PWBB_GEOMETRY:-256x4096}"
SEED="${PWBB_SEED:-1}"
BLOCK_DIR="${PWBB_BLOCK_DIR:-}"
DEFAULT_CONFIGS="pmem-auto pmem-none file-dax"
[ -n "$BLOCK_DIR" ] && DEFAULT_CONFIGS="$DEFAULT_CONFIGS file-block direct-block"
CONFIGS="${PWBB_CONFIGS:-$DEFAULT_CONFIGS}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CPU_TAG=
[ -n "${PWBB_CPUS:-}" ] && CPU_TAG="-cpus${PWBB_CPUS//,/_}"
TAG=
[ -n "${PWBB_TAG:-}" ] && TAG="-$PWBB_TAG"
OUT="${PWBB_OUT:-$REPO/results/$STAMP-$(hostname -s)-pwbtree-bench$CPU_TAG$TAG}"

BENCH_BIN=bin/pwbtreebench.x86-64-linux
# Every run must report each of these, in this order in the summary.
KINDS="insert update lookup"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rule() { printf -- '---- %s\n' "$*"; }
loadavg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown"; }

# ------------------------------------------------------------ host facts
# The helpers below are the same as scripts/pwops-bench.sh's.

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

power_facts() {
    local cpu=${PWBB_CPUS:-0} d name
    cpu=${cpu%%[,-]*}
    printf 'cpu          %s (the first pinned CPU, or 0)\n' "$cpu"
    printf 'intel_pstate %s\n' "$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo absent)"
    printf 'no_turbo     %s\n' "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo unknown)"
    printf 'governor     %s\n' "$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null || echo 'none (no cpufreq driver)')"
    printf 'epp          %s\n' "$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/energy_performance_preference" 2>/dev/null || echo unknown)"
    printf 'cpuidle      %s\n' "$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo unknown)"
    printf 'idle states '
    for d in /sys/devices/system/cpu/cpu"$cpu"/cpuidle/state*; do
        [ -r "$d/name" ] || continue
        name=$(cat "$d/name")
        [ "$(cat "$d/disable" 2>/dev/null)" = 1 ] && name="$name(disabled)"
        printf ' %s' "$name"
    done
    printf '\n'
}

# What Linux reports about the devices under a directory: the chain from the
# filesystem's source down to the disks, and each disk's write-cache mode (a
# write-through device's fdatasync sends no flush; docs/persistent-backends.md).
storage_facts() {
    local src disk
    src=$(source_of "$1")
    [ -b "$src" ] && have lsblk || { printf '  devices (not a block device, or no lsblk)\n'; return 0; }
    lsblk -s -o NAME,TYPE,ROTA,MODEL "$src" 2>/dev/null | sed 's/^/  /'
    for disk in $(lsblk -s -nr -o NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        printf '  %s write_cache %s\n' "$disk" "$(cat "/sys/block/$disk/queue/write_cache" 2>/dev/null || echo unknown)"
    done
}

PIN=()
PIN_DESC=none
resolve_pinning() {
    local want=${PWBB_NUMA_NODE:-auto} node
    if [ -n "${PWBB_CPUS:-}" ]; then
        [[ "$PWBB_CPUS" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] ||
            die "PWBB_CPUS is not a CPU list such as 2 or 16-19,24: $PWBB_CPUS"
        have taskset || die "PWBB_CPUS needs taskset (util-linux)"
        local types; types=$(core_types_of "$PWBB_CPUS")
        [[ "$types" == *" + "* ]] && warn "PWBB_CPUS=$PWBB_CPUS spans both core types; the timings will mix two microarchitectures"
        PIN=(taskset -c "$PWBB_CPUS")
        PIN_DESC="cpus $PWBB_CPUS ($types)"
        return
    fi
    if [ "$want" = none ]; then PIN_DESC="disabled"; return; fi
    have numactl || { PIN_DESC="unavailable (no numactl)"; return; }
    if [ "$want" = auto ]; then
        [ -n "${PWASM_PMEM_TEST_DIR:-}" ] || { PIN_DESC="undetermined (no DAX directory to take the node from)"; return; }
        node=$(numa_node_of "$PWASM_PMEM_TEST_DIR")
    else
        node=$want
    fi
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

uses_dax()   { tr ' ' '\n' <<< "$CONFIGS" | grep -qxE 'pmem-.*|file-dax'; }
uses_block() { tr ' ' '\n' <<< "$CONFIGS" | grep -qxE 'file-block|direct-block'; }

# Refused rather than warned about, as in pwsieve-bench.sh: off a DAX mount the
# pmem configurations fail, but file-dax would run on whatever filesystem this
# is and be recorded as a DAX result.
require_dirs() {
    if uses_dax; then
        [ -n "${PWASM_PMEM_TEST_DIR:-}" ] || die "PWASM_PMEM_TEST_DIR must name your writable directory on the fsdax mount"
        [ -d "$PWASM_PMEM_TEST_DIR" ] && [ -w "$PWASM_PMEM_TEST_DIR" ] ||
            die "PWASM_PMEM_TEST_DIR is not a writable directory: $PWASM_PMEM_TEST_DIR"
        is_dax_dir "$PWASM_PMEM_TEST_DIR" ||
            die "PWASM_PMEM_TEST_DIR ($PWASM_PMEM_TEST_DIR) is on $(source_of "$PWASM_PMEM_TEST_DIR"), options '$(options_of "$PWASM_PMEM_TEST_DIR")': not a dax or dax=always mount"
    fi
    if uses_block; then
        [ -n "$BLOCK_DIR" ] || die "file-block and direct-block need PWBB_BLOCK_DIR, a writable directory on block storage"
        [ -d "$BLOCK_DIR" ] && [ -w "$BLOCK_DIR" ] || die "PWBB_BLOCK_DIR is not a writable directory: $BLOCK_DIR"
        is_dax_dir "$BLOCK_DIR" && die "PWBB_BLOCK_DIR ($BLOCK_DIR) is on a DAX mount; the block configurations need block storage"
        is_network_fs "$BLOCK_DIR" && die "PWBB_BLOCK_DIR ($BLOCK_DIR) is on $(fstype_of "$BLOCK_DIR"), a network filesystem: fdatasync would measure the network"
    fi
    return 0
}

require_clean_tree() {
    [ "${PWBB_ALLOW_DIRTY:-0}" = 1 ] && return 0
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && return 0
    die "working tree is dirty; commit first so the results name a revision, or set PWBB_ALLOW_DIRTY=1"
}

# config -> "<backend> <directory> [writeback=<w>]"
config_args() {
    case "$1" in
        pmem-auto|pmem-none) echo "pmem ${PWASM_PMEM_TEST_DIR:-.} writeback=${1#pmem-}" ;;
        file-dax)            echo "file ${PWASM_PMEM_TEST_DIR:-.}" ;;
        file-block)          echo "file ${BLOCK_DIR:-.}" ;;
        direct-block)        echo "direct ${BLOCK_DIR:-.}" ;;
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
        if have lscpu; then lscpu | grep -Ei 'model name|^model:|stepping|^cpu\(s\)|thread|l1d|l2|l3|numa node' || true; fi
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
            storage_facts "$BLOCK_DIR"
        fi
        printf 'pinned   %s\n' "$PIN_DESC"
        rule "power"
        power_facts
        rule "parameters"
        printf 'reps %s\nrounds %s\nkeys %s\nops %s\ngeometry %s\nseed %s\nconfigs %s\n' \
            "$REPS" "$ROUNDS" "$KEYS" "$OPS" "$GEOMETRY" "$SEED" "$CONFIGS"
    } > "$OUT/provenance.txt"
}

# ------------------------------------------------------------ runs

CSV=
COLUMNS_CSV="samples min_ns median_ns p90_ns p99_ns max_ns mean_ns compute_ns alloc_ns write_ns publish_ns free_ns boundaries_x1000 prepares_x1000 lines_x1000 boundaries_min boundaries_max splits"
csv_header() {
    CSV=$OUT/runs.csv
    echo "config,rep,kind,${COLUMNS_CSV// /,},tsc_per_us,height,wall_insert_ns,wall_mix_ns,load1" > "$CSV"
}

# One CSV row per "op" line: the kind, then each field in COLUMNS_CSV order,
# looked up by name so the line's field order may change.
parse_ops() {
    awk -v cols="$COLUMNS_CSV" '
        BEGIN { n = split(cols, c, " ") }
        /^op / { delete kv; for (i = 3; i < NF; i += 2) kv[$i] = $(i + 1)
            row = $2; for (k = 1; k <= n; k++) row = row "," kv[c[k]]; print row }' "$1"
}

# Check one finished run's log against its configuration and append its rows.
# Shared by the campaign and by rebuild, so both apply the same checks.
record_run() {
    local config=$1 rep=$2 load=$3 log=$4 dir=${5:-}
    local args; read -r -a args <<< "$(config_args "$config")"
    local backend=${args[0]} wb= a
    for a in "${args[@]:2}"; do
        case "$a" in writeback=*) wb=${a#writeback=} ;; esac
    done
    local want='^OK$'
    [ "$wb" = none ] && want='^OK timing-only: writeback=none'
    grep -qE "$want" "$log" || { warn "    no expected final line in $log"; return 1; }
    grep -q "^backend $backend " "$log" || { warn "    $log does not name backend $backend"; return 1; }
    if [ -n "$wb" ]; then
        grep -qE "^writeback $wb " "$log" || { warn "    $log does not name writeback $wb"; return 1; }
    fi
    grep -q '^round 0 audited ' "$log" || { warn "    $log has no audited round 0"; return 1; }
    # Only a fresh run knows its directory and parameters; a rebuild elsewhere cannot.
    if [ -n "$dir" ]; then
        grep -qxF "directory $dir" "$log" || { warn "    $log does not name directory $dir"; return 1; }
        local blocks=${GEOMETRY%%x*} bs=${GEOMETRY#*x}
        grep -qxF "region $blocks blocks of $bs bytes, rounds $ROUNDS measured after 1 audited" "$log" ||
            { warn "    $log did not run $ROUNDS rounds on $GEOMETRY"; return 1; }
        grep -qxF "workload per round: load $KEYS keys, then $OPS operations, half lookups and half updates, seed $SEED" "$log" ||
            { warn "    $log did not run $KEYS keys and $OPS operations from seed $SEED"; return 1; }
    fi
    local tsc height wall_insert wall_mix
    tsc=$(awk '/^tsc cycles per microsecond/ { print $NF }' "$log")
    height=$(sed -nE 's/^after the load: [0-9]+ keys, height ([0-9]+), [0-9]+ nodes$/\1/p' "$log")
    wall_insert=$(sed -nE 's/^wall ns per insert \(load\) ([0-9]+), per operation \(mix\) ([0-9]+)$/\1/p' "$log")
    wall_mix=$(sed -nE 's/^wall ns per insert \(load\) ([0-9]+), per operation \(mix\) ([0-9]+)$/\2/p' "$log")
    [ -n "$tsc" ] && [ -n "$height" ] && [ -n "$wall_insert" ] && [ -n "$wall_mix" ] ||
        { warn "    could not read the run facts of $log -- pwbtreebench's output format has moved"; return 1; }
    local rows; rows=$(parse_ops "$log")
    local kind row
    for kind in $KINDS; do
        row=$(grep "^$kind," <<< "$rows" || true)
        [ "$(grep -c . <<< "$row")" -eq 1 ] || { warn "    $log reports $kind $(grep -c . <<< "$row") times, not once"; return 1; }
        [[ "$row" != *,,* && "$row" != *, ]] || { warn "    could not parse $kind in $log -- the format has moved: $row"; return 1; }
    done
    [ "$(grep -c . <<< "$rows")" -eq "$(wc -w <<< "$KINDS")" ] ||
        { warn "    $log reports operation kinds this script does not know; update KINDS"; return 1; }
    while IFS= read -r row; do
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$config" "$rep" "$row" "$tsc" "$height" "$wall_insert" "$wall_mix" "$load"
    done <<< "$rows" >> "$CSV"
}

run_one() {
    local config=$1 rep=$2 blocks=${GEOMETRY%%x*} bs=${GEOMETRY#*x}
    local log="$OUT/run-$config-r$rep.log"
    local args; read -r -a args <<< "$(config_args "$config")"
    local load; load=$(loadavg | cut -d' ' -f1)
    say "  $config rep=$rep"
    "${PIN[@]}" "$BENCH_BIN" "${args[1]}" "${args[0]}" "$ROUNDS" "$KEYS" "$OPS" "$blocks" "$bs" "${args[@]:2}" "seed=$SEED" > "$log" 2>&1 ||
        { warn "    FAILED -- see $log"; tail -3 "$log" >&2; return 1; }
    record_run "$config" "$rep" "$load" "$log" "${args[1]}"
}

campaign() {
    local c; for c in $CONFIGS; do config_args "$c" >/dev/null; done
    require_dirs
    require_clean_tree
    case "$GEOMETRY" in *x*) ;; *) die "PWBB_GEOMETRY is not <blocks>x<blockSize>: $GEOMETRY" ;; esac
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
        [ -f "$dir/runs.csv.orig" ] && load=$(awk -F, -v k="$config,$rep," 'index($0, k) == 1 { print $NF; exit }' "$dir/runs.csv.orig")
        record_run "$config" "$rep" "${load:-NA}" "$f" || failures=$((failures + 1))
    done
    say "rebuilt $CSV from $(ls "$dir"/run-*.log | wc -l | tr -d ' ') logs ($failures rejected)"
    summary "$dir" | tee "$dir/summary.txt"
    [ "$failures" -eq 0 ] || die "$failures log(s) rejected; see the messages above"
}

# Kinds as row groups and configurations as rows: the median over repetitions of
# each run's statistic, the repetitions' spread, the phases and the persistence
# share, the work per operation, and pmem-auto - pmem-none.
summary() {
    local csv=$1/runs.csv
    [ -f "$csv" ] || die "no runs.csv in $1"
    awk -F, -v kinds="$KINDS" '
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        { c = $1; k = $3
          if (!(c in seen)) { seen[c] = 1; cfg[++nc] = c }
          for (f in col) v[c, k, f] = v[c, k, f] " " $col[f]
          work = $col["boundaries_x1000"] " " $col["lines_x1000"] " " $col["prepares_x1000"] " " $col["boundaries_min"] " " $col["boundaries_max"] " " $col["splits"]
          if (!((c, k) in counts)) counts[c, k] = work
          else if (counts[c, k] != work) counts[c, k] = "VARIES" }
        function median(s,   a, m, i, j, t) { m = split(s, a, " ")
            for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
            if (m == 0) return ""; if (m % 2) return a[(m + 1) / 2]; return (a[m / 2] + a[m / 2 + 1]) / 2 }
        function lo(s,   a, m, i, r) { m = split(s, a, " "); r = a[1]; for (i = 2; i <= m; i++) if (a[i] + 0 < r + 0) r = a[i]; return r }
        function hi(s,   a, m, i, r) { m = split(s, a, " "); r = a[1]; for (i = 2; i <= m; i++) if (a[i] + 0 > r + 0) r = a[i]; return r }
        function reps(s,   a) { return split(s, a, " ") }
        function m(c, k, f) { return median(v[c, k, f]) }
        END {
            nk = split(kinds, kd, " ")
            print "---- per operation, ns; each figure the median over repetitions of a run'"'"'s statistic"
            printf "%-8s %-14s %4s %10s %10s %10s %7s %9s %9s %9s %9s %9s %9s %8s\n", "kind", "config", "reps", "median", "p90", "mean", "spread", "compute", "alloc", "write", "publish", "free", "persist", "share"
            for (q = 1; q <= nk; q++) { k = kd[q]
                for (i = 1; i <= nc; i++) { c = cfg[i]
                    if (v[c, k, "median_ns"] == "") continue
                    med = m(c, k, "median_ns")
                    spread = (med > 0 ? 100 * (hi(v[c, k, "median_ns"]) - lo(v[c, k, "median_ns"])) / med : 0)
                    comp = m(c, k, "compute_ns"); per = m(c, k, "alloc_ns") + m(c, k, "write_ns") + m(c, k, "publish_ns") + m(c, k, "free_ns")
                    # The share is of the whole operation, as the sieve'"'"'s is of the
                    # whole step: the persistence phases over the mean rdtsc time of
                    # an operation of this kind, which includes what falls outside
                    # the marks (pwsieve-bench.sh divides by its wall time per step,
                    # clock_gettime over a loop of nothing but steps).
                    tot = m(c, k, "mean_ns")
                    printf "%-8s %-14s %4d %10.0f %10.0f %10.0f %6.1f%% %9.0f %9.0f %9.0f %9.0f %9.0f %9.0f %7.1f%%\n", k, c, reps(v[c, k, "median_ns"]),
                        med, m(c, k, "p90_ns"), m(c, k, "mean_ns"), spread, comp, m(c, k, "alloc_ns"), m(c, k, "write_ns"),
                        m(c, k, "publish_ns"), m(c, k, "free_ns"), per, (tot > 0 ? 100 * per / tot : 0) }
            }
            print ""
            print "---- work per operation, checked on every operation of every round: boundaries (min-max) / lines written back / prepare calls, per op; splits"
            for (q = 1; q <= nk; q++) { k = kd[q]
                for (i = 1; i <= nc; i++) { c = cfg[i]; s = counts[c, k]
                    if (s == "") continue
                    if (s == "VARIES") { printf "%-8s %-14s VARIES between repetitions\n", k, c; continue }
                    split(s, w, " ")
                    printf "%-8s %-14s %7.3f (%d-%d) / %8.3f / %8.3f; %d splits over %d ops\n", k, c, w[1] / 1000, w[4], w[5], w[2] / 1000, w[3] / 1000, w[6], m(c, k, "samples") }
            }
            print ""
            print "---- per boundary: the persistence phases over the boundaries they make, ns"
            for (q = 1; q <= nk; q++) { k = kd[q]
                for (i = 1; i <= nc; i++) { c = cfg[i]; b = m(c, k, "boundaries_x1000") / 1000
                    if (v[c, k, "median_ns"] == "" || b <= 0) continue
                    per = m(c, k, "alloc_ns") + m(c, k, "write_ns") + m(c, k, "publish_ns") + m(c, k, "free_ns")
                    printf "%-8s %-14s %9.0f\n", k, c, per / b }
            }
            print ""
            print "---- run facts, median over repetitions"
            for (i = 1; i <= nc; i++) { c = cfg[i]
                printf "%-14s height after the load %s; wall ns per insert %.0f, per mixed operation %.0f\n", c,
                    m(c, "insert", "height"), m(c, "insert", "wall_insert_ns"), m(c, "insert", "wall_mix_ns") }
            if (("pmem-auto", "update", "median_ns") in v && ("pmem-none", "update", "median_ns") in v) {
                print ""
                print "---- pmem-auto - pmem-none: what the writeback instructions cost an operation, ns (an eADR approximation)"
                for (q = 1; q <= nk; q++) { k = kd[q]
                    a = m("pmem-auto", k, "median_ns"); b = m("pmem-none", k, "median_ns")
                    printf "%-8s %10.0f  (%5.1f %% of pmem-auto)\n", k, a - b, (a > 0 ? 100 * (a - b) / a : 0) }
            }
            print ""
            print "Columns: median, p90 and mean of each run'"'"'s per-operation rdtsc times; spread = (max - min) / median"
            print "of the per-run medians; the phases are PWBTree'"'"'s onPhase marks, means per operation; persist ="
            print "alloc + write + publish + free; share = persist / mean, the persistence phases over the whole"
            print "operation'"'"'s mean time (rdtsc around each put or get), as pwsieve-bench.sh'"'"'s share is over a"
            print "whole step'"'"'s wall time; what the marks leave out counts against it. A mutation at height h"
            print "with k new nodes makes k + h + 1 boundaries: k allocations, one fence over the new nodes, the"
            print "publish (root swap and first free) and h - 1 further frees. Inserts include the load'"'"'s first"
            print "inserts, made while the root is still a leaf. pmem-none drops CLWB and keeps SFENCE: an"
            print "approximation of eADR timing, never durable. A difference is real only outside both spreads."
        }' "$csv"
}

doctor() {
    rule "revision"
    git -C "$REPO" log -1 --oneline
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && say "tree clean" || warn "tree DIRTY (the campaign refuses unless PWBB_ALLOW_DIRTY=1)"
    rule "cpu"
    if have lscpu; then lscpu | grep -Ei 'model name|^model:|stepping|numa node' || true; fi
    local topo; topo=$(hybrid_topology)
    if [ "$topo" != "not hybrid" ]; then
        say "hybrid $topo"
        warn "hybrid CPU: set PWBB_CPUS to CPUs of one core type (cpu_core = performance, cpu_atom = efficiency)"
    fi
    say "governor $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';' || echo unknown)"
    rule "power"
    power_facts
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
    rule "block directory (PWBB_BLOCK_DIR)"
    if [ -z "$BLOCK_DIR" ]; then
        say "unset: file-block and direct-block are skipped"
    else
        say "$BLOCK_DIR"
        say "  source  $(source_of "$BLOCK_DIR")"
        say "  fstype  $(fstype_of "$BLOCK_DIR")"
        say "  options $(options_of "$BLOCK_DIR")"
        storage_facts "$BLOCK_DIR"
        [ -w "$BLOCK_DIR" ] && say "  writable yes" || warn "  NOT writable"
        is_dax_dir "$BLOCK_DIR" && warn "  a DAX mount: the block configurations would refuse it"
        is_network_fs "$BLOCK_DIR" && warn "  a network filesystem: the block configurations would refuse it"
    fi
    rule "pinning"
    resolve_pinning
    say "$PIN_DESC"
    rule "tools"
    printf 'taskset          %s\n' "$(have taskset && echo present || echo 'absent -- PWBB_CPUS unavailable')"
    printf 'numactl          %s\n' "$(have numactl && echo present || echo 'absent -- runs are unpinned')"
    printf 'pwbtreebench     %s\n' "$([ -x "$BENCH_BIN" ] && echo present || echo 'absent (campaign builds it)')"
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
