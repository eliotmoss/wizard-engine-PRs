#!/usr/bin/env bash
#
# Failed-boundary check on pc-ubuntu: after a commit whose log write fails
# with EIO, does the same-boot abandon, reopen and recover replay a record
# that the page cache holds and the disk does not? (Rebello et al., ATC '20;
# docs/persistent-backends.md, "Persistence-failure contract".)
#   scripts/desktop-fsyncfail-check.sh check
#   sudo env PWROOT_USER=sean-tan scripts/desktop-fsyncfail-check.sh run --yes-inject-io-errors
# check needs no root: it checks prerequisites, builds pwreboot, runs the
# driver's three steps once per backend with no fault injected, and prints the
# plan and the predictions. run builds nothing and uses no existing device:
# for each file system (ext4; XFS only if mkfs.xfs exists) and backend (file,
# then direct as the control) it makes a sparse image under the owner's home
# on /, attaches it to a new loop device, puts a new device-mapper device over
# that, makes a fresh file system on it and mounts it under the owner's home.
# pwreboot always runs as the owner. Everything is torn down on exit, failure
# or interrupt. The images are deleted; each 2 MiB region file is copied into
# the results first.
#
# The fault. While fault-commit waits, the dm table is swapped for one that
# maps exactly the log chunk's sectors to the `error` target and the rest
# linearly; the commit runs; the all-linear table goes back before anything
# reads those sectors again, so the device fails one write, as in Rebello's
# transient faults. Not dm-flakey: with error_writes it fails every write bio
# while down, and the empty flush that dm sends to each target with
# num_flush_bios > 0 is a write bio (v7.0 dm-flakey.c flakey_ctr sets
# num_flush_bios = 1; flakey_map; dm.c __send_empty_flush; only linear and
# stripe set flush_bypasses_map). Every flush on the device would then fail,
# and the next journal commit with it: Rebello's journal-failure case
# (Table 1, Q8-Q9), not the case under test. `error` sets no num_flush_bios
# (dm-target.c io_err_ctr), so flushes skip it; it also fails reads, which is
# why the table is restored before the reopen, and what lets the script check
# the armed table without writing: a read of the log block must fail and the
# blocks either side must not.

set -euo pipefail
umask 077

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }
usage() { say "usage: $0 check | run --yes-inject-io-errors"; }
REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
BIN=$REPO/bin/pwreboot.x86-64-linux
SELF=$REPO/scripts/desktop-fsyncfail-check.sh
[ "$#" -gt 0 ] || { usage; exit 2; }
CMD=$1
shift
# Check the opt-in before doing any other work.
case "$CMD" in
    run)
        [ "$#" = 1 ] && [ "$1" = --yes-inject-io-errors ] || die "run refused: requires --yes-inject-io-errors"
        [ "$(id -u)" = 0 ] || die "run needs root via sudo (and --yes-inject-io-errors)"
        ;;
    check) [ "$#" = 0 ] || { usage; exit 2; } ;;
    help|-h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac
if [ "$CMD" = run ]; then U=${PWROOT_USER:-${SUDO_USER:-}}; else
    [ "$(id -u)" != 0 ] || die "check must run as the ordinary checkout owner, without sudo"
    U=$(id -un)
fi
[ -n "$U" ] && [ "$U" != root ] || die "set PWROOT_USER to the checkout's owner"
UID_RUN=$(id -u "$U"); GID_RUN=$(id -g "$U")
UHOME=$(realpath -e -- "$(getent passwd "$U" | cut -d: -f6)")
[ "$(stat -c %U "$REPO")" = "$U" ] || die "$REPO is not owned by $U"
if [ "$(id -u)" = 0 ]; then
    as_user() { setpriv --reuid="$UID_RUN" --regid="$GID_RUN" --init-groups -- env HOME="$UHOME" "$@"; }
else
    as_user() { "$@"; }
fi
# The owner opens the output file, so it is the owner's.
as_user_log() { local log=$1; shift; as_user sh -c 'log=$1; shift; exec "$@" > "$log" 2>&1' sh "$log" "$@"; }
[ "$(hostname -s)" = pc-ubuntu ] || die "this procedure is for pc-ubuntu (results tag sean-tan-PC)"
[ "$(findmnt -nro SOURCE,FSTYPE -T /)" = '/dev/nvme1n1p3 ext4' ] || die "/ must be ext4 on /dev/nvme1n1p3"
[ "$(findmnt -nro TARGET -T "$REPO")" = / ] || die "checkout/results must be on /, never /tmp"
PARENT=$UHOME/pwfsyncfail

