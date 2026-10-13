#!/usr/bin/env bash
#
# Basic-operation latencies per persistence backend (test/pwopsbench.main.v3),
# in the style of Corundum's Table 5: allocChunk(1, 8, 64 blocks), freeChunk of
# the same chunks, an empty commit, the mount of a cleanly closed 1 MiB and
# 64 MiB region, and the recovery of a 1 MiB region whose log holds one
# committed, unapplied transaction of 8 or 24 entries. Every operation goes
# through the production PWRegion, RegionTransaction and DualTxnWal, and the
# benchmark fails a run in which any operation does other persistence work than
# it should. A commit of k entries is pwbench's (scripts/pmem-experiments.sh,
# scripts/clwb-eviction.sh) and is not measured here.
#
#   scripts/pwops-bench.sh doctor            what this host can run, and why not
#   scripts/pwops-bench.sh campaign          the runs, into results/<stamp>-<host>-pwops-bench
#   scripts/pwops-bench.sh summary <dir>     recompute the summary from runs.csv
#   scripts/pwops-bench.sh rebuild <dir>     re-derive runs.csv from the run logs, then
#                                            the summary; the old one is kept as runs.csv.orig
#
# Configurations:
#
#   pmem-auto        PMEM backend on the DAX mount, production writeback (CPUID)
#   pmem-none        the same with no writeback instruction and the fence kept:
#                    an approximation of an eADR platform's timing, never durable,
#                    and not an eADR measurement (an ADR host stays ADR)
#   file-dax         the file backend (mmap + fdatasync) on the same DAX mount
#   file-block       the file backend on block storage (PWOB_BLOCK_DIR)
#   direct-block     the direct backend (pwrite + O_DIRECT + fdatasync) on the
#                    same block storage (PWOB_BLOCK_DIR)
#   file-dax-legacy, file-block-legacy
#                    file-dax and file-block with the file backend's boundary
#                    before 2026-10-13 (a flag and fdatasync, persistRange an msync
#                    of its own pages), for the old-against-new comparison only
#
# There is no direct configuration without writeback: on the direct backend a
# writeback request only marks a unit for the boundary to write. There is no
# file configuration with pwopsbench's boundary=msync, which it refuses.
#
# The block configurations run only when PWOB_BLOCK_DIR is set, and never on a
# network filesystem, whose fdatasync would measure the network. The default is
# the three DAX configurations, plus the two block ones when PWOB_BLOCK_DIR is
# set; PWOB_CONFIGS="file-block direct-block" runs block storage alone. The
# legacy configurations run only when named, e.g.
# PWOB_CONFIGS="file-block file-block-legacy".
#
# Each run is one pwopsbench invocation: PWOB_WARMUP unmeasured and PWOB_OPS
# measured operations of each allocation, free and empty commit, and
# PWOB_MOUNT_WARMUP unmeasured and PWOB_MOUNTS measured mounts and recoveries of
# each kind (fewer, because a direct mount reads the whole region). Runs are
# interleaved, repetition outermost and configuration innermost, so a load spike
# lands on one sample of each.
#
# Pinning. PWOB_CPUS pins every run to a CPU list with taskset (needed on hybrid
# CPUs, whose two core types differ: pick CPUs of one type; doctor lists them).
# Otherwise runs are pinned with numactl to the NUMA node that owns the DAX
# namespace (PWOB_NUMA_NODE=auto, the default; none, or a node number): on
# Magpie a cross-socket fdatasync on DAX costs +24 % at 2 MiB.
#
# Overrides: PWASM_PMEM_TEST_DIR (your writable directory on the DAX mount;
# required by the pmem and file-dax configurations), PWOB_BLOCK_DIR, PWOB_REPS
# (5), PWOB_OPS (50000), PWOB_WARMUP (2000), PWOB_MOUNTS (200),
# PWOB_MOUNT_WARMUP (20), PWOB_CONFIGS, PWOB_CPUS, PWOB_NUMA_NODE, PWOB_OUT
# (results/<stamp>-<host>-pwops-bench[-cpus<list>]), PWOB_ALLOW_DIRTY (0).

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

