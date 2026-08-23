#!/usr/bin/env bash
#
# Provision and drive a QEMU virtual machine with an emulated NVDIMM, so that
# the opt-in PMEM/DAX integration tests can run on a host without persistent
# memory. See docs/pmem-emulation.md for the design and the evidence limits.
#
#   scripts/pmem-vm.sh doctor     report host support and missing host tools
#   scripts/pmem-vm.sh setup      one-time: fetch image, build VM, configure DAX
#   scripts/pmem-vm.sh start      boot detached, wait for SSH, mount, report
#   scripts/pmem-vm.sh status     report VM, namespace, block device, mount
#   scripts/pmem-vm.sh ssh [cmd]  shell (or one command) in the guest
#   scripts/pmem-vm.sh sync       rebuild the test binary and copy it in
#   scripts/pmem-vm.sh test       run the PMEM integration tests in the guest
#   scripts/pmem-vm.sh stop       clean shutdown
#   scripts/pmem-vm.sh kill       abrupt kill, for crash-consistency experiments
#   scripts/pmem-vm.sh console    tail the guest serial log
#   scripts/pmem-vm.sh reseed     rebuild the cloud-init seed and reboot
#   scripts/pmem-vm.sh destroy    delete the VM directory (asks first)
#
# The VM lives outside the repository, by default in
# ~/.local/share/wizard-pmem-vm. Override with PMEMVM_DIR. Other overrides:
# PMEMVM_SSH_PORT, PMEMVM_RAM, PMEMVM_CPUS, PMEMVM_BOOT_TIMEOUT,
# PMEMVM_LOGIN_GRACE, PMEMVM_IMAGE_URL, PMEMVM_DISK_SIZE,
# PMEMVM_PMEM_SIZE (setup only).
#
# The guest is always x86-64 Linux, because the backend under test is
# x86-64-specific. On an x86-64 Linux host this runs under KVM; on an
# Apple-silicon Mac it runs under TCG emulation, which is correct but slow.

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="${PMEMVM_DIR:-$HOME/.local/share/wizard-pmem-vm}"

BASE_IMG_URL="${PMEMVM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
BASE_IMG="$VM_DIR/base-cloudimg.img"
GUEST_IMG="$VM_DIR/guest.qcow2"
PMEM_IMG="$VM_DIR/wizard-pmem.img"
SEED_ISO="$VM_DIR/seed.iso"
SSH_KEY="$VM_DIR/ssh_key"
KNOWN_HOSTS="$VM_DIR/known_hosts"
PID_FILE="$VM_DIR/qemu.pid"
SERIAL_LOG="$VM_DIR/serial.log"
GEOMETRY="$VM_DIR/geometry"

SSH_PORT="${PMEMVM_SSH_PORT:-2222}"
# How long after the guest's login prompt to keep waiting for sshd. Generous for
# emulation, where the last cloud-init stages still run after the prompt appears.
LOGIN_GRACE="${PMEMVM_LOGIN_GRACE:-240}"
GUEST_USER="${PMEMVM_USER:-ubuntu}"
GUEST_RAM="${PMEMVM_RAM:-4G}"
DISK_SIZE="${PMEMVM_DISK_SIZE:-20G}"
PMEM_SIZE="${PMEMVM_PMEM_SIZE:-2G}"
MOUNT_POINT=/mnt/pmem
SCRATCH_DIR=$MOUNT_POINT/wizard
TEST_BIN=pmemtest.x86-64-linux

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- host support

