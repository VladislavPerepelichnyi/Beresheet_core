#!/usr/bin/env bash
#
# Convert a program into the $readmemh image the testbench loads.
#
#   usage: prog_to_hex.sh <input> <output.hex>
#
# The input may be an ELF file, a raw binary, or an already-converted hex
# image; the type is detected from its contents rather than its name, so
# "make sim_no_graphics_rv32I /path/to/bin/riscv" works whatever that file is.

set -euo pipefail

IN=${1:?usage: prog_to_hex.sh <input> <output.hex>}
OUT=${2:?usage: prog_to_hex.sh <input> <output.hex>}
OBJCOPY=${OBJCOPY:-riscv64-unknown-elf-objcopy}

if [ ! -f "$IN" ]; then
    echo "prog_to_hex: no such file: $IN" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"

# ELF magic 0x7F 'E' 'L' 'F'
magic=$(head -c 4 "$IN" | od -An -tx1 | tr -d ' \n')

if [ "$magic" = "7f454c46" ]; then
    echo "prog_to_hex: $IN is an ELF, extracting with objcopy"
    "$OBJCOPY" -O verilog "$IN" "$OUT"

elif head -c 512 "$IN" | LC_ALL=C grep -qE '^(@[0-9A-Fa-f]+|[0-9A-Fa-f]{2}([ \t]|$))'; then
    echo "prog_to_hex: $IN already looks like a hex image, copying"
    cp "$IN" "$OUT"

else
    echo "prog_to_hex: treating $IN as a raw binary loaded at address 0"
    python3 - "$IN" "$OUT" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as f:
    f.write("@00000000\n")
    for i in range(0, len(data), 16):
        f.write(" ".join("%02X" % b for b in data[i:i+16]) + "\n")
PY
fi

echo "prog_to_hex: wrote $OUT"
