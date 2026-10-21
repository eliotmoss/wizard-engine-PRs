#!/usr/bin/env bash
#
# Failed-boundary check on pc-ubuntu: after a commit whose log write fails
# with EIO, does the same-boot abandon, reopen and recover replay a record
# that the page cache holds and the disk does not? (Rebello et al., ATC '20;
# docs/persistent-backends.md, "Persistence-failure contract".)
#   scripts/desktop-fsyncfail-check.sh check [scenario...]
#   sudo env PWROOT_USER=sean-tan scripts/desktop-fsyncfail-check.sh run --yes-inject-io-errors [scenario...]
# Scenarios, all three by default, in this order:
#   single      4 KiB blocks. One transaction after a clean close (both slots
#               scrubbed), so it is sequence 1; the whole log chunk fails.
#   stale-slot  8 KiB blocks, so the two log slots lie on different 4 KiB
#               pages. Prepare leaves two acknowledged records, N-2 and N-1;
#               only the page holding slot N mod 2 fails; after the same-boot
#               reopen one more transaction, "next", writes another word.
#   tear        4 KiB blocks, both slots on the one page. N-2 and N-1 as for
#               stale-slot; N writes two words; the page fails; nothing is
#               committed after the reopen.
# The predictions (predictions() below, printed by check and saved by run) say
# what each scenario tests and what each outcome would mean.
# check needs no root: it checks prerequisites, builds pwreboot, runs the
# verdict self-test, runs the driver's steps once per scenario and backend
# with no fault injected (for stale-slot and tear on the file backend, also
# once with the failing page's pre-commit bytes written back into a copy of
# the region, as the predicted fault would leave the device), and prints the
# plan and the predictions. run builds nothing and uses no existing device:
# for each scenario, file system (ext4; XFS only if mkfs.xfs exists) and
# backend (file, then direct as the control) it makes a sparse image under the
# owner's home on /, attaches it to a new loop device, puts a new
# device-mapper device over that, makes a fresh file system on it and mounts
# it under the owner's home. pwreboot always runs as the owner. Everything is
# torn down on exit, failure or interrupt. The images are deleted; each region
# file is copied into the results first.
#
# The fault. While fault-commit waits, the dm table is swapped for one that
# maps exactly the failing sectors to the `error` target and the rest
# linearly; the commit runs; the all-linear table goes back before anything
# reads those sectors again, so the device fails one write, as in Rebello's
# transient faults. The failing sectors are the log chunk's (single), or the
# 4 KiB page holding slot N mod 2 (stale-slot, tear). Not dm-flakey: with
# error_writes it fails every write bio
# while down, and the empty flush that dm sends to each target with
# num_flush_bios > 0 is a write bio (v7.0 dm-flakey.c flakey_ctr sets
# num_flush_bios = 1; flakey_map; dm.c __send_empty_flush; only linear and
# stripe set flush_bypasses_map). Every flush on the device would then fail,
# and the next journal commit with it: Rebello's journal-failure case
# (Table 1, Q8-Q9), not the case under test. `error` sets no num_flush_bios
# (dm-target.c io_err_ctr), so flushes skip it; it also fails reads, which is
# why the table is restored before the reopen, and what lets the script check
# the armed table without writing: a read of the failing block must fail and
# the blocks either side (and, for stale-slot, the other slot's page) must not.

set -euo pipefail
umask 077

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }
usage() { say "usage: $0 check [scenario...] | run --yes-inject-io-errors [scenario...]"; say "scenarios: single stale-slot tear (default: all three)"; }
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
        [ "$#" -ge 1 ] && [ "$1" = --yes-inject-io-errors ] || die "run refused: requires --yes-inject-io-errors"
        shift
        [ "$(id -u)" = 0 ] || die "run needs root via sudo (and --yes-inject-io-errors)"
        ;;
    check) ;;
    help|-h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac
SCENARIOS=${*:-single stale-slot tear}
seen=
for s in $SCENARIOS; do
    case "$s" in single|stale-slot|tear) ;; *) usage; exit 2 ;; esac
    case " $seen " in *" $s "*) die "scenario $s given twice" ;; esac
    seen="$seen $s"
done
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
STEPS=2
IMAGE_SIZE=1G           # sparse; >= 512 MiB so mke2fs uses its default profile, >= 300 MiB for XFS
DRIVER_TIMEOUT=120      # pwreboot's limit on each wait for a go file, seconds
TOOLS="losetup dmsetup mkfs.ext4 blkid filefrag setpriv findmnt lsblk blockdev mountpoint gnudd od cmp paste sha256sum mount umount ps"
# GNU dd, not /usr/bin/dd: on this Ubuntu dd is uutils coreutils, whose read
# buffer is not 512-byte aligned (seen at 0x...580 under strace). An O_DIRECT
# read then fails with EINVAL ("IO error: Invalid input") on the loop device
# and the dm device over it (queue/dma_alignment 511), though it succeeds on
# the NVMe drive (dma_alignment 3). GNU dd aligns its buffer to a page.
# First run, results/20261021T080228Z-sean-tan-PC-fsyncfail-diEiwq.
DD=gnudd
if command -v mkfs.xfs > /dev/null; then
    FILESYSTEMS="ext4 xfs"; XFS_NOTE="xfs included: $(mkfs.xfs -V 2>&1 | sed -n 1p)"
else
    FILESYSTEMS=ext4; XFS_NOTE='xfs skipped: mkfs.xfs not installed'
fi
# stale-slot needs the slots on different 4 KiB pages: from 8 KiB blocks up.
block_size_of() { case "$1" in stale-slot) say 8192 ;; *) say 4096 ;; esac; }

# State files are data, never shell-sourced.
value() {
    local key=$1 file=$2
    awk -v k="$key" '$1 == k { n++; sub(/^[^ ]+ /, ""); v=$0 }
        END { if (n != 1 || v == "") exit 1; print v }' "$file" || die "missing/duplicate $key in $file"
}
number() { local n; n=$(value "$1" "$2") || return 2; [[ "$n" =~ ^[0-9]+$ ]] || die "invalid number $1"; say "$n"; }
# For the summary: the last value of a key, or ?.
get() { [ -f "$2" ] || { say '?'; return 0; }; awk -v k="$1" '$1 == k { v=$2 } END { print (v == "" ? "?" : v) }' "$2"; }