# Acceleration is a host property: KVM on x86-64 Linux, HVF on an Intel Mac,
# and plain TCG emulation everywhere else -- notably on Apple silicon, where the
# guest architecture does not match the host and no hypervisor can help.
detect_host() {
    HOST_OS=$(uname -s)
    HOST_ARCH=$(uname -m)
    EMULATED=1
    case "$HOST_OS" in
        Linux)
            if [ "$HOST_ARCH" = x86_64 ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
                ACCEL_ARGS=(-accel kvm -cpu host); EMULATED=0; ACCEL_NAME=kvm
            elif [ "$HOST_ARCH" = x86_64 ]; then
                ACCEL_ARGS=(-accel tcg -cpu max); ACCEL_NAME="tcg (no /dev/kvm access)"
            else
                ACCEL_ARGS=(-accel tcg -cpu max); ACCEL_NAME="tcg (non-x86-64 host)"
            fi ;;
        Darwin)
            if [ "$HOST_ARCH" = x86_64 ]; then
                ACCEL_ARGS=(-accel hvf -cpu host); EMULATED=0; ACCEL_NAME=hvf
            else
                ACCEL_ARGS=(-accel tcg -cpu max); ACCEL_NAME="tcg (Apple silicon emulating x86-64)"
            fi ;;
        *)
            ACCEL_ARGS=(-accel tcg -cpu max); ACCEL_NAME="tcg ($HOST_OS)" ;;
    esac

    if [ "$EMULATED" = 0 ]; then
        GUEST_CPUS="${PMEMVM_CPUS:-4}"
        BOOT_TIMEOUT="${PMEMVM_BOOT_TIMEOUT:-180}"
    else
        GUEST_CPUS="${PMEMVM_CPUS:-2}"
        BOOT_TIMEOUT="${PMEMVM_BOOT_TIMEOUT:-1500}"
    fi
}

install_hint() {
    case "$HOST_OS" in
        Darwin) say "  brew install qemu" ;;
        Linux)  say "  sudo apt install qemu-system-x86 qemu-utils cloud-image-utils" ;;
        *)      say "  install QEMU with x86-64 system emulation" ;;
    esac
}

check_host_tools() {
    local missing=0
    for tool in qemu-system-x86_64 qemu-img ssh scp ssh-keygen; do
        have "$tool" || { warn "missing host tool: $tool"; missing=1; }
    done
    have curl || have wget || { warn "missing host tool: curl or wget"; missing=1; }
    seed_tool >/dev/null || { warn "no ISO builder found (cloud-localds, xorriso, mkisofs, genisoimage, or hdiutil)"; missing=1; }
    [ "$missing" = 0 ] || { install_hint; die "install the tools above and re-run"; }
}

# QEMU registers the `pmem` property on memory-backend-file only when it was
# built against libpmem (PMDK), and PMDK is Linux-only -- Homebrew's macOS QEMU
# has no such property and rejects the entire -object argument with
# "Invalid parameter 'pmem'". Off is the default behaviour, so where the
# property is absent, omitting it is equivalent: QEMU flushes the backing file
# with msync rather than with libpmem's persist.
qemu_has_pmem_prop() {
    qemu-system-x86_64 -machine none -object memory-backend-file,help 2>&1 \
        | grep -q '^[[:space:]]*pmem='
}

# cloud-init reads its configuration from a small ISO. Every platform spells
# building one differently; take whichever tool exists.
seed_tool() {
    for t in cloud-localds xorriso mkisofs genisoimage hdiutil; do
        have "$t" && { printf '%s' "$t"; return 0; }
    done
    return 1
}

doctor() {
    detect_host
    say "host:        $HOST_OS $HOST_ARCH"
    say "guest:       x86-64 Linux (fixed: the backend under test is x86-64)"
    say "accel:       $ACCEL_NAME"
    [ "$EMULATED" = 0 ] || say "             emulated -- expect slow boots (timeout ${BOOT_TIMEOUT}s)"
    say "qemu:        $(have qemu-system-x86_64 && qemu-system-x86_64 --version | head -1 || echo MISSING)"
    if have qemu-system-x86_64; then
        say "pmem prop:   $(qemu_has_pmem_prop && echo 'supported (libpmem)' \
            || echo 'absent (no libpmem; pmem=off omitted, msync flushes instead)')"
    fi
    say "seed tool:   $(seed_tool || echo MISSING)"
    say "repo:        $REPO"
    say "vm dir:      $VM_DIR$([ -d "$VM_DIR" ] && echo '' || echo ' (not created yet)')"
    say "ssh port:    $SSH_PORT"
    check_host_tools
    say "host tools:  ok"
}

# ------------------------------------------------------------------ ssh access

