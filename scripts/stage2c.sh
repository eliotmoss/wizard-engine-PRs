#!/usr/bin/env bash
#
# Stage 2c: cache-loss sensitivity across a warm reboot. Runbook and host setup
# are in docs/stage2c-handoff.md; the argument is in docs/pmem-emulation.md.
#
#   scripts/stage2c.sh doctor                 check this host can run the experiment
#   scripts/stage2c.sh probe                  arm the direct sensitivity probe
#   scripts/stage2c.sh sieve <ordinary|elide-clwb>
#                                             arm the sieve with either provider
#   scripts/stage2c.sh verify                 after the reboot: verify the armed run
#   scripts/stage2c.sh status                 show the armed run, if any
#   scripts/stage2c.sh abandon                forget the armed run without verifying
#
# One run is armed at a time. Arming writes the evidence and a pointer to it,
# then asks for the reboot; after the machine comes back, `verify` finds the
# pointer, copies the raw image into the results directory before anything
# mounts it, and records the verdict.
#
# Two rules this script exists to enforce:
#   - A sysrq reboot does not sync disks, so everything this script needs after
#     the reboot is written and synced *before* it asks for one -- but only with
#     `sync -f` on the results filesystem. A plain `sync` would also sync the
#     DAX filesystem, which could write back exactly the cache lines under test.
#   - The results directory must not be on the DAX filesystem, which lives in
#     reserved DRAM and is erased by any cold boot.
#
# Environment:
#   STAGE2C_DAX_DIR      directory on the fsdax mount backed by memmap (required)
#   STAGE2C_BACKEND      pmem (default); file is a plumbing dry run only, and
#                        verifies without a reboot
#   STAGE2C_PROBE_BYTES  probe file size (2097152)
#   STAGE2C_BLOCKS, STAGE2C_BLOCKSIZE   sieve region geometry (512, 4096)
#   STAGE2C_SETUP_STEPS, STAGE2C_ARM_STEPS   sieve steps before and during arming (2, 3)
#   STAGE2C_REBOOT       prompt (default: offer to run the reboot via sudo) or print
#   STAGE2C_ALLOW_DIRTY  1 to run from a dirty working tree (0)
#   STAGE2C_OUT_ROOT     where results directories go ($REPO/results)

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

BIN=bin/pwreboot.x86-64-linux
DAX_DIR="${STAGE2C_DAX_DIR:-}"
BACKEND="${STAGE2C_BACKEND:-pmem}"
PROBE_BYTES="${STAGE2C_PROBE_BYTES:-2097152}"
BLOCKS="${STAGE2C_BLOCKS:-512}"
BLOCKSIZE="${STAGE2C_BLOCKSIZE:-4096}"
SETUP_STEPS="${STAGE2C_SETUP_STEPS:-2}"
ARM_STEPS="${STAGE2C_ARM_STEPS:-3}"
REBOOT_MODE="${STAGE2C_REBOOT:-prompt}"
OUT_ROOT="${STAGE2C_OUT_ROOT:-$REPO/results}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pwasm-stage2c"
PENDING="$STATE_DIR/pending"
REBOOT_CMD="sudo sh -c 'echo b > /proc/sysrq-trigger'"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
rule() { printf -- '---- %s\n' "$*"; }

# syncfs on the filesystem holding $1 only. Never a plain sync; see above.
sync_fs_of() { sync -f "$1"; }

fs_dev() { stat -c %d "$1"; }
mount_opts() { findmnt -no OPTIONS -T "$1" 2>/dev/null || true; }
mount_src() { findmnt -no SOURCE -T "$1" 2>/dev/null || true; }
boot_id() { cat /proc/sys/kernel/random/boot_id; }
virt() { if have systemd-detect-virt; then systemd-detect-virt 2>/dev/null || true; else echo unknown; fi; }
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# ----------------------------------------------------------------- checks

