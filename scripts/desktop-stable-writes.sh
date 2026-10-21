#!/usr/bin/env bash
#
# Price stable writes on ext4-over-loop, NO reset and no change to /'s queue.
#   sudo env PWROOT_USER=sean-tan scripts/desktop-stable-writes.sh
# Two private fully written 2 GiB /var/tmp images, direct-IO loop devices, fresh ext4
# mounts under /mnt. Set stable_writes BEFORE mkfs and mount, never afterwards.
# Four balanced pairs (ABBA twice), five rounds each, file-block, 256x4096, warm-up 8;
# CPU 2 (P-core), or PWROOT_CPU. Intended to finish well within 30 minutes;
# the benchmark campaign has a 24-minute total deadline, leaving cleanup time.
# One discarded warm-up campaign per mount precedes the measured pairs.
# pwsieve-bench.sh selects one block directory per campaign, so each invocation
# is one sample and this driver interleaves the mounts.
# Signals stop/wait for the campaign before cleanup; busy resources are retained
# with a diagnostic rather than detached or removed unsafely.

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
for path in "$REPO" /var/tmp /mnt; do
    [ "$(findmnt -nro TARGET -T "$path")" = / ] || die "$path must be on the root filesystem"
done
for cmd in setpriv losetup mkfs.ext4 mount umount dd timeout taskset mountpoint; do
    command -v "$cmd" >/dev/null || die "missing $cmd"
done
CPU=${PWROOT_CPU:-2}
[[ "$CPU" =~ ^[0-9]+$ ]] || die "PWROOT_CPU must be one CPU number"
as_user taskset -c "$CPU" true || die "CPU $CPU is not available"
# Build as yourself first: under sudo the PATH has no v3c, so this only checks.
as_user make -q bin/pwsievebench.x86-64-linux \
    || die "pwsievebench is out of date: run 'make bin/pwsievebench.x86-64-linux' as yourself, then rerun"