ssh_args() {
    SSH_COMMON=(-o "StrictHostKeyChecking=accept-new" -o "UserKnownHostsFile=$KNOWN_HOSTS")
    # A VM created by this script has its own key; a directory adopted from an
    # earlier manual setup may not, so fall back to the agent's default keys.
    if [ -f "$SSH_KEY" ]; then
        SSH_COMMON+=(-o "IdentitiesOnly=yes" -i "$SSH_KEY")
    fi
    SSH_OPTS=(-p "$SSH_PORT" "${SSH_COMMON[@]}")
    SSH_BATCH=("${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5)
    SCP_BATCH=(-P "$SSH_PORT" "${SSH_COMMON[@]}" -o BatchMode=yes -o ConnectTimeout=5)
}

gssh()   { ssh "${SSH_BATCH[@]}" "$GUEST_USER@localhost" "$@"; }
ssh_up() { gssh true >/dev/null 2>&1; }

# The serial log tells "still booting" apart from "booted, and sshd is dead":
# the getty prompt is the last thing a finished boot prints.
guest_reached_login() { grep -q 'login:' "$SERIAL_LOG" 2>/dev/null; }

report_dead_sshd() {
    local n
    n=$(grep -c 'Failed to start.*ssh\.service' "$SERIAL_LOG" 2>/dev/null || true)
    n=${n// /}; [ -n "$n" ] || n=0
    warn ""
    warn "The guest reached its login prompt, but nothing answers ssh on port 22."
    if [ "$n" != 0 ]; then
        warn "  ssh.service failed to start $n time(s) during this boot; systemd"
        warn "  gives a unit five restarts before it gives up for the whole boot."
    fi
    warn "The usual cause is that the guest has no sshd host keys yet. Repair with:"
    warn "  scripts/pmem-vm.sh reseed"
    warn "which rebuilds the cloud-init seed -- its bootcmd creates the missing host"
    warn "keys and restores the ssh.socket listener -- and reboots into it."
}

# ------------------------------------------------------------------- vm control

vm_pid() {
    local pid=""
    [ -f "$PID_FILE" ] && pid=$(cat "$PID_FILE" 2>/dev/null || true)
    # Adopt a QEMU started by hand: match this VM's NVDIMM backing file.
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        pid=$(pgrep -f "mem-path=$PMEM_IMG" 2>/dev/null | head -1 || true)
    fi
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

# The NVDIMM geometry must not drift between boots: the namespace definition
# stored in the image's label area was sized for the device it was created on.
pmem_size_for_boot() {
    if [ -f "$GEOMETRY" ]; then
        local recorded
        recorded=$(sed -n 's/^pmem_size=//p' "$GEOMETRY" | head -1)
        if [ -n "$recorded" ]; then
            if [ -n "${PMEMVM_PMEM_SIZE:-}" ] && [ "$PMEMVM_PMEM_SIZE" != "$recorded" ]; then
                warn "ignoring PMEMVM_PMEM_SIZE=$PMEMVM_PMEM_SIZE: this VM's namespace was made for $recorded"
            fi
            printf '%s' "$recorded"; return 0
        fi
    fi
    printf '%s' "$PMEM_SIZE"
}

start_vm() {
    detect_host; ssh_args
    [ -f "$GUEST_IMG" ] || die "no VM in $VM_DIR; run: scripts/pmem-vm.sh setup"
    [ -f "$PMEM_IMG" ]  || die "missing NVDIMM backing file: $PMEM_IMG"
    local seed size
    size=$(pmem_size_for_boot)
    seed="$SEED_ISO"
    [ -f "$seed" ] || seed="$VM_DIR/seed.img"   # adopted manual setups

    if vm_pid >/dev/null; then
        say "already running (pid $(vm_pid))"
    else
        rm -f "$PID_FILE"
        local drives=(-drive "if=virtio,file=$GUEST_IMG,format=qcow2")
        [ -f "$seed" ] && drives+=(-drive "if=virtio,file=$seed,format=raw")
        local backend="memory-backend-file,id=pmem0,share=on,mem-path=$PMEM_IMG,size=$size,align=128M"
        if qemu_has_pmem_prop; then backend+=",pmem=off"; fi
        qemu-system-x86_64 \
            -machine q35,nvdimm=on "${ACCEL_ARGS[@]}" -smp "$GUEST_CPUS" \
            -m "$GUEST_RAM",slots=4,maxmem=16G \
            -object "$backend" \
            -device nvdimm,id=nvdimm0,memdev=pmem0,label-size=2M \
            "${drives[@]}" \
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22" \
            -device virtio-net-pci,netdev=n0 \
            -display none -serial "file:$SERIAL_LOG" \
            -pidfile "$PID_FILE" -daemonize
        say "booting with $ACCEL_NAME (pid $(cat "$PID_FILE")), serial log: $SERIAL_LOG"
        [ "$EMULATED" = 0 ] || say "emulated boot: this takes minutes, not seconds"
    fi

    printf 'waiting for ssh on port %s' "$SSH_PORT"
    local waited=0 login_at=-1
    until ssh_up; do
        vm_pid >/dev/null || { printf '\n'; die "QEMU exited during boot; see $SERIAL_LOG"; }
        if [ "$login_at" -lt 0 ] && guest_reached_login; then login_at=$waited; fi
        # The login prompt ends the boot. Sitting out the rest of a 25-minute
        # emulated-boot budget after that teaches nothing: sshd is not coming.
        if [ "$login_at" -ge 0 ] && [ $((waited - login_at)) -ge "$LOGIN_GRACE" ]; then
            printf '\n'; report_dead_sshd; die "no sshd in the guest; see $SERIAL_LOG"
        fi
        [ "$waited" -lt "$BOOT_TIMEOUT" ] || {
            printf '\n'
            guest_reached_login && report_dead_sshd
            die "no ssh after ${BOOT_TIMEOUT}s; see $SERIAL_LOG"
        }
        sleep 5; waited=$((waited + 5)); printf '.'
    done
    printf ' up after %ss\n' "$waited"
}

stop_vm() {
    ssh_args
    local pid
    pid=$(vm_pid) || { say "already stopped"; return 0; }
    if ssh_up; then
        say "sending poweroff"
        gssh "sudo systemctl poweroff" >/dev/null 2>&1 || true
    else
        warn "ssh unreachable; terminating QEMU"
        kill "$pid" 2>/dev/null || true
    fi
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$waited" -lt 120 ] || { warn "still alive after 120s; use: scripts/pmem-vm.sh kill"; return 1; }
        sleep 2; waited=$((waited + 2))
    done
    rm -f "$PID_FILE"
    say "stopped cleanly after ${waited}s"
}

# Abrupt termination, for the Stage 2 crash-consistency experiments. kill -9
# returns before the kernel tears the process down, and QEMU holds a write lock
# on the guest image until it does, so wait the exit out here: otherwise the
# next start fails with 'Failed to get "write" lock'.
kill_vm() {
    local pid
    pid=$(vm_pid) || { say "not running"; return 0; }
    kill -9 "$pid"
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$waited" -lt 30 ] || { warn "pid $pid still present after 30s"; break; }
        sleep 1; waited=$((waited + 1))
    done
    rm -f "$PID_FILE"
    say "killed pid $pid without shutdown (region file left mid-flight)"
}

# ------------------------------------------------------------------ provisioning

fetch_base_image() {
    [ -f "$BASE_IMG" ] && { say "base image present"; return 0; }
    say "downloading $BASE_IMG_URL"
    if have curl; then
        curl -fL --progress-bar -o "$BASE_IMG.part" "$BASE_IMG_URL"
    else
        wget -O "$BASE_IMG.part" "$BASE_IMG_URL"
    fi
    mv "$BASE_IMG.part" "$BASE_IMG"
}

make_seed() {
    local src="$VM_DIR/seed-src"
    rm -rf "$src"; mkdir -p "$src"
    printf 'instance-id: wizard-pmem\nlocal-hostname: pmemvm\n' > "$src/meta-data"
    cat > "$src/user-data" <<EOF
#cloud-config
hostname: pmemvm
users:
  - name: $GUEST_USER
    sudo:
      - "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")
# The cloud image ships without sshd host keys -- cloud-init writes them part
# way through the boot -- and Ubuntu 24.04 activates sshd from ssh.socket. Under
# emulation the first connection lands before the keys exist, so the activated
# ssh.service exits with "sshd: no hostkeys available", and systemd allows a
# unit only five restarts before it stops trying: sshd is then down for the rest
# of the boot, however long the host waits. bootcmd runs on every boot and
# finishes before sockets.target, which is early enough to close the race:
# create the missing host keys, clear a start limit latched by an earlier boot,
# and make sure the listener is in place. It runs inside cloud-init.service,
# which sysinit.target waits for, so nothing here may block on a systemd job: a
# plain systemctl start (no --no-block) waits for a job that is itself ordered
# after sysinit.target and deadlocks the boot. Backquotes are just as
# dangerous in this heredoc -- the host shell would run them at seed time.
bootcmd:
  # cloud-init 26.1 has been seen to leave /etc/sudoers.d/90-cloud-init-users
  # empty, giving the user above no sudo rights at all; a clean first boot of
  # this same seed writes it correctly, so it is a first-boot race rather than a
  # certainty. Either way the users module is once-per-instance, so a VM that
  # lands wrong can never repair itself, and everything this script does in the
  # guest (ndctl, mkfs, mount) is sudo. Write the rule directly as well,
  # syntax-checked. No new authority: it is the rule the user block asks for.
  - [ sh, -c, "echo '$GUEST_USER ALL=(ALL) NOPASSWD:ALL' > /tmp/wizard-sudo && visudo -cqf /tmp/wizard-sudo && install -m 0440 /tmp/wizard-sudo /etc/sudoers.d/90-wizard-pmem-vm; rm -f /tmp/wizard-sudo" ]
  - [ sh, -c, "timeout 120 ssh-keygen -A || true" ]
  - [ sh, -c, "timeout 30 systemctl reset-failed ssh.service ssh.socket >/dev/null 2>&1 || true" ]
  - [ sh, -c, "timeout 30 systemctl enable ssh.socket >/dev/null 2>&1 || true" ]
  - [ sh, -c, "timeout 30 systemctl --no-block start ssh.socket >/dev/null 2>&1 || true" ]
# Once more after the boot has settled, for a failure bootcmd ran too early to
# see. Unlike bootcmd this runs once per instance, so it only covers first boot.
runcmd:
  - [ sh, -c, "systemctl reset-failed ssh.service ssh.socket >/dev/null 2>&1 || true" ]
  - [ sh, -c, "systemctl is-active --quiet ssh.socket || systemctl restart ssh.socket" ]
package_update: true
packages:
  - ndctl
  - daxctl
  - linux-image-generic
EOF
    rm -f "$SEED_ISO"
    case "$(seed_tool)" in
        cloud-localds) cloud-localds "$SEED_ISO" "$src/user-data" "$src/meta-data" ;;
        xorriso)       xorriso -as mkisofs -quiet -output "$SEED_ISO" -volid CIDATA -joliet -rock "$src" ;;
        mkisofs)       mkisofs -quiet -output "$SEED_ISO" -volid CIDATA -joliet -rock "$src" ;;
        genisoimage)   genisoimage -quiet -output "$SEED_ISO" -volid CIDATA -joliet -rock "$src" ;;
        hdiutil)       hdiutil makehybrid -quiet -iso -joliet -default-volume-name CIDATA -o "${SEED_ISO%.iso}" "$src" ;;
        *)             die "no ISO builder available" ;;
    esac
    say "cloud-init seed built with $(seed_tool)"
}

