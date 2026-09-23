#!/usr/bin/env bash
#
# Run the persistence experiments reproducibly and record their provenance.
# See docs/persistent-backends.md for the boundary-cost results and
# docs/pmem-emulation.md for the flush-placement negative control.
#
#   scripts/pmem-experiments.sh doctor    report what this host can run, and why
#   scripts/pmem-experiments.sh cost      boundary-cost campaign, three configs
#   scripts/pmem-experiments.sh control   flush-placement negative control
#   scripts/pmem-experiments.sh all       both campaigns
#
# Every run writes a self-contained directory under results/, holding the raw
# log of each invocation, a machine-readable cost.csv, and a provenance file
# recording the commit, host, CPU, mounts and load. A result that cannot be
# attributed to a commit and a host is not evidence, so the script refuses to
# proceed from a dirty working tree unless PWEXP_ALLOW_DIRTY=1.
#
# Configurations. The cost campaign separates the boundary primitive from the
# media, which a two-way PMEM-versus-file comparison cannot do:
#
#   pmem-dax    SFENCE boundary    on the DAX mount      (PWASM_PMEM_TEST_DIR)
#   file-dax    fdatasync boundary on the same DAX mount (PWASM_PMEM_TEST_DIR)
#   file-block  fdatasync boundary on block storage      (PWEXP_BLOCK_DIR)
#
# pmem-dax versus file-dax isolates the primitive with the media held constant;
# file-dax versus file-block isolates the media with the primitive held
# constant. file-block is skipped, loudly, when its directory is on a network
# filesystem: an fdatasync dominated by a round trip measures the network.
#
# Repetitions are interleaved rather than batched, so a transient load spike on
# a shared host lands on one sample of each configuration instead of all samples
# of one. Load average is recorded beside every run so interference is auditable
# after the fact.
#
# Placement. Cross-socket access to a PMEM namespace costs about 24% on the
# fdatasync boundary, so by default the runs are pinned with numactl to the node
# that owns the DAX namespace. Leaving this to the scheduler makes the results
# bimodal -- which is how the effect was found. PWEXP_NUMA_NODE=none reverts to
# unpinned, or set it to a node number to force one.
#
# Region geometry. pwbench's region is always 512 blocks, so its block size sets
# the region size: 4096 gives 2 MiB, 2048 gives 1 MiB. On a DAX file this is not
# a neutral choice -- a region of 2 MiB or more is mapped with 2 MiB DAX entries,
# and fdatasync writes back a whole entry, so file-dax costs ~927 us at 2 MiB and
# ~5 us at 1 MiB. PWEXP_REGION_BLOCKSIZES takes a list; the sizes are interleaved
# within each repetition like the configurations, so a comparison across
# geometries is never also a comparison across sittings. A smaller block size
# also means a smaller WAL slot (about 26 entries at 2048), and the campaign
# refuses to start if a requested transaction size cannot fit.
#
# Overrides: PWASM_PMEM_TEST_DIR (required for the DAX configs and the control),
# PWEXP_BLOCK_DIR (default $HOME), PWEXP_REPS (3), PWEXP_SIZES ("1 8 32 56"),
# PWEXP_REGION_BLOCKSIZES ("4096"), PWEXP_COMMITS (20000), PWEXP_WARMUP (2000),
# PWEXP_OUT (results/<stamp>), PWEXP_SIEVE_ARGS ("20 1 512 4096"),
# PWEXP_ALLOW_DIRTY (0), PWEXP_NUMA_NODE (auto).

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

