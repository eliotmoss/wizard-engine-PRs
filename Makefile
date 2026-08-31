all: x86-linux x86-64-linux jvm

.PHONY: clean x86-linux x86-64-linux jvm wasm-wave pmem-integration pwsieve pwsieve-pmem
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
PWSIEVE_X86_64_LINUX=test/unittest/x86-64-linux/PWSieve.v3 test/pwsieve.main.v3
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

bin/pwsieve.x86-64-linux: $(ENGINE) $(PWSIEVE_X86_64_LINUX) $(X86_64) $(JIT) build.sh
	./build.sh pwsieve x86-64-linux

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