REPS="${PWOB_REPS:-5}"
OPS="${PWOB_OPS:-50000}"
WARMUP="${PWOB_WARMUP:-2000}"
MOUNTS="${PWOB_MOUNTS:-200}"
MOUNT_WARMUP="${PWOB_MOUNT_WARMUP:-20}"
BLOCK_DIR="${PWOB_BLOCK_DIR:-}"
DEFAULT_CONFIGS="pmem-auto pmem-none file-dax"
[ -n "$BLOCK_DIR" ] && DEFAULT_CONFIGS="$DEFAULT_CONFIGS file-block direct-block"
CONFIGS="${PWOB_CONFIGS:-$DEFAULT_CONFIGS}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CPU_TAG=
[ -n "${PWOB_CPUS:-}" ] && CPU_TAG="-cpus${PWOB_CPUS//,/_}"
OUT="${PWOB_OUT:-$REPO/results/$STAMP-$(hostname -s)-pwops-bench$CPU_TAG}"

BENCH_BIN=bin/pwopsbench.x86-64-linux
# Every run must report each of these, in this order in the summary.
OPS_ORDER="alloc-1 alloc-8 alloc-64 free-1 free-8 free-64 commit-empty timer mount-1mib mount-64mib recover-8 recover-24"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rule() { printf -- '---- %s\n' "$*"; }
loadavg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown"; }

# ------------------------------------------------------------ host facts
# The helpers below are the same as scripts/pwsieve-bench.sh's.

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
    local cpu=${PWOB_CPUS:-0} d name
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
    local want=${PWOB_NUMA_NODE:-auto} node
    if [ -n "${PWOB_CPUS:-}" ]; then
        [[ "$PWOB_CPUS" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] ||
            die "PWOB_CPUS is not a CPU list such as 2 or 16-19,24: $PWOB_CPUS"
        have taskset || die "PWOB_CPUS needs taskset (util-linux)"
        local types; types=$(core_types_of "$PWOB_CPUS")
        [[ "$types" == *" + "* ]] && warn "PWOB_CPUS=$PWOB_CPUS spans both core types; the timings will mix two microarchitectures"
        PIN=(taskset -c "$PWOB_CPUS")
        PIN_DESC="cpus $PWOB_CPUS ($types)"
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

uses_dax()   { tr ' ' '\n' <<< "$CONFIGS" | grep -qxE 'pmem-.*|file-dax(-legacy)?'; }
uses_block() { tr ' ' '\n' <<< "$CONFIGS" | grep -qxE 'file-block(-legacy)?|direct-block'; }

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
        [ -n "$BLOCK_DIR" ] || die "file-block, file-block-legacy and direct-block need PWOB_BLOCK_DIR, a writable directory on block storage"
        [ -d "$BLOCK_DIR" ] && [ -w "$BLOCK_DIR" ] || die "PWOB_BLOCK_DIR is not a writable directory: $BLOCK_DIR"
        is_dax_dir "$BLOCK_DIR" && die "PWOB_BLOCK_DIR ($BLOCK_DIR) is on a DAX mount; the block configurations need block storage"
        is_network_fs "$BLOCK_DIR" && die "PWOB_BLOCK_DIR ($BLOCK_DIR) is on $(fstype_of "$BLOCK_DIR"), a network filesystem: fdatasync would measure the network"
    fi
    return 0
}

require_clean_tree() {
    [ "${PWOB_ALLOW_DIRTY:-0}" = 1 ] && return 0
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && return 0
    die "working tree is dirty; commit first so the results name a revision, or set PWOB_ALLOW_DIRTY=1"
}

# config -> "<backend> <directory> [writeback=<w>] [boundary=<b>]"
config_args() {
    case "$1" in
        pmem-auto|pmem-none) echo "pmem ${PWASM_PMEM_TEST_DIR:-.} writeback=${1#pmem-}" ;;
        file-dax)            echo "file ${PWASM_PMEM_TEST_DIR:-.}" ;;
        file-dax-legacy)     echo "file ${PWASM_PMEM_TEST_DIR:-.} boundary=legacy" ;;
        file-block)          echo "file ${BLOCK_DIR:-.}" ;;
        file-block-legacy)   echo "file ${BLOCK_DIR:-.} boundary=legacy" ;;
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
        printf 'reps %s\nops %s\nwarmup %s\nmounts %s\nmount_warmup %s\nconfigs %s\n' \
            "$REPS" "$OPS" "$WARMUP" "$MOUNTS" "$MOUNT_WARMUP" "$CONFIGS"
    } > "$OUT/provenance.txt"
}