BLOCK_DIR="${PWEXP_BLOCK_DIR:-$HOME}"
REPS="${PWEXP_REPS:-3}"
SIZES="${PWEXP_SIZES:-1 8 32 56}"
REGION_BLOCKSIZES="${PWEXP_REGION_BLOCKSIZES:-4096}"
COMMITS="${PWEXP_COMMITS:-20000}"
WARMUP="${PWEXP_WARMUP:-2000}"
SIEVE_ARGS="${PWEXP_SIEVE_ARGS:-20 1 512 4096}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# A non-default geometry is named in the directory, so a 1 MiB campaign cannot be
# mistaken for one at the 2 MiB geometry every earlier result used.
BS_TAG=
[ "$REGION_BLOCKSIZES" = 4096 ] || BS_TAG="-bs$(tr -s ' ' '-' <<< "$REGION_BLOCKSIZES")"
OUT="${PWEXP_OUT:-$REPO/results/$STAMP-$(hostname -s)$BS_TAG}"

BENCH_BIN=bin/pwbench.x86-64-linux
SIEVE_BIN=bin/pwsieve.x86-64-linux
UNIT_BIN=bin/unittest.x86-64-linux

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rule() { printf -- '---- %s\n' "$*"; }

loadavg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown"; }

# The filesystem type backing a directory. Used to exclude a network filesystem
# from the block-media configuration rather than publishing its latency.
fstype_of() {
    local dir=$1
    if have findmnt; then
        findmnt -no FSTYPE -T "$dir" 2>/dev/null || echo unknown
    else
        df -PT "$dir" 2>/dev/null | awk 'NR == 2 { print $2 }' || echo unknown
    fi
}

source_of() {
    local dir=$1
    if have findmnt; then
        findmnt -no SOURCE -T "$dir" 2>/dev/null || echo unknown
    else
        df -P "$dir" 2>/dev/null | awk 'NR == 2 { print $1 }' || echo unknown
    fi
}

# The NUMA node owning a DAX directory's namespace. Cross-socket access costs
# about 24% on the fdatasync boundary (see docs/persistent-backends.md), so an
# unpinned campaign silently randomises a large variable.
numa_node_of() {
    local src dev f
    src=$(source_of "$1"); dev=${src##*/}
    for f in "/sys/block/$dev/device/numa_node" "/sys/bus/nd/devices/region${dev#pmem}/numa_node"; do
        if [ -r "$f" ]; then cat "$f"; return; fi
    done
    echo unknown
}

is_network_fs() {
    case "$1" in
        nfs|nfs3|nfs4|cifs|smb|smb3|smbfs|fuse.sshfs|9p|afs|glusterfs|ceph|lustre) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve the pinning prefix. Default: pin to the node owning the DAX namespace,
# so the measurement is controlled rather than left to the scheduler.
# PWEXP_NUMA_NODE=none disables pinning; a number forces that node.
PIN_CMD=()
PIN_NODE=none
resolve_pinning() {
    local want=${PWEXP_NUMA_NODE:-auto} node
    if [ "$want" = none ]; then PIN_NODE="disabled"; return; fi
    if ! have numactl; then PIN_NODE="unavailable (no numactl)"; return; fi
    if [ "$want" = auto ]; then
        node=$(numa_node_of "${PWASM_PMEM_TEST_DIR:-/}")
    else
        node=$want
    fi
    case "$node" in
        ''|*[!0-9]*) PIN_NODE="undetermined ($node)"; return ;;
    esac
    PIN_CMD=(numactl "--cpunodebind=$node" --)
    PIN_NODE="$node"
}

# ------------------------------------------------------------------ provenance

require_clean_tree() {
    [ "${PWEXP_ALLOW_DIRTY:-0}" = 1 ] && return 0
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && return 0
    die "working tree is dirty; commit first so the results name a revision, or set PWEXP_ALLOW_DIRTY=1"
}