BLOCKS=512
BLOCK_SIZE=4096
STEPS=2
IMAGE_SIZE=1G           # sparse; >= 512 MiB so mke2fs uses its default profile, >= 300 MiB for XFS
DRIVER_TIMEOUT=120      # pwreboot's limit on each wait for a go file, seconds
TOOLS="losetup dmsetup mkfs.ext4 blkid filefrag setpriv findmnt lsblk blockdev mountpoint dd od cmp paste sha256sum mount umount ps"
if command -v mkfs.xfs > /dev/null; then
    FILESYSTEMS="ext4 xfs"; XFS_NOTE="xfs included: $(mkfs.xfs -V 2>&1 | sed -n 1p)"
else
    FILESYSTEMS=ext4; XFS_NOTE='xfs skipped: mkfs.xfs not installed'
fi

# State files are data, never shell-sourced.
value() {
    local key=$1 file=$2
    awk -v k="$key" '$1 == k { n++; sub(/^[^ ]+ /, ""); v=$0 }
        END { if (n != 1 || v == "") exit 1; print v }' "$file" || die "missing/duplicate $key in $file"
}
number() { local n; n=$(value "$1" "$2") || return 2; [[ "$n" =~ ^[0-9]+$ ]] || die "invalid number $1"; say "$n"; }
# For the summary: the last value of a key, or ?.
get() { [ -f "$2" ] || { say '?'; return 0; }; awk -v k="$1" '$1 == k { v=$2 } END { print (v == "" ? "?" : v) }' "$2"; }

# ---- the driver, as the owner, in the background

CUR_PID=
start_driver() { # log, command...
    local log=$1; shift
    as_user touch "$log"
    if [ "$(id -u)" = 0 ]; then
        setpriv --reuid="$UID_RUN" --regid="$GID_RUN" --init-groups -- env HOME="$UHOME" \
            sh -c 'log=$1; shift; exec "$@" > "$log" 2>&1' sh "$log" "$@" &
    else
        sh -c 'log=$1; shift; exec "$@" > "$log" 2>&1' sh "$log" "$@" &
    fi
    CUR_PID=$!
}
alive() {
    local s
    [ -n "$CUR_PID" ] || return 1
    s=$(ps -o stat= -p "$CUR_PID" 2> /dev/null) || return 1
    case "$s" in Z*|'') return 1 ;; esac
}
wait_line() { # log, line, seconds
    local i=0
    while ! grep -qx "$2" "$1"; do
        alive || { grep -qx "$2" "$1"; return; }
        i=$((i + 1)); [ "$i" -le $(($3 * 10)) ] || return 1
        sleep 0.1
    done
}
finish_driver() { # seconds; sets DRIVER_RC
    local i=0
    while alive; do
        i=$((i + 1)); if [ "$i" -gt $(($1 * 10)) ]; then kill "$CUR_PID" 2> /dev/null || true; break; fi
        sleep 0.1
    done
    DRIVER_RC=0; wait "$CUR_PID" || DRIVER_RC=$?
    CUR_PID=
}

predictions() {
    cat <<'EOF'
PREDICTIONS (not results). One transaction (one redo entry: a nonce in the
marker word) is committed after a clean close, so it is sequence 1 and lands
in slot 1 of the log chunk; the error target fails the write of that chunk.
"Visible" means the marker holds the nonce.

file on ext4 (data=ordered):
  commit 0, latched: fdatasync returns EIO for the log page's write.
  same-boot reopen: REPLAYED, visible. ext4 marks the failed page clean but
    keeps its new bytes (Rebello Table 1, Q4-Q5), and the reopened MAP_SHARED
    mapping reads that page.
  log chunk, buffered vs O_DIRECT: differ; the nonce is in the buffered copy
    only, after the commit and again after the reopen (recovery never stores
    to a record, so its page stays clean and is never rewritten).
  after the restore and the cache drop (umount + mount): CLEAN, and still
    visible. The same-boot replay persisted the after-image through a page
    outside the failed range, so the disk holds the transaction's data
    without its record, the reverse of write-ahead order.
  Together: the same-boot recovery replayed a record the disk lacks, which
  confirms the thesis's inference for the file backend on ext4.

direct on ext4 (control):
  commit 0, latched: the O_DIRECT pwrite of the log unit returns EIO.
  same-boot reopen: CLEAN, not visible: create() reads the region through
    O_DIRECT, from the device.
  log chunk, buffered vs O_DIRECT: equal; the nonce is in neither.
  after the drop: CLEAN, not visible.

What other outcomes would mean:
  file, same-boot CLEAN: refutes the inference on this kernel; the page kept
    neither the new bytes nor its place in the cache (as Btrfs reverts it,
    Table 1, Q5), or the reopen read the device.
  file, commit 1 (or direct, commit 1): no failure reached the boundary;
    check dm-tables.txt and dmesg.txt. The case says nothing.
  file, after the drop REPLAYED: the record reached the disk after all, so
    something retried the failed write (contradicts Q4 and section 3.3.1).
  file, after the drop not visible: the replay's own data write did not
    reach the disk either; read dmesg.txt.
  file system read-only, shut down, or a failed mount or remount: Rebello's
    journal-failure case (Table 1, Q8-Q9), not the case under test; the error
    range was meant to hold file data only.
  driver killed by SIGBUS: the clean page was evicted while its blocks still
    failed reads; the run says nothing about the reopen.
  direct, same-boot REPLAYED or visible: the control read a cached copy and
    fails as a control.
  verify INCONSISTENT on any case: a structural failure beyond the contract.
EOF
}