# The conditions under which a pmem result means what the thesis says it
# means. Returns the problems found, one per line; empty means runnable.
host_problems() {
    [ -n "$DAX_DIR" ] || { echo "STAGE2C_DAX_DIR is not set"; return; }
    [ -d "$DAX_DIR" ] || { echo "STAGE2C_DAX_DIR is not a directory: $DAX_DIR"; return; }
    [ -w "$DAX_DIR" ] || echo "STAGE2C_DAX_DIR is not writable: $DAX_DIR"
    [ "$BACKEND" = pmem ] || return 0
    mkdir -p "$OUT_ROOT"
    [ "$(fs_dev "$DAX_DIR")" != "$(fs_dev "$OUT_ROOT")" ] ||
        echo "the results directory is on the same filesystem as STAGE2C_DAX_DIR; it would be lost with the reserved memory"
    if is_wsl; then echo "this is WSL: a guest reset never discards the host's CPU caches"; fi
    local v; v=$(virt)
    case "$v" in none) ;; *) echo "virtualisation detected ($v): a guest reset never discards the host's CPU caches" ;; esac
    grep -q 'memmap=' /proc/cmdline || echo "no memmap= on the kernel command line: this is not a reserved-DRAM host"
    case "$(mount_opts "$DAX_DIR")" in *dax*) ;; *) echo "STAGE2C_DAX_DIR is not on a dax mount" ;; esac
    case "$(mount_src "$DAX_DIR")" in /dev/pmem*) ;; *) echo "STAGE2C_DAX_DIR is not backed by /dev/pmem*" ;; esac
    grep -qw clwb /proc/cpuinfo || grep -qw clflushopt /proc/cpuinfo || echo "the CPU reports neither clwb nor clflushopt"
}

require_clean_tree() {
    [ "${STAGE2C_ALLOW_DIRTY:-0}" = 1 ] && return 0
    git diff --quiet && git diff --cached --quiet && return 0
    die "working tree is dirty; commit first so the results name a revision, or set STAGE2C_ALLOW_DIRTY=1"
}

require_runnable() {
    local problems; problems=$(host_problems)
    [ -z "$problems" ] || { warn "$problems"; die "this host cannot run the experiment (scripts/stage2c.sh doctor)"; }
    [ "$(id -u)" != 0 ] || die "run as your ordinary user; only the reboot needs root"
    [ ! -e "$PENDING" ] || die "a run is already armed ($(cat "$PENDING")); verify or abandon it first"
    make "$BIN" >/dev/null || die "could not build $BIN"
}

# ------------------------------------------------------------- provenance

write_provenance() {
    local f=$1/provenance.txt
    {
        rule "revision"
        git log -1 --pretty='commit %H%nsubject  %s'
        printf 'dirty    %s\n' "$(git diff --quiet && git diff --cached --quiet && echo no || echo YES)"
        rule "host"
        printf 'hostname %s\n' "$(hostname)"
        printf 'kernel   %s\n' "$(uname -srmo)"
        printf 'cmdline  %s\n' "$(cat /proc/cmdline)"
        printf 'virt     %s\n' "$(virt)"
        printf 'boot_id  %s\n' "$(boot_id)"
        printf 'armed    %s\n' "$(date -uIseconds)"
        rule "cpu"
        if have lscpu; then lscpu | grep -Ei 'model name|^cpu\(s\)|cache' || true; fi
        printf 'clwb     %s\n' "$(grep -qw clwb /proc/cpuinfo && echo yes || echo no)"
        rule "media"
        printf 'dax dir  %s\n  source %s\n  options %s\n' "$DAX_DIR" "$(mount_src "$DAX_DIR")" "$(mount_opts "$DAX_DIR")"
        rule "kernel settings"
        for k in kernel/sysrq vm/dirty_writeback_centisecs vm/dirty_expire_centisecs; do
            printf '%-32s %s\n' "$k" "$(cat /proc/sys/$k 2>/dev/null || echo '?')"
        done
        rule "parameters"
        printf 'backend %s\n' "$BACKEND"
    } > "$f"
}

new_out() {
    local kind=$1
    local out="$OUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$(hostname -s)-stage2c-$kind"
    [ "$BACKEND" = pmem ] || out="$out-DRYRUN"
    mkdir -p "$OUT_ROOT"
    # Never reuse a directory: two runs armed within the same second would
    # otherwise write into one, and the second would overwrite the evidence.
    local n=1 try=$out
    until mkdir "$try" 2>/dev/null; do
        n=$((n + 1)); try="$out-$n"
        [ "$n" -le 20 ] || die "could not create a fresh results directory under $OUT_ROOT"
    done
    echo "$try"
}