write_provenance() {
    local f=$OUT/provenance.txt
    {
        rule "revision"
        git -C "$REPO" log -1 --pretty='commit %H%nauthored %aI%nsubject  %s'
        printf 'dirty    %s\n' "$(git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet && echo no || echo YES)"
        rule "host"
        printf 'hostname %s\n' "$(hostname -f 2>/dev/null || hostname)"
        printf 'kernel   %s\n' "$(uname -srmo)"
        printf 'started  %s\n' "$(date -uIseconds)"
        printf 'load     %s\n' "$(loadavg)"
        rule "cpu"
        if have lscpu; then lscpu | grep -Ei 'model name|^cpu\(s\)|thread|core|mhz|cache' || true; fi
        printf 'clwb     %s\n' "$(grep -qw clwb /proc/cpuinfo 2>/dev/null && echo yes || echo no)"
        rule "media"
        for d in "${PWASM_PMEM_TEST_DIR:-}" "$BLOCK_DIR"; do
            [ -n "$d" ] || continue
            printf '%s\n  fstype %s\n  source %s\n' "$d" "$(fstype_of "$d")" "$(source_of "$d")"
            if have findmnt; then findmnt -no OPTIONS -T "$d" 2>/dev/null | sed 's/^/  options /' || true; fi
        done
        if have ndctl; then rule "ndctl"; ndctl list 2>/dev/null || true; fi
        rule "numa"
        printf 'pinned to node   %s\n' "$PIN_NODE"
        if [ -n "${PWASM_PMEM_TEST_DIR:-}" ]; then
            printf 'dax namespace on %s\n' "$(numa_node_of "$PWASM_PMEM_TEST_DIR")"
        fi
        if have numactl; then numactl --hardware 2>/dev/null | head -20 || true; fi
        rule "parameters"
        printf 'reps %s\nsizes %s\ncommits %s\nwarmup %s\n' "$REPS" "$SIZES" "$COMMITS" "$WARMUP"
        printf 'region block sizes %s (512 blocks each)\n' "$REGION_BLOCKSIZES"
    } > "$f"
    say "provenance -> $f"
}

# ---------------------------------------------------------------------- build

ensure_bin() {
    local target=$1
    make "$target" >/dev/null || die "could not build $target"
    [ -x "$target" ] || die "$target missing after build"
}

# ----------------------------------------------------------------- cost campaign

CSV=
csv_header() {
    CSV=$OUT/cost.csv
    printf 'config,backend,dir,fstype,entries,commits,warmup,rep,boundaries_per_commit_x1000,clwb_lines,tsc_per_us,cyc_min,cyc_med,cyc_p90,cyc_p99,cyc_max,ns_min,ns_med,ns_p90,ns_p99,ns_max,total_boundary_cycles,total_prepare_cycles,wall_ns,boundary_share_x1000,wall_ns_per_commit,load1,block_size\n' > "$CSV"
}

# Extract every measured field in one pass and emit them comma-separated.
#
# Two details the first version of this got wrong, both worth keeping in mind if
# the harness output ever changes. Numbers carry trailing commas and colons, so
# a bare /^[0-9]+$/ test silently matches nothing; and "x1000" must not be read
# as the number 1000, so only trailing [,:] is stripped rather than all
# non-digits. The parse is strict: a short or empty field aborts the run, since
# a blank cell in a results file is worse than a failed run -- it survives into
# a figure.
parse_run() {
    awk '
        function nums(  i, t) { delete v; n = 0
            for (i = 1; i <= NF; i++) { t = $i; sub(/[,:]+$/, "", t)
                if (t ~ /^[0-9]+$/) v[++n] = t } }
        /boundaries per commit/      { nums(); bpc = v[1]; clwb = v[2] }
        /tsc cycles per microsecond/ { nums(); tsc = v[1] }
        /boundary cycles: min/       { nums(); cmin = v[1]; cmed = v[2]; c90 = v[3] }
        /boundary cycles: p99/       { nums(); c99 = v[1]; cmax = v[2] }
        /boundary ns: min/           { nums(); nmin = v[1]; nmed = v[2]; n90 = v[3] }
        /boundary ns: p99/           { nums(); n99 = v[1]; nmax = v[2] }
        /total boundary cycles/      { nums(); tbc = v[1] }
        /total prepare cycles/       { nums(); tpc = v[1] }
        /measured wall ns/           { nums(); wall = v[1]; share = v[2] }
        /wall ns per commit/         { nums(); wpc = v[1] }
        END { print bpc "," clwb "," tsc "," cmin "," cmed "," c90 "," c99 "," cmax \
                    "," nmin "," nmed "," n90 "," n99 "," nmax \
                    "," tbc "," tpc "," wall "," share "," wpc }
    ' "$1"
}