# ---- the log chunk's two slots (docs/persistent-backends.md, "Active on-region layout")
#
# Header 64 B, then slot 0 and slot 1 of slotBytes = alignDown((blockSize -
# 64) / 2, 64) each; slot k holds sequences of parity k. A record is
# TxnRecordHeader (magic +0, entryCount +40, txnSeq +56; 64 B), 32-byte
# entries, then TxnCommitTrailer (magic +0, txnSeq +32). The driver validates
# records with the WAL's own validateSlot(), checksum included; these readers
# check the structure in a raw copy (no checksum), so the device's copy can be
# checked too. Reads of the copies are bounds-checked: od returns 0 on a short
# read.
REC_MAGIC=4924476513641318468   # 0x4457414c54584844, "DWALTXHD"
TRL_MAGIC=4924476513641317197   # 0x4457414c5458434d, "DWALTXCM"
set_slots() { # block size [prepare.state]: SLOT_BYTES, SLOT_REL0/1 (offsets in the log chunk)
    SLOT_BYTES=$(( ($1 - 64) / 2 / 64 * 64 ))
    SLOT_REL0=64 SLOT_REL1=$((64 + SLOT_BYTES))
    [ $((SLOT_REL1 + SLOT_BYTES)) -le "$LOG_BYTES" ] || die "the slots do not fit the log chunk"
    if [ "$#" = 2 ]; then
        [ "$(number slot_bytes "$2")" = "$SLOT_BYTES" ] || die "the driver's slotBytes differs from alignDown((blockSize - 64) / 2, 64) = $SLOT_BYTES"
        [ "$(number slot0_offset "$2")" = $((LOG_OFF + SLOT_REL0)) ] && [ "$(number slot1_offset "$2")" = $((LOG_OFF + SLOT_REL1)) ] \
            || die "the driver's slot offsets differ from the layout's"
    fi
}
slot_rel() { if [ "$1" = 0 ]; then say "$SLOT_REL0"; else say "$SLOT_REL1"; fi; }
uint_at() { # file, offset, bytes (4 or 8): the little-endian unsigned integer there
    local v
    [ $(($2 + $3)) -le "$(stat -c %s "$1")" ] || die "read past the end of $1 at $2"
    v=$(od -An -v -tu"$3" -j "$2" -N "$3" "$1" | tr -d ' \n') || die "od failed on $1"
    [[ "$v" =~ ^[0-9]+$ ]] || die "could not read $3 bytes at $2 of $1"
    say "$v"
}
slot_seq() { # log-chunk copy, slot: its record's sequence, or - if it holds no record
    local f=$1 k=$2 o m s n t tm ts
    o=$(slot_rel "$k")
    m=$(uint_at "$f" "$o" 8) || exit 2
    [ "$m" = "$REC_MAGIC" ] || { say -; return 0; }
    s=$(uint_at "$f" $((o + 56)) 8) || exit 2
    n=$(uint_at "$f" $((o + 40)) 4) || exit 2
    [ "$n" -le $(( (SLOT_BYTES - 112) / 32 )) ] || { say -; return 0; }
    t=$((o + 64 + 32 * n))
    tm=$(uint_at "$f" "$t" 8) || exit 2
    ts=$(uint_at "$f" $((t + 32)) 8) || exit 2
    [ "$tm" = "$TRL_MAGIC" ] && [ "$ts" = "$s" ] && [ "$s" != 0 ] && [ "${#s}" -le 18 ] && [ $((s % 2)) = "$k" ] || { say -; return 0; }
    say "$s"
}
slots_of() { # log-chunk copy: "s0,s1"
    local a b
    a=$(slot_seq "$1" 0) || die "slot read failed on $1"
    b=$(slot_seq "$1" 1) || die "slot read failed on $1"
    say "$a,$b"
}
hex_in() { # file, little-endian hex, offset, length: 1 if those bytes hold the value at a byte boundary
    local hex pat
    [ $(($3 + $4)) -le "$(stat -c %s "$1")" ] || die "read past the end of $1 at $3"
    hex=$(od -An -v -tx1 -w1 -j "$3" -N "$4" "$1" | tr -d ' ' | paste -sd' ') || die "od failed on $1"
    pat=" $(printf '%s' "$2" | sed -E 's/(..)/\1 /g')"
    case " $hex " in *"$pat"*) say 1 ;; *) say 0 ;; esac
}
check_prepared() { # log-chunk copy, label: both slots hold fault-prepare's records, N-1 and N-2
    local f=$1 got ka kb
    got=$(slots_of "$f")
    [ "$got" = "$(number slot0_seq "$PS"),$(number slot1_seq "$PS")" ] || die "$2: the slots hold $got, not fault-prepare's"
    ka=$(( $(number seq_a "$PS") % 2 )); kb=$(( $(number seq_b "$PS") % 2 ))
    [ "$(hex_in "$f" "$(value value_a_le_hex "$PS")" "$(slot_rel "$ka")" "$SLOT_BYTES")" = 1 ] || die "$2: A is not in N-2's slot $ka"
    [ "$(hex_in "$f" "$(value value_b_le_hex "$PS")" "$(slot_rel "$kb")" "$SLOT_BYTES")" = 1 ] || die "$2: B is not in N-1's slot $kb"
    say "$got"
}
set_fail_range() { # FAIL_OFF, FAIL_BYTES (file offsets), OTHER_PAGE, TEST_SLOT
    if [ "$SCN" = single ]; then FAIL_OFF=$LOG_OFF FAIL_BYTES=$LOG_BYTES OTHER_PAGE= TEST_SLOT=1; return 0; fi
    local n t o tf tl of ol
    n=$(( $(number seq_b "$PS") + 1 )); TEST_SLOT=$((n % 2))
    t=$((LOG_OFF + $(slot_rel "$TEST_SLOT"))); o=$((LOG_OFF + $(slot_rel $((1 - TEST_SLOT)))))
    tf=$((t / 4096 * 4096)); tl=$(((t + SLOT_BYTES - 1) / 4096 * 4096))
    of=$((o / 4096 * 4096)); ol=$(((o + SLOT_BYTES - 1) / 4096 * 4096))
    [ "$tf" = "$tl" ] || die "slot $TEST_SLOT spans two 4 KiB pages"
    [ "$of" = "$ol" ] || die "slot $((1 - TEST_SLOT)) spans two 4 KiB pages"
    [ "$tf" -ge "$LOG_OFF" ] && [ $((tf + 4096)) -le $((LOG_OFF + LOG_BYTES)) ] || die "the failing page is outside the log chunk"
    case "$SCN" in
        stale-slot) [ "$tf" != "$of" ] || die "stale-slot needs the two slots on different pages (block size $BS)" ;;
        tear) [ "$tf" = "$of" ] || die "tear needs both slots on one page (block size $BS)" ;;
    esac
    FAIL_OFF=$tf FAIL_BYTES=4096 OTHER_PAGE=$of
}
fail_sectors() { # from S (the log chunk's first sector) and N: FS0, FN (the failing sectors), OS (the other slot's page)
    FS0=$((S + (FAIL_OFF - LOG_OFF) / 512)) FN=$((FAIL_BYTES / 512)) OS=
    [ -z "$OTHER_PAGE" ] || OS=$((S + (OTHER_PAGE - LOG_OFF) / 512))
    [ $((FS0 % 8)) = 0 ] && [ "$FS0" -ge "$S" ] && [ $((FS0 + FN)) -le $((S + N)) ] || die "unexpected failing sectors $FS0+$FN"
    if [ -n "$OS" ]; then
        [ $((OS % 8)) = 0 ] && [ "$OS" -ge "$S" ] && [ $((OS + 8)) -le $((S + N)) ] || die "unexpected other-slot sector $OS"
        case "$SCN" in
            stale-slot) [ "$OS" != "$FS0" ] || die "the other slot's page is the failing page" ;;
            tear) [ "$OS" = "$FS0" ] || die "tear: the other slot is not on the failing page" ;;
        esac
    fi
}
armed_table() { # device size in sectors, loop MAJ:MIN
    printf '%s\n' "0 $FS0 linear $2 0" "$FS0 $FN error" "$((FS0 + FN)) $(($1 - FS0 - FN)) linear $2 $((FS0 + FN))"
}
geometry() {
    say "scenario $SCN"
    say "block_size $BS"
    say "log_offset $LOG_OFF"
    say "log_bytes $LOG_BYTES"
    say "slot_bytes $SLOT_BYTES"
    say "slot0_offset $((LOG_OFF + SLOT_REL0))"
    say "slot1_offset $((LOG_OFF + SLOT_REL1))"
    say "test_slot $TEST_SLOT"
    say "fail_offset $FAIL_OFF"
    say "fail_bytes $FAIL_BYTES"
    say "other_slot_page ${OTHER_PAGE:--}"
}
check_ready() { # commit.log: the driver's view at READY agrees with fault-prepare's
    local cl=$1 k
    [ "$(value scenario "$cl")" = "$SCN" ] || die "fault-commit runs another scenario"
    [ "$(value mount_recovery "$cl")" = REPLAYED ] || die "the mount before the fault did not replay N-2 and N-1"
    for k in 0 1; do
        [ "$(number "pre_slot${k}_seq" "$cl")" = "$(number "slot${k}_seq" "$PS")" ] || die "slot $k changed between fault-prepare and the mount"
        [ "$(number "slot${k}_offset" "$cl")" = "$(number "slot${k}_offset" "$PS")" ] || die "slot $k's offset differs"
    done
    [ "$(number txn_seq "$cl")" = $(( $(number seq_b "$PS") + 1 )) ] || die "N is not (N-1) + 1"
    [ "$(number test_slot "$cl")" = "$TEST_SLOT" ] || die "the driver's slot under test differs from the failing page's slot"
    [ "$(value m_before "$cl")" = "$(value value_b "$PS")" ] || die "M does not hold B after the mount"
    [ "$(number x_before "$cl")" = 0 ] || die "the second word is not 0 after the mount"
    [ "$(number leaks_reclaimed "$cl")" = 0 ] || die "the mount reclaimed a leak"
}
set_values() { # A, B from prepare.state; C, the second word's value, its label: for label()
    VA=$(value value_a "$PS"); VB=$(value value_b "$PS")
    VC=$(value value_c "$1"); VX=$(value value_x "$1")
    if [ "$SCN" = stale-slot ]; then XL=D; else XL=E; fi
}
label() { # a word's value: A, B, C, D or E (the second word's value), 0, other, or ? (missing)
    case "$1" in
        ''|'?') say '?' ;;
        0) say 0 ;;
        "$VA") say A ;;
        "$VB") say B ;;
        "$VC") say C ;;
        "$VX") say "$XL" ;;
        *) say other ;;
    esac
}
seqs() { # file, key prefix: "s0,s1", 0 as -
    local a b
    a=$(get "${2}_slot0_seq" "$1"); b=$(get "${2}_slot1_seq" "$1")
    [ "$a" != 0 ] || a=-; [ "$b" != 0 ] || b=-
    say "$a,$b"
}
next_arg() { # commit.log: next's sequence for fault-verify-acks, 0 if next was not acknowledged
    local ok s
    ok=$(get next_ok "$1"); s=$(get next_seq "$1")
    if [ "$ok" != 1 ]; then say 0; return 0; fi
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" != 0 ]; then say "$s"; return 0; fi
    s=$(get next_seq_expected "$1")
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" != 0 ]; then say "$s"; else say 1; fi
}
# The log chunk's device sectors. FIEMAP offsets are bytes on the file
# system's device, which starts at sector 0 of the dm device.
map_log_chunk() { # region file, filefrag output file: S (first sector), FLAGS
    as_user filefrag -v -b512 -s "$1" | as_user tee "$2" > /dev/null
    # Extent lines: "i: lstart.. lend: pstart.. pend: len: [expected] [flags]".
    read -r S FLAGS < <(sed -E 's/\.\./ /g; s/:/ /g' "$2" | awk -v l0=$((LOG_OFF / 512)) -v n=$((LOG_BYTES / 512)) '
        $1 ~ /^[0-9]+$/ && NF >= 6 && $2 ~ /^[0-9]+$/ && $2 <= l0 && l0 + n - 1 <= $3 {
            s = $4 + (l0 - $2); flags = ($NF ~ /[a-z]/) ? $NF : "-"; found++
        }
        END { if (found == 1) print s, flags }') || die "the log chunk does not lie in one extent; see $2"
    local f
    for f in ${FLAGS//,/ }; do
        case "$f" in -|last|eof|merged) ;; *) die "the log chunk's extent is flagged $f: not allocated and written" ;; esac
    done
}