# ---- check (no root)

if [ "$CMD" = check ]; then
    for t in $TOOLS; do command -v "$t" > /dev/null || die "missing tool: $t"; done
    say "tools: ok ($TOOLS)"
    say "$XFS_NOTE"
    [ -e /sys/module/dm_mod ] || die "device-mapper is not available (no /sys/module/dm_mod)"
    [ -e /sys/module/loop ] || say "note: the loop module is not loaded; losetup will load it"
    avail=$(df --output=avail -k "$UHOME" | tail -n1 | tr -d ' ')
    [ "$avail" -gt $((4 * 1024 * 1024)) ] || die "less than 4 GiB free under $UHOME"
    say "free under $UHOME: $((avail / 1024 / 1024)) GiB"
    make bin/pwreboot.x86-64-linux || die "could not build pwreboot"
    make -q bin/pwreboot.x86-64-linux || die "pwreboot is not up to date after make"
    say "pwreboot: built, sha256 $(sha256sum "$BIN" | cut -d' ' -f1)"
    mkdir -p "$PARENT"
    [ "$(findmnt -nro TARGET -T "$PARENT")" = / ] || die "$PARENT must be on /"
    P=$(mktemp -d "$PARENT/check-XXXXXX")
    say "---- plumbing, no fault injected, in $P"
    for be in file direct; do
        d=$P/$be
        mkdir -p "$d/region" "$d/signal"
        "$BIN" fault-prepare "$d/region" "$d/prepare.state" "$be" "$BLOCKS" "$BLOCK_SIZE" "$STEPS" > "$d/prepare.log" 2>&1 \
            || die "fault-prepare $be failed; see $d/prepare.log"
        R=$(value region "$d/prepare.state")
        start_driver "$d/commit.log" "$BIN" fault-commit "$R" "$be" "$BLOCKS" "$BLOCK_SIZE" "$d/signal" 30
        wait_line "$d/commit.log" READY 30 || die "no READY; see $d/commit.log"
        touch "$d/signal/go-commit"
        wait_line "$d/commit.log" ATTEMPTED 30 || die "no ATTEMPTED; see $d/commit.log"
        touch "$d/signal/go-reopen"
        finish_driver 30
        [ "$DRIVER_RC" = 0 ] && grep -qx DONE "$d/commit.log" || die "fault-commit $be failed; see $d/commit.log"
        rc=0
        "$BIN" fault-verify "$R" "$be" "$BLOCKS" "$BLOCK_SIZE" "$(value nonce "$d/commit.log")" \
            "$(value setup_cursor "$d/prepare.state")" "$(value setup_count "$d/prepare.state")" > "$d/verify.log" 2>&1 || rc=$?
        got="commit $(get commit_ok "$d/commit.log") latched $(get latched "$d/commit.log") reopen $(get reopen_recovery "$d/commit.log") visible $(get reopen_visible "$d/commit.log") | verify $(get recovery "$d/verify.log") visible $(get visible "$d/verify.log") $(get verdict "$d/verify.log")"
        say "$be: $got"
        [ "$rc" = 0 ] && [ "$got" = "commit 1 latched 0 reopen REPLAYED visible 1 | verify REPLAYED visible 1 CONSISTENT" ] \
            || die "plumbing for $be did not give the no-fault result; see $d"
    done
    rm -rf -- "$P"
    say "plumbing: ok (a successful commit replays on reopen and verifies; directory removed)"
    cat <<EOF
