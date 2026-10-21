#!/usr/bin/env bash
#
# Desktop mount/queue facts and block:block_rq_issue around pwbench; NO reset.
#   sudo env PWROOT_USER=sean-tan scripts/desktop-root-checks.sh
# Requires an already mounted tracefs; never mounts it or changes global tracing.
# PWROOT_BLOCK_DIR defaults to the reused $HOME/pwroot-desktop directory on /.
# Results: results/<UTC stamp>-sean-tan-PC-desktop-root-checks/ (owner's files).

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }
rule() { printf -- '---- %s\n' "$*"; }
[ "$(id -u)" = 0 ] || die "needs root: sudo env PWROOT_USER=<user> $0"
[ "$#" = 0 ] || die "usage: sudo env PWROOT_USER=<user> $0"
U=${PWROOT_USER:-${SUDO_USER:-}}
[ -n "$U" ] && [ "$U" != root ] || die "set PWROOT_USER to the checkout's owner"
UID_RUN=$(id -u "$U"); GID_RUN=$(id -g "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
as_user() { setpriv --reuid="$UID_RUN" --regid="$GID_RUN" --init-groups -- env HOME="$UHOME" "$@"; }
[ "$(hostname -s)" = pc-ubuntu ] || die "this procedure is for pc-ubuntu (results tag sean-tan-PC)"
[ "$(findmnt -nro SOURCE,FSTYPE -T /)" = '/dev/nvme1n1p3 ext4' ] || die "/ must be ext4 on /dev/nvme1n1p3"
[ "$(findmnt -nro TARGET -T "$REPO")" = / ] || die "checkout/results must be on the root filesystem"
for cmd in setpriv tune2fs timeout; do command -v "$cmd" >/dev/null || die "missing $cmd"; done
BENCH=$REPO/bin/pwbench.x86-64-linux
# Build as yourself first: under sudo the PATH has no v3c, so this only checks.
as_user make -q bin/pwbench.x86-64-linux \
    || die "pwbench is out of date: run 'make bin/pwbench.x86-64-linux' as yourself, then rerun"
OUT=$REPO/results/$(date -u +%Y%m%dT%H%M%SZ)-sean-tan-PC-desktop-root-checks
as_user mkdir -p "$REPO/results"
as_user mkdir "$OUT" || die "results directory already exists: $OUT"
BLOCK_DIR=${PWROOT_BLOCK_DIR:-$UHOME/pwroot-desktop}
BLOCK_DIR=$(realpath -m -- "$BLOCK_DIR")
case "$BLOCK_DIR" in "$UHOME"/*) ;; *) die "PWROOT_BLOCK_DIR must be under $UHOME" ;; esac
as_user mkdir -p "$BLOCK_DIR"
[ "$(findmnt -nro TARGET -T "$BLOCK_DIR")" = / ] || die "benchmark directory must be on /"
say "results -> $OUT"

# A private instance leaves the global buffer, filters, enables, clock and
# tracing_on untouched. Removing the instance restores all our local settings.
T=
child=
stop_child() {
    if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        child=
    fi
}
on_signal() {
    trap '' INT TERM HUP
    stop_child
    exit "$1"
}
cleanup() {
    local rc=$? failed=0
    trap - EXIT
    trap '' INT TERM HUP
    stop_child
    if [ -n "$T" ]; then
        { echo 0 > "$T/tracing_on"; } || failed=1
        { echo 0 > "$T/events/block/block_rq_issue/enable"; } || failed=1
        rmdir "$T" || failed=1
    fi
    chown -R "$UID_RUN:$GID_RUN" "$OUT" || failed=1
    if [ "$failed" != 0 ]; then
        say "ERROR: cleanup incomplete; inspect trace instance $T" >&2
        rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
{
    rule provenance
    say "commit   $(as_user git rev-parse HEAD)"
    say "host     $(hostname -f) (results tag sean-tan-PC)"
    say "kernel   $(uname -srmo)"
    say "started  $(date -uIseconds)"
    say "run by   ${SUDO_USER:-root} for $U"
    say "block    $BLOCK_DIR"
    say 'pwbench <directory> <file|direct> 2000 8 200 4096 512'
    say '2 MiB; 8 entries; 2000 measured + 200 warm-up commits, as on Magpie.'
    as_user git status --short
    say 'binary make -q: up-to-date (built by the owner before sudo)'
    sha256sum "$BENCH" "$REPO/scripts/desktop-root-checks.sh"
} > "$OUT/provenance.txt"
as_user cp -- "$REPO/scripts/desktop-root-checks.sh" "$OUT/"
{
    rule 'findmnt /'
    findmnt -T /
    rule '/proc/mounts root-device entry (runtime options, including data mode if reported)'
    awk '$1 == "/dev/nvme1n1p3" && $2 == "/"' /proc/mounts
    rule 'tune2fs -l /dev/nvme1n1p3 (read-only superblock defaults/features/journal)'
    tune2fs -l /dev/nvme1n1p3
    rule '/proc/fs/ext4/nvme1n1p3/options (effective options: data mode, delalloc, dioread_nolock, barrier)'
    cat /proc/fs/ext4/nvme1n1p3/options
    rule 'nvme1n1 queue (absent attributes are reported explicitly)'
    for f in write_cache fua stable_writes 'atomic_write_*' logical_block_size physical_block_size \
             rotational minimum_io_size optimal_io_size; do
        # Expand atomic_write_* against the queue, not the checkout.
        if [ "$f" = 'atomic_write_*' ]; then
            for attr in /sys/block/nvme1n1/queue/atomic_write_*; do
                if [ -e "$attr" ]; then say "${attr##*/} $(cat "$attr")"; else say 'atomic_write_* absent'; fi
            done
        elif [ -e "/sys/block/nvme1n1/queue/$f" ]; then
            say "$f $(cat "/sys/block/nvme1n1/queue/$f")"
        else say "$f absent"; fi
    done
} > "$OUT/block-stack.txt" 2>&1
BASE=/sys/kernel/tracing
[ -d "$BASE/instances" ] || BASE=/sys/kernel/debug/tracing
[ -d "$BASE/instances" ] || die "tracefs instances unavailable; mount tracefs separately before running"
INSTANCE=$BASE/instances/pwroot-desktop-$$
mkdir "$INSTANCE"
T=$INSTANCE
[ -e "$T/events/block/block_rq_issue/enable" ] || die "block:block_rq_issue unavailable"
echo 0 > "$T/tracing_on"
echo 4096 > "$T/buffer_size_kb"
# Kernel dev_t uses major << 20 | minor; printed traces use major,minor.
IFS=: read -r MAJOR MINOR < /sys/block/nvme1n1/dev
DEV=$(( (MAJOR << 20) | MINOR ))
echo "dev == $DEV" > "$T/events/block/block_rq_issue/filter"
cat "$T/events/block/block_rq_issue/format" > "$OUT/block_rq_issue.format"
cat "$T/events/block/block_rq_issue/filter" > "$OUT/block_rq_issue.filter"
# Wait on a background timeout, so shell signal traps run immediately. Timeout
# owns a process group: its TERM reaches descendants, but its KILL after 10s
# reaches only its direct child (uutils timeout 0.10, tested 2026-10-21).
trace_window() {
    local name=$1 start end rc=0
    shift
    echo 0 > "$T/tracing_on"
    echo > "$T/trace"
    echo 1 > "$T/events/block/block_rq_issue/enable"
    start=$(awk '{print $1}' /proc/uptime)
    echo 1 > "$T/tracing_on"
    "$@" > "$OUT/$name.log" 2>&1 &
    child=$!
    wait "$child" || rc=$?
    child=
    echo 0 > "$T/tracing_on"
    end=$(awk '{print $1}' /proc/uptime)
    DURATION=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b-a }')
    printf '%s\n' "$DURATION" > "$OUT/$name.seconds"
    echo 0 > "$T/events/block/block_rq_issue/enable"
    cat "$T/trace" > "$OUT/$name.trace"
    cat "$T"/per_cpu/cpu*/stats > "$OUT/$name.trace-stats"
    awk '/overrun:|dropped events:/ { if ($NF + 0 != 0) bad=1 } END { exit bad }' \
        "$OUT/$name.trace-stats" || die "$name trace overflowed; counts are incomplete"
    WINDOW_RC=$rc
}
for backend in file direct; do
    trace_window "block-$backend" timeout --signal=TERM --kill-after=10s 6m \
        setpriv --reuid="$UID_RUN" --regid="$GID_RUN" --init-groups -- env HOME="$UHOME" \
        "$BENCH" "$BLOCK_DIR" "$backend" 2000 8 200 4096 512
    rc=$WINDOW_RC
    [ "$rc" = 0 ] && grep -qx OK "$OUT/block-$backend.log" || die "pwbench $backend failed (exit $rc); see log"
    if [ "$backend" = file ]; then
        grep -qx 'boundary fdatasync' "$OUT/block-file.log" || die "file benchmark did not report boundary fdatasync"
    else
        # Direct always uses pwrite + fdatasync; it prints no boundary line.
        grep -qx 'backend direct (pwrite + O_DIRECT + fdatasync) on a file' "$OUT/block-direct.log" || die "direct benchmark backend differs"
    fi
    awk '/^persist boundaries [0-9]+, prepare calls [0-9]+$/ {
        n++; count=$3+0
    } END { if (n != 1 || count <= 0) exit 1; print count }' \
        "$OUT/block-$backend.log" > "$OUT/block-$backend.boundaries" || die "missing measured persistence boundary count"
    # Same requested idle length as the full benchmark trace, recorded with
    # monotonic /proc/uptime (0.01s resolution); record actual idle length too.
    # Drain the benchmark's own close/unlink journal commit and deferred
    # writeback outside the trace (commit=5), so the window holds idle IO only.
    sync -f "$BLOCK_DIR"
    sleep 10
    say "idle-$backend: synced $BLOCK_DIR and waited 10 s before tracing" >> "$OUT/provenance.txt"
    trace_window "idle-$backend" sleep "$DURATION"
    [ "$WINDOW_RC" = 0 ] || die "idle trace sleep failed"