# Configure the guest: drivers, fsdax namespace, DAX filesystem, scratch dir.
# Idempotent, and deliberately conservative -- it reformats nothing that already
# holds a filesystem, because a missing /dev/pmem0 is a driver problem far more
# often than a data problem.
provision_guest() {
    # SSH answers before cloud-init has finished its own package installation,
    # and the two would fight over the apt lock.
    say "waiting for cloud-init to finish"
    gssh 'sudo timeout 1800 cloud-init status --wait >/dev/null 2>&1 || true'
    say "installing guest packages (ndctl, NVDIMM drivers)"
    gssh 'sudo apt-get -o DPkg::Lock::Timeout=600 update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq ndctl daxctl linux-image-generic "linux-modules-extra-$(uname -r)"' >/dev/null
    gssh 'sudo modprobe nd_pmem dax_pmem'

    if ! gssh 'sudo ndctl list -N 2>/dev/null | grep -q fsdax'; then
        say "creating fsdax namespace"
        if gssh 'sudo ndctl list -Nu --idle 2>/dev/null | grep -q namespace0.0'; then
            gssh 'sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=fsdax --map=dev' >/dev/null
        else
            gssh 'sudo ndctl create-namespace --force --mode=fsdax --map=dev' >/dev/null
        fi
    else
        say "fsdax namespace already configured"
    fi
    gssh 'test -b /dev/pmem0' || die "no /dev/pmem0 after provisioning; see: scripts/pmem-vm.sh ssh 'sudo ndctl list -Nu --idle'"

    local fstype
    fstype=$(gssh 'sudo blkid -o value -s TYPE /dev/pmem0 2>/dev/null || true')
    if [ "$fstype" = ext4 ]; then
        say "existing ext4 filesystem kept (not reformatting)"
    else
        say "formatting /dev/pmem0 (block size 4096, required for DAX)"
        gssh 'sudo mkfs.ext4 -F -q -b 4096 /dev/pmem0'
    fi

    gssh "sudo mkdir -p $MOUNT_POINT"
    gssh "grep -q '^/dev/pmem0 ' /etc/fstab || echo '/dev/pmem0 $MOUNT_POINT ext4 dax=always 0 0' | sudo tee -a /etc/fstab >/dev/null"
    gssh "findmnt -n $MOUNT_POINT >/dev/null 2>&1 || sudo mount -a"
    gssh "findmnt -no OPTIONS $MOUNT_POINT | grep -q dax=always" \
        || die "$MOUNT_POINT is mounted without dax=always; MAP_SYNC will be refused"
    gssh "sudo mkdir -p $SCRATCH_DIR && sudo chown $GUEST_USER: $SCRATCH_DIR"
    say "DAX mount ready at $MOUNT_POINT, scratch directory $SCRATCH_DIR"
}

