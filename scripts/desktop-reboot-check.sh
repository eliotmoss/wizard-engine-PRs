#!/usr/bin/env bash
#
# File-backend kernel-reset check on pc-ubuntu; arm RESETS THE MACHINE.
#   scripts/desktop-reboot-check.sh prepare ordinary
#   sudo env PWROOT_USER=sean-tan scripts/desktop-reboot-check.sh arm ordinary --yes-reset-this-machine
#   scripts/desktop-reboot-check.sh verify
# Repeat all three with elide-clwb and a fresh prepare. No root for prepare/verify.
# verify [ordinary|elide-clwb|<results-directory>] selects a particular run;
# without an argument it selects the most recently prepared run.
# PWREBOOT_REGION_PARENT defaults to $HOME/pwfile-reboot; it must be under
# the owner's home on /. State/metadata always live in this checkout's results/.

set -euo pipefail
umask 077

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }
usage() { say "usage: $0 prepare <ordinary|elide-clwb> | arm <ordinary|elide-clwb> --yes-reset-this-machine | verify [ordinary|elide-clwb|<results-directory>]"; }
REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
BIN=$REPO/bin/pwreboot.x86-64-linux
[ "$#" -gt 0 ] || { usage; exit 2; }
CMD=$1
shift "$(( $# > 0 ? 1 : 0 ))"
# Check the dangerous opt-in before reading state, building, opening a reset
# descriptor or doing any other work. Never offer a non-reset arm dry run.
case "$CMD" in
    arm)
        [ "$#" = 2 ] && [ "$2" = --yes-reset-this-machine ] || die "arm refused: requires <ordinary|elide-clwb> --yes-reset-this-machine (RESETS THE MACHINE)"
        [ "$(id -u)" = 0 ] || die "arm needs root via sudo (and --yes-reset-this-machine)"
        ;;
    prepare) [ "$#" = 1 ] || { usage; exit 2; } ;;
    verify) [ "$#" -le 1 ] || { usage; exit 2; } ;;
    help|-h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac
if [ "$CMD" = arm ]; then U=${PWROOT_USER:-${SUDO_USER:-}}; else
    [ "$(id -u)" != 0 ] || die "$CMD must run as the ordinary checkout owner, without sudo"
    U=$(id -un)
