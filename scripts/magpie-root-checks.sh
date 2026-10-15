#!/usr/bin/env bash
#
# The root-only evidence the docs leave open, collected in one sitting.
# Run on Magpie from the checkout, by someone with sudo, on behalf of the
# account that owns the checkout:
#
#   sudo scripts/magpie-root-checks.sh
#
# or, when the sudoer is not the checkout's owner:
#
#   sudo env PWROOT_USER=<owner> <checkout>/scripts/magpie-root-checks.sh
#
# 1. RAID controller. /home is LVM on sda behind a MegaRAID SAS3508 that
#    reports write-through, so fdatasync sends no flush and every file-block
#    and direct-block figure is the controller's acknowledgement. Whether that
#    acknowledgement is power-safe depends on the controller's cache policy and
#    cache module, or on the drive's own write cache if sda is a pass-through
#    drive. Read-only storcli/smartctl/sdparm queries answer it.
# 2. Block trace. Does an fdatasync on /home put any flush on sda? Inferred so
#    far only from its ~1.7 us duration. block:block_rq_issue during a short
#    pwbench run shows every request pwbench causes, with its flags.
# 3. DAX writeback granularity. fs_dax:dax_writeback_one during short pwbench
#    runs on the DAX mount at 2 MiB and 1 MiB regions: the region-size
#    mechanism predicts pglen 0x200 (a whole 2 MiB entry) and 0x1.
# 4. Block stack, for B2 of the file backend's restriction argument
#    (docs/pmem-crash-model.md): is /home's LVM volume linear and unencrypted,
#    so that no layer copies pages with the CPU, and does any block device
#    request stable writes? dmsetup table and dmsetup info -c (crypt keys are
#    not shown without --showkeys, which is not used), lsblk, and every block
#    device's queue/stable_writes.
# 5. Core clock on block storage. The clock probe found that a thread that
#    blocks on /home comes back at 1.0 GHz against 3.6 GHz busy, which fits
#    the C1E idle state ("a minimum performance state when it is idle"), and
#    only turbostat can say which state the core entered. Probed sieve runs
#    (file and direct) and a B+Tree run (file) on /home, pinned to one CPU,
#    once with that CPU's idle states as they are and once with C1E and C6
#    disabled on it alone, interleaved. turbostat records each run's busy
#    clock and idle-state residency, and perf stat its cycles, reference cycles
#    (at the TSC rate) and instructions; either is skipped if it does not run.
#    On this CPU model intel_idle switches off the hardware's own promotion of
#    C1 to C1E, so disabling the C1E state is enough to keep the core out of it.
#
# Only section 5 changes the host, and only CPU PWROOT_CPU's C1E and C6
# settings, for the length of its runs: each is restored after every run, and
# again on exit if the script stops early. Otherwise the controller and drive
# queries are "show" and "get" operations, the device-mapper queries only read
# tables; tracing is switched on only around each run and the previous state
# and buffer size are restored; the benchmarks run as the checkout's owner in
# that owner's own directories. Results go to
# results/<stamp>-<host>-root-checks/, owned by that account.
#
# Overrides: PWASM_PMEM_TEST_DIR (default /mnt/pmem0.0/sean), PWROOT_USER (the
# account to run the benchmarks as; default the sudo caller), PWROOT_BLOCK_DIR
# (default that account's home), PWROOT_DEVICE (default sda), PWROOT_CPU (the
# CPU section 5 pins to, default 2, on node 0 like the earlier clock runs),
# PWROOT_CLOCK_REPS (default 2; 0 skips section 5).

set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0" >&2; exit 2; }
U=${PWROOT_USER:-${SUDO_USER:-}}
[ -n "$U" ] && [ "$U" != root ] || { echo "run via sudo from the account that owns the checkout (or set PWROOT_USER)" >&2; exit 2; }
REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UHOME=$(getent passwd "$U" | cut -d: -f6)
BLOCK_DIR=${PWROOT_BLOCK_DIR:-$UHOME}
PMEM_DIR=${PWASM_PMEM_TEST_DIR:-/mnt/pmem0.0/sean}
DEV=${PWROOT_DEVICE:-sda}
BENCH=$REPO/bin/pwbench.x86-64-linux
OUT=$REPO/results/$(date -u +%Y%m%dT%H%M%SZ)-$(hostname -s)-root-checks