# Record the pointer, sync the results filesystem, then ask for the reboot.
# Nothing may touch the DAX filesystem between arming and the reboot.
finish_arming() {
    local out=$1 kind=$2
    printf 'armed_unix %s\n' "$(date +%s.%N)" >> "$out/provenance.txt"
    mkdir -p "$STATE_DIR"
    printf '%s %s\n' "$kind" "$out" > "$PENDING"
    sync_fs_of "$out"
    sync_fs_of "$PENDING"
    say ""
    if [ "$BACKEND" != pmem ]; then
        say "DRY RUN armed ($kind). No reboot is needed: run  scripts/stage2c.sh verify"
        return
    fi
    say "ARMED ($kind). Reboot now, and do nothing else on this machine first:"
    say ""
    say "    $REBOOT_CMD"
    say ""
    say "After it comes back: mount the DAX filesystem if fstab does not, then run"
    say "    scripts/stage2c.sh verify"
    if [ "$REBOOT_MODE" = prompt ] && [ -t 0 ]; then
        say ""
        read -r -p "Press Enter to reboot now via sudo, or Ctrl-C to reboot yourself: " _
        eval "$REBOOT_CMD"
    fi
}

# ------------------------------------------------------------------- arming

probe() {
    require_clean_tree
    require_runnable
    local out; out=$(new_out probe)
    write_provenance "$out"
    printf 'probe bytes %s\n' "$PROBE_BYTES" >> "$out/provenance.txt"
    say "arming the sensitivity probe -> $out"
    "$BIN" probe-arm "$DAX_DIR" "$out/probe.state" "$BACKEND" "$PROBE_BYTES" | tee "$out/arm.log"
    grep -q '^READY$' "$out/arm.log" || die "probe-arm did not report READY; see $out/arm.log"
    finish_arming "$out" probe
}

sieve() {
    local provider=${1:-}
    case "$provider" in ordinary|elide-clwb) ;; *) die "usage: scripts/stage2c.sh sieve <ordinary|elide-clwb>" ;; esac
    require_clean_tree
    require_runnable
    local out; out=$(new_out "sieve-$provider")
    write_provenance "$out"
    printf 'provider %s\ngeometry %sx%s\nsetup steps %s\narm steps %s\n' \
        "$provider" "$BLOCKS" "$BLOCKSIZE" "$SETUP_STEPS" "$ARM_STEPS" >> "$out/provenance.txt"
    say "setup (production provider, clean close) -> $out"
    "$BIN" setup "$DAX_DIR" "$out/setup.state" "$BACKEND" "$BLOCKS" "$BLOCKSIZE" "$SETUP_STEPS" | tee "$out/setup.log"
    grep -q '^OK$' "$out/setup.log" || die "setup failed; see $out/setup.log"
    # Safe here and only here: setup closed cleanly with the production
    # provider, so nothing is deliberately left unflushed yet. This makes the
    # new file's metadata durable before the experiment starts.
    sync_fs_of "$DAX_DIR"
    local region; region=$(awk '$1 == "region" { print $2 }' "$out/setup.state")
    say "arming with the $provider provider"
    "$BIN" arm "$region" "$out/arm.state" "$BACKEND" "$provider" "$BLOCKS" "$BLOCKSIZE" "$ARM_STEPS" | tee "$out/arm.log"
    grep -q '^READY$' "$out/arm.log" || die "arm did not report READY; see $out/arm.log"
    finish_arming "$out" "sieve-$provider"
}

# ------------------------------------------------------------------ verify

state_value() { awk -v k="$2" '$1 == k { print $2 }' "$1"; }