# ---- the log chunk read back, and the summary tables (run; check reuses them)

nonce_in() { # bytes on stdin; 1 if the nonce's bytes occur at a byte boundary
    local hex pat
    hex=" $(od -An -v -tx1 -w1 | tr -d ' ' | paste -sd' ') "
    pat=" $(printf '%s' "$NONCE_HEX" | sed -E 's/(..)/\1 /g')"
    case "$hex" in *"$pat"*) say 1 ;; *) say 0 ;; esac
}
compare_log() { # tag: the log chunk through the page cache and through O_DIRECT
    local b=$CD/log-$1-buffered.bin d=$CD/log-$1-direct.bin sb sd rb=1 rd=1 slb sld
    as_user "$DD" if="$R" bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$b" status=none || rb=0
    as_user "$DD" if="$R" iflag=direct bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$d" status=none || rd=0
    # A failed read is the tool or the setup, not a result: an empty copy would
    # read as "differs, nonce absent", the predicted outcome. Stop instead.
    [ "$rb" = 1 ] && [ "$rd" = 1 ] || die "log read failed at $1 (buffered ok $rb, O_DIRECT ok $rd); see $CD"
    [ "$(stat -c %s "$b")" = "$LOG_BYTES" ] && [ "$(stat -c %s "$d")" = "$LOG_BYTES" ] || die "short log read at $1; see $CD"
    sb=$(sha256sum < "$b" | cut -d' ' -f1); sd=$(sha256sum < "$d" | cut -d' ' -f1)
    slb=$(slots_of "$b"); sld=$(slots_of "$d")
    {
        say "buffered_read_ok $rb"
        say "direct_read_ok $rd"
        say "buffered_sha256 $sb"
        say "direct_sha256 $sd"
        say "equal $([ "$sb" = "$sd" ] && say 1 || say 0)"
        # single: the nonce; stale-slot and tear: C, the value N stored in M.
        say "nonce_in_buffered $(nonce_in < "$b")"
        say "nonce_in_direct $(nonce_in < "$d")"
        say "buffered_slots $slb"
        say "direct_slots $sld"
    } | as_user tee "$CD/compare-$1.txt" > /dev/null
}
logcol() { # tag: for the two-record tables, equal/buffered slots/O_DIRECT slots
    local f=$CD/compare-$1.txt
    say "$(get equal "$f")/$(get buffered_slots "$f")/$(get direct_slots "$f")"
}
FMT_SINGLE='%-24s %-6s %-7s %-12s %-7s %-14s %-14s %-12s %-12s %-7s %-12s %s\n'
FMT_STALE='%-28s %-6s %-7s %-10s %-5s %-5s %-11s %-11s %-11s %-11s %-10s %-6s %-5s %-5s %-12s %s\n'
FMT_TEAR='%-22s %-6s %-7s %-10s %-5s %-5s %-11s %-11s %-11s %-10s %-6s %-5s %-5s %-12s %s\n'
summary_header() { # scenario
    say ""
    case "$1" in
        single)
            say "==== single: one transaction after a clean close; the log chunk fails"
            say "# commit = commit() succeeded; latched = requiresRecovery() after it"
            say "# same-boot = the reopen in the same process: recovery, marker visible"
            say "# log x/yz = buffered and O_DIRECT copies of the log chunk equal (x), nonce in buffered (y) and direct (z)"
            say "# after-drop = fault-verify after umount + mount: recovery, visible, verdict"
            say "# fs = rw or ro after the reopen (ro: a journal failure, not the case under test)"
            # shellcheck disable=SC2059
            printf "$FMT_SINGLE" case commit latched same-boot visible log@commit log@reopen log@drop after-drop visible verdict fs
            ;;
        stale-slot)
            say "==== stale-slot: N-2 (M = A) and N-1 (M = B) acknowledged; N stores M = C, only slot N mod 2's page fails; next stores M2 = D"
            say "# commit = commit N succeeded; latched = requiresRecovery() after it"
            say "# same-boot = the reopen: recovery; M = its value then (A, B, C, D, 0, other)"
            say "# next = next's commit() result / sequence (0: none)"
            say "# log x/b/d = buffered and O_DIRECT copies of the log chunk equal (x); slot 0,1 sequences in the buffered (b) and O_DIRECT (d) copy, - = no record"
            say "# after-drop = fault-verify-acks after umount + mount: recovery; slots found; M; M2; verdict (every acknowledged transaction present, N whole or absent)"
            # shellcheck disable=SC2059
            printf "$FMT_STALE" case commit latched same-boot M next log@commit log@reopen log@next log@drop after-drop slots M M2 verdict fs
            ;;
        tear)
            say "==== tear: N-2 (M = A) and N-1 (M = B) acknowledged; N stores M = C and Z = E; the page holding both slots fails"
            say "# commit = commit N succeeded; latched = requiresRecovery() after it"
            say "# same-boot = the reopen: recovery; M and Z then (A, B, C, E, 0, other)"
            say "# log x/b/d = buffered and O_DIRECT copies of the log chunk equal (x); slot 0,1 sequences in the buffered (b) and O_DIRECT (d) copy, - = no record"
            say "# after-drop = fault-verify-acks after umount + mount: recovery; slots found; M; Z; verdict (N-1 present, N whole or absent)"
            # shellcheck disable=SC2059
            printf "$FMT_TEAR" case commit latched same-boot M Z log@commit log@reopen log@drop after-drop slots M Z verdict fs
            ;;
    esac
}