as_user() { runuser -u "$U" -- "$@"; }
rule() { printf -- '---- %s\n' "$*"; }
say() { printf '%s\n' "$*"; }

# Each section that changes state appends its restore function here.
CLEANUP=()
cleanup() { local f; for f in "${CLEANUP[@]}"; do "$f"; done; }
trap cleanup EXIT

[ -x "$BENCH" ] || { echo "$BENCH is missing; build it first as $U: make bin/pwbench.x86-64-linux" >&2; exit 2; }
as_user mkdir -p "$OUT" || { echo "could not create $OUT as $U" >&2; exit 2; }
say "results -> $OUT"

{
    rule "provenance"
    say "commit   $(as_user git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    say "host     $(hostname -f 2>/dev/null || hostname)"
    say "kernel   $(uname -srmo)"
    say "started  $(date -uIseconds)"
    say "run by   ${SUDO_USER:-root} for $U"
    say "block    $BLOCK_DIR ($(findmnt -no FSTYPE,SOURCE -T "$BLOCK_DIR" 2>/dev/null))"
    say "dax      $PMEM_DIR ($(findmnt -no FSTYPE,SOURCE,OPTIONS -T "$PMEM_DIR" 2>/dev/null))"
    for f in rotational write_cache fua; do say "$DEV $f $(cat /sys/block/$DEV/queue/$f 2>/dev/null)"; done
} > "$OUT/provenance.txt"

# ------------------------------------------------------------ 1. controller

STORCLI=$(command -v storcli64 || command -v storcli || command -v perccli64 || command -v perccli ||
          ls /opt/MegaRAID/storcli/storcli64 /opt/MegaRAID/perccli/perccli64 2>/dev/null | head -1 || true)
{
    rule "storcli: ${STORCLI:-NOT FOUND}"
    if [ -n "$STORCLI" ]; then
        for q in "/c0 show" "/c0/vall show all" "/c0 show jbod" "/c0/eall/sall show all" \
                 "/c0/cv show all" "/c0/bbu show all"; do
            rule "$STORCLI $q"
            # shellcheck disable=SC2086
            "$STORCLI" $q 2>&1
        done
    fi
    rule "sdparm --get=WCE /dev/$DEV (the cache bit the controller presents to Linux)"
    if command -v sdparm >/dev/null; then sdparm --get=WCE "/dev/$DEV" 2>&1; else say "sdparm not installed"; fi
    rule "smartctl --scan"
    if command -v smartctl >/dev/null; then
        smartctl --scan 2>&1
        # Physical drives behind the controller, with their own write-cache setting.
        smartctl --scan 2>/dev/null | awk '/megaraid,/ { print $1, $3 }' | while read -r bus type; do
            rule "smartctl -d $type -i -g wcache $bus"
            smartctl -d "$type" -i -g wcache "$bus" 2>&1
        done
        rule "smartctl -i -g wcache /dev/$DEV"
        smartctl -i -g wcache "/dev/$DEV" 2>&1
    else
        say "smartctl not installed (smartmontools)"
    fi
} > "$OUT/controller.txt" 2>&1
chown "$U" "$OUT/controller.txt"
say "1. controller queries -> controller.txt (storcli: ${STORCLI:-not found})"

# ------------------------------------------------------------ 4. block stack (B2)