BINARY_SHA=$(sha256sum bin/pwsievebench.x86-64-linux | cut -d' ' -f1)
OUT=$REPO/results/$(date -u +%Y%m%dT%H%M%SZ)-sean-tan-PC-desktop-stable-writes
as_user mkdir -p "$REPO/results"
as_user mkdir "$OUT" || die "results directory already exists: $OUT"
say "results -> $OUT"
IMAGES=() LOOPS=() MOUNTS=()
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
    local rc=$? bit failed=0 safe attached dev
    trap - EXIT
    trap '' INT TERM HUP
    stop_child
    set +e
    # Do not detach or remove an image if unmount fails. Retain its paths in
    # cleanup.txt for manual recovery rather than damaging a mounted filesystem.
    for bit in 1 0; do
        safe=1
        if [ -n "${MOUNTS[$bit]:-}" ]; then
            if mountpoint -q "${MOUNTS[$bit]}"; then
                # The benchmark may still be exiting after a signal: retry.
                tries=0
                until umount "${MOUNTS[$bit]}"; do
                    tries=$((tries + 1))
                    if [ "$tries" -ge 5 ]; then failed=1; safe=0; break; fi
                    sleep 1
                done
            fi
            if [ "$safe" = 1 ]; then rmdir "${MOUNTS[$bit]}" || failed=1; fi
        fi
        if [ "$safe" = 1 ] && [ -n "${IMAGES[$bit]:-}" ]; then
            # Attachment can complete before an interrupted --show assignment
            # saves its output. Discover all loops by our exact private image.
            attached=$(losetup -j "${IMAGES[$bit]}") || { failed=1; safe=0; }
            while IFS= read -r dev; do
                [ -n "$dev" ] || continue
                dev=${dev%%:*}
                if [[ "$dev" =~ ^/dev/loop[0-9]+$ ]] && \
                   [ "$(losetup -nO BACK-FILE "$dev")" = "${IMAGES[$bit]}" ]; then
                    losetup -d "$dev" || { failed=1; safe=0; }
                else
                    say "ERROR: unexpected attachment for ${IMAGES[$bit]}: $dev" >&2
                    failed=1; safe=0
                fi
            done <<< "$attached"
        fi
        if [ "$safe" = 1 ] && [ -n "${IMAGES[$bit]:-}" ]; then
            rm -f -- "${IMAGES[$bit]}" || failed=1
        fi
        printf 'stable_writes=%s loop=%s image=%s mount=%s safe_to_remove=%s\n' \
            "$bit" "${LOOPS[$bit]:-none}" "${IMAGES[$bit]:-none}" "${MOUNTS[$bit]:-none}" "$safe" >> "$OUT/cleanup.txt"
    done
    if [ "$failed" != 0 ]; then
        say "ERROR: cleanup incomplete; see $OUT/cleanup.txt" >&2
        rc=1
    else say 'cleanup complete: mounts, loop devices and images removed' >> "$OUT/cleanup.txt"; fi
    chown -R "$UID_RUN:$GID_RUN" "$OUT" || rc=1
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
    say "CPU      $CPU"
    say 'campaign file-block, 4 balanced pairs (ABBA twice) x 5 rounds, 8 warm-up steps, 256x4096 (1 MiB)'
    say 'Each round measures the remaining descriptor steps (159 at this geometry), with reference-sieve validation.'
    say 'One discarded five-round warm-up campaign per mount; no warm-up rows enter runs.csv.'
    say 'binary make -q: up-to-date (exit 0 after incremental make), before hashing'
    say 'Benchmark deadline 24 minutes total; intended total under 30 minutes.'
    say 'PWSB_ALLOW_DIRTY=1: scripts may be uncommitted; provenance includes the diff.'
    say 'This prices stable writes on ext4-over-loop using direct IO, not on the NVMe directly.'
    say 'No NVMe queue, CPU governor or existing filesystem setting is changed.'
    findmnt -T /
    findmnt -T /var/tmp
    for f in scaling_governor scaling_driver; do
        path=/sys/devices/system/cpu/cpu$CPU/cpufreq/$f
        [ ! -r "$path" ] || say "cpu$CPU $f $(cat "$path")"
    done
    as_user git status --short
    sha256sum bin/pwsievebench.x86-64-linux scripts/pwsieve-bench.sh scripts/desktop-stable-writes.sh
} > "$OUT/provenance.txt"
as_user cp -- "$REPO/scripts/desktop-stable-writes.sh" "$OUT/"
as_user git diff HEAD -- scripts docs > "$OUT/working-tree.diff"

for bit in 0 1; do
    IMAGES[$bit]=$(mktemp "/var/tmp/pwstable-$bit-XXXXXXXX.img")
    # No sparse holes or unwritten extents in the backing file.
    dd if=/dev/zero of="${IMAGES[$bit]}" bs=16M count=128 conv=fsync status=none
    LOOPS[$bit]=$(losetup --find --show --direct-io=on "${IMAGES[$bit]}")
    dev=${LOOPS[$bit]}
    [[ "$dev" =~ ^/dev/loop[0-9]+$ ]] || die "unexpected loop device $dev"
    queue=/sys/block/${dev##*/}/queue
    [ "$(losetup --noheadings --list --output DIO "$dev" | tr -d ' ')" = 1 ] || die "loop direct IO was not enabled"
    {
        rule "before setting stable_writes=$bit (before mkfs/mount)"
        for f in "$queue"/*; do [ ! -f "$f" ] || { printf '%s ' "${f##*/}"; cat "$f"; }; done
    } > "$OUT/queue-$bit-before.txt" 2>&1
    { echo "$bit" > "$queue/stable_writes"; } || die "cannot set $queue/stable_writes on this kernel"
    [ "$(cat "$queue/stable_writes")" = "$bit" ] || die "stable_writes=$bit did not take effect"
    [ "$(losetup -nO BACK-FILE "$dev")" = "${IMAGES[$bit]}" ] || die "loop backing file is not our private image: $dev"
    mkfs.ext4 -q -F -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$dev" > "$OUT/mkfs-$bit.log" 2>&1
    MOUNTS[$bit]=$(mktemp -d "/mnt/pwstable-$bit-XXXXXXXX")
    mount -t ext4 -o rw,relatime "$dev" "${MOUNTS[$bit]}"
    chown "$UID_RUN:$GID_RUN" "${MOUNTS[$bit]}"
    {
        rule "stable_writes=$bit, after mount (setting was made before mkfs/mount)"
        say "image ${IMAGES[$bit]}"
        losetup --list --output NAME,BACK-FILE,DIO "$dev"
        findmnt -T "${MOUNTS[$bit]}"
        for f in "$queue"/*; do [ ! -f "$f" ] || { printf '%s ' "${f##*/}"; cat "$f"; }; done
    } > "$OUT/queue-$bit-mounted.txt" 2>&1
    [ "$(cat "$queue/stable_writes")" = "$bit" ] || die "stable_writes changed during formatting/mount"