verify() {
    [ -e "$PENDING" ] || die "no run is armed"
    local kind out; read -r kind out < "$PENDING"
    [ -d "$out" ] || die "the armed run's results directory is missing: $out (lost in the reboot?)"
    local armed_boot; armed_boot=$(awk '$1 == "boot_id" { print $2 }' "$out/provenance.txt")
    # The backend the run was armed with, not whatever this shell has set.
    local armed_backend; armed_backend=$(awk '$1 == "backend" { print $2 }' "$out/provenance.txt")
    local rebooted=yes
    [ "$armed_boot" != "$(boot_id)" ] || rebooted=no
    if [ "$rebooted" = no ] && [ "$armed_backend" = pmem ]; then
        die "this is the same boot the run was armed in; reboot first (or abandon the run)"
    fi
    {
        rule "verify"
        printf 'verified %s\nboot_id  %s\nrebooted %s\n' "$(date -uIseconds)" "$(boot_id)" "$rebooted"
        printf 'booted_unix %s\n' "$(awk '$1 == "btime" { print $2 }' /proc/stat)"
    } >> "$out/provenance.txt"

    local img code
    if [ "$kind" = probe ]; then
        local f; f=$(state_value "$out/probe.state" probe_file)
        [ -e "$f" ] || die "the probe file is gone: $f (is the DAX filesystem mounted?)"
        cp --sparse=never "$f" "$out/probe.img"
        img=$out/probe.img
        set +e
        "$BIN" probe-verify "$img" "$(state_value "$out/probe.state" bytes)" \
            "$(state_value "$out/probe.state" nonce)" | tee "$out/verify.log"
        code=${PIPESTATUS[0]}
        set -e
        rm -f "$f"
    else
        local region; region=$(state_value "$out/setup.state" region)
        [ -e "$region" ] || die "the region file is gone: $region (is the DAX filesystem mounted?)"
        # Evidence first: the verifier mounts and recovers, which changes the file.
        cp --sparse=never "$region" "$out/pre-recovery.img"
        set +e
        "$BIN" verify "$region" "$(state_value "$out/setup.state" backend)" \
            "$(state_value "$out/setup.state" blocks)" "$(state_value "$out/setup.state" block_size)" \
            "$(state_value "$out/setup.state" setup_cursor)" \
            "$(state_value "$out/arm.state" acked_cursor)" "$(state_value "$out/arm.state" acked_count)" \
            | tee "$out/verify.log"
        code=${PIPESTATUS[0]}
        set -e
        rm -f "$region"
    fi
    sha256sum "$out"/*.img > "$out/images.sha256"
    rm -f "$PENDING"
    sync_fs_of "$out"
    say ""
    say "verdict for $kind: $(awk '$1 == "verdict" { print $2 }' "$out/verify.log")  (exit $code)"
    say "results in $out"
    [ "$rebooted" = yes ] || say "NOTE: no reboot happened; this is a plumbing check, not a result."
}

# --------------------------------------------------------------- doctor etc.

doctor() {
    rule "revision"
    git log -1 --pretty='%h %s'
    git diff --quiet && git diff --cached --quiet && say "tree clean" || warn "tree DIRTY"
    rule "host"
    printf 'kernel  %s\nvirt    %s\nwsl     %s\n' "$(uname -r)" "$(virt)" "$(is_wsl && echo yes || echo no)"
    printf 'cmdline %s\n' "$(cat /proc/cmdline)"
    rule "cpu"
    if have lscpu; then lscpu | grep -Ei 'model name|L3' || true; fi
    printf 'clwb %s, clflushopt %s\n' "$(grep -qw clwb /proc/cpuinfo && echo yes || echo no)" \
        "$(grep -qw clflushopt /proc/cpuinfo && echo yes || echo no)"
    rule "pmem devices"
    ls -l /dev/pmem* 2>/dev/null || say "(none)"
    rule "dax dir (STAGE2C_DAX_DIR)"
    if [ -n "$DAX_DIR" ]; then
        printf '%s\n  source  %s\n  options %s\n' "$DAX_DIR" "$(mount_src "$DAX_DIR")" "$(mount_opts "$DAX_DIR")"
    else
        say "(unset)"
    fi
    rule "kernel settings"
    for k in kernel/sysrq vm/dirty_writeback_centisecs vm/dirty_expire_centisecs; do
        printf '%-32s %s\n' "$k" "$(cat /proc/sys/$k 2>/dev/null || echo '?')"
    done
    rule "armed run"
    if [ -e "$PENDING" ]; then cat "$PENDING"; else say "(none)"; fi
    rule "verdict (backend $BACKEND)"
    local problems; problems=$(host_problems)
    if [ -z "$problems" ]; then say "runnable"; else warn "$problems"; fi
}

status() { if [ -e "$PENDING" ]; then cat "$PENDING"; else say "no run is armed"; fi; }

abandon() {
    [ -e "$PENDING" ] || { say "no run is armed"; return; }
    say "forgetting $(cat "$PENDING") (its results directory is kept)"
    say "any region or probe file it created stays in STAGE2C_DAX_DIR; remove it by hand if unwanted"
    rm -f "$PENDING"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

case "${1:-doctor}" in
    doctor)  doctor ;;
    probe)   probe ;;
    sieve)   shift; sieve "${1:-}" ;;
    verify)  verify ;;
    status)  status ;;
    abandon) abandon ;;
    help|-h|--help) usage ;;
    *)       usage; exit 2 ;;
esac