# Rebuild the cloud-init seed and reboot into it. The seed's bootcmd runs on
# every boot, so this repairs an existing VM -- an unreachable sshd above all --
# without touching the guest disk or asking for a fresh setup.
reseed() {
    detect_host; ssh_args
    [ -f "$SSH_KEY.pub" ] || die "no ssh key in $VM_DIR; run: scripts/pmem-vm.sh setup"
    make_seed
    if vm_pid >/dev/null; then
        say "restarting the VM to boot the new seed"
        stop_vm || kill_vm
    fi
    start_vm
}

setup() {
    detect_host
    check_host_tools
    mkdir -p "$VM_DIR"
    say "host: $HOST_OS $HOST_ARCH, acceleration: $ACCEL_NAME"
    [ "$EMULATED" = 0 ] || say "emulated x86-64: setup will take a while"

    fetch_base_image
    if [ ! -f "$SSH_KEY" ]; then
        ssh-keygen -q -t ed25519 -N '' -C wizard-pmem-vm -f "$SSH_KEY"
        say "generated VM-only ssh key: $SSH_KEY"
    fi
    [ -f "$SEED_ISO" ] || make_seed
    if [ ! -f "$GUEST_IMG" ]; then
        qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMG" "$GUEST_IMG" "$DISK_SIZE"
        say "guest disk created ($DISK_SIZE, layered on the cloud image)"
    fi
    if [ ! -f "$PMEM_IMG" ]; then
        qemu-img create -q -f raw "$PMEM_IMG" "$PMEM_SIZE"
        printf 'pmem_size=%s\n' "$PMEM_SIZE" > "$GEOMETRY"
        say "NVDIMM backing file created ($PMEM_SIZE)"
    fi
    [ -f "$GEOMETRY" ] || printf 'pmem_size=%s\n' "$PMEM_SIZE" > "$GEOMETRY"

    start_vm
    provision_guest
    sync_bin
    say ""
    status_vm
    say ""
    say "setup complete; run: scripts/pmem-vm.sh test"
}