done

# Keep full snapshots as well as selected deltas, so counters exposed by this
# kernel can be inspected without guessing a stable-page counter name.
{
    for f in /proc/sys/vm/dirty_*; do say "${f##*/} $(cat "$f")"; done
} > "$OUT/vm-dirty-settings.txt"
awk '$1 != "nr_unstable" && $1 ~ /stable|wait/ && $1 ~ /page|writeback/ { print; found=1 }
    END { if (!found) print "No named stable-page/writeback-wait counter exposed in /proc/vmstat." }' \
    /proc/vmstat > "$OUT/writeback-counter-availability.txt"
vm_snapshot() {
    cat /proc/vmstat > "$OUT/vmstat-$1.$2"
    for f in /proc/sys/vm/dirty_*; do say "${f##*/} $(cat "$f")"; done > "$OUT/dirty-$1.$2"
}
DEADLINE=$((SECONDS + 24 * 60))
run_campaign() {
    local label=$1 bit=$2 sample=$OUT/$1 remaining rc=0
    remaining=$((DEADLINE - SECONDS))
    [ "$remaining" -gt 0 ] || die "24-minute benchmark deadline reached"
    as_user make -q bin/pwsievebench.x86-64-linux || die "benchmark sources changed during experiment"
    say "$(date -uIseconds) stable_writes=$bit campaign=$label" >> "$OUT/order.txt"
    vm_snapshot "$label" before
    # Run timeout itself in the background (not a shell function around it),
    # so TERM reaches its whole process group, including campaign descendants.
    timeout --signal=TERM --kill-after=10s "${remaining}s" \
        setpriv --reuid="$UID_RUN" --regid="$GID_RUN" --init-groups -- \
        env HOME="$UHOME" PWSB_BLOCK_DIR="${MOUNTS[$bit]}" PWSB_CONFIGS=file-block \
            PWSB_REPS=1 PWSB_ROUNDS=5 PWSB_WARMUP=8 PWSB_GEOMETRY=256x4096 \
            PWSB_CPUS="$CPU" PWSB_NUMA_NODE=none PWSB_CLOCK=0 PWSB_ALLOW_DIRTY=1 PWSB_OUT="$sample" \
            "$REPO/scripts/pwsieve-bench.sh" campaign > "$OUT/campaign-$label.log" 2>&1 &
    child=$!
    wait "$child" || rc=$?
    child=
    vm_snapshot "$label" after
    awk 'NR == FNR { before[$1]=$2; next }
        $1 ~ /^(nr_dirtied|nr_written|nr_dirty|nr_writeback|nr_writeback_temp|nr_throttled_written)$/ ||
        ($1 != "nr_unstable" && $1 ~ /stable|wait/ && $1 ~ /page|writeback/) {
            printf "%s before %.0f after %.0f delta %+.0f\n", $1,before[$1],$2,$2-before[$1]
        }' "$OUT/vmstat-$label.before" "$OUT/vmstat-$label.after" > "$OUT/vmstat-$label.delta"
    [ "$rc" = 0 ] || die "campaign failed/timed out (exit $rc); see $OUT/campaign-$label.log"
    as_user make -q bin/pwsievebench.x86-64-linux || die "benchmark is no longer up to date"
    [ "$(sha256sum bin/pwsievebench.x86-64-linux | cut -d' ' -f1)" = "$BINARY_SHA" ] || die "campaign rebuilt/changed the benchmark binary"
    [ "$(cat "/sys/block/${LOOPS[$bit]##*/}/queue/stable_writes")" = "$bit" ] || die "stable_writes changed during campaign"
}
for bit in 1 0; do
    say "discarded warm-up campaign, stable_writes=$bit"
    run_campaign "warmup-$bit" "$bit"
done
for rep in 1 2 3 4; do
    # 1 0 | 0 1 | 1 0 | 0 1: ABBA twice, each mount first twice.
    ORDER='1 0'; [ "$((rep % 2))" != 0 ] || ORDER='0 1'
    for bit in $ORDER; do
        sample=$OUT/stable-$bit-r$rep
        say "stable_writes=$bit pair=$rep -> $sample"
        run_campaign "stable-$bit-r$rep" "$bit"
        if [ ! -f "$OUT/runs.csv" ]; then
            printf 'stable_writes,pair,%s\n' "$(head -1 "$sample/runs.csv")" > "$OUT/runs.csv"
        fi
        awk -v b="$bit" -v r="$rep" 'NR > 1 { print b "," r "," $0 }' "$sample/runs.csv" >> "$OUT/runs.csv"
    done
done
{
    rule 'mapped-file sieve: stable_writes=1 against 0 (ext4-over-loop)'
    awk -F, '
        NR == 1 { next }
        { b=$1; wall[b]=wall[b] " " $7; samples[b]++
          persist[b]=persist[b] " " ($12+$13+$14+$15)
          pair[$2,b]=$7 }
        function med(s, a,n,i,j,t) {
            n=split(s,a," "); for(i=1;i<=n;i++) for(j=i+1;j<=n;j++)
                if(a[j]+0<a[i]+0) {t=a[i];a[i]=a[j];a[j]=t}
            if (n % 2) return a[(n+1)/2]
            return (a[n/2]+a[n/2+1])/2
        }
        END {
            for(b=0;b<=1;b++) {
                m[b]=med(wall[b]); p=med(persist[b])
                printf "stable_writes=%d: %d samples, median wall %.0f ns/step, persistence %.0f ns/step\n", b,samples[b],m[b],p
            }
            if(m[0]>0) printf "stable writes wall cost: %+.0f ns/step (%+.2f%%)\n",m[1]-m[0],100*(m[1]/m[0]-1)
            for(r=1;r<=4;r++) printf "pair %d wall ns/step: stable=0 %.0f, stable=1 %.0f, delta %+.0f\n", r,pair[r,0],pair[r,1],pair[r,1]-pair[r,0]
        }' "$OUT/runs.csv"
    say 'Discarded one warm-up campaign per mount; measured order is ABBA twice (four pairs).'
    say 'Each sample: existing file-block campaign, five rounds, warm-up 8, 256x4096, reference sieve checked.'
    say "Pinned CPU $CPU; governor unchanged. Order and individual campaign summaries/logs are retained."
    say 'Persistence is alloc + bitmap + publish + retire, as in the sieve campaign.'
    say 'This prices stable writes on ext4-over-loop, not on the NVMe directly; it is not a crash/durability test.'
    say 'A null result must be read with vmstat-*.delta, dirty-* and vm-dirty-settings.txt.'
    say 'Counters are system-wide; nr_dirty/nr_writeback are gauges, nr_dirtied/nr_written cumulative page counters.'
    say 'Stable-page waits require a store during writeback; fdatasync serializes this single-threaded workload.'
    say 'Little background writeback can mean no stable-page waits were exercised; near-zero cost does not establish they are free.'
    cat "$OUT/writeback-counter-availability.txt"
    say "finished $(date -uIseconds)"
} | tee "$OUT/summary.txt"
