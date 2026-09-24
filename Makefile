all: x86-linux x86-64-linux jvm

.PHONY: clean x86-linux x86-64-linux jvm wasm-wave pmem-integration pwsieve pwsieve-pmem pwsieve-pmem-mutant pwbench-pmem pwbench-file pwbench-block pwbench-direct pwbench-device pwsieve-direct pwsieve-direct-mutant pwsieve-device
clean:
	rm -f TAGS bin/*
	cp scripts/* bin/

x86-linux: bin/wizeng.x86-linux bin/unittest.x86-linux

x86-64-linux: bin/wizeng.x86-64-linux bin/unittest.x86-64-linux

jvm: bin/wizeng.jvm bin/unittest.jvm

wasm-wave: bin/wizeng.wasm bin/unittest.wasm

v3i: bin/wizeng.v3i bin/unittest.v3i

WIZENG_BUILD_SH_ARGS ?=

ENGINE=src/engine/*.v3 src/engine/v3/*.v3 src/util/*.v3
MONITORS=src/monitors/*.v3 src/monitors/test/*.v3
JIT=src/engine/compiler/*.v3
X86_64=src/engine/x86-64/*.v3
WAVE=src/modules/wave/*.v3
WASI=src/modules/wasi/*.v3
WASI_X86_64_LINUX=src/modules/wasi/x86-64-linux/*.v3
WALI=src/modules/wali/*.v3
WALI_X86_64_LINUX=src/modules/wali/x86-64-linux/*.v3
OBJDUMP=$(ENGINE) src/objdump.main.v3
UNITTEST=$(ENGINE) test/unittest/*.v3 test/wasm-spec/*.v3 test/unittest.main.v3
UNITTEST_X86_64_LINUX=test/unittest/x86-64-linux/*.v3 $(WASI) $(WASI_X86_64_LINUX)
PMEMTEST_X86_64_LINUX=test/integration/x86-64-linux/PmemDaxIntegrationTest.v3 test/pmem-integration.main.v3
PWSIEVE_X86_64_LINUX=test/unittest/x86-64-linux/PWSieve.v3 test/unittest/x86-64-linux/ElidedWritebackOps.v3 test/pwsieve.main.v3
PWREBOOT_X86_64_LINUX=test/unittest/x86-64-linux/PWSieve.v3 test/unittest/x86-64-linux/ElidedWritebackOps.v3 test/pwreboot.main.v3
PWBENCH_X86_64_LINUX=test/unittest/x86-64-linux/ElidedWritebackOps.v3 test/pwbench.main.v3
WIZENG=$(ENGINE) $(WAVE) $(WASI) $(WALI) src/SpectestMode.v3 src/WasmMode.v3 src/wizeng.main.v3  src/modules/*.v3 src/modules/wizeng/*.v3

TAGS: $(WIZENG) $(WAVE) $(WASI) $(WALI) $(SPECTEST) $(UNITTEST) $(WASI_X86_64_LINUX) $(JIT) $(X86_64)
	vctags -e $(WIZENG) $(WAVE) $(WASI) $(WALI) $(SPECTEST) $(UNITTEST) $(WASI_X86_64_LINUX) $(WALI_X86_64_LINUX) $(JIT) $(X86_64)

# JVM targets
bin/unittest.jvm: $(UNITTEST) build.sh
	./build.sh unittest jvm

bin/wizeng.jvm: $(WIZENG) $(MONITORS) build.sh
	./build.sh ${WIZENG_BUILD_SH_ARGS} wizeng jvm

bin/objdump.jvm: $(OBJDUMP) build.sh
	./build.sh objdump jvm

# WAVE targets
bin/unittest.wasm: $(UNITTEST) build.sh
	./build.sh unittest wasm-wave

bin/wizeng.wasm: $(WIZENG) $(MONITORS) build.sh
	./build.sh ${WIZENG_BUILD_SH_ARGS} wizeng wasm-wave

bin/objdump.wasm: $(OBJDUMP) build.sh
	./build.sh objdump wasm-wave

# x86-linux targets
bin/unittest.x86-linux: $(UNITTEST) build.sh
	./build.sh unittest x86-linux

bin/wizeng.x86-linux: $(WIZENG) $(MONITORS) build.sh
	./build.sh ${WIZENG_BUILD_SH_ARGS} wizeng x86-linux

bin/objdump.x86-linux: $(OBJDUMP) build.sh
	./build.sh objdump x86-linux

# x86-64-linux targets
bin/unittest.x86-64-linux: $(UNITTEST) $(UNITTEST_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh unittest x86-64-linux

# Opt-in: PWASM_PMEM_TEST_DIR must name an assigned writable directory on an
# fsdax mount. The runner exclusively creates and removes its own unique file.
pmem-integration: bin/pmemtest.x86-64-linux
	@if [ -z "$(PWASM_PMEM_TEST_DIR)" ]; then \
		echo "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"; \
		exit 2; \
	fi
	bin/pmemtest.x86-64-linux "$(PWASM_PMEM_TEST_DIR)"

bin/pmemtest.x86-64-linux: $(ENGINE) $(PMEMTEST_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh pmemtest x86-64-linux

# Random-timer crash loop over the resumable sieve, on the file backend. The
# runner reserves its own uniquely named file inside the given directory.
# PWSIEVE_ARGS overrides the directory, iteration count, seed and geometry.
PWSIEVE_ARGS ?= /tmp 50 1
pwsieve: bin/pwsieve.x86-64-linux
	bin/pwsieve.x86-64-linux $(PWSIEVE_ARGS)

# Opt-in: the same crash loop through the production PMEM backend.
# PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax
# mount; MAP_SYNC has no fallback, so a run that starts is a run on real DAX.
# 512 x 4096 = 2 MiB, matching the mount's 2 MiB alignment while keeping the
# fast 32512-integer segment span. PWSIEVE_PMEM_ARGS overrides the rest.
PWSIEVE_PMEM_ARGS ?= 20 1 512 4096
pwsieve-pmem: bin/pwsieve.x86-64-linux
	@if [ -z "$(PWASM_PMEM_TEST_DIR)" ]; then \
		echo "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"; \
		exit 2; \
	fi
	bin/pwsieve.x86-64-linux "$(PWASM_PMEM_TEST_DIR)" $(PWSIEVE_PMEM_ARGS) pmem

# The flush-placement negative control: the same crash loop, same geometry and
# same seed, with cache-line writeback elided. docs/pmem-emulation.md predicts
# this still reports OK, because a MAP_SYNC mapping's memory is the media and a
# killed process loses nothing still in cache. Run it against pwsieve-pmem above
# and the layer-1b sweep in persistent_control: to complete the 2x2.
pwsieve-pmem-mutant: bin/pwsieve.x86-64-linux
	@if [ -z "$(PWASM_PMEM_TEST_DIR)" ]; then \
		echo "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"; \
		exit 2; \
	fi
	bin/pwsieve.x86-64-linux "$(PWASM_PMEM_TEST_DIR)" $(PWSIEVE_PMEM_ARGS) pmem elide-clwb

# The crash loop on the direct-I/O backend (pwrite + O_DIRECT from a private
# staging buffer), where process death is the crash: whatever the child never
# wrote back dies with it. The ordinary build must report OK and the mutant must
# report LOST -- the random-crash-point counterpart of the Stage 2c pair.
# PWDIRECT_DIR must name local block storage that honours O_DIRECT (not tmpfs).
# The optional eighth argument raises the 20 ms kill delay on slow media.
PWSIEVE_DIRECT_ARGS ?= 20 1 512 4096
pwsieve-direct: bin/pwsieve.x86-64-linux
	@if [ -z "$(PWDIRECT_DIR)" ]; then \
		echo "PWDIRECT_DIR must name a writable directory on block storage that honours O_DIRECT"; \
		exit 2; \
	fi
	bin/pwsieve.x86-64-linux "$(PWDIRECT_DIR)" $(PWSIEVE_DIRECT_ARGS) direct ordinary

pwsieve-direct-mutant: bin/pwsieve.x86-64-linux
	@if [ -z "$(PWDIRECT_DIR)" ]; then \
		echo "PWDIRECT_DIR must name a writable directory on block storage that honours O_DIRECT"; \
		exit 2; \
	fi
	bin/pwsieve.x86-64-linux "$(PWDIRECT_DIR)" $(PWSIEVE_DIRECT_ARGS) direct elide-clwb

# The same loop on a raw block device, overwritten from offset 0 for the
# region's length; see pwbench-device for the safeguards. PWDIRECT_WRITEBACK
# selects ordinary (default) or elide-clwb.
PWDIRECT_WRITEBACK ?= ordinary
pwsieve-device: bin/pwsieve.x86-64-linux
	@if [ -z "$(PWDIRECT_DEVICE)" ]; then \
		echo "PWDIRECT_DEVICE must name a spare block device whose first 2 MiB may be overwritten"; \
		exit 2; \
	fi
	bin/pwsieve.x86-64-linux "$(PWDIRECT_DEVICE)" $(PWSIEVE_DIRECT_ARGS) direct-device="$(PWDIRECT_DEVICE)" $(PWDIRECT_WRITEBACK)

bin/pwsieve.x86-64-linux: $(ENGINE) $(PWSIEVE_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh pwsieve x86-64-linux

# Persistence-boundary cost. Three configurations: the SFENCE boundary on DAX,
# the fdatasync boundary on the same DAX media, and the fdatasync boundary on
# ordinary block storage. 1 vs 2 isolates the primitive, 2 vs 3 the media.
PWBENCH_ARGS ?= 20000 8 2000
pwbench-pmem: bin/pwbench.x86-64-linux
	@if [ -z "$(PWASM_PMEM_TEST_DIR)" ]; then \
		echo "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"; \
		exit 2; \
	fi
	bin/pwbench.x86-64-linux "$(PWASM_PMEM_TEST_DIR)" pmem $(PWBENCH_ARGS)

pwbench-file: bin/pwbench.x86-64-linux
	@if [ -z "$(PWASM_PMEM_TEST_DIR)" ]; then \
		echo "PWASM_PMEM_TEST_DIR must name an assigned writable directory on an fsdax mount"; \
		exit 2; \
	fi
	bin/pwbench.x86-64-linux "$(PWASM_PMEM_TEST_DIR)" file $(PWBENCH_ARGS)

# Block-media point. PWBENCH_DIR must name ordinary local storage; check with
# findmnt -T first, since an fdatasync over NFS measures the network.
pwbench-block: bin/pwbench.x86-64-linux
	@if [ -z "$(PWBENCH_DIR)" ]; then \
		echo "PWBENCH_DIR must name a writable directory on ordinary block storage"; \
		exit 2; \
	fi
	bin/pwbench.x86-64-linux "$(PWBENCH_DIR)" file $(PWBENCH_ARGS)

# Direct-I/O backend on block storage: pwrite + O_DIRECT from a private staging
# buffer, one fdatasync per boundary, no page cache. PWDIRECT_DIR must name a
# local block-backed filesystem that honours O_DIRECT; tmpfs and NFS do not, and
# the backend refuses a descriptor that only pretends to.
pwbench-direct: bin/pwbench.x86-64-linux
	@if [ -z "$(PWDIRECT_DIR)" ]; then \
		echo "PWDIRECT_DIR must name a writable directory on block storage that honours O_DIRECT"; \
		exit 2; \
	fi
	bin/pwbench.x86-64-linux "$(PWDIRECT_DIR)" direct $(PWBENCH_ARGS)

# The same on a raw block device, overwritten from offset 0 for the region's
# length (2 MiB by default). The binary refuses a mounted device and one that
# carries a known partition, filesystem, LVM, LUKS or swap signature, and the
# device path is passed to it twice on purpose.
pwbench-device: bin/pwbench.x86-64-linux
	@if [ -z "$(PWDIRECT_DEVICE)" ]; then \
		echo "PWDIRECT_DEVICE must name a spare block device whose first 2 MiB may be overwritten"; \
		exit 2; \
	fi
	bin/pwbench.x86-64-linux "$(PWDIRECT_DEVICE)" direct-device="$(PWDIRECT_DEVICE)" $(PWBENCH_ARGS)

bin/pwbench.x86-64-linux: $(ENGINE) $(PWBENCH_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh pwbench x86-64-linux

# Stage 2c warm-reboot harness; driven by scripts/stage2c.sh, see
# docs/stage2c-handoff.md.
bin/pwreboot.x86-64-linux: $(ENGINE) $(PWREBOOT_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh pwreboot x86-64-linux

bin/spectest.x86-64-linux: $(SPECTEST) $(X86_64) $(JIT) build.sh
	./build.sh spectest x86-64-linux

bin/wizeng.x86-64-linux: $(WIZENG) $(MONITORS) $(WASI_X86_64_LINUX) $(WALI_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh ${WIZENG_BUILD_SH_ARGS} wizeng x86-64-linux

bin/objdump.x86-64-linux: $(OBJDUMP) $(X86_64) build.sh
	./build.sh objdump x86-64-linux

# interpreter targets
bin/unittest.v3i: $(UNITTEST) build.sh
	./build.sh unittest v3i

bin/wizeng.v3i: $(WIZENG) $(MONITORS) build.sh
	./build.sh ${WIZENG_BUILD_SH_ARGS} wizeng v3i

bin/objdump.v3i: $(OBJDUMP) build.sh
	./build.sh objdump v3i
