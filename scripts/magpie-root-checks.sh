#!/usr/bin/env bash
#
# The root-only evidence the docs leave open, collected in one sitting.
# Run on Magpie from the checkout, by someone with sudo, on behalf of the
# account that owns the checkout:
#
#   sudo scripts/magpie-root-checks.sh
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
#
# Nothing here changes the host: the controller and drive queries are "show"
# and "get" operations; tracing is switched on only around each run and the
# previous state and buffer size are restored; the benchmarks run as the
# checkout's owner in that owner's own directories. Results go to
# results/<stamp>-<host>-root-checks/, owned by that account.
#
# Overrides: PWASM_PMEM_TEST_DIR (default /mnt/pmem0.0/sean), PWROOT_USER (the
# account to run the benchmarks as; default the sudo caller), PWROOT_BLOCK_DIR
# (default that account's home), PWROOT_DEVICE (default sda).

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
    trap restore EXIT
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
} | tee "$OUT/summary.txt"
chown -R "$U" "$OUT"
say "done; commit $OUT as $U"