readonly PARSED_FIELDS=18

run_cost_one() {
    local config=$1 backend=$2 dir=$3 entries=$4 rep=$5 bs=$6
    local log="$OUT/cost-$config-bs$bs-e$entries-r$rep.log"
    local load; load=$(loadavg | cut -d' ' -f1)

    say "  $config blocksize=$bs entries=$entries rep=$rep"
    if ! "${PIN_CMD[@]}" "$BENCH_BIN" "$dir" "$backend" "$COMMITS" "$entries" "$WARMUP" "$bs" > "$log" 2>&1; then
        warn "    FAILED -- see $log"
        tail -3 "$log" >&2
        return 1
    fi
    grep -q '^OK$' "$log" || { warn "    no OK in $log"; return 1; }

    local parsed; parsed=$(parse_run "$log")
    local count; count=$(awk -F, '{ print NF }' <<< "$parsed")
    if [ "$count" -ne "$PARSED_FIELDS" ] || [[ "$parsed" == *,,* ]] ||
       [[ "$parsed" == ,* ]] || [[ "$parsed" == *, ]]; then
        warn "    could not parse $log -- the harness output format has moved"
        warn "    got: $parsed"
        return 1
    fi

    # The directory is quoted: a path may legitimately contain a comma, and an
    # unquoted one would shift every column after it.
    printf '%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$config" "$backend" "$dir" "$(fstype_of "$dir")" \
        "$entries" "$COMMITS" "$WARMUP" "$rep" "$parsed" "$load" "$bs" >> "$CSV"
}

# Refuse a sweep point the WAL slot cannot hold before any run starts, rather
# than discovering it as a failed run halfway through a campaign. The arithmetic
# mirrors pwbench's maxEntriesEstimate(): each of the two slots gets half of a
# block less the 64-byte WAL header, and a record is a 112-byte header and
# trailer plus one 32-byte entry per write. It is an estimate; the commit itself
# stays the authority.
check_geometry() {
    local bs entries slot max
    for bs in $REGION_BLOCKSIZES; do
        case "$bs" in ''|*[!0-9]*) die "PWEXP_REGION_BLOCKSIZES: not a number: $bs" ;; esac
        [ $((bs % 8)) -eq 0 ] || die "PWEXP_REGION_BLOCKSIZES: $bs is not a multiple of 8"
        slot=$(( (bs - 64) / 2 ))
        max=$(( slot > 112 ? (slot - 112) / 32 : 0 ))
        for entries in $SIZES; do
            [ "$entries" -le "$max" ] ||
                die "$entries entries do not fit a WAL slot at block size $bs (about $max do); lower PWEXP_SIZES"
        done
    done
}