# shellcheck disable=SC2059
summary_row() { # case name: its row, from $CD's files, for $SCN's table
    local cl=$CD/commit.log vl=$CD/verify.log
    case "$SCN" in
        single)
            printf "$FMT_SINGLE" \
                "$1" "$(get commit_ok "$cl")" "$(get latched "$cl")" \
                "$(get reopen_recovery "$cl")" "$(get reopen_visible "$cl")" \
                "$(get equal "$CD/compare-after-commit.txt")/$(get nonce_in_buffered "$CD/compare-after-commit.txt")$(get nonce_in_direct "$CD/compare-after-commit.txt")" \
                "$(get equal "$CD/compare-after-reopen.txt")/$(get nonce_in_buffered "$CD/compare-after-reopen.txt")$(get nonce_in_direct "$CD/compare-after-reopen.txt")" \
                "$(get equal "$CD/compare-after-drop.txt")" \
                "$(get recovery "$vl")" "$(get visible "$vl")" \
                "$(get verdict "$vl")" "${FSSTATE:-?}"
            ;;
        stale-slot)
            printf "$FMT_STALE" \
                "$1" "$(get commit_ok "$cl")" "$(get latched "$cl")" \
                "$(get reopen_recovery "$cl")" "$(label "$(get reopen_m "$cl")")" \
                "$(get next_ok "$cl")/$(get next_seq "$cl")" \
                "$(logcol after-commit)" "$(logcol after-reopen)" "$(logcol after-next)" "$(logcol after-drop)" \
                "$(get recovery "$vl")" "$(seqs "$vl" found)" "$(get m_is "$vl")" "$(get x_is "$vl")" \
                "$(get verdict "$vl")" "${FSSTATE:-?}"
            ;;
        tear)
            printf "$FMT_TEAR" \
                "$1" "$(get commit_ok "$cl")" "$(get latched "$cl")" \
                "$(get reopen_recovery "$cl")" "$(label "$(get reopen_m "$cl")")" "$(label "$(get reopen_x "$cl")")" \
                "$(logcol after-commit)" "$(logcol after-reopen)" "$(logcol after-drop)" \
                "$(get recovery "$vl")" "$(seqs "$vl" found)" "$(get m_is "$vl")" "$(get x_is "$vl")" \
                "$(get verdict "$vl")" "${FSSTATE:-?}"
            ;;
    esac
}

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
PREDICTIONS (not results).

==== single: 4 KiB blocks. One transaction (one redo entry: a nonce in the
marker word) is committed after a clean close, so it is sequence 1 and lands
in slot 1 of the log chunk; the error target fails the write of that chunk.
"Visible" means the marker holds the nonce.

file on ext4 (data=ordered) and XFS:
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
  (Seen on ext4 twice and XFS once on 2026-10-21; this run repeats it.)

direct on ext4 and XFS (control):
  commit 0, latched: the O_DIRECT pwrite of the log unit returns EIO.
  same-boot reopen: CLEAN, not visible: create() reads the region through
    O_DIRECT, from the device.
  log chunk, buffered vs O_DIRECT: equal; the nonce is in neither.
  after the drop: CLEAN, not visible.

What other outcomes would mean:
  file, same-boot CLEAN: the page kept neither the new bytes nor its place
    in the cache (as Btrfs reverts it, Table 1, Q5), or the reopen read the
    device.
  file or direct, commit 1: no failure reached the boundary; check
    dm-tables.txt and dmesg.txt. The case says nothing.
  file, after the drop REPLAYED: the record reached the disk after all, so
    something retried the failed write (contradicts Q4 and section 3.3.1).
  file, after the drop not visible: the replay's own data write did not
    reach the disk either; read dmesg.txt.
  direct, same-boot REPLAYED or visible: the control read a cached copy and
    fails as a control.