---- plan for: sudo env PWROOT_USER=$U $SELF run --yes-inject-io-errors
For each file system ($FILESYSTEMS) and backend (file, then direct):
  1  a sparse $IMAGE_SIZE image under $PARENT/<run>/, attached with
     losetup --find --show --direct-io=on; a new dm device pwfsf-<run>-<fs>-<backend>
     with one linear target over it; refuses anything resolving to nvme0n1
  2  mkfs.ext4 -b 4096 -E lazy_itable_init=0,lazy_journal_init=0 (otherwise
     defaults, so data=ordered); mounted with default options under <run>/
  3  as $U: pwreboot fault-prepare ($BLOCKS x $BLOCK_SIZE region, $STEPS sieve steps,
     clean close, log chunk rewritten and fdatasynced)
  4  filefrag -v -b512 -s: the log chunk must lie in one extent with no flag
     but last/eof/merged; its O_DIRECT copies through the file and through
     the dm device must match and start with the WAL header magic
  5  as $U: pwreboot fault-commit mounts and prints READY
  6  table: linear | log sectors -> error | linear, read back and compared;
     an O_DIRECT read of the log block must fail, the blocks either side not
  7  go-commit: one commit; the all-linear table is restored; the log chunk
     is read buffered and O_DIRECT (checksums, nonce)
  8  go-reopen: abandon, reopen, recover in the same process; log chunk read
     again; file-system state and the run's dmesg lines recorded
  9  umount + mount (drops the file's pages); log chunk read again; region
     copied; as $U: pwreboot fault-verify
  10 umount, dmsetup remove, losetup -d, image deleted
Never touched: nvme0n1 and its partitions, existing dm or loop devices, idle
states, other mounts; no reboot. Results: $REPO/results/<UTC>-sean-tan-PC-fsyncfail-*/
$XFS_NOTE
EOF
    predictions
    exit 0
fi

# ---- run (root)

as_user make -q bin/pwreboot.x86-64-linux || die "pwreboot is missing or stale: run '$SELF check' as $U first"
[ -x "$BIN" ] || die "pwreboot is missing"
for t in $TOOLS; do command -v "$t" > /dev/null || die "missing tool: $t"; done
dmsetup targets | awk '{print $1}' | grep -qx error || die "the dm error target is unavailable"
dmsetup targets | awk '{print $1}' | grep -qx linear || die "the dm linear target is unavailable"
dmesg > /dev/null || die "dmesg is not readable"

guard_dev() {
    local real
    real=$(readlink -f -- "$1") || die "cannot resolve $1"
    case "${real##*/}" in nvme0n1*) die "refusing $1: it resolves to $real (the Windows disk)" ;; esac
    if lsblk -rnso KNAME "$real" 2> /dev/null | grep -q '^nvme0n1'; then die "refusing $1: it depends on nvme0n1"; fi
}

as_user mkdir -p "$REPO/results" "$PARENT"
[ "$(findmnt -nro TARGET -T "$PARENT")" = / ] || die "$PARENT must be on /"
OUT=$(as_user mktemp -d "$REPO/results/$(date -u +%Y%m%dT%H%M%SZ)-sean-tan-PC-fsyncfail-XXXXXX")
RUNID=${OUT##*-}
RUNDIR=$(realpath -e -- "$(as_user mktemp -d "$PARENT/$(basename "$OUT")-XXXXXX")")
case "$RUNDIR" in "$UHOME"/*) ;; *) die "run directory must be under $UHOME" ;; esac
as_user cp -- "$SELF" "$OUT/"
predictions | as_user tee "$OUT/predictions.txt" > /dev/null
{
    say "recorded $(date -uIseconds)"
    say "host $(hostname -s)"
    say "kernel $(uname -srvmo)"
    say "boot_id $(cat /proc/sys/kernel/random/boot_id)"
    say "owner $U"
    say "commit $(as_user git -C "$REPO" rev-parse HEAD)"
    say "binary_sha256 $(sha256sum "$BIN" | cut -d' ' -f1)"
    say "script_sha256 $(sha256sum "$SELF" | cut -d' ' -f1)"
    say "run_dir $RUNDIR"
    say "geometry $BLOCKS x $BLOCK_SIZE; setup $STEPS sieve steps; image $IMAGE_SIZE sparse; loop --direct-io=on"
    say "fault dm error target over the log chunk's sectors, for one commit (see the script's header for why not dm-flakey)"
    say "cache_drop umount+mount (not drop_caches)"
    say "images deleted after each case; region-before-verify.img keeps each region"
    say "$XFS_NOTE"
    say '---- git status --short'
    as_user git -C "$REPO" status --short
    say '---- tools'
    losetup --version; dmsetup --version; mke2fs -V 2>&1 | sed -n 1p; filefrag -V 2>&1 | sed -n 1p
    say '---- dm targets'; dmsetup targets
    say '---- / mount'; findmnt -no SOURCE,FSTYPE,OPTIONS -T /; cat /proc/fs/ext4/nvme1n1p3/options
    say '---- dm devices before the run'; dmsetup ls
    say '---- loop devices before the run'; losetup -l
    say '---- vm.dirty_*'; for f in /proc/sys/vm/dirty_*; do say "${f##*/} $(cat "$f")"; done
} 2>&1 | as_user tee "$OUT/provenance.txt" > /dev/null