cost() {
    require_clean_tree
    [ -n "${PWASM_PMEM_TEST_DIR:-}" ] || die "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"
    [ -d "$PWASM_PMEM_TEST_DIR" ] || die "PWASM_PMEM_TEST_DIR is not a directory: $PWASM_PMEM_TEST_DIR"
    check_geometry
    ensure_bin "$BENCH_BIN"
    resolve_pinning
    say "numa pinning: node $PIN_NODE"
    say "region block sizes: $REGION_BLOCKSIZES"
    mkdir -p "$OUT"
    write_provenance
    csv_header

    local block_fs; block_fs=$(fstype_of "$BLOCK_DIR")
    local do_block=1
    if [ ! -d "$BLOCK_DIR" ]; then
        warn "skipping file-block: $BLOCK_DIR is not a directory"; do_block=0
    elif is_network_fs "$block_fs"; then
        warn "skipping file-block: $BLOCK_DIR is $block_fs, and an fdatasync over a network filesystem measures the network"
        do_block=0
    fi
    printf 'file-block: %s (%s)\n' \
        "$([ $do_block = 1 ] && echo included || echo SKIPPED)" "$block_fs" >> "$OUT/provenance.txt"

    local failures=0
    # rep outermost, config innermost: interleaved, so a load spike hits one
    # sample of each configuration and geometry rather than every sample of one.
    for rep in $(seq 1 "$REPS"); do
        for bs in $REGION_BLOCKSIZES; do
            for entries in $SIZES; do
                run_cost_one pmem-dax   pmem "$PWASM_PMEM_TEST_DIR" "$entries" "$rep" "$bs" || failures=$((failures + 1))
                run_cost_one file-dax   file "$PWASM_PMEM_TEST_DIR" "$entries" "$rep" "$bs" || failures=$((failures + 1))
                [ $do_block = 1 ] &&
                    { run_cost_one file-block file "$BLOCK_DIR" "$entries" "$rep" "$bs" || failures=$((failures + 1)); }
            done
        done
    done

    printf 'finished %s\nload     %s\n' "$(date -uIseconds)" "$(loadavg)" >> "$OUT/provenance.txt"
    cost_summary | tee "$OUT/cost-summary.txt"
    say ""
    say "csv -> $CSV"
    [ "$failures" -eq 0 ] || die "$failures run(s) failed; the logs are retained in $OUT"
}

# Median of the per-run medians, per configuration and size. Medians rather than
# means because the intended host is shared: interference lands in the tail.
cost_summary() {
    rule "median boundary ns, median over $REPS repetitions"
    awk -F, 'NR > 1 { key = $1 "\t" $NF "\t" $5; vals[key] = vals[key] " " $18 }
        END {
            printf "%-12s %9s %8s %14s\n", "config", "blocksize", "entries", "boundary_ns"
            for (k in vals) {
                n = split(vals[k], a, " "); m = 0
                for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
                m = (n % 2) ? a[(n + 1) / 2] : int((a[n / 2] + a[n / 2 + 1]) / 2)
                split(k, p, "\t"); printf "%-12s %9s %8s %14s\n", p[1], p[2], p[3], m
            }
        }' "$CSV" | { read -r h; printf '%s\n' "$h"; sort -k1,1 -k2,2n -k3,3n; }
    rule "boundaries per commit (must be 1000; a higher value means the overwrite guard fired)"
    awk -F, 'NR > 1 { print $9 }' "$CSV" | sort -u | tr '\n' ' '; echo
}

# -------------------------------------------------------- negative control

control() {
    require_clean_tree
    [ -n "${PWASM_PMEM_TEST_DIR:-}" ] || die "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"
    ensure_bin "$UNIT_BIN"
    ensure_bin "$SIEVE_BIN"
    resolve_pinning
    mkdir -p "$OUT"
    [ -f "$OUT/provenance.txt" ] || write_provenance

    local log=$OUT/control.log
    local rc=0
    {
        rule "layer 1b: explorer must reject the elided-writeback mutant"
        "$UNIT_BIN" 'persistent_control:*' 2>&1 || rc=1
        rule "layer 3: ordinary build on real PMEM, expected OK"
        # shellcheck disable=SC2086
        "$SIEVE_BIN" "$PWASM_PMEM_TEST_DIR" $SIEVE_ARGS pmem 2>&1 || rc=1
        rule "layer 3: elided-writeback mutant on real PMEM, expected OK"
        # shellcheck disable=SC2086
        "$SIEVE_BIN" "$PWASM_PMEM_TEST_DIR" $SIEVE_ARGS pmem elide-clwb 2>&1 || rc=1
    } 2>&1 | tee "$log"

    say ""
    rule "2x2"
    local unit_fail ord mut
    unit_fail=$(grep -c '^##-fail' "$log" || true)
    ord=$(awk '/mutant on real PMEM/ { exit } /^OK$/ { n++ } END { print n + 0 }' "$log")
    mut=$(awk '/mutant on real PMEM/ { seen = 1 } seen && /^OK$/ { n++ } END { print n + 0 }' "$log")
    printf '%-28s %s\n' "explorer rejects mutant:" "$([ "$unit_fail" -eq 0 ] && echo yes || echo NO)"
    printf '%-28s %s\n' "ordinary build on PMEM:"  "$([ "$ord" -ge 1 ] && echo OK || echo FAILED)"
    printf '%-28s %s\n' "mutant on PMEM:"          "$([ "$mut" -ge 1 ] && echo OK || echo FAILED)"
    say ""
    say "The expected outcome is all three above: the hardware cannot distinguish"
    say "the builds and the model can. A mutant that FAILS on PMEM would mean the"
    say "hardware test is more sensitive than docs/pmem-emulation.md claims, and"
    say "the surrounding argument needs rewriting rather than confirming."
    say "log -> $log"
    return $rc
}

