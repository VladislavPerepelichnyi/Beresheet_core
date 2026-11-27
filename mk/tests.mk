# =============================================================================
# Directed ISA tests (tests/rv32i), built as ELFs and run on fast_sim.
#
#   make test-isa          build every test, run each on fast_sim, summarise;
#                          exits non-zero if any fails
#   make test-isa-build    build the ELFs only, into build/tests/
#
# One linker script (tests/rv32i/test.ld) places every test in the SoC's boot
# RAM, so the same ELF also runs on the full-SoC simulator.
#
# Pass/fail convention (tests/rv32i/test_macros.h): EBREAK with mtvec == 0
# ends the run, and a0 == 0 is a pass. A trap test instead passes by halting on
# the trap named after its colon below. fast_sim also checks the structural
# invariants (RV32M stall, CSR atomicity, RV32A sequencing, delegated traps) on
# every cycle and fails a run that breaks one.
# =============================================================================

ifndef TESTS_MK_INCLUDED
TESTS_MK_INCLUDED := 1

# Rules here must not become the including Makefile's default goal.
TESTS_MK_SAVED_GOAL := $(.DEFAULT_GOAL)

BUILD_DIR ?= build

# Cross toolchain prefix. The top-level Makefile normally sets it; on its own,
# take the first one installed (Ubuntu, Arch, Fedora naming in that order).
ifeq ($(origin CROSS),undefined)
CROSS := $(firstword $(foreach p,riscv64-unknown-elf- riscv64-elf- riscv64-linux-gnu-,\
             $(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
endif

# fast_sim's build rules, if this fragment is used without the top level.
ifndef FAST_SIM_BIN
include $(dir $(lastword $(MAKEFILE_LIST)))fast_sim.mk
endif

ISA_DIR     := tests/rv32i
ISA_BIN_DIR := $(BUILD_DIR)/tests
ISA_LD      := $(ISA_DIR)/test.ld

# Every test in tests/rv32i. The CLINT and PLIC tests (10, 11, 18, 19) need
# devices, which fast_sim models, so nothing here is SoC-only any more.
ISA_FUNC_TESTS := 01_raw_alu 02_branches 03_jumps 04_loadstore 05_hazard_stress \
                  06_muldiv 07_muldiv_random 08_csr 09_traps 10_interrupts \
                  11_plic 12_atomics 13_privilege 14_trap_timing 15_fence \
                  16_mmu 17_umode_mem 18_div_irq 19_mip_seip_rmw \
                  20_ifault_phantom_load 21_amo_perm

# name:mcause. Each must stop on exactly this trap with mtvec still zero.
ISA_TRAP_TESTS := trap_illegal:2 trap_load_misaligned:4 trap_store_misaligned:6 \
                  trap_jump_misaligned:0 trap_csr_nonexistent:2 trap_csr_readonly:2

ISA_ELFS := $(addprefix $(ISA_BIN_DIR)/,$(addsuffix .elf,\
                $(ISA_FUNC_TESTS) $(foreach t,$(ISA_TRAP_TESTS),$(firstword $(subst :, ,$(t))))))

# A safety net so a hung test fails the regression instead of stalling it. The
# longest test needs well under a million cycles.
ISA_MAX_CYCLES ?= 20000000

ISA_CC     := $(CROSS)gcc
ISA_CFLAGS := -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
              -ffreestanding -I$(ISA_DIR) -T $(ISA_LD) -Wl,--no-warn-rwx-segments

.PHONY: test-isa test-isa-build

test-isa-build: $(ISA_ELFS)

$(ISA_BIN_DIR)/%.elf: $(ISA_DIR)/%.S $(ISA_DIR)/test_macros.h $(ISA_LD)
	@mkdir -p $(@D)
	$(ISA_CC) $(ISA_CFLAGS) $< -o $@

$(ISA_BIN_DIR)/%.elf: $(ISA_DIR)/traps/%.S $(ISA_DIR)/test_macros.h $(ISA_LD)
	@mkdir -p $(@D)
	$(ISA_CC) $(ISA_CFLAGS) $< -o $@

# stdin is /dev/null so a run started from a terminal does not take it over.
test-isa: $(FAST_SIM_BIN) $(ISA_ELFS)
	@pass=0; fail=0; \
	for spec in $(ISA_FUNC_TESTS) $(ISA_TRAP_TESTS); do \
	    t=$${spec%%:*}; args=; note=; \
	    case $$spec in *:*) args="--expect-trap $${spec##*:}"; \
	                        note="expected mcause=$${spec##*:}";; esac; \
	    out=$$($(FAST_SIM_BIN) --max-cycles $(ISA_MAX_CYCLES) $$args \
	           $(ISA_BIN_DIR)/$$t.elf </dev/null 2>&1); rc=$$?; \
	    info=$$(printf '%s\n' "$$out" | awk '/^  cycles/ {c=$$2} \
	           /^  instructions/ {i=$$2} END {printf "%s cycles, %s instructions", c, i}'); \
	    if [ $$rc -eq 0 ]; then \
	        printf '  \033[32mPASS\033[0m  %-24s %s %s\n' "$$t" "$$info" "$$note"; \
	        pass=$$((pass+1)); \
	    else \
	        printf '  \033[31mFAIL\033[0m  %-24s exit %d %s\n' "$$t" "$$rc" "$$note"; \
	        printf '%s\n' "$$out" | sed 's/^/          /'; fail=$$((fail+1)); \
	    fi; \
	done; \
	echo '----------------------------------------------------------------'; \
	printf ' ISA tests on fast_sim: %d passed, %d failed\n' "$$pass" "$$fail"; \
	[ $$fail -eq 0 ]

.DEFAULT_GOAL := $(TESTS_MK_SAVED_GOAL)

endif  # TESTS_MK_INCLUDED