fi
[ -n "$U" ] && [ "$U" != root ] || die "set PWROOT_USER to the checkout's owner"
UID_RUN=$(id -u "$U"); GID_RUN=$(id -g "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
as_user() { setpriv --reuid="$UID_RUN" --regid="$GID_RUN" --init-groups -- env HOME="$UHOME" "$@"; }
[ "$(hostname -s)" = pc-ubuntu ] || die "this procedure is for pc-ubuntu (results tag sean-tan-PC)"
[ "$(findmnt -nro SOURCE,FSTYPE -T /)" = '/dev/nvme1n1p3 ext4' ] || die "/ must be ext4 on /dev/nvme1n1p3"
[ "$(findmnt -nro TARGET -T "$REPO")" = / ] || die "checkout/results must be on /, never /tmp"

provider() { case "$1" in ordinary|elide-clwb) ;; *) die "provider must be ordinary or elide-clwb" ;; esac; }
# State files are data, never shell-sourced; preserve spaces in region paths.
value() {
    local key=$1 file=$2
    awk -v k="$key" '$1 == k { n++; sub(/^[^ ]+ /, ""); v=$0 }
        END { if (n != 1 || v == "") exit 1; print v }' "$file" || die "missing/duplicate $key in $file"
}
number() { local n; n=$(value "$1" "$2") || return 2; [[ "$n" =~ ^[0-9]+$ ]] || die "invalid number $1"; say "$n"; }
boot_facts() {
    say "recorded $(date -uIseconds)"
    say "boot_id $(cat /proc/sys/kernel/random/boot_id)"
    uptime
    say "proc_uptime $(cat /proc/uptime)"
}
# Prefer NVMe's power_cycles/unsafe_shutdowns; report any readable sysfs
# equivalents if nvme-cli is absent. Do not substitute the Windows controller.
smart_facts() {
    say "recorded $(date -uIseconds)"
    if command -v nvme >/dev/null; then
        nvme smart-log /dev/nvme1 || die "nvme smart-log failed"
    else
        local f found=0
        say 'nvme CLI absent; looking for sysfs power-cycle/unsafe-shutdown counters'
        for f in /sys/class/nvme/nvme1/{power_cycles,unsafe_shutdowns} \
                 /sys/class/nvme/nvme1/device/{power_cycles,unsafe_shutdowns} \
                 /sys/block/nvme1n1/device/{power_cycles,unsafe_shutdowns}; do
            if [ -r "$f" ]; then say "$f $(cat "$f")"; found=1; fi
        done
        [ "$found" = 1 ] || say 'No sysfs equivalents exposed; install nvme-cli for these counters.'
    fi
}
smart_after_command() {
    say 'Record the post-reboot NVMe counters (redirection runs as your ordinary user):'
    if command -v nvme >/dev/null; then
        printf 'sudo nvme smart-log /dev/nvme1 > %q\n' "$OUT/verify-smart-after.txt"
    else
        # Exact read-only fallback when nvme-cli is unavailable.
        printf 'sudo sh -c %q > %q\n' 'found=0; for base in /sys/class/nvme/nvme1 /sys/class/nvme/nvme1/device /sys/block/nvme1n1/device; do for key in power_cycles unsafe_shutdowns; do f=$base/$key; if [ -r "$f" ]; then printf "%s " "$f"; cat "$f"; found=1; fi; done; done; [ "$found" = 1 ] || echo "No sysfs equivalents exposed; install nvme-cli and run sudo nvme smart-log /dev/nvme1"' "$OUT/verify-smart-after.txt"
    fi
}
verify_command() { printf '%q verify %q\n' "$REPO/scripts/desktop-reboot-check.sh" "$OUT"; }
select_run() {
    local selector=$1 pointer
    case "$selector" in
        ordinary|elide-clwb) pointer=$REPO/results/desktop-reboot-$selector.latest ;;
        '') pointer=$REPO/results/desktop-reboot.latest ;;
        *) OUT=$(realpath -e -- "$selector") || die "no such results directory"; pointer= ;;
    esac
    if [ -n "$pointer" ]; then
        [ -f "$pointer" ] || die "no prepare state: run prepare first"
        IFS= read -r OUT < "$pointer"
        OUT=$(realpath -e -- "$OUT") || die "prepared results directory is missing"
    fi
    case "$OUT" in "$REPO"/results/*-sean-tan-PC-desktop-reboot-*) ;; *) die "run must be in this checkout's desktop-reboot results" ;; esac
    [ -f "$OUT/prepared" ] && [ -f "$OUT/setup.state" ] || die "prepare did not complete"
    [ "$(value owner "$OUT/manifest.txt")" = "$U" ] || die "run belongs to another user"
    P=$(value provider "$OUT/manifest.txt"); provider "$P"
    if [ "$selector" = ordinary ] || [ "$selector" = elide-clwb ]; then
        [ "$selector" = "$P" ] || die "provider differs from prepare"
    fi
    D=$(value region_dir "$OUT/manifest.txt")
    D=$(realpath -e -- "$D") || die "region directory is missing"
    case "$D" in "$UHOME"/*) ;; *) die "region directory must be under $UHOME" ;; esac
    [ "$(findmnt -nro TARGET -T "$D")" = / ] || die "region must be on /"
    R=$(value region "$OUT/setup.state")
    [ -f "$R" ] && [ ! -L "$R" ] && [ "$(dirname -- "$R")" = "$D" ] || die "region is not a regular file in prepared directory"
    [ "$(value backend "$OUT/setup.state")" = file ] || die "prepared backend is not file"
    [ "$(number blocks "$OUT/setup.state")" = 512 ] && [ "$(number block_size "$OUT/setup.state")" = 4096 ] || die "unexpected geometry"
    [ -x "$BIN" ] || die "prepared binary missing; preserve/rebuild it before proceeding"
    [ "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$(value binary_sha256 "$OUT/manifest.txt")" ] || die "binary changed since prepare"
}

case "$CMD" in
    prepare)
        P=$1; provider "$P"
        make bin/pwreboot.x86-64-linux || die "could not build pwreboot"
        make -q bin/pwreboot.x86-64-linux || die "pwreboot is not up to date after make"
        mkdir -p "$REPO/results"
        OUT=$(mktemp -d "$REPO/results/$(date -u +%Y%m%dT%H%M%SZ)-sean-tan-PC-desktop-reboot-$P-XXXXXX")
        PARENT=$(realpath -m -- "${PWREBOOT_REGION_PARENT:-$UHOME/pwfile-reboot}")
        case "$PARENT" in "$UHOME"/*) ;; *) die "PWREBOOT_REGION_PARENT must be under $UHOME" ;; esac
        mkdir -p "$PARENT"
        [ "$(findmnt -nro TARGET -T "$PARENT")" = / ] || die "region parent must be on / (not tmpfs or another mount)"
        D=$(mktemp -d "$PARENT/$(basename "$OUT")-XXXXXX")
        {
            say "owner $U"
            say "provider $P"
            say "region_dir $D"
            say "commit $(git rev-parse HEAD)"
            say "binary_sha256 $(sha256sum "$BIN" | cut -d' ' -f1)"
            say "binary_make_q up-to-date (exit 0 after incremental make)"
            say "host $(hostname -s)"
            say "kernel $(uname -srmo)"
            sha256sum "$REPO/scripts/desktop-reboot-check.sh"
            say 'geometry 512 x 4096; setup 2 steps; arm 3 steps; reset fd 3'
            git status --short
        } > "$OUT/manifest.txt"
        cp -- "$REPO/scripts/desktop-reboot-check.sh" "$OUT/"
        boot_facts > "$OUT/prepare-boot.txt"
        {
            say 'State and region share the ext4 root on /dev/nvme1n1p3; /tmp is volatile tmpfs.'
            say 'There is no other writable disk filesystem available for a separate state filesystem.'
            say 'pwreboot StateFile.line fsyncs every line (test/pwreboot.main.v3:182-190).'
            say 'The final ack and summary share one fsync immediately before reset (lines 458-473).'
            say 'Inference: under data=ordered an fsync forces out only data blocks newly allocated in its transaction, so a state fsync could mask a mutant loss only if ext4 fell back to nodelalloc (low free space); heavy concurrent dirtying could mask one through background writeback instead.'
            say 'No sync is inserted after pwreboot starts arm. Preparation/arm metadata are synced beforehand.'
            say 'A warm reset keeps the device powered: this tests kernel/filesystem cache loss, not device-cache power-loss durability.'
        } > "$OUT/notes.txt"
        "$BIN" setup "$D" "$OUT/setup.state" file 512 4096 2 > "$OUT/setup.log" 2>&1 || die "setup failed; see $OUT/setup.log"
        grep -qx OK "$OUT/setup.log" || die "setup did not finish; see $OUT/setup.log"
        number setup_cursor "$OUT/setup.state" > /dev/null
        # The documented flushed control: sync the region filesystem before
        # selecting this run. All metadata must survive the unsynced reset.
        sync -f "$D"
        touch "$OUT/prepared"
        printf '%s\n' "$OUT" > "$REPO/results/desktop-reboot-$P.latest"
        printf '%s\n' "$OUT" > "$REPO/results/desktop-reboot.latest"
        sync -f "$OUT"
        say "prepared $P -> $OUT"
        say "region -> $D"
        say "Before arming, check that GRUB's default boot entry is Ubuntu."
        printf 'arm (RESETS THE MACHINE): sudo env PWROOT_USER=%q %q arm %q --yes-reset-this-machine\n' \
            "$U" "$REPO/scripts/desktop-reboot-check.sh" "$P"
        printf 'after reboot: '; verify_command
        ;;
    arm)
        select_run "$1"
        [ ! -e "$OUT/arm-before.txt" ] && [ ! -e "$OUT/arm.state" ] || die "run already armed/attempted; prepare a fresh region"
        [ -w /proc/sysrq-trigger ] || die "/proc/sysrq-trigger is not writable"
        # Root reads privileged facts; all output paths are opened as the owner.
        {
            boot_facts
            say '---- effective ext4 options'
            cat /proc/fs/ext4/nvme1n1p3/options
            say '---- Dirty/Writeback (kB)'
            awk '/^(Dirty|Writeback|WritebackTmp):/' /proc/meminfo
            say '---- vm.dirty_*'
            for f in /proc/sys/vm/dirty_*; do say "${f##*/} $(cat "$f")"; done
            say '---- df /'
            df /
        } | as_user tee "$OUT/arm-before.txt" > /dev/null
        smart_facts | as_user tee "$OUT/arm-smart-before.txt" > /dev/null
        as_user touch "$OUT/arm.log"
        sync -f "$OUT"
        say 'WARNING: this immediately RESETS pc-ubuntu without syncing or unmounting.'
        say 'Save work and close applications first. All filesystems remain at risk.'
        say "Check that GRUB's default boot entry is Ubuntu before arming."
        say "provider $P; region $R; state $OUT/arm.state"
        printf 'After the machine returns, run exactly: '; verify_command
        say 'The device stays powered; this is not a device-cache power-loss test.'
        # All values are positional shell arguments, never interpolated code.
        # Root opens only fd 3; pwreboot itself runs as the owner. The program
        # requests reset just after its final state fsync; nothing syncs after it.
        USER_LOG_EXEC='log=$1; shift; exec "$@" > "$log" 2>&1'
        exec sh -c 'exec 3>/proc/sysrq-trigger && exec setpriv --reuid="$1" --regid="$2" --init-groups -- env HOME="$7" sh -c "$9" sh "$8" "$3" arm "$4" "$5" file "$6" 512 4096 3 3' \
            sh "$UID_RUN" "$GID_RUN" "$BIN" "$R" "$OUT/arm.state" "$P" "$UHOME" "$OUT/arm.log" "$USER_LOG_EXEC"
        ;;
    verify)
        select_run "${1:-}"
        smart_after_command
        [ -f "$OUT/arm-before.txt" ] && [ -f "$OUT/arm.state" ] || die "no arm state; arm must run first"
        [ ! -e "$OUT/verify.log" ] || die "already verified; recovery modifies the image, so preserve the first verdict"
        boot_facts > "$OUT/verify-boot.txt"
        [ "$(value boot_id "$OUT/arm-before.txt")" != "$(cat /proc/sys/kernel/random/boot_id)" ] || die "boot id has not changed; no reset has occurred"
        [ "$(value provider "$OUT/arm.state")" = "$P" ] || die "arm provider differs from prepare"
        SC=$(number setup_cursor "$OUT/setup.state")
        AC=$(number acked_cursor "$OUT/arm.state")
        AN=$(number acked_count "$OUT/arm.state")
        [ "$AC" -gt "$SC" ] || die "arm acknowledged no progress"
        # Verification mounts and recovers; retain the exact pre-recovery bytes.
        cp --reflink=never -- "$R" "$OUT/region-before-verify.img"
        rc=0
        "$BIN" verify "$R" file 512 4096 "$SC" "$AC" "$AN" > "$OUT/verify.log" 2>&1 || rc=$?
        boot_facts > "$OUT/verify-after.txt"
        {
            say "---- $P kernel-reset verification"
            say "pwreboot exit $rc (0 SURVIVED; 1 LOST; 3 INVALID; other codes are errors)"
            cat "$OUT/verify.log"
            say '---- limits'
            cat "$OUT/notes.txt"
        } | tee "$OUT/summary.txt"
        sync -f "$OUT"
        exit "$rc"
        ;;
esac