done
{
    rule 'nvme1n1 requests: complete pwbench processes and equal-length idle windows'
    say 'Linux rwbs: leading F = PREFLUSH or standalone FLUSH; F after the operation = FUA.'
    say 'F-any is the union, not the sum; a request may carry both flags.'
    say 'Traces include setup/close, warm-up, root journal commits (commit=5), desktop IO and /boot/efi IO.'
    say 'Counts are grouped by comm for context, never filtered: jbd2/kworker can issue benchmark IO.'
    say 'Ratios use the measured persist boundaries count reported by pwbench (one fdatasync each).'
    say 'That denominator excludes setup/close and warm-up, which remain in the whole-process numerator.'
    for backend in file direct; do
        boundaries=$(cat "$OUT/block-$backend.boundaries")
        say "$backend: measured fdatasync boundaries $boundaries"
        for window in block idle; do
            name=$window-$backend
            say "  $window duration $(cat "$OUT/$name.seconds") seconds (monotonic, 0.01s resolution)"
            awk -v dev="$MAJOR,$MINOR" -v denom="$boundaries" '
                /block_rq_issue:/ {
                    for (i=1; i<NF; i++) if ($i == "block_rq_issue:" && $(i+1) == dev) {
                        comm=$1; sub(/-[0-9]+$/, "", comm)
                        c="other"
                        if (comm ~ /^pwbench/) c="pwbench"
                        else if (comm ~ /^jbd2/) c="jbd2"
                        else if (comm ~ /^kworker/) c="kworker"
                        rwbs=$(i+2); flags[rwbs]++
                        isflush=(rwbs ~ /^F/); tail=rwbs; sub(/^F/, "", tail)
                        isfua=(tail ~ /F/ && tail ~ /[WDRZN]/)
                        for (j=0; j<2; j++) {
                            k=(j == 0 ? "all" : c); n[k]++
                            if (rwbs ~ /F/) any[k]++
                            if (isflush) flush[k]++
                            if (isfua) fua[k]++
                        }
                        break
                    }
                }
                END {
                    split("all pwbench jbd2 kworker other", classes, " ")
                    for (j=1; j<=5; j++) {
                        k=classes[j]
                        printf "    %-7s total %d, flush/PREFLUSH %d, FUA %d, F-any %d\n", k,n[k],flush[k],fua[k],any[k]
                        printf "      per measured fdatasync: requests %.6f, flush %.6f, FUA %.6f, F-any %.6f\n", n[k]/denom,flush[k]/denom,fua[k]/denom,any[k]/denom
                    }
                    for (f in flags) printf "    rwbs %-8s %d\n", f, flags[f]
                }' "$OUT/$name.trace"
        done
    done
    say 'Compare idle traffic and durations with benchmark traffic; background activity is variable, not a subtractable constant.'
    say 'Aggregate counts cannot prove one flush/FUA per syscall. Inspect raw traces and logs together.'
    say 'This shows requests sent, not that the device makes them durable.'
} | tee "$OUT/summary.txt"