# ---- teardown, also on any exit

CUR_DM= CUR_DEV= CUR_LINEAR= CUR_LOOP= CUR_IMG= CUR_MNT=
teardown_case() {
    local left= t
    local live=0
    if [ -n "$CUR_DM" ] && dmsetup info "$CUR_DM" > /dev/null 2>&1; then
        live=1
        # Suspended (file system frozen), armed or loaded: the all-linear
        # table goes back first, so nothing below waits on a frozen file
        # system or writes to the error target.
        printf '%s\n' "$CUR_LINEAR" | dmsetup load "$CUR_DM"
        dmsetup resume "$CUR_DM"
    fi
    if [ -n "$CUR_PID" ]; then kill "$CUR_PID" 2> /dev/null; wait "$CUR_PID" 2> /dev/null; CUR_PID=; fi
    if [ "$live" = 1 ]; then
        for t in $(findmnt -rno TARGET -S "$CUR_DEV" 2> /dev/null); do umount "$t" || left="$left mount:$t"; done
        dmsetup remove --retry "$CUR_DM" || left="$left dm:$CUR_DM"
    fi
    CUR_DM=
    if [ -n "$CUR_LOOP" ]; then
        if [ "$(losetup -nO BACK-FILE "$CUR_LOOP" 2> /dev/null | sed 's/ *$//')" = "$CUR_IMG" ]; then
            losetup -d "$CUR_LOOP" || left="$left loop:$CUR_LOOP"
        else
            left="$left loop:$CUR_LOOP(backing file changed; not detached)"
        fi
    fi
    CUR_LOOP=
    if [ -n "$CUR_IMG" ]; then
        if [ -z "$(losetup -j "$CUR_IMG" 2> /dev/null)" ]; then as_user rm -f -- "$CUR_IMG"; else left="$left image:$CUR_IMG"; fi
    fi
    CUR_IMG=
    if [ -n "$CUR_MNT" ] && ! mountpoint -q "$CUR_MNT"; then as_user rmdir -- "$CUR_MNT" 2> /dev/null; fi
    CUR_MNT=
    [ -z "$left" ] || { printf 'WARNING: left behind:%s\n' "$left" >&2; return 1; }
}
cleanup() {
    local rc=$?
    trap - EXIT ERR
    set +e
    [ "$rc" = 0 ] || [ -z "${FAILED_AT:-}" ] || printf 'error: stopped at %s\n' "$FAILED_AT" >&2
    teardown_case || rc=3
    [ -n "${RUNDIR:-}" ] && as_user rmdir -- "$RUNDIR" 2> /dev/null
    [ "$rc" = 0 ] || printf 'run stopped (exit %s); its devices were torn down; partial results in %s\n' "$rc" "$OUT" >&2
    exit "$rc"
}
set -E
trap 'FAILED_AT="line $LINENO: $BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---- one case

check_table() { # expected, label
    local got
    got=$(dmsetup table "$NAME" | sed 's/ *$//')
    { say "---- $2"; say "$got"; } | as_user tee -a "$CD/dm-tables.txt" > /dev/null
    [ "$got" = "$1" ] || die "dm table differs from the one loaded ($2)"
}
swap_table() { # table, label
    printf '%s\n' "$1" | dmsetup load "$NAME" || die "dmsetup load failed ($2)"
    dmsetup suspend "$NAME" || die "dmsetup suspend failed ($2)"
    dmsetup resume "$NAME" || die "dmsetup resume failed ($2)"
    check_table "$1" "$2"
}
read_block() { dd if="$DEV" iflag=direct bs=4096 skip="$1" count=1 of=/dev/null status=none 2> /dev/null; }
nonce_in() { # bytes on stdin; 1 if the nonce's bytes occur at a byte boundary
    local hex pat
    hex=" $(od -An -v -tx1 -w1 | tr -d ' ' | paste -sd' ') "
    pat=" $(printf '%s' "$NONCE_HEX" | sed -E 's/(..)/\1 /g')"
    case "$hex" in *"$pat"*) say 1 ;; *) say 0 ;; esac
}
compare_log() { # tag: the log chunk through the page cache and through O_DIRECT
    local b=$CD/log-$1-buffered.bin d=$CD/log-$1-direct.bin sb sd rb=1 rd=1
    as_user dd if="$R" bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$b" status=none || rb=0
    as_user dd if="$R" iflag=direct bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$d" status=none || rd=0
    sb=$(sha256sum < "$b" | cut -d' ' -f1); sd=$(sha256sum < "$d" | cut -d' ' -f1)
    {
        say "buffered_read_ok $rb"
        say "direct_read_ok $rd"
        say "buffered_sha256 $sb"
        say "direct_sha256 $sd"
        say "equal $([ "$sb" = "$sd" ] && say 1 || say 0)"
        say "nonce_in_buffered $(nonce_in < "$b")"
        say "nonce_in_direct $(nonce_in < "$d")"
    } | as_user tee "$CD/compare-$1.txt" > /dev/null
}
fs_facts() { # label
    local dm
    dm=$(basename "$(readlink -f "$DEV")")
    say "---- $1"
    findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS -S "$DEV" || say 'not mounted'
    if [ "$FS" = ext4 ] && [ -r "/proc/fs/ext4/$dm/options" ]; then
        say "ext4_options $(tr '\n' ',' < "/proc/fs/ext4/$dm/options")"
        say "ext4_errors_count $(cat "/sys/fs/ext4/$dm/errors_count" 2> /dev/null || say '?')"
    fi
}

