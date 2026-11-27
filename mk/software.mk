# =============================================================================
# Software: the BIOS, custom bare-metal programs and OpenSBI.
# =============================================================================

.PHONY: compile-bios compile-bin compile-openSBI

# --- BIOS ---------------------------------------------------------------------
# One source tree, three builds that differ only in -D flags:
#
#   bios          hardware: 38400 baud, full memory test, boots from the SD
#                 card by reading BOOT.TXT
#   bios_sim      simulation self-test: fast UART, sampled memory test, ends
#                 with EBREAK so the testbench reports PASS or FAIL
#   bios_preload  simulation of a BOOT.TXT: the images are already in SDRAM
#                 (preloaded by the testbench), so it skips the card and hands
#                 straight off to OpenSBI with the descriptor's addresses
#
# Each build's flags are kept in a .flags file that changes only when the flags
# do, so switching variants rebuilds exactly what is affected.
BIOS_SRC  := $(BIOS_DIR)/crt0.S $(filter-out $(BIOS_DIR)/crt0.S,$(wildcard $(BIOS_DIR)/*.c))
BIOS_HDRS := $(wildcard $(BIOS_DIR)/*.h)
BIOS_LD   := $(BIOS_DIR)/bios.ld
BOOT_RAM_BYTES := 32768

BIOS_CFLAGS := $(ARCH_FLAGS) -Os -g -ffreestanding -nostdlib -nostartfiles \
               -fno-builtin -Wall -Wextra -I$(BIOS_DIR)

BIOS_HW_DEFS  := -DCPU_HZ=$(SOC_CLK_HZ)u -DBAUD=$(BAUD)u -DMEMTEST_STRIDE=1 \
                 -DSTARTUP_DELAY_MS=1500u -DBOOT_FROM_SD
# The simulated UART runs at the real bit rate, so the console is sped up and
# the memory test samples one word in 8192.
BIOS_SIM_DEFS := -DCPU_HZ=$(SOC_CLK_HZ)u -DBAUD=$(SIM_BAUD)u -DMEMTEST_STRIDE=8192 \
                 -DSTARTUP_DELAY_MS=0u -DSIMULATION

# bios_preload takes its addresses from the descriptor being simulated.
ifneq ($(filter %.txt %.TXT,$(BIN)),)
BOOT_DESC_DEFS := $(shell $(PYTHON) $(SCRIPTS)/run_image.py defines $(BIN))
endif

BIOS_VARIANTS := bios bios_sim bios_preload
bios_DEFS         := $(BIOS_HW_DEFS)
bios_sim_DEFS     := $(BIOS_SIM_DEFS)
bios_preload_DEFS := $(BIOS_SIM_DEFS) $(BOOT_DESC_DEFS)

$(foreach v,$(BIOS_VARIANTS),$(FW_BUILD)/$(v).flags): $(FW_BUILD)/%.flags: FORCE
	@$(call update-file,$@,'$(CC) $(BIOS_CFLAGS) $($*_DEFS)')

$(FW_BUILD)/%.elf: $(BIOS_SRC) $(DIV64_SRC) $(BIOS_HDRS) $(BIOS_LD) $(FW_BUILD)/%.flags
	$(require-cross)
	@echo '  CC    $@'
	@$(CC) $(BIOS_CFLAGS) $($*_DEFS) -T $(BIOS_LD) -Wl,--no-warn-rwx-segments \
	    -Wl,-Map=$(FW_BUILD)/$*.map $(BIOS_SRC) $(DIV64_SRC) $(LIBGCC) -o $@
	$(call check-no-rvc,$@)
	@$(SIZE) $@ | tail -1

$(FW_BUILD)/%.vmem: $(FW_BUILD)/%.elf $(SCRIPTS)/translate_bin_to_vmem.py
	@$(PYTHON) $(SCRIPTS)/translate_bin_to_vmem.py $< $@ --base 0 --size $(BOOT_RAM_BYTES)

$(FW_BUILD)/%.bin: $(FW_BUILD)/%.elf
	@$(OBJCOPY) -O binary $< $@

.PRECIOUS: $(FW_BUILD)/%.elf $(FW_BUILD)/%.vmem $(FW_BUILD)/%.flags

compile-bios: $(FW_BUILD)/bios.elf $(FW_BUILD)/bios.bin $(FW_BUILD)/bios.vmem

# --- Custom bare-metal programs -----------------------------------------------
# make compile-bin SRC="a.c b.S" [OUT=build/bin/a.elf] [LINK=boot|sdram]
#
# crt0 and the linker scripts are in software/common. LINK=boot (default)
# places the program in the 32 KB boot RAM at the reset vector; LINK=sdram
# places it at 0x8000_0000 (needed for QEMU and for programs over 32 KB).
LINK ?= boot
ifeq ($(filter $(LINK),boot sdram),)
$(error LINK=$(LINK): expected boot or sdram)
endif

BIN_OUT    := $(if $(OUT),$(OUT),$(BUILD_DIR)/bin/$(basename $(notdir $(firstword $(SRC)))).elf)
BIN_CRT0   := $(SW_DIR)/common/crt0.S
BIN_LDS    := $(SW_DIR)/common/$(LINK).ld $(SW_DIR)/common/sections.ld
BIN_CFLAGS := $(ARCH_FLAGS) -O2 -g -ffreestanding -nostdlib -nostartfiles \
              -Wall -Wextra -I$(SW_DIR)/common \
              -DCPU_HZ=$(SOC_CLK_HZ)u -DBAUD=$(BAUD)u

ifneq ($(filter compile-bin,$(MAKECMDGOALS)),)
ifeq ($(strip $(SRC)),)
$(error compile-bin needs SRC=<file.c|file.S ...>)
endif
endif

compile-bin: $(BIN_OUT)

$(BIN_OUT).flags: FORCE
	@$(call update-file,$@,'$(CC) $(BIN_CFLAGS) $(LINK)' '$(SRC)')

$(BIN_OUT): $(SRC) $(BIN_CRT0) $(DIV64_SRC) $(BIN_LDS) $(BIN_OUT).flags
	$(require-cross)
	@mkdir -p $(@D)
	@echo '  CC    $@'
	@$(CC) $(BIN_CFLAGS) -L$(SW_DIR)/common -T $(SW_DIR)/common/$(LINK).ld \
	    -Wl,--no-warn-rwx-segments -Wl,-Map=$(basename $@).map \
	    $(BIN_CRT0) $(SRC) $(DIV64_SRC) $(LIBGCC) -o $@
	$(call check-no-rvc,$@)
	@$(OBJCOPY) -O binary $@ $(basename $@).bin
	@$(SIZE) $@ | tail -1
	@echo '  -> $@, $(basename $@).bin (linked for $(LINK))'

# --- OpenSBI ------------------------------------------------------------------
# fw_dynamic for the generic platform, linked at the top of SDRAM where the
# Linux boot map puts it. Pinned to the revision the board boots with.
#
# OpenSBI must be linked as a PIE. Bare-metal (*-elf) binutils cannot do that,
# so the first toolchain in OPENSBI_CANDIDATES that can is used: the detected
# CROSS, a distribution Linux cross compiler, then Buildroot's.
OPENSBI_REPO   ?= https://github.com/riscv-software-src/opensbi
OPENSBI_COMMIT := 4e79fd7de59f1b2899092c1a84ce68c8ebc68f93
OPENSBI_DIR    := $(BUILD_DIR)/opensbi
OPENSBI_SRC    := $(OPENSBI_DIR)/src
OPENSBI_OBJ    := $(OPENSBI_DIR)/build
OPENSBI_BIN    := $(OPENSBI_DIR)/fw_dynamic.bin
OPENSBI_ADDR   := 0x80700000
OPENSBI_CROSS  ?=
OPENSBI_CANDIDATES := $(OPENSBI_CROSS) $(CROSS) riscv64-linux-gnu- \
    $(BUILDROOT)/output/host/bin/riscv32-buildroot-linux-gnu- \
    $(BR_OUTPUT)/host/bin/riscv32-buildroot-linux-musl-

OPENSBI_FLAGS := PLATFORM=generic PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ABI=ilp32 \
                 PLATFORM_RISCV_ISA=$(MARCH) FW_TEXT_START=$(OPENSBI_ADDR)

compile-openSBI: $(OPENSBI_BIN)

$(OPENSBI_SRC)/Makefile:
	@rm -rf $(OPENSBI_SRC) && mkdir -p $(OPENSBI_SRC)
	git -C $(OPENSBI_SRC) init -q
	git -C $(OPENSBI_SRC) fetch -q --depth 1 $(OPENSBI_REPO) $(OPENSBI_COMMIT)
	git -C $(OPENSBI_SRC) -c advice.detachedHead=false checkout -q FETCH_HEAD

$(OPENSBI_BIN): $(OPENSBI_SRC)/Makefile
	@head=$$(git -C $(OPENSBI_SRC) rev-parse HEAD); \
	if [ "$$head" != "$(OPENSBI_COMMIT)" ]; then \
	    echo "$(OPENSBI_SRC) is at $$head, expected $(OPENSBI_COMMIT)."; \
	    echo "Remove it and run make compile-openSBI again."; exit 1; fi
	@cross=''; for p in $(OPENSBI_CANDIDATES); do \
	    if $${p}gcc -march=$(MARCH) -mabi=$(MABI) -fPIE -nostdlib -Wl,-pie \
	           -x c /dev/null -o /dev/null >/dev/null 2>&1; then cross=$$p; break; fi; \
	    command -v $${p}gcc >/dev/null 2>&1 && \
	        echo "  $${p}gcc cannot link a PIE, skipped"; \
	done; \
	if [ -z "$$cross" ]; then \
	    echo 'No toolchain able to link OpenSBI (it must produce a PIE).'; \
	    echo 'Install gcc-riscv64-linux-gnu, run make linux-toolchain, or set OPENSBI_CROSS.'; \
	    exit 1; fi; \
	echo "  OpenSBI with $${cross}gcc"; \
	env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make -C $(OPENSBI_SRC) -j$(JOBS) \
	    O=$(abspath $(OPENSBI_OBJ)) CROSS_COMPILE=$$cross $(OPENSBI_FLAGS) >/dev/null
	@cp $(OPENSBI_OBJ)/platform/generic/firmware/fw_dynamic.bin $@
	@cp $(OPENSBI_OBJ)/platform/generic/firmware/fw_dynamic.elf $(OPENSBI_DIR)/
	@echo "  -> $@ ($$(stat -c %s $@) bytes, linked at $(OPENSBI_ADDR))"