# --------------------------------------------------------------------- doctor

doctor() {
    rule "revision"
    git -C "$REPO" log -1 --pretty='%h %s'
    if git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
        say "tree clean"
    else
        warn "tree DIRTY -- cost and control refuse to run without PWEXP_ALLOW_DIRTY=1"
    fi
    rule "binaries"
    for b in "$BENCH_BIN" "$SIEVE_BIN" "$UNIT_BIN"; do
        printf '%-32s %s\n' "$b" "$([ -x "$b" ] && echo present || echo 'absent (will be built)')"
    done
    rule "cpu"
    printf 'clwb in /proc/cpuinfo   %s\n' "$(grep -qw clwb /proc/cpuinfo 2>/dev/null && echo yes || echo no)"
    rule "dax directory (PWASM_PMEM_TEST_DIR)"
    if [ -z "${PWASM_PMEM_TEST_DIR:-}" ]; then
        warn "unset -- pmem-dax, file-dax and the whole control campaign are unavailable"
    else
        printf '%s\n  fstype   %s\n  source   %s\n  writable %s\n' \
            "$PWASM_PMEM_TEST_DIR" "$(fstype_of "$PWASM_PMEM_TEST_DIR")" \
            "$(source_of "$PWASM_PMEM_TEST_DIR")" \
            "$([ -w "$PWASM_PMEM_TEST_DIR" ] && echo yes || echo NO)"
        if have findmnt; then
            local opts; opts=$(findmnt -no OPTIONS -T "$PWASM_PMEM_TEST_DIR" 2>/dev/null || true)
            printf '  options  %s\n' "$opts"
            case "$opts" in *dax*) ;; *) warn "  no dax option -- MAP_SYNC will fail and pmem runs will refuse to start" ;; esac
        fi
    fi
    rule "block directory (PWEXP_BLOCK_DIR)"
    local fs; fs=$(fstype_of "$BLOCK_DIR")
    printf '%s\n  fstype   %s\n  source   %s\n' "$BLOCK_DIR" "$fs" "$(source_of "$BLOCK_DIR")"
    if is_network_fs "$fs"; then
        warn "  network filesystem -- file-block will be skipped, since fdatasync would measure the network"
    else
        say "  usable as the block-media configuration"
    fi
    rule "numa"
    if have numactl; then
        say "numactl present"
        if [ -n "${PWASM_PMEM_TEST_DIR:-}" ]; then
            say "dax namespace on node $(numa_node_of "$PWASM_PMEM_TEST_DIR")  (runs pin here by default)"
        fi
    else
        warn "numactl absent -- runs cannot be pinned, and an unpinned campaign randomises a 24% variable"
    fi
    rule "load"
    say "$(loadavg)   (a shared host inflates the tail; medians survive, means do not)"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

case "${1:-doctor}" in
    doctor)  doctor ;;
    cost)    cost ;;
    control) control ;;
    all)     cost; control ;;
    help|-h|--help) usage ;;
    *)       usage; exit 2 ;;
esac
