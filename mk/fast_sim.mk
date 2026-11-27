# =============================================================================
# fast_sim - the core alone under Verilator, memory and devices in C++.
#
#   make fast_sim BIN=<program> [THREADS=n] [MAX_CYCLES=n] [FAST_SIM_ARGS=...]
#       Build if needed, then run <program>: an ELF, a raw image (loaded at the
#       reset vector), or a boot descriptor such as an SD card's BOOT.TXT. The
#       console is this terminal; Ctrl-A x quits.
#   make fast_sim-build    build only
#   make fast_sim-tsan     ThreadSanitizer build, in build/fast_sim/tsan/.
#                          On kernels with high mmap randomisation it aborts
#                          with "unexpected memory mapping"; run it under
#                          `setarch -R` to disable ASLR for that process.
#
#   THREADS     Verilator model threads (default 1).
#               1 is the default because it is by
#               far the fastest: the core is too small for Verilator's
#               partitioning to pay for the thread hand-off inside each of the
#               two evals per cycle. Measured booting Linux: 1 thread
#               2.5 Mcycles/s, 2 threads 0.30, 4 threads 0.12. Changing it
#               rebuilds.
#   MAX_CYCLES  stop after this many cycles; 0 (default) runs until the program
#               ends or the user quits. For regression scripts only.
#
# Included from the top-level Makefile; usable on its own as well
# (make -f mk/fast_sim.mk fast_sim BIN=...).
# =============================================================================

ifndef FAST_SIM_MK_INCLUDED
FAST_SIM_MK_INCLUDED := 1

# Rules here must not become the including Makefile's default goal.
FAST_SIM_MK_SAVED_GOAL := $(.DEFAULT_GOAL)

BUILD_DIR ?= build
VERILATOR ?= verilator
MAX_CYCLES ?= 0

# Verilator model threads. The model is small: a 2-thread build already runs
# about eight times slower than a single thread, so 1 is the default.
THREADS ?= 1
FAST_SIM_THREADS := $(THREADS)

FAST_SIM_DIR  := $(BUILD_DIR)/fast_sim
FAST_SIM_BIN  := $(FAST_SIM_DIR)/fast_sim
FAST_SIM_SRCD := RTL/sim/fast

FAST_SIM_V    := $(FAST_SIM_SRCD)/fast_sim_top.v
FAST_SIM_CPP  := $(wildcard $(FAST_SIM_SRCD)/*.cpp)
FAST_SIM_H    := $(wildcard $(FAST_SIM_SRCD)/*.h)
# The whole core directory: Verilator elaborates only what fast_sim_top
# instantiates, and globbing means a new core file needs no edit here.
FAST_CORE_V   := $(wildcard RTL/core/*.v)
FAST_CORE_VH  := $(wildcard RTL/core/*.vh)

# --x-assign/--x-initial fast: X becomes whatever is cheapest, not randomised.
# The core resets every register it depends on, so this costs no fidelity.
# No tracing support is compiled in; it slows the model even when unused.
FAST_SIM_VFLAGS := --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
                   --top-module fast_sim_top +incdir+RTL/core -Wno-fatal \
                   --threads $(FAST_SIM_THREADS)
# OPT_* are the optimisation levels of Verilator's generated makefile; its
# default is -Os. Set both ways, because where CFLAGS lands relative to them
# differs between Verilator releases.
# -fno-stack-protector: the distribution default guards every one of the
# model's large functions and costs about 5% here.
FAST_SIM_CXXFLAGS := -O3 -fno-stack-protector -std=gnu++17 -I$(abspath $(FAST_SIM_SRCD)) \
                     -DFAST_SIM_THREADS=$(FAST_SIM_THREADS)
FAST_SIM_MAKEFLAGS := OPT_FAST=-O3 OPT_SLOW=-O1 OPT_GLOBAL=-O3

# Rebuild when THREADS changes: the setting is recorded in a stamp that is
# rewritten only when it differs.
FAST_SIM_CONFIG := threads=$(FAST_SIM_THREADS)
FAST_SIM_STAMP  := $(FAST_SIM_DIR)/config.stamp
$(shell mkdir -p $(FAST_SIM_DIR) && \
        [ "$$(cat $(FAST_SIM_STAMP) 2>/dev/null)" = '$(FAST_SIM_CONFIG)' ] || \
        printf '%s\n' '$(FAST_SIM_CONFIG)' > $(FAST_SIM_STAMP))

.PHONY: fast_sim fast_sim-build fast_sim-tsan

fast_sim-build: $(FAST_SIM_BIN)

$(FAST_SIM_BIN): $(FAST_SIM_V) $(FAST_SIM_CPP) $(FAST_SIM_H) $(FAST_CORE_V) \
                 $(FAST_CORE_VH) $(FAST_SIM_STAMP) mk/fast_sim.mk
	@rm -rf $(FAST_SIM_DIR)/obj
	$(VERILATOR) $(FAST_SIM_VFLAGS) --Mdir $(FAST_SIM_DIR)/obj -o $(abspath $@) \
	    -CFLAGS '$(FAST_SIM_CXXFLAGS)' -LDFLAGS -pthread \
	    -MAKEFLAGS '$(FAST_SIM_MAKEFLAGS)' \
	    $(FAST_SIM_V) $(FAST_CORE_V) $(abspath $(FAST_SIM_CPP))

fast_sim: $(FAST_SIM_BIN)
	@if [ -z '$(BIN)' ]; then \
	    echo 'usage: make fast_sim BIN=<elf | raw image | BOOT.TXT> [THREADS=n] [MAX_CYCLES=n]'; \
	    exit 2; fi
	$(FAST_SIM_BIN) --max-cycles $(MAX_CYCLES) $(FAST_SIM_ARGS) $(BIN)

# ThreadSanitizer build of the same harness, single-threaded model. Used to
# check the console threads and rings for data races.
FAST_SIM_TSAN := $(FAST_SIM_DIR)/tsan/fast_sim

fast_sim-tsan: $(FAST_SIM_TSAN)

$(FAST_SIM_TSAN): $(FAST_SIM_V) $(FAST_SIM_CPP) $(FAST_SIM_H) $(FAST_CORE_V) \
                  $(FAST_CORE_VH) mk/fast_sim.mk
	@rm -rf $(FAST_SIM_DIR)/tsan/obj && mkdir -p $(FAST_SIM_DIR)/tsan
	$(VERILATOR) $(subst --threads $(FAST_SIM_THREADS),--threads 1,$(FAST_SIM_VFLAGS)) \
	    --Mdir $(FAST_SIM_DIR)/tsan/obj -o $(abspath $@) \
	    -CFLAGS '$(subst THREADS=$(FAST_SIM_THREADS),THREADS=1,$(FAST_SIM_CXXFLAGS)) -g -fsanitize=thread' \
	    -LDFLAGS '-pthread -fsanitize=thread' \
	    -MAKEFLAGS 'OPT_FAST=-O1 OPT_SLOW=-O1 OPT_GLOBAL=-O1' \
	    $(FAST_SIM_V) $(FAST_CORE_V) $(abspath $(FAST_SIM_CPP))

.DEFAULT_GOAL := $(FAST_SIM_MK_SAVED_GOAL)

endif  # FAST_SIM_MK_INCLUDED