==== stale-slot: 8 KiB blocks. slotBytes = alignDown((8192 - 64) / 2, 64) =
4032, so slot 0 is bytes 64-4095 of the log chunk (its first 4 KiB page,
with the header) and slot 1 is bytes 4096-8127 (its second page).
fault-prepare leaves N-2 = 1 (M = A) in slot 1 and N-1 = 2 (M = B) in slot
0, both acknowledged, their data flushed, no clean close. N = 3 stores M = C
and goes to slot 3 mod 2 = 1; the error target covers only slot 1's page.
After the same-boot reopen, "next" stores M2 = D, a word N never touches.
Acknowledged: N-2, N-1 and next; N is not. So M must end B or C, and M2 D.
"Slots s0,s1" are the sequences of the records in slot 0 and slot 1.

file on ext4 and XFS:
  mount before the fault: REPLAYED (1 then 2), M = B.
  commit N: 0, latched: fdatasync returns EIO for slot 1's page.
  log after the commit: copies differ: buffered slots 2,3, O_DIRECT 2,1; C in
    the buffered copy only.
  same-boot reopen: reads 2,3 from the cached page; REPLAYED (2 then 3),
    M = C. Recovery's boundary writes M's page; slot 1's page stays clean.
  log after the reopen: as after the commit.
  next: acknowledged, sequence 4, so slot 0, whose page lies outside the
    failed range and reaches the device.
  log after next: buffered 4,3; O_DIRECT 4,1.
  after umount + mount: the device holds 4 in slot 0 and the stale 1 in
    slot 1. Recovery replays 1 then 4: REPLAYED, M = A, M2 = D.
    Verdict LOST: N-2's stale record undoes the acknowledged N-1's M = B.
    This is the inference in the thesis's reading note on Rebello et al.
    ("What that does to the log"), tested here.

direct on ext4 and XFS (control):
  commit N: 0, latched. Log after the commit: equal, 2,1, no C.
  same-boot reopen: reads 2,1 from the device; REPLAYED (1 then 2), M = B.
  next: acknowledged, sequence 3, in slot 1 over N-2's record.
  log after next: equal, 2,3.
  after umount + mount: REPLAYED (2 then 3), M = B, M2 = D. CONSISTENT, N
    absent, no loss.

What other outcomes would mean:
  file, the reopen read 2,1 and M = B: the cache did not keep the failed
    bytes (or the page was evicted and read again); next then takes sequence
    3 as on direct, and the hazard does not arise on this kernel.
  file, after the drop 4,3 and M = C: the failed write reached the device
    after all (a retry, contrary to Rebello Q4); N present, CONSISTENT.
  file, after the drop 4,- (slot 1 holds no valid record): only 4 replays;
    M = C from the same-boot replay's write, CONSISTENT: the stale record did
    not survive whole, so nothing undid N-1.
  Recovery as written (DualTxnWal.recover()) does not check that the two
    sequences are adjacent; it replays every valid slot in ascending order.
    A recovery that refused non-adjacent sequences would show CORRUPT after
    the drop (verdict INCONSISTENT: the loss detected and the region
    unavailable, not silent), or replay only 4 (M = C, M2 = D: CONSISTENT,
    with the unacknowledged N present, which REPLAYED allows). Either would
    mean the build differs from the code these predictions were read from.
  next 0 or latched: next's own boundary failed, so the error range was not
    the slot 1 page alone or was not restored; see dm-tables.txt, dmesg.txt.
  direct, the reopen read 2,3 or M = C: the control read a cached copy.

==== tear: 4 KiB blocks. slotBytes = alignDown((4096 - 64) / 2, 64) = 1984:
slot 0 is bytes 64-2047 and slot 1 bytes 2048-4031 of the log chunk's one
page. fault-prepare as for stale-slot: N-2 = 1 (M = A) in slot 1, N-1 = 2
(M = B) in slot 0. N = 3 (slot 1) stores M = C and Z = E; Z is 0 before, and
N-2 and N-1 never touch it. The error target covers the page. Nothing is
committed after the reopen. N-1 is acknowledged and N is not, so (M, Z) must
end (B, 0), N absent, or (C, E), N present.

file on ext4 and XFS:
  commit N: 0, latched. Log after the commit: copies differ: buffered 2,3,
    O_DIRECT 2,1.
  same-boot reopen: REPLAYED (2 then 3) from the cached page: M = C, Z = E,
    both made durable by recovery's boundary.
  log after the reopen: as after the commit.
  after umount + mount: the device's page holds 2,1; recovery replays 1 then
    2: M = B, Z = E. Verdict TORN: N is partly present, its Z durable and its
    M undone by N-1's replay. The contract allows N absent or replayed, not
    in part.

direct on ext4 and XFS (control):
  same-boot reopen reads 2,1 from the device: REPLAYED, M = B, Z = 0. After
  the drop the same: CONSISTENT, N absent.

What other outcomes would mean:
  file, after the drop 2,3 and M = C, Z = E: the record reached the device
    (a retry); N wholly present, CONSISTENT.
  file, same-boot M = B, Z = 0: as for stale-slot, the cache did not keep
    the failed bytes, and no tear arises.
  M = A (LOST): N-1's record in slot 0, on the failing page, did not
    validate after the drop, so the device holds less than the pre-commit
    page; compare log-after-drop-direct.bin with log-device-before.bin.