# ------------------------------------------------------------ runs

CSV=
COLUMNS_CSV="samples entries min_ns median_ns p90_ns p99_ns max_ns mean_ns boundaries prepares lines"
csv_header() {
    CSV=$OUT/runs.csv
    echo "config,rep,op,${COLUMNS_CSV// /,},tsc_per_us,load1" > "$CSV"
}

# One CSV row per "op" line: the operation, then each field in COLUMNS_CSV
# order, looked up by name so the line's field order may change.
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
    local backend=${args[0]} wb= boundary= a
    for a in "${args[@]:2}"; do
        case "$a" in
            writeback=*) wb=${a#writeback=} ;;
            boundary=*) boundary=${a#boundary=} ;;
        esac
    done
    local want='^OK$'
    [ "$wb" = none ] && want='^OK timing-only: writeback=none'
    grep -qE "$want" "$log" || { warn "    no expected final line in $log"; return 1; }
    grep -q "^backend $backend " "$log" || { warn "    $log does not name backend $backend"; return 1; }
    if [ -n "$wb" ]; then
        grep -qE "^writeback $wb " "$log" || { warn "    $log does not name writeback $wb"; return 1; }
    fi
    # Every file run names its boundary, fdatasync unless the configuration
    # names another. Logs from before boundary= existed (2026-10-13) name
    # none: those runs had the boundary now called legacy, under an
    # unsuffixed name, so a rebuild accepts an unsuffixed file configuration's
    # log without the line. A fresh run, a suffixed configuration and a log
    # that names a boundary are always checked.
    if [ "$backend" = file ]; then
        if [ -n "$dir" ] || [ -n "$boundary" ] || grep -q '^boundary ' "$log"; then
            grep -qxF "boundary ${boundary:-fdatasync}" "$log" ||
                { warn "    $log does not name boundary ${boundary:-fdatasync}"; return 1; }
        fi
    fi
    # Only a fresh run knows its directory; a rebuild elsewhere cannot.
    if [ -n "$dir" ]; then
        grep -qxF "directory $dir" "$log" || { warn "    $log does not name directory $dir"; return 1; }
    fi
    local tsc counts ops warm mounts mwarm
    tsc=$(awk '/^tsc cycles per microsecond/ { print $NF }' "$log")
    counts=$(sed -nE 's/^operations ([0-9]+) after ([0-9]+) warm-up, mounts ([0-9]+) after ([0-9]+) warm-up$/\1 \2 \3 \4/p' "$log")
    read -r ops warm mounts mwarm <<< "$counts"
    [ -n "$tsc" ] && [ -n "$mwarm" ] || { warn "    could not read the parameters of $log -- pwopsbench's output format has moved"; return 1; }
    # A fresh run must have measured what it was asked to.
    if [ -n "$dir" ] && [ "$ops $warm $mounts $mwarm" != "$OPS $WARMUP $MOUNTS $MOUNT_WARMUP" ]; then
        warn "    $log measured $ops/$warm/$mounts/$mwarm, not $OPS/$WARMUP/$MOUNTS/$MOUNT_WARMUP"; return 1
    fi
    local rows; rows=$(parse_ops "$log")
    local op row samples
    for op in $OPS_ORDER; do
        row=$(grep "^$op," <<< "$rows" || true)
        [ "$(grep -c . <<< "$row")" -eq 1 ] || { warn "    $log reports $op $(grep -c . <<< "$row") times, not once"; return 1; }
        [[ "$row" != *,,* && "$row" != *, ]] || { warn "    could not parse $op in $log -- the format has moved: $row"; return 1; }
        samples=$(cut -d, -f2 <<< "$row")
        case "$op" in mount-*|recover-*) [ "$samples" = "$mounts" ] ;; *) [ "$samples" = "$ops" ] ;; esac ||
            { warn "    $op in $log has $samples samples"; return 1; }
    done
    [ "$(grep -c . <<< "$rows")" -eq "$(wc -w <<< "$OPS_ORDER")" ] ||
        { warn "    $log reports operations this script does not know; update OPS_ORDER"; return 1; }
    while IFS= read -r row; do printf '%s,%s,%s,%s,%s\n' "$config" "$rep" "$row" "$tsc" "$load"; done <<< "$rows" >> "$CSV"
}