run_case() { # fs, backend
    FS=$1 BE=$2
    local c=$1-$2 IMG MNT SIG S N SIZE LOOP_MM SC SN FLAGS f rc
    CD=$OUT/$c
    IMG=$RUNDIR/$c.img
    MNT=$RUNDIR/$c.mnt
    NAME=pwfsf-$RUNID-$c
    DEV=/dev/mapper/$NAME
    say "==== $c"
    as_user mkdir "$CD" "$CD/signal" "$MNT"
    SIG=$CD/signal
    CUR_MNT=$MNT
    ! dmsetup info "$NAME" > /dev/null 2>&1 || die "dm device $NAME already exists"
    [ ! -e "$IMG" ] || die "$IMG already exists"
    as_user truncate -s "$IMAGE_SIZE" "$IMG"
    CUR_IMG=$(realpath -e -- "$IMG")
    [ "$(findmnt -nro SOURCE -T "$CUR_IMG")" = /dev/nvme1n1p3 ] || die "the image is not on /dev/nvme1n1p3"
    [ -z "$(losetup -j "$CUR_IMG")" ] || die "the image is already attached"
    CUR_LOOP=$(losetup --find --show --direct-io=on "$CUR_IMG") || die "losetup failed"
    case "$CUR_LOOP" in /dev/loop[0-9]*) ;; *) die "unexpected loop device $CUR_LOOP" ;; esac
    [ "$(losetup -nO BACK-FILE "$CUR_LOOP" | sed 's/ *$//')" = "$CUR_IMG" ] || die "$CUR_LOOP is not backed by the image"
    guard_dev "$CUR_LOOP"
    [ "$(lsblk -dnro TYPE "$CUR_LOOP")" = loop ] || die "$CUR_LOOP is not a loop device"
    LOOP_MM=$(lsblk -dnro MAJ:MIN "$CUR_LOOP")
    SIZE=$(blockdev --getsz "$CUR_LOOP")
    CUR_LINEAR="0 $SIZE linear $LOOP_MM 0"
    dmsetup create "$NAME" --table "$CUR_LINEAR" || die "dmsetup create failed"
    CUR_DM=$NAME CUR_DEV=$DEV
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -b "$DEV" ] && break; sleep 0.2; done
    [ -b "$DEV" ] || die "$DEV did not appear"
    guard_dev "$DEV"
    check_table "$CUR_LINEAR" "created: all linear"
    {
        losetup -l -O NAME,BACK-FILE,DIO,LOG-SEC "$CUR_LOOP"
        say "loop_dio $(cat "/sys/block/${CUR_LOOP##*/}/loop/dio" 2> /dev/null || say '?')"
        say "dm $NAME -> $(readlink -f "$DEV"), $SIZE sectors"
    } | as_user tee "$CD/devices.txt" > /dev/null

    if blkid -p "$DEV" > /dev/null 2>&1; then die "$DEV already carries a signature"; fi
    case "$FS" in
        ext4) mkfs.ext4 -q -b 4096 -E lazy_itable_init=0,lazy_journal_init=0 "$DEV" < /dev/null ;;
        xfs) mkfs.xfs -q "$DEV" < /dev/null ;;
    esac 2>&1 | as_user tee "$CD/mkfs.txt" > /dev/null
    mount -t "$FS" "$DEV" "$MNT"
    [ "$(findmnt -rno TARGET -S "$DEV" | wc -l)" = 1 ] || die "$DEV is mounted more than once (an automounter?)"
    fs_facts mounted | as_user tee "$CD/fs.txt" > /dev/null
    install -d -o "$UID_RUN" -g "$GID_RUN" -m 700 "$MNT/region"

    as_user_log "$CD/prepare.log" "$BIN" fault-prepare "$MNT/region" "$CD/prepare.state" "$BE" "$BLOCKS" "$BLOCK_SIZE" "$STEPS" \
        || die "fault-prepare failed; see $CD/prepare.log"
    grep -qx OK "$CD/prepare.log" || die "fault-prepare did not finish; see $CD/prepare.log"
    R=$(value region "$CD/prepare.state")
    [ -f "$R" ] && [ ! -L "$R" ] && [ "$(dirname -- "$R")" = "$MNT/region" ] || die "unexpected region path $R"
    [ "$(value backend "$CD/prepare.state")" = "$BE" ] || die "prepared backend differs"
    LOG_OFF=$(number log_offset "$CD/prepare.state"); LOG_BYTES=$(number log_bytes "$CD/prepare.state")
    SC=$(number setup_cursor "$CD/prepare.state"); SN=$(number setup_count "$CD/prepare.state")
    [ $((LOG_OFF % 4096)) = 0 ] && [ $((LOG_BYTES % 4096)) = 0 ] && [ "$LOG_BYTES" -gt 0 ] || die "log chunk is not 4 KiB aligned"
    as_user sync -f "$R"

    # The log chunk's device sectors. FIEMAP offsets are bytes on the file
    # system's device, which starts at sector 0 of the dm device.
    as_user filefrag -v -b512 -s "$R" | as_user tee "$CD/filefrag.txt" > /dev/null
    # Extent lines: "i: lstart.. lend: pstart.. pend: len: [expected] [flags]".
    read -r S FLAGS < <(sed -E 's/\.\./ /g; s/:/ /g' "$CD/filefrag.txt" | awk -v l0=$((LOG_OFF / 512)) -v n=$((LOG_BYTES / 512)) '
        $1 ~ /^[0-9]+$/ && NF >= 6 && $2 ~ /^[0-9]+$/ && $2 <= l0 && l0 + n - 1 <= $3 {
            s = $4 + (l0 - $2); flags = ($NF ~ /[a-z]/) ? $NF : "-"; found++
        }
        END { if (found == 1) print s, flags }') || die "the log chunk does not lie in one extent; see $CD/filefrag.txt"
    for f in ${FLAGS//,/ }; do
        case "$f" in -|last|eof|merged) ;; *) die "the log chunk's extent is flagged $f: not allocated and written" ;; esac
    done
    N=$((LOG_BYTES / 512))
    [ $((S % 8)) = 0 ] && [ "$S" -ge 8 ] && [ $((S + N)) -lt "$SIZE" ] || die "unexpected log sectors $S+$N of $SIZE"
    dd if="$DEV" iflag=direct bs=4096 skip=$((S / 8)) count=$((N / 8)) status=none | as_user tee "$CD/log-device-before.bin" > /dev/null
    as_user dd if="$R" iflag=direct bs=4096 skip=$((LOG_OFF / 4096)) count=$((N / 8)) of="$CD/log-file-before.bin" status=none
    cmp -s "$CD/log-device-before.bin" "$CD/log-file-before.bin" || die "the device's sectors $S+$N do not hold the file's log chunk"
    [ "$(head -c 8 "$CD/log-device-before.bin")" = DAEHLAWD ] || die "sectors $S+$N do not start with the WAL header magic"
    { say "log_offset $LOG_OFF"; say "log_bytes $LOG_BYTES"; say "log_sector $S"; say "log_sectors $N"; say "extent_flags $FLAGS"; } \
        | as_user tee "$CD/mapping.txt" > /dev/null

    start_driver "$CD/commit.log" "$BIN" fault-commit "$R" "$BE" "$BLOCKS" "$BLOCK_SIZE" "$SIG" "$DRIVER_TIMEOUT"
    wait_line "$CD/commit.log" READY 60 || die "fault-commit did not reach READY; see $CD/commit.log"
    NONCE=$(number nonce "$CD/commit.log")
    NONCE_HEX=$(value nonce_le_hex "$CD/commit.log")
    [[ "$NONCE_HEX" =~ ^[0-9a-f]{16}$ ]] || die "bad nonce_le_hex"
    DMESG0=$(dmesg --time-format iso | wc -l)

    # Arm, and check the armed table without writing to it.
    swap_table "$(printf '%s\n' "0 $S linear $LOOP_MM 0" "$S $N error" "$((S + N)) $((SIZE - S - N)) linear $LOOP_MM $((S + N))")" \
        "armed: log sectors $S+$N -> error"
    if read_block $((S / 8)); then die "a read of the log block succeeded: the error target is not in effect"; fi
    read_block $((S / 8 - 1)) || die "the block before the log chunk is unreadable"
    read_block $(((S + N) / 8)) || die "the block after the log chunk is unreadable"
    say "armed: sectors $S+$N fail; neighbours read"

    as_user touch "$SIG/go-commit"
    if wait_line "$CD/commit.log" ATTEMPTED 60; then ATTEMPTED=1; else ATTEMPTED=0; fi
    swap_table "$CUR_LINEAR" "restored: all linear"
    compare_log after-commit
    if [ "$ATTEMPTED" = 1 ]; then
        as_user touch "$SIG/go-reopen"
        finish_driver 120
    else
        say "fault-commit did not report ATTEMPTED; see $CD/commit.log"
        finish_driver 1
    fi
    say "driver_exit $DRIVER_RC" | as_user tee -a "$CD/commit.log" > /dev/null
    compare_log after-reopen
    fs_facts "after the reopen" | as_user tee -a "$CD/fs.txt" > /dev/null
    # rw, or ro if a journal failure remounted it (Rebello Q8-Q9).
    FSSTATE=$(findmnt -no OPTIONS -S "$DEV" | cut -d, -f1) || FSSTATE=unmounted

    # Drop the file's pages: unmount and mount again.
    umount "$MNT" || die "umount failed"
    if mount -t "$FS" "$DEV" "$MNT"; then
        fs_facts "remounted (cache dropped)" | as_user tee -a "$CD/fs.txt" > /dev/null
        compare_log after-drop
        as_user cp --reflink=never -- "$R" "$CD/region-before-verify.img"
        rc=0
        as_user_log "$CD/verify.log" "$BIN" fault-verify "$R" "$BE" "$BLOCKS" "$BLOCK_SIZE" "$NONCE" "$SC" "$SN" || rc=$?
        say "verify_exit $rc" | as_user tee -a "$CD/verify.log" > /dev/null
    else
        FSSTATE=$FSSTATE/no-remount
        say "---- remount failed: no verify" | as_user tee -a "$CD/fs.txt" > /dev/null
    fi
    dmesg --time-format iso | tail -n +$((DMESG0 + 1)) | as_user tee "$CD/dmesg.txt" > /dev/null
    fs_facts "after verify" | as_user tee -a "$CD/fs.txt" > /dev/null

    printf '%-12s %-6s %-7s %-12s %-7s %-14s %-14s %-12s %-12s %-7s %-12s %s\n' \
        "$c" "$(get commit_ok "$CD/commit.log")" "$(get latched "$CD/commit.log")" \
        "$(get reopen_recovery "$CD/commit.log")" "$(get reopen_visible "$CD/commit.log")" \
        "$(get equal "$CD/compare-after-commit.txt")/$(get nonce_in_buffered "$CD/compare-after-commit.txt")$(get nonce_in_direct "$CD/compare-after-commit.txt")" \
        "$(get equal "$CD/compare-after-reopen.txt")/$(get nonce_in_buffered "$CD/compare-after-reopen.txt")$(get nonce_in_direct "$CD/compare-after-reopen.txt")" \
        "$(get equal "$CD/compare-after-drop.txt")" \
        "$(get recovery "$CD/verify.log")" "$(get visible "$CD/verify.log")" \
        "$(get verdict "$CD/verify.log")" "${FSSTATE:-?}" | as_user tee -a "$OUT/summary.txt"
    teardown_case || die "teardown of $c left something behind"
}

{
    say "# commit = commit() succeeded; latched = requiresRecovery() after it"
    say "# same-boot = the reopen in the same process: recovery, marker visible"
    say "# log x/yz = buffered and O_DIRECT copies of the log chunk equal (x), nonce in buffered (y) and direct (z)"
    say "# after-drop = fault-verify after umount + mount: recovery, visible, verdict"
    say "# fs = rw or ro after the reopen (ro: a journal failure, not the case under test)"
    printf '%-12s %-6s %-7s %-12s %-7s %-14s %-14s %-12s %-12s %-7s %-12s %s\n' \
        case commit latched same-boot visible log@commit log@reopen log@drop after-drop visible verdict fs
} | as_user tee "$OUT/summary.txt"
for fs in $FILESYSTEMS; do
    for be in file direct; do run_case "$fs" "$be"; done
done
[ "$FILESYSTEMS" != ext4 ] || say "$XFS_NOTE" | as_user tee -a "$OUT/summary.txt"
say "results -> $OUT"
say "predictions: $OUT/predictions.txt"
left=$(find "$OUT" ! -user "$U" -print -quit)
[ -z "$left" ] || say "WARNING: $left is not owned by $U"
