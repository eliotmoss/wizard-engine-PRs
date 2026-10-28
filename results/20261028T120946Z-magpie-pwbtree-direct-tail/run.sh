#!/usr/bin/env bash
# Is the direct backend's B+Tree tail on Magpie's /home still there, and where
# does its time go? 2026-10-28, Magpie as u7599095, ~/wizard-engine-PRs at
# e635180a. Its benchmark code is 95e055fa's (the 2026-10-27 campaign's): the
# only change under src/ and test/ since is ProviderTest.v3. Compiler: Magpie's
# Virgil III-11.1968 at 47be87e81 (~/virgil-titzer, built 2026-08-31).
#
# Each step ran as its own ssh session, in this order (UTC):
#   step1      12:09:46-12:12:39  one direct-block run, then one under strace
#   order      12:13:24-12:19:07  60 s idle, then direct, direct, file, direct,
#                                 back to back
#   diskstats  12:20:18-12:23:38  /proc/diskstats every 50 ms: 40 s idle, then
#                                 one direct-block run under strace
# A first attempt at step1 stopped in make (v3c is on PATH only in .bashrc,
# which a non-interactive shell does not read) and ran nothing.
#
# Parameters are the campaign's (scripts/pwbtree-bench.sh defaults): 3 measured
# rounds after 1 audited, 5000 keys, 5000 operations, 256 x 4096 B, seed 1,
# pinned to NUMA node 0, the DAX namespace's node, where the campaign's numactl
# pinning resolves on Magpie. The block directory is a fresh subdirectory of
# $HOME on /home (the campaigns used $HOME itself). Single runs, not
# repetitions; the strace runs locate where the time goes and are not timings
# (strace makes an operation 40-60 % slower).
#
# The steps below are the commands as run, less their progress echoes.
# Summary: python3 analyse.py . > summary.txt

step1() {
	set -euo pipefail
	export PATH=$PATH:$HOME/virgil-titzer/bin
	cd ~/wizard-engine-PRs
	make bin/pwbtreebench.x86-64-linux > /tmp/u7599095-make.log 2>&1 || { tail -20 /tmp/u7599095-make.log; exit 1; }
	ls -la bin/pwbtreebench.x86-64-linux
	S=$(date -u +%Y%m%dT%H%M%SZ)
	D=~/btree-tail-$S; mkdir -p "$D/blk"
	B=$PWD/bin/pwbtreebench.x86-64-linux
	{ git rev-parse HEAD; git status --short | wc -l; date -u; uptime; } > "$D/provenance.txt"
	numactl --cpunodebind=0 -- "$B" "$D/blk" direct 3 5000 5000 256 4096 seed=1 > "$D/plain.log" 2>&1
	numactl --cpunodebind=0 -- strace -f -tt -T -e trace=pwrite64,pwritev,pwritev2,pread64,fdatasync,fsync,openat,ftruncate,unlink,unlinkat,fallocate \
		-o "$D/strace.txt" "$B" "$D/blk" direct 3 5000 5000 256 4096 seed=1 > "$D/strace.log" 2>&1
	uptime >> "$D/provenance.txt"
}

order() {
	set -uo pipefail
	cd ~/wizard-engine-PRs
	D=~/btree-tail-20261028T120946Z/order; mkdir -p "$D/blk"
	B=$PWD/bin/pwbtreebench.x86-64-linux
	run() { numactl --cpunodebind=0 -- "$B" "$D/blk" "$2" 3 5000 5000 256 4096 seed=1 > "$D/$1.log" 2>&1; }
	sleep 60
	run 1-direct direct
	run 2-direct-after-direct direct
	run 3-file file
	run 4-direct-after-file direct
}

diskstats() {
	set -uo pipefail
	cd ~/wizard-engine-PRs
	D=~/btree-tail-20261028T120946Z/diskstats; mkdir -p "$D/blk"
	B=$PWD/bin/pwbtreebench.x86-64-linux
	# Per sample: epoch, device, then /proc/diskstats fields 4, 8, 10, 12, 13
	# and 14: reads completed, writes completed, sectors written, I/Os in
	# flight, ms doing I/O, weighted ms. sda holds dm-0 (/), dm-1 (/var/log)
	# and dm-2 (/home), all LVM volumes on sda3.
	python3 -c '
import time,sys
f=open(sys.argv[1],"w")
end=time.time()+float(sys.argv[2])
while time.time()<end:
    t=time.time()
    for l in open("/proc/diskstats"):
        p=l.split()
        if p[2] in ("sda","dm-0","dm-1","dm-2"):
            f.write(f"{t:.3f} {p[2]} {p[3]} {p[7]} {p[9]} {p[11]} {p[12]} {p[13]}\n")
    time.sleep(0.05)
' "$D/diskstats.txt" 200 &
	SP=$!
	sleep 40
	numactl --cpunodebind=0 -- strace -f -ttt -T -e trace=pwrite64,fdatasync -o "$D/strace.txt" \
		"$B" "$D/blk" direct 3 5000 5000 256 4096 seed=1 > "$D/strace.log" 2>&1
	wait $SP
}

# The traces were compressed with xz -9 when copied into results/.
"$@"