Common to every scenario:
  file system read-only, shut down, or a failed mount or remount: Rebello's
    journal-failure case (Table 1, Q8-Q9), not the case under test; the
    error range was meant to hold file data only.
  driver killed by SIGBUS: the clean page was evicted while its blocks still
    failed reads; the run says nothing about the reopen.
  verdict INCONSISTENT: a structural failure beyond the contract (or, with
    acks LOST or TORN in verify.log, the words' verdict under a broken
    invariant).
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
    say "---- verdict self-test (pwreboot fault-verdict-test)"
    "$BIN" fault-verdict-test || die "the verdict self-test failed"
    mkdir -p "$PARENT"
    [ "$(findmnt -nro TARGET -T "$PARENT")" = / ] || die "$PARENT must be on /"
    P=$(mktemp -d "$PARENT/check-XXXXXX")
    say "---- plumbing, no fault injected, in $P"
    verify_pair() { # region, log: fault-verify-acks with this case's values; sets VRC
        VRC=0
        "$BIN" fault-verify-acks "$1" "$BE" "$BLOCKS" "$BS" "$SCN" "$(number setup_cursor "$PS")" "$(number setup_count "$PS")" \
            "$VA" "$VB" "$VC" "$VX" "$(next_arg "$CL")" > "$2" 2>&1 || VRC=$?
    }
    plumb() { # scenario, backend
        SCN=$1 BE=$2
        local d=$P/$1-$2 got want prep logafter emu other
        BS=$(block_size_of "$SCN")
        mkdir -p "$d/region" "$d/signal"
        PS=$d/prepare.state CL=$d/commit.log
        "$BIN" fault-prepare "$d/region" "$PS" "$BE" "$BLOCKS" "$BS" "$STEPS" "$SCN" > "$d/prepare.log" 2>&1 \
            || die "fault-prepare $SCN $BE failed; see $d/prepare.log"
        R=$(value region "$PS")
        [ "$(value scenario "$PS")" = "$SCN" ] && [ "$(number block_size "$PS")" = "$BS" ] || die "fault-prepare used another scenario or block size"
        LOG_OFF=$(number log_offset "$PS"); LOG_BYTES=$(number log_bytes "$PS")
        sync -f "$R"
        if [ "$SCN" = single ]; then set_slots "$BS"; else set_slots "$BS" "$PS"; fi
        set_fail_range
        geometry > "$d/geometry.txt"
        prep=-
        if [ "$SCN" != single ]; then
            "$DD" if="$R" iflag=direct bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$d/log-before.bin" status=none \
                || die "O_DIRECT read of the log chunk failed"
            [ "$(stat -c %s "$d/log-before.bin")" = "$LOG_BYTES" ] || die "short read of the log chunk"
            prep=$(check_prepared "$d/log-before.bin" "after fault-prepare")
            if [ "$BE" = file ]; then
                # run's mapping code on this file, on /: the arithmetic only.
                map_log_chunk "$R" "$d/filefrag.txt"
                N=$((LOG_BYTES / 512))
                fail_sectors
                if [ "$OS" = "$FS0" ]; then other="shares the failing page"; else other="is at sector $OS and must read"; fi
                say "$SCN $BE: geometry: slot $TEST_SLOT (N mod 2) at file offset $((LOG_OFF + $(slot_rel "$TEST_SLOT"))), page $FAIL_OFF; the other slot's page $OTHER_PAGE; mapped as run maps it, the failing sectors would be $FS0+$FN and the other slot's page $other"
            fi
        fi
        start_driver "$CL" "$BIN" fault-commit "$R" "$BE" "$BLOCKS" "$BS" "$d/signal" 30 "$SCN"
        wait_line "$CL" READY 30 || die "no READY; see $CL"
        # run's log reads (compare_log) and summary row (summary_row), at the
        # same points; with no fault each copy pair should be equal.
        CD=$d FSSTATE=-
        if [ "$SCN" = single ]; then
            NONCE_HEX=$(value nonce_le_hex "$CL")
        else
            check_ready "$CL"
            set_values "$CL"
            NONCE_HEX=$(value value_c_le_hex "$CL")
            # The page the fault would leave stale on the device, as it is now.
            "$DD" if="$R" bs=4096 skip=$((FAIL_OFF / 4096)) count=1 of="$d/page-before.bin" status=none || die "page read failed"
            [ "$(stat -c %s "$d/page-before.bin")" = 4096 ] || die "short page read"
        fi
        touch "$d/signal/go-commit"
        wait_line "$CL" ATTEMPTED 30 || die "no ATTEMPTED; see $CL"
        compare_log after-commit
        touch "$d/signal/go-reopen"
        if [ "$SCN" = stale-slot ]; then
            wait_line "$CL" REOPENED 30 || die "no REOPENED; see $CL"
            compare_log after-reopen
            touch "$d/signal/go-next"
            finish_driver 30
            compare_log after-next
        else
            finish_driver 30
            compare_log after-reopen
        fi
        [ "$DRIVER_RC" = 0 ] && grep -qx DONE "$CL" || die "fault-commit $SCN $BE failed; see $CL"
        # No umount in check: "after-drop" is read with the pages still cached.
        compare_log after-drop
        if [ "$SCN" = single ]; then
            rc=0
            "$BIN" fault-verify "$R" "$BE" "$BLOCKS" "$BS" "$(value nonce "$CL")" \
                "$(value setup_cursor "$PS")" "$(value setup_count "$PS")" > "$d/verify.log" 2>&1 || rc=$?
            got="commit $(get commit_ok "$CL") latched $(get latched "$CL") reopen $(get reopen_recovery "$CL") visible $(get reopen_visible "$CL") | verify $(get recovery "$d/verify.log") visible $(get visible "$d/verify.log") $(get verdict "$d/verify.log")"
            say "$SCN $BE: $got"
            [ "$rc" = 0 ] && [ "$got" = "commit 1 latched 0 reopen REPLAYED visible 1 | verify REPLAYED visible 1 CONSISTENT" ] \
                || die "plumbing for $SCN $BE did not give the no-fault result; see $d"
            summary_row "$SCN-$BE" >> "$P/rows-$SCN"
            return 0
        fi
        "$DD" if="$R" iflag=direct bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$d/log-after.bin" status=none \
            || die "O_DIRECT read of the log chunk failed"
        [ "$(stat -c %s "$d/log-after.bin")" = "$LOG_BYTES" ] || die "short read of the log chunk"
        logafter=$(slots_of "$d/log-after.bin")
        [ "$BE" != file ] || cp --reflink=never -- "$R" "$d/emulated.region"
        verify_pair "$R" "$d/verify.log"
        got="prepare $prep | commit $(get commit_ok "$CL") latched $(get latched "$CL") | reopen saw $(seqs "$CL" reopen_seen) $(get reopen_recovery "$CL") M=$(label "$(get reopen_m "$CL")")"
        if [ "$SCN" = stale-slot ]; then
            got="$got | next $(get next_ok "$CL") seq $(get next_seq "$CL")"
            want="prepare 2,1 | commit 1 latched 0 | reopen saw 2,3 REPLAYED M=C | next 1 seq 4 | log 4,3 | verify found 4,3 REPLAYED M=C M2=D CONSISTENT exit 0"
        else
            got="$got Z=$(label "$(get reopen_x "$CL")")"
            want="prepare 2,1 | commit 1 latched 0 | reopen saw 2,3 REPLAYED M=C Z=E | log 2,3 | verify found 2,3 REPLAYED M=C Z=E CONSISTENT exit 0"
        fi
        got="$got | log $logafter | verify found $(seqs "$d/verify.log" found) $(get recovery "$d/verify.log") M=$(get m_is "$d/verify.log") $(get x_word "$CL")=$(get x_is "$d/verify.log") $(get verdict "$d/verify.log") exit $VRC"
        say "$SCN $BE: $got"
        [ "$got" = "$want" ] || die "plumbing for $SCN $BE did not give the no-fault result ($want); see $d"
        summary_row "$SCN-$BE" >> "$P/rows-$SCN"
        [ "$BE" = file ] || return 0
        # The predicted file outcome, emulated without a fault: the failing
        # page's pre-commit bytes written back into a copy of the region, as
        # the device keeps them when the write fails and the page stays clean.
        "$DD" if="$d/page-before.bin" of="$d/emulated.region" bs=4096 seek=$((FAIL_OFF / 4096)) count=1 conv=notrunc status=none \
            || die "could not write the page into the copy"
        "$DD" if="$d/emulated.region" bs=4096 skip=$((LOG_OFF / 4096)) count=$((LOG_BYTES / 4096)) of="$d/log-emulated.bin" status=none \
            || die "could not read the copy's log chunk"
        emu=$(slots_of "$d/log-emulated.bin")
        verify_pair "$d/emulated.region" "$d/verify-emulated.log"
        got="emulated log $emu | verify found $(seqs "$d/verify-emulated.log" found) $(get recovery "$d/verify-emulated.log") M=$(get m_is "$d/verify-emulated.log") $(get x_word "$CL")=$(get x_is "$d/verify-emulated.log") $(get verdict "$d/verify-emulated.log") exit $VRC"
        if [ "$SCN" = stale-slot ]; then
            want="emulated log 4,1 | verify found 4,1 REPLAYED M=A M2=D LOST exit 1"
        else
            want="emulated log 2,1 | verify found 2,1 REPLAYED M=B Z=E TORN exit 5"
        fi
        say "$SCN $BE (predicted fault outcome, emulated): $got"
        [ "$got" = "$want" ] || die "the emulated fault outcome for $SCN did not give $want; see $d"
    }
    for sc in $SCENARIOS; do
        for be in file direct; do plumb "$sc" "$be"; done
    done
    say "---- the no-fault runs in run's summary tables (fs -: not a dm device; after-drop: no umount)"
    for sc in $SCENARIOS; do summary_header "$sc"; cat "$P/rows-$sc"; done
    rm -rf -- "$P"
    say "plumbing: ok (no-fault runs replay and verify CONSISTENT; the emulated stale page verifies LOST/TORN; directory removed)"
    cat <<EOF