# --------------------------------------------------------------- daily commands

ensure_mount() {
    gssh "findmnt -n $MOUNT_POINT >/dev/null 2>&1" && return 0
    if ! gssh 'test -b /dev/pmem0'; then
        warn ""
        warn "/dev/pmem0 is absent: the nd_pmem driver is not bound."
        warn "Most likely the guest booted a new kernel without linux-modules-extra."
        warn "Recover (do NOT run mkfs, the filesystem is intact):"
        warn "  scripts/pmem-vm.sh ssh"
        warn "  sudo ndctl list -Nu --idle    # state: disabled?"
        warn "  sudo apt-get install -y linux-modules-extra-\$(uname -r) linux-image-generic"
        warn "  sudo modprobe nd_pmem && sudo mount -a"
        return 1
    fi
    gssh "sudo mount -a >/dev/null 2>&1 || sudo mount -o dax=always /dev/pmem0 $MOUNT_POINT" \
        || { warn "could not mount $MOUNT_POINT"; return 1; }
    gssh "sudo mkdir -p $SCRATCH_DIR && sudo chown $GUEST_USER: $SCRATCH_DIR"
}

status_vm() {
    detect_host; ssh_args
    if ! vm_pid >/dev/null; then
        say "VM:        stopped ($VM_DIR)"
        return 0
    fi
    say "VM:        running (pid $(vm_pid)), $ACCEL_NAME, ssh port $SSH_PORT"
    if ! ssh_up; then
        say "SSH:       not answering yet"
        return 0
    fi
    # `ndctl list -N` shows only enabled namespaces; empty output is the symptom
    # of an unbound driver, not of a broken command.
    local mode
    mode=$(gssh 'sudo ndctl list -N 2>/dev/null | tr -d " \n" | sed -n "s/.*\"mode\":\"\([a-z]*\)\".*/\1/p" | head -1' || true)
    say "namespace: ${mode:-none enabled (see: sudo ndctl list -Nu --idle)}"
    say "blockdev:  $(gssh 'test -b /dev/pmem0 && echo "/dev/pmem0 present" || echo MISSING')"
    say "mount:     $(gssh "findmnt -no SOURCE,TARGET,OPTIONS $MOUNT_POINT 2>/dev/null || echo 'not mounted'")"
    say "scratch:   $(gssh "test -d $SCRATCH_DIR && echo $SCRATCH_DIR || echo absent")"
    say "test bin:  $(gssh "test -x ~/$TEST_BIN && date -r ~/$TEST_BIN '+%Y-%m-%d %H:%M' || echo 'not copied'")"
    local stale
    stale=$(gssh "ls -1 $SCRATCH_DIR/wizard-pmem-*.region 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    [ "${stale// /}" = "0" ] || say "leftovers: ${stale// /} stale wizard-pmem-*.region file(s) in $SCRATCH_DIR"
}

sync_bin() {
    ssh_args
    ssh_up || die "guest unreachable; run: scripts/pmem-vm.sh start"
    say "building bin/$TEST_BIN"
    if ! make -C "$REPO" "bin/$TEST_BIN"; then
        warn ""
        warn "build failed. The Virgil compiler must run on this host and emit an"
        warn "x86-64 Linux binary. On Apple silicon that means Rosetta 2:"
        warn "  softwareupdate --install-rosetta"
        warn "Alternatively build on another machine and copy the binary in:"
        warn "  scp -P $SSH_PORT -i $SSH_KEY bin/$TEST_BIN $GUEST_USER@localhost:"
        die "cannot build $TEST_BIN"
    fi
    scp "${SCP_BATCH[@]}" "$REPO/bin/$TEST_BIN" "$GUEST_USER@localhost:" >/dev/null
    say "copied to guest ~/$TEST_BIN"
}

run_test() {
    ssh_args
    ssh_up || die "guest unreachable; run: scripts/pmem-vm.sh start"
    gssh "test -x ~/$TEST_BIN" || die "~/$TEST_BIN missing; run: scripts/pmem-vm.sh sync"
    ensure_mount || die "$MOUNT_POINT unavailable"
    gssh "./$TEST_BIN $SCRATCH_DIR"
}

destroy() {
    [ -d "$VM_DIR" ] || { say "nothing to remove at $VM_DIR"; return 0; }
    say "This deletes the VM directory and everything in it:"
    say "  $VM_DIR"
    say "The repository is untouched. Re-creating it needs another setup run."
    printf 'Type the word destroy to confirm: '
    local answer; read -r answer
    [ "$answer" = destroy ] || { say "aborted"; return 1; }
    kill_vm >/dev/null 2>&1 || true
    rm -rf "$VM_DIR"
    say "removed $VM_DIR"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

case "${1:-status}" in
    doctor)  doctor ;;
    setup)   setup ;;
    start)   start_vm; ensure_mount || true; status_vm ;;
    status)  status_vm ;;
    ssh)     shift; ssh_args; exec ssh "${SSH_OPTS[@]}" "$GUEST_USER@localhost" "$@" ;;
    sync)    sync_bin ;;
    test)    run_test ;;
    stop)    stop_vm ;;
    kill)    kill_vm ;;
    console) tail -f "$SERIAL_LOG" ;;
    reseed)  reseed; ensure_mount || true; status_vm ;;
    destroy) destroy ;;
    help|-h|--help) usage ;;
    *)       usage; exit 2 ;;
esac