{
    rule "findmnt -T $BLOCK_DIR"
    findmnt -T "$BLOCK_DIR" 2>&1
    rule "lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT"
    lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT 2>&1
    rule "dmsetup table (target per segment: linear, striped, crypt, raid, ...)"
    if command -v dmsetup >/dev/null; then dmsetup table 2>&1; else say "dmsetup not installed"; fi
    rule "dmsetup info -c"
    if command -v dmsetup >/dev/null; then dmsetup info -c 2>&1; fi
    rule "dm uuids (CRYPT- for dm-crypt, LVM- for LVM)"
    for d in /sys/block/dm-*; do
        [ -e "$d/dm/uuid" ] && say "$(basename "$d") $(cat "$d/dm/name" 2>/dev/null) $(cat "$d/dm/uuid")"
    done
    rule "queue/stable_writes per block device (1 = the device requests stable pages)"
    for d in /sys/block/*; do
        [ -e "$d/queue/stable_writes" ] && say "$(basename "$d") $(cat "$d/queue/stable_writes")"
    done
} > "$OUT/block-stack.txt" 2>&1
chown "$U" "$OUT/block-stack.txt"
say "4. block stack -> block-stack.txt"

# ------------------------------------------------------------ 2 and 3. traces

T=/sys/kernel/tracing
[ -e "$T/tracing_on" ] || T=/sys/kernel/debug/tracing
[ -e "$T/tracing_on" ] || mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null && T=/sys/kernel/tracing
if [ ! -e "$T/tracing_on" ]; then
    say "tracefs is not available; skipping the traces"
else
    OLD_ON=$(cat "$T/tracing_on")
    # "7 (expanded: 1408)" before the buffer is first used: restore the
    # expanded size, not the placeholder.
    OLD_KB=$(sed -E 's/.*expanded: ([0-9]+).*/\1/; s/^([0-9]+).*/\1/' "$T/buffer_size_kb")
    restore() {
        echo 0 > "$T/tracing_on"
        for ev in block/block_rq_issue fs_dax/dax_writeback_one; do
            [ -e "$T/events/$ev/enable" ] && echo 0 > "$T/events/$ev/enable"
        done
        { echo "$OLD_KB" > "$T/buffer_size_kb"; } 2>/dev/null
        echo "$OLD_ON" > "$T/tracing_on"
    }
    CLEANUP+=(restore)
    echo 16384 > "$T/buffer_size_kb"

    # trace_run <event> <name> <command...>: trace only while the command runs.
    trace_run() {
        local ev=$1 name=$2 rc=0; shift 2
        if [ ! -e "$T/events/$ev/enable" ]; then
            say "  $name: tracepoint $ev does not exist on this kernel"; return
        fi
        echo 0 > "$T/tracing_on"; echo > "$T/trace"
        echo 1 > "$T/events/$ev/enable"; echo 1 > "$T/tracing_on"
        as_user "$@" > "$OUT/$name.log" 2>&1 || rc=$?
        echo 0 > "$T/tracing_on"; echo 0 > "$T/events/$ev/enable"
        cat "$T/trace" > "$OUT/$name.trace"
        chown "$U" "$OUT/$name.log" "$OUT/$name.trace"
        say "  $name: pwbench exit $rc ($(tail -1 "$OUT/$name.log")), $(grep -vc '^#' "$OUT/$name.trace") trace lines"
    }

    say "2. block requests during fdatasync on $BLOCK_DIR"
    trace_run block/block_rq_issue block-direct "$BENCH" "$BLOCK_DIR" direct 2000 8 200
    trace_run block/block_rq_issue block-file   "$BENCH" "$BLOCK_DIR" file   2000 8 200
    say "3. DAX writeback granularity on $PMEM_DIR"
    trace_run fs_dax/dax_writeback_one dax-2mib "$BENCH" "$PMEM_DIR" file 200 8 20 4096
    trace_run fs_dax/dax_writeback_one dax-1mib "$BENCH" "$PMEM_DIR" file 200 8 20 2048
fi

# ------------------------------------------------------------ 5. core clock

CPU=${PWROOT_CPU:-2}
CLOCK_REPS=${PWROOT_CLOCK_REPS:-2}
SIEVE=$REPO/bin/pwsievebench.x86-64-linux
BTREE=$REPO/bin/pwbtreebench.x86-64-linux
CPUIDLE=/sys/devices/system/cpu/cpu$CPU/cpuidle
TURBOSTAT=$(command -v turbostat || true)
PERF=$(command -v perf || true)
PERF_EVENTS=cycles,ref-cycles,instructions

IDLE_SAVED=()
# shallow_idle: disable C1E and C6 on $CPU, remembering each one's setting.
shallow_idle() {
    local s
    for s in "$CPUIDLE"/state*; do
        case "$(cat "$s/name")" in
            C1E|C6) IDLE_SAVED+=("$s=$(cat "$s/disable")"); echo 1 > "$s/disable" ;;
        esac
    done
}
restore_idle() {
    local e
    for e in "${IDLE_SAVED[@]}"; do echo "${e#*=}" > "${e%=*}/disable"; done
    IDLE_SAVED=()
}
CLEANUP+=(restore_idle)