---- plan for: sudo env PWROOT_USER=$U $SELF run --yes-inject-io-errors${*:+ $*}
Scenarios: $SCENARIOS. For each scenario, file system ($FILESYSTEMS) and
backend (file, then direct): $(set -- $SCENARIOS; say "$# x $(set -- $FILESYSTEMS; say $#) x 2") cases.
  1  a sparse $IMAGE_SIZE image under $PARENT/<run>/, attached with
     losetup --find --show --direct-io=on; a new dm device
     pwfsf-<run>-<scenario>-<fs>-<backend> with one linear target over it;
     refuses anything resolving to nvme0n1
  2  mkfs.ext4 -b 4096 -E lazy_itable_init=0,lazy_journal_init=0 (otherwise
     defaults, so data=ordered) or mkfs.xfs; mounted with default options
  3  as $U: pwreboot fault-prepare ($BLOCKS blocks of 4096, or 8192 for
     stale-slot; $STEPS sieve steps; clean close; for stale-slot and tear a
     second mount commits N-2 and N-1, flushes, exits without closing; log
     chunk rewritten and fdatasynced)
  4  filefrag -v -b512 -s: the log chunk must lie in one extent with no flag
     but last/eof/merged; its O_DIRECT copies through the file and through
     the dm device must match and start with the WAL header magic; for
     stale-slot and tear both slots must hold N-2's and N-1's records
  5  as $U: pwreboot fault-commit mounts (stale-slot, tear: replays N-2 and
     N-1, checked against step 4; the device's log chunk re-read unchanged)
     and prints READY
  6  table: linear | failing sectors -> error | linear, read back and
     compared; failing sectors = the log chunk (single) or the 4 KiB page of
     slot N mod 2 (stale-slot, tear); an O_DIRECT read of the failing block
     must fail, the blocks either side and (stale-slot) the other slot's
     page must not
  7  go-commit: commit N; the all-linear table is restored; the log chunk is
     read buffered and O_DIRECT (checksums, slot sequences, the value N wrote)
  8  go-reopen: abandon, reopen, recover in the same process; stale-slot:
     log chunk read, then go-next: next commits; log chunk read again;
     file-system state and the run's dmesg lines recorded
  9  umount + mount (drops the file's pages); log chunk read again; region
     copied; as $U: pwreboot fault-verify (single) or fault-verify-acks
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
# Everything printed from here on also goes to run.log, owned by the user.
exec > >(as_user tee -a "$OUT/run.log") 2>&1
TEE_PID=$!
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
    say "scenarios $SCENARIOS"
    say "geometry $BLOCKS blocks of 4096 (single, tear) or 8192 (stale-slot); setup $STEPS sieve steps; image $IMAGE_SIZE sparse; loop --direct-io=on"
    say "fault dm error target over the log chunk's sectors (single) or slot N mod 2's 4 KiB page (stale-slot, tear), for one commit (see the script's header for why not dm-flakey)"
    say "cache_drop umount+mount (not drop_caches)"
    say "images deleted after each case; region-before-verify.img keeps each region"
    say "$XFS_NOTE"
    say '---- git status --short'
    as_user git -C "$REPO" status --short
    say '---- tools'
    losetup --version; dmsetup --version; mke2fs -V 2>&1 | sed -n 1p; filefrag -V 2>&1 | sed -n 1p
    say "dd $DD: $("$DD" --version | sed -n 1p) (/usr/bin/dd: $(dd --version 2>&1 | sed -n 1p))"
    say "od: $(od --version 2>&1 | sed -n 1p) (checked against GNU od 2026-10-21 for -tu4/-tu8/-tx1 -w1 with -j/-N)"
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
    # Let tee write the last lines to the terminal and run.log before exiting.
    if [ -n "${TEE_PID:-}" ]; then exec > /dev/null 2>&1; wait "$TEE_PID" 2> /dev/null; fi
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
read_block() { "$DD" if="$DEV" iflag=direct bs=4096 skip="$1" count=1 of=/dev/null status=none 2> /dev/null; }
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

run_case() { # scenario, fs, backend
    SCN=$1 FS=$2 BE=$3
    local c=$1-$2-$3 IMG MNT SIG S N SIZE LOOP_MM SC SN FLAGS rc FS0 FN OS armed
    BS=$(block_size_of "$SCN")
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

    PS=$CD/prepare.state
    as_user_log "$CD/prepare.log" "$BIN" fault-prepare "$MNT/region" "$PS" "$BE" "$BLOCKS" "$BS" "$STEPS" "$SCN" \
        || die "fault-prepare failed; see $CD/prepare.log"
    grep -qx OK "$CD/prepare.log" || die "fault-prepare did not finish; see $CD/prepare.log"
    R=$(value region "$PS")
    [ -f "$R" ] && [ ! -L "$R" ] && [ "$(dirname -- "$R")" = "$MNT/region" ] || die "unexpected region path $R"
    [ "$(value backend "$PS")" = "$BE" ] || die "prepared backend differs"
    [ "$(value scenario "$PS")" = "$SCN" ] && [ "$(number block_size "$PS")" = "$BS" ] || die "prepared scenario or block size differs"
    LOG_OFF=$(number log_offset "$PS"); LOG_BYTES=$(number log_bytes "$PS")
    SC=$(number setup_cursor "$PS"); SN=$(number setup_count "$PS")
    [ $((LOG_OFF % 4096)) = 0 ] && [ $((LOG_BYTES % 4096)) = 0 ] && [ "$LOG_BYTES" -gt 0 ] || die "log chunk is not 4 KiB aligned"
    as_user sync -f "$R"
    if [ "$SCN" = single ]; then set_slots "$BS"; else set_slots "$BS" "$PS"; fi
    set_fail_range

    map_log_chunk "$R" "$CD/filefrag.txt"
    N=$((LOG_BYTES / 512))
    [ $((S % 8)) = 0 ] && [ "$S" -ge 8 ] && [ $((S + N)) -lt "$SIZE" ] || die "unexpected log sectors $S+$N of $SIZE"
    "$DD" if="$DEV" iflag=direct bs=4096 skip=$((S / 8)) count=$((N / 8)) status=none | as_user tee "$CD/log-device-before.bin" > /dev/null
    as_user "$DD" if="$R" iflag=direct bs=4096 skip=$((LOG_OFF / 4096)) count=$((N / 8)) of="$CD/log-file-before.bin" status=none
    [ "$(stat -c %s "$CD/log-device-before.bin")" = "$LOG_BYTES" ] || die "short read of the device's log sectors"
    cmp -s "$CD/log-device-before.bin" "$CD/log-file-before.bin" || die "the device's sectors $S+$N do not hold the file's log chunk"
    [ "$(head -c 8 "$CD/log-device-before.bin")" = DAEHLAWD ] || die "sectors $S+$N do not start with the WAL header magic"
    PREP_SLOTS=-
    [ "$SCN" = single ] || PREP_SLOTS=$(check_prepared "$CD/log-device-before.bin" "the device's log chunk after fault-prepare")
    # The failing sectors: the log chunk (single) or slot N mod 2's page.
    fail_sectors
    {
        say "log_offset $LOG_OFF"; say "log_bytes $LOG_BYTES"; say "log_sector $S"; say "log_sectors $N"; say "extent_flags $FLAGS"
        say "fail_sector $FS0"; say "fail_sectors $FN"; say "other_slot_sector ${OS:--}"; say "prepared_slots $PREP_SLOTS"
    } | as_user tee "$CD/mapping.txt" > /dev/null
    geometry | as_user tee "$CD/geometry.txt" > /dev/null

    start_driver "$CD/commit.log" "$BIN" fault-commit "$R" "$BE" "$BLOCKS" "$BS" "$SIG" "$DRIVER_TIMEOUT" "$SCN"
    wait_line "$CD/commit.log" READY 60 || die "fault-commit did not reach READY; see $CD/commit.log"
    if [ "$SCN" = single ]; then
        NONCE=$(number nonce "$CD/commit.log")
        NONCE_HEX=$(value nonce_le_hex "$CD/commit.log")
    else
        check_ready "$CD/commit.log"
        set_values "$CD/commit.log"
        NONCE_HEX=$(value value_c_le_hex "$CD/commit.log")
        # The mount replayed N-2 and N-1 without storing to a record: the
        # device's log chunk must be the one checked above.
        "$DD" if="$DEV" iflag=direct bs=4096 skip=$((S / 8)) count=$((N / 8)) status=none | as_user tee "$CD/log-device-ready.bin" > /dev/null
        cmp -s "$CD/log-device-before.bin" "$CD/log-device-ready.bin" || die "the log chunk on the device changed between fault-prepare and READY"
    fi
    [[ "$NONCE_HEX" =~ ^[0-9a-f]{16}$ ]] || die "bad nonce_le_hex"
    # The run window by time, not by line count: the ring buffer drops its
    # oldest lines as new ones arrive (UFW logs every few seconds here), so a
    # count taken now no longer marks the same line later. Timestamps in
    # dmesg's ISO format compare as strings (results/20261021T105823Z-...-Px6IUW).
    DMESG_T0=$(date '+%Y-%m-%dT%H:%M:%S,%6N')

    # Arm, and check the armed table without writing to it.
    swap_table "$(armed_table "$SIZE" "$LOOP_MM")" "armed: sectors $FS0+$FN -> error"
    if read_block $((FS0 / 8)); then die "a read of the failing block succeeded: the error target is not in effect"; fi
    read_block $((FS0 / 8 - 1)) || die "the block before the failing range is unreadable"
    read_block $(((FS0 + FN) / 8)) || die "the block after the failing range is unreadable"
    armed="armed: sectors $FS0+$FN fail; neighbours read"
    if [ -n "$OS" ]; then
        if [ "$OS" = "$FS0" ]; then
            [ "$SCN" = tear ] || die "the other slot's page is the failing page"
            armed="$armed; the other slot shares the failing page (tear)"
        else
            read_block $((OS / 8)) || die "the other slot's page (sector $OS) is unreadable"
            armed="$armed; the other slot's page (sector $OS) reads"
        fi
    fi
    say "$armed"

    as_user touch "$SIG/go-commit"
    if wait_line "$CD/commit.log" ATTEMPTED 60; then ATTEMPTED=1; else ATTEMPTED=0; fi
    swap_table "$CUR_LINEAR" "restored: all linear"
    compare_log after-commit
    if [ "$ATTEMPTED" = 1 ]; then
        as_user touch "$SIG/go-reopen"
        if [ "$SCN" = stale-slot ]; then
            if wait_line "$CD/commit.log" REOPENED 120; then
                compare_log after-reopen
                as_user touch "$SIG/go-next"
                finish_driver 120
                compare_log after-next
            else
                say "fault-commit did not report REOPENED; see $CD/commit.log"
                finish_driver 1
                compare_log after-reopen
            fi
        else
            finish_driver 120
            compare_log after-reopen
        fi
    else
        say "fault-commit did not report ATTEMPTED; see $CD/commit.log"
        finish_driver 1
        compare_log after-reopen
    fi
    say "driver_exit $DRIVER_RC" | as_user tee -a "$CD/commit.log" > /dev/null
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
        if [ "$SCN" = single ]; then
            as_user_log "$CD/verify.log" "$BIN" fault-verify "$R" "$BE" "$BLOCKS" "$BS" "$NONCE" "$SC" "$SN" || rc=$?
        else
            as_user_log "$CD/verify.log" "$BIN" fault-verify-acks "$R" "$BE" "$BLOCKS" "$BS" "$SCN" "$SC" "$SN" \
                "$VA" "$VB" "$VC" "$VX" "$(next_arg "$CD/commit.log")" || rc=$?
        fi
        say "verify_exit $rc" | as_user tee -a "$CD/verify.log" > /dev/null
    else
        FSSTATE=$FSSTATE/no-remount
        say "---- remount failed: no verify" | as_user tee -a "$CD/fs.txt" > /dev/null
    fi
    dmesg --time-format iso | awk -v t0="$DMESG_T0" 'substr($1, 1, 26) >= t0' | as_user tee "$CD/dmesg.txt" > /dev/null
    fs_facts "after verify" | as_user tee -a "$CD/fs.txt" > /dev/null

    summary_row "$c" | as_user tee -a "$OUT/summary.txt"
    teardown_case || die "teardown of $c left something behind"
}

say "# $(set -- $SCENARIOS; say $#) scenario(s): $SCENARIOS; file systems: $FILESYSTEMS; backends: file, direct" | as_user tee "$OUT/summary.txt"
for sc in $SCENARIOS; do
    summary_header "$sc" | as_user tee -a "$OUT/summary.txt"
    for fs in $FILESYSTEMS; do
        for be in file direct; do run_case "$sc" "$fs" "$be"; done
    done
done
[ "$FILESYSTEMS" != ext4 ] || say "$XFS_NOTE" | as_user tee -a "$OUT/summary.txt"
say "results -> $OUT"
say "predictions: $OUT/predictions.txt"
left=$(find "$OUT" ! -user "$U" -print -quit)
[ -z "$left" ] || say "WARNING: $left is not owned by $U"
