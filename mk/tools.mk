# =============================================================================
# Auxiliary tools: disassembler, QEMU reference model and gdb, vmem converter,
# board console.
# =============================================================================

.PHONY: disassembler qemu qemu-gdb gdb translate_bin_to_vmem console monitor

# Targets that take BIN=<file> refuse to start without one.
BIN_GOALS := disassembler qemu qemu-gdb translate_bin_to_vmem
ifneq ($(filter $(BIN_GOALS),$(MAKECMDGOALS)),)
ifeq ($(BIN),)
$(error $(firstword $(filter $(BIN_GOALS),$(MAKECMDGOALS))) needs BIN=<file>)
endif
ifeq ($(wildcard $(BIN)),)
$(error BIN=$(BIN): no such file)
endif
endif

# --- Disassembler -------------------------------------------------------------
# An ELF is disassembled by section with symbols; a raw binary as rv32 code
# loaded at BIN_ADDR. NO_ALIASES=1 prints canonical instructions (addi, not li).
NO_ALIASES ?=
DISASM_OPTS := $(if $(NO_ALIASES),-M no-aliases,)

disassembler:
	$(require-cross)
	@if [ "$$(head -c 4 '$(BIN)' | od -An -c | tr -d ' ')" = '177ELF' ]; then \
	    $(OBJDUMP) -d $(DISASM_OPTS) '$(BIN)'; \
	else \
	    $(OBJDUMP) -D -b binary -m riscv:rv32 $(DISASM_OPTS) \
	        --adjust-vma=$(or $(BIN_ADDR),0) '$(BIN)'; \
	fi

# --- QEMU ---------------------------------------------------------------------
# A reference model to compare against: the virt machine with a CPU restricted
# to what Beresheet implements (RV32IMA, Zicsr, Zicntr, Zifencei, M/S/U, Sv32,
# no PMP) and the same amount of RAM at the same address. The CLINT, PLIC and
# UART are at the same addresses as on the SoC. Privileged spec 1.10 is what
# OpenSBI detects on the core (it has no mcountinhibit or menvcfg).
#
#   ELF       loaded at its link address (must be SDRAM: compile-bin LINK=sdram)
#   BOOT.TXT  every image at its descriptor address, started through a shim
#             that performs the BIOS's OpenSBI hand-off
#
# marchid is set to "QEMU" (Beresheet reports 0) so software can tell the two
# apart; the compile-bin crt0 uses it to exit QEMU. Otherwise quit with Ctrl-A X.
QEMU_CPU_PROPS := i=true e=false m=true a=true f=false d=false c=false v=false h=false \
    s=true u=true mmu=true sv32=true pmp=false priv_spec=v1.10.0 \
    zicsr=true zifencei=true zicntr=true zihpm=false zicbom=false zicboz=false \
    zicond=false zawrs=false zfa=false zihintntl=false zihintpause=false zmmul=false \
    sstc=false svadu=false svinval=false svnapot=false svpbmt=false \
    debug=false marchid=0x51454d55
space := $(subst ,, )
QEMU_CPU := rv32,$(subst $(space),$(comma),$(strip $(QEMU_CPU_PROPS)))
QEMU_FLAGS := -M virt -m 8M -smp 1 -nographic -bios none -cpu $(QEMU_CPU)
QEMU_DIR   := $(BUILD_DIR)/qemu
QEMU_SHIM  := $(QEMU_DIR)/fw_dynamic_shim.elf

ifneq ($(filter %.txt %.TXT,$(BIN)),)
QEMU_DEPS := $(QEMU_SHIM)
endif

# The shim lives in the virt machine's boot ROM (0x1000-0xffff), clear of RAM.
$(QEMU_SHIM): $(SW_DIR)/qemu/fw_dynamic_shim.S FORCE
	$(require-cross)
	@mkdir -p $(@D)
	@$(CC) $(ARCH_FLAGS) -nostdlib -nostartfiles -Wl,-Ttext=0x8000 \
	    -Wl,--no-warn-rwx-segments $(patsubst %u,%,$(BOOT_DESC_DEFS)) $< -o $@

QEMU_RUN = args=$$($(PYTHON) $(SCRIPTS)/run_image.py qemu --out $(QEMU_DIR) \
                   --shim $(QEMU_SHIM) $(BIN)) && $(QEMU) $(QEMU_FLAGS) $$args

qemu: $(QEMU_DEPS)
	@echo '  QEMU  $(BIN)  (Ctrl-A X quits)'
	@$(QEMU_RUN)

# Waits for gdb on :1234 before the first instruction; attach with make gdb.
qemu-gdb: $(QEMU_DEPS)
	@echo '  QEMU  $(BIN)  waiting for gdb on :1234 (make gdb BIN=...)'
	@$(QEMU_RUN) -s -S

# GDB is auto-detected (gdb-multiarch, riscv64-elf-gdb, gdb); BIN, if an ELF,
# provides the symbols.
gdb:
	$(GDB) -q -ex 'set architecture riscv:rv32' \
	    $(if $(filter-out %.txt %.TXT,$(BIN)),$(BIN)) -ex 'target remote :1234'

# --- vmem ---------------------------------------------------------------------
# One 32-bit little-endian word per line, the $readmemh format wb_ram loads.
# SIZE=<bytes> pads the image to a memory size and checks that it fits.
SIZE_BYTES ?=
VMEM_OUT := $(if $(OUT),$(OUT),$(BUILD_DIR)/vmem/$(basename $(notdir $(BIN))).vmem)

translate_bin_to_vmem:
	@mkdir -p $(dir $(VMEM_OUT))
	@$(PYTHON) $(SCRIPTS)/translate_bin_to_vmem.py '$(BIN)' $(VMEM_OUT) \
	    $(if $(BIN_ADDR),--base $(BIN_ADDR)) $(if $(SIZE_BYTES),--size $(SIZE_BYTES))

# --- Board console ------------------------------------------------------------
# Interactive. Uses tio, picocom or minicom when installed, otherwise a small
# built-in console (Ctrl-] quits). Attach after `make load`: programming the
# FPGA resets the USB serial channel.
console monitor:
	@test -e $(PORT) || { echo 'No serial port $(PORT); set PORT=.'; exit 1; }
	@if command -v tio >/dev/null; then exec tio -b $(BAUD) $(PORT); \
	elif command -v picocom >/dev/null; then exec picocom -b $(BAUD) $(PORT); \
	elif command -v minicom >/dev/null; then exec minicom -D $(PORT) -b $(BAUD); \
	else exec $(PYTHON) $(SCRIPTS)/uart_console.py $(PORT) $(BAUD); fi