# measure <name> <command...>: run as $U pinned to $CPU, under turbostat and
# perf stat where they run.
measure() {
    local name=$1 rc=0; shift
    local cmd=(runuser -u "$U" -- taskset -c "$CPU" "$@")
    [ -n "$PERF" ] && cmd=("$PERF" stat -x, -e "$PERF_EVENTS" -o "$OUT/$name.perf" -- "${cmd[@]}")
    [ -n "$TURBOSTAT" ] && cmd=("$TURBOSTAT" --quiet --cpu "$CPU" --out "$OUT/$name.turbostat" -- "${cmd[@]}")
    "${cmd[@]}" > "$OUT/$name.log" 2>&1 || rc=$?
    chown "$U" "$OUT/$name".*
    say "  $name: exit $rc ($(tail -1 "$OUT/$name.log"))"
}

if [ "$CLOCK_REPS" = 0 ]; then
    say "5. core clock: skipped (PWROOT_CLOCK_REPS=0)"
elif [ ! -x "$SIEVE" ] || [ ! -x "$BTREE" ]; then
    say "5. core clock: skipped; build both benchmarks first as $U: make bin/pwsievebench.x86-64-linux bin/pwbtreebench.x86-64-linux"
elif [ ! -d "$CPUIDLE" ]; then
    say "5. core clock: skipped; CPU $CPU has no cpuidle directory"
else
    {
        rule "cpuidle driver: $(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
        rule "CPU $CPU idle states before section 5: state, name, exit latency (us), disable"
        for s in "$CPUIDLE"/state*; do
            say "$(basename "$s") $(cat "$s/name") $(cat "$s/latency") $(cat "$s/disable")"
        done
        rule "turbostat: ${TURBOSTAT:-not installed}"
        if [ -n "$TURBOSTAT" ] && ! "$TURBOSTAT" --quiet -- true 2>&1; then TURBOSTAT=; say "does not run; skipped"; fi
        rule "perf: ${PERF:-not installed}"
        if [ -n "$PERF" ] && ! "$PERF" stat -e "$PERF_EVENTS" -- true 2>&1; then PERF=; say "does not run; skipped"; fi
    } > "$OUT/clock-setup.txt" 2>&1
    chown "$U" "$OUT/clock-setup.txt"
    CDIR=$BLOCK_DIR/pwroot-clock
    as_user mkdir -p "$CDIR"
    say "5. core clock on $CDIR, CPU $CPU, $CLOCK_REPS repetitions (turbostat: ${TURBOSTAT:-none}, perf: ${PERF:-none})"
    for r in $(seq 1 "$CLOCK_REPS"); do
        for idle in default shallow; do
            [ "$idle" = shallow ] && shallow_idle
            measure "clock-sieve-file-$idle-r$r"   "$SIEVE" "$CDIR" file   20 8 256 4096 clock=probe
            measure "clock-sieve-direct-$idle-r$r" "$SIEVE" "$CDIR" direct 20 8 256 4096 clock=probe
            measure "clock-btree-file-$idle-r$r"   "$BTREE" "$CDIR" file   3 5000 5000 256 4096 seed=1
            restore_idle
        done
    done
fi

# ------------------------------------------------------------ summary

