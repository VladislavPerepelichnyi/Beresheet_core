# =============================================================================
# Sipeed Tang Mega 138K Pro: placeholder.
#
# Selecting it is accepted so the option is visible, but every target that
# needs the SoC stops with "not supported yet". Porting means adding a top
# level, PLL, constraints and build.tcl under RTL/fpga/tangmega138kpro and
# filling in the values below (see tangnano20k.mk).
# =============================================================================

BOARD_NAME      := Sipeed Tang Mega 138K Pro
BOARD_SUPPORTED :=
BOARD_DEFINE    := TANGMEGA138KPRO
SOC_CLK_HZ      := 24000000

BOARD_RTL_DIR   := RTL/fpga/tangmega138kpro
BOARD_TCL       := $(BOARD_RTL_DIR)/build.tcl
BOARD_SDC       :=
BOARD_SRC       :=
GOWIN_PART      := GW5AST-LV138FPG676AES
GOWIN_OUTPUT    := beresheet
BOARD_BOOT_IMAGE := bios.wordhex
LOADER_BOARD    := tangmega138kpro