run_one() {
    local config=$1 rep=$2
    local log="$OUT/run-$config-r$rep.log"
    local args; read -r -a args <<< "$(config_args "$config")"
    local load; load=$(loadavg | cut -d' ' -f1)
    say "  $config rep=$rep"
    "${PIN[@]}" "$BENCH_BIN" "${args[1]}" "${args[0]}" "$OPS" "$WARMUP" "$MOUNTS" "$MOUNT_WARMUP" "${args[@]:2}" > "$log" 2>&1 ||
        { warn "    FAILED -- see $log"; tail -3 "$log" >&2; return 1; }
    record_run "$config" "$rep" "$load" "$log" "${args[1]}"
}

campaign() {
    local c; for c in $CONFIGS; do config_args "$c" >/dev/null; done
    require_dirs
    require_clean_tree
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

# Operations as rows and configurations as columns, as Corundum's Table 5:
# the median over repetitions of each run's median, and of each run's p90,
# then the repetitions' spread, the persistence work per operation, and the
# differences the table exists to show.
summary() {
    local csv=$1/runs.csv
    [ -f "$csv" ] || die "no runs.csv in $1"
    awk -F, -v order="$OPS_ORDER" '
        NR == 1 { next }
        { c = $1; op = $3
          if (!(c in seen)) { seen[c] = 1; cfg[++nc] = c }
          med[c, op] = med[c, op] " " $7; p90[c, op] = p90[c, op] " " $8
          work = $5 " " $12 " " $14
          if (!((c, op) in counts)) counts[c, op] = work
          else if (counts[c, op] != work) counts[c, op] = "VARIES" }
        function median(s,   a, m, i, j, t) { m = split(s, a, " ")
            for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
            if (m == 0) return ""; if (m % 2) return a[(m + 1) / 2]; return (a[m / 2] + a[m / 2 + 1]) / 2 }
        function lo(s,   a, m, i, r) { m = split(s, a, " "); r = a[1]; for (i = 2; i <= m; i++) if (a[i] + 0 < r + 0) r = a[i]; return r }
        function hi(s,   a, m, i, r) { m = split(s, a, " "); r = a[1]; for (i = 2; i <= m; i++) if (a[i] + 0 > r + 0) r = a[i]; return r }
        function reps(s,   a) { return split(s, a, " ") }
        function header(title,   i) { print ""; print title
            printf "%-14s", "operation"; for (i = 1; i <= nc; i++) printf " %17s", cfg[i]; print "" }
        function table(title, v,   k, i, s) { header(title)
            for (k = 1; k <= nops; k++) { printf "%-14s", ops[k]
                for (i = 1; i <= nc; i++) { s = v[cfg[i], ops[k]]; if (s == "") printf " %17s", "-"; else printf " %17.0f", median(s) }
                print "" } }
        END {
            nops = split(order, ops, " ")
            print "---- ns per operation; each cell the median over repetitions of a run'"'"'s statistic"
            printf "repetitions:"; for (i = 1; i <= nc; i++) printf " %s %d", cfg[i], reps(med[cfg[i], "alloc-1"]); print ""
            table("---- median", med)
            table("---- p90", p90)
            header("---- spread of the per-run medians, (max - min) / median, %")
            for (k = 1; k <= nops; k++) { printf "%-14s", ops[k]
                for (i = 1; i <= nc; i++) { s = med[cfg[i], ops[k]]
                    if (s == "" || median(s) + 0 <= 0) printf " %17s", "-"
                    else printf " %16.1f%%", 100 * (hi(s) - lo(s)) / median(s) }
                print "" }
            header("---- work per operation, checked on every operation: entries / boundaries / lines written back")
            for (k = 1; k <= nops; k++) { printf "%-14s", ops[k]
                for (i = 1; i <= nc; i++) { s = counts[cfg[i], ops[k]]
                    if (s == "") s = "-"; else if (s != "VARIES") { split(s, w, " "); s = w[1] " / " w[2] " / " w[3] }
                    printf " %17s", s }
                print "" }
            header("---- derived, from the medians")
            split("recover-8 recover-24", rk, " ")
            for (r = 1; r <= 2; r++) { printf "%-14s", "replay-" substr(rk[r], 9)
                for (i = 1; i <= nc; i++) { c = cfg[i]
                    if (med[c, rk[r]] == "" || med[c, "mount-1mib"] == "") printf " %17s", "-"
                    else printf " %17.0f", median(med[c, rk[r]]) - median(med[c, "mount-1mib"]) }
                print "" }
            printf "%-14s", "64mib/1mib"
            for (i = 1; i <= nc; i++) { c = cfg[i]
                if (med[c, "mount-64mib"] == "" || median(med[c, "mount-1mib"]) + 0 <= 0) printf " %17s", "-"
                else printf " %16.1fx", median(med[c, "mount-64mib"]) / median(med[c, "mount-1mib"]) }
            print ""
            if (("pmem-auto", "alloc-1") in med && ("pmem-none", "alloc-1") in med) {
                print ""
                print "---- pmem-auto - pmem-none: what the writeback instructions cost each operation, ns (an eADR approximation)"
                for (k = 1; k <= nops; k++) { a = med["pmem-auto", ops[k]]; b = med["pmem-none", ops[k]]
                    if (a == "" || b == "") continue
                    d = median(a) - median(b); m = median(a)
                    printf "%-14s %10.0f  (%5.1f %% of pmem-auto)\n", ops[k], d, (m > 0 ? 100 * d / m : 0) }
            }
            print ""
            print "Each operation is its own committed transaction except commit-empty (production commits nothing for"
            print "it: no boundary) and timer (an empty rdtsc window, the floor under every figure). mount-* opens a"
            print "cleanly closed region; recover-k opens a 1 MiB region whose log holds one committed, unapplied"
            print "transaction of k entries, so replay-k = recover-k - mount-1mib. lines counts writeback requests"
            print "(pmem, direct and file; 0 on file-*-legacy, the file boundary before 2026-10-13, which makes none)."
            print "pmem-none drops CLWB and keeps SFENCE: an approximation of eADR timing, never durable. A difference"
            print "is real only outside both spreads."
        }' "$csv"
}

doctor() {
    rule "revision"
    git -C "$REPO" log -1 --oneline
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && say "tree clean" || warn "tree DIRTY (the campaign refuses unless PWOB_ALLOW_DIRTY=1)"
    rule "cpu"
    if have lscpu; then lscpu | grep -Ei 'model name|^model:|stepping|numa node' || true; fi
    local topo; topo=$(hybrid_topology)
    if [ "$topo" != "not hybrid" ]; then
        say "hybrid $topo"
        warn "hybrid CPU: set PWOB_CPUS to CPUs of one core type (cpu_core = performance, cpu_atom = efficiency)"
    fi
    say "governor $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';' || echo unknown)"
    rule "power"
    power_facts
    rule "dax directory (PWASM_PMEM_TEST_DIR)"
    if [ -z "${PWASM_PMEM_TEST_DIR:-}" ]; then
        warn "unset: the pmem-*, file-dax and file-dax-legacy configurations cannot run"
    else
        say "$PWASM_PMEM_TEST_DIR"
        say "  source  $(source_of "$PWASM_PMEM_TEST_DIR")"
        say "  options $(options_of "$PWASM_PMEM_TEST_DIR")"
        say "  node    $(numa_node_of "$PWASM_PMEM_TEST_DIR")"
        [ -w "$PWASM_PMEM_TEST_DIR" ] && say "  writable yes" || warn "  NOT writable"
        is_dax_dir "$PWASM_PMEM_TEST_DIR" || warn "  NOT a DAX mount: the campaign will refuse it"
    fi
    rule "block directory (PWOB_BLOCK_DIR)"
    if [ -z "$BLOCK_DIR" ]; then
        say "unset: file-block, file-block-legacy and direct-block are skipped"
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
    printf 'taskset          %s\n' "$(have taskset && echo present || echo 'absent -- PWOB_CPUS unavailable')"
    printf 'numactl          %s\n' "$(have numactl && echo present || echo 'absent -- runs are unpinned')"
    printf 'pwopsbench       %s\n' "$([ -x "$BENCH_BIN" ] && echo present || echo 'absent (campaign builds it)')"
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