{
    rule "block requests issued by pwbench (device, flags): count"
    say "flags containing F are flushes (or FUA); expected none if the device is write-through"
    for name in block-direct block-file; do
        [ -f "$OUT/$name.trace" ] || continue
        say "$name:"
        awk '/block_rq_issue:/ && /pwbench/ {
                 for (i = 1; i <= NF; i++) if ($i == "block_rq_issue:") { print "  " $(i + 1), $(i + 2); break }
             }' "$OUT/$name.trace" | sort | uniq -c
        say "  flush-flagged requests from pwbench: $(awk '/block_rq_issue:/ && /pwbench/ {
                 for (i = 1; i <= NF; i++) if ($i == "block_rq_issue:") { if ($(i + 2) ~ /F/) n++; break } }
             END { print n + 0 }' "$OUT/$name.trace")"
    done
    rule "dax_writeback_one pglen (pages per writeback): count"
    say "expected: 0x200 (a whole 2 MiB entry) at 2 MiB, 0x1 at 1 MiB, about once per commit"
    for name in dax-2mib dax-1mib; do
        [ -f "$OUT/$name.trace" ] || continue
        say "$name:"
        grep -o 'pglen 0x[0-9a-f]*' "$OUT/$name.trace" | sort | uniq -c | sed 's/^/  /'
    done
    rule "core clock (5): CPU $CPU, idle states as they are (default) and with C1E and C6 disabled (shallow)"
    say "probe: implied MHz busy, after the sieve, after the bitmap boundary; op: median ns;"
    say "turbostat: CPU $CPU over the run; perf: cycles over reference cycles at the TSC rate"
    for f in "$OUT"/clock-*.log; do
        [ -f "$f" ] || continue
        b=${f%.log}
        say "$(basename "$b"):"
        probe=$(sed -nE 's/^clock (busy|after sieve|after bitmap): .*implied MHz ([0-9]+).*/\1 \2/p' "$f" | paste -sd, - | sed "s/,/, /g")
        [ -n "$probe" ] && say "  probe MHz: $probe"
        ops=$(sed -nE 's/^op (insert|update) .* median_ns ([0-9]+) .*/\1 \2/p' "$f" | paste -sd, - | sed "s/,/, /g")
        [ -n "$ops" ] && say "  op median ns: $ops"
        [ -f "$b.turbostat" ] && awk -v cpu="$CPU" '
            /Bzy_MHz/ { for (i = 1; i <= NF; i++) col[$i] = i; next }
            ("CPU" in col) && $col["CPU"] == cpu {
                line = "  turbostat:"
                n = split("Avg_MHz Busy% Bzy_MHz POLL% C1% C1E% C6%", want, " ")
                for (i = 1; i <= n; i++) if (want[i] in col) line = line " " want[i] " " $col[want[i]]
                print line
            }' "$b.turbostat"
        [ -f "$b.perf" ] && awk -F, -v khz="$(awk '/^tsc kHz/ { print $3 }' "$f")" '
            $3 ~ /^cycles/ { c = $1 } $3 ~ /^ref-cycles/ { r = $1 } $3 ~ /^instructions/ { n = $1 }
            END {
                if (c + 0 > 0 && r + 0 > 0 && khz + 0 > 0)
                    printf "  perf: unhalted MHz %d, instructions per cycle %.2f\n", c * khz / r / 1000, n / c
                else
                    print "  perf: cycles " c ", ref-cycles " r ", tsc kHz " khz
            }' "$b.perf"
    done
    rule "block stack (B2): device-mapper targets, and devices requesting stable writes"
    say "targets: $(dmsetup table 2>/dev/null | awk '{ print $4 }' | sort | uniq -c | tr -s ' \n' ' ')"
    say "stable_writes=1: $(for d in /sys/block/*; do [ "$(cat "$d/queue/stable_writes" 2>/dev/null)" = 1 ] && printf '%s ' "$(basename "$d")"; done)"
} | tee "$OUT/summary.txt"
chown -R "$U" "$OUT"
say "done; commit $OUT as $U"
