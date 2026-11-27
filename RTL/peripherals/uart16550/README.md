# uart16550 — local copy

Source: OpenCores `uart16550`, from
`RTL/perepherical_reference/uart16550_latest/uart16550/trunk/rtl/verilog/`,
which stays untouched so this copy can be diffed against it.

## Why a copy at all

One change is required: `uart_defines.v` now defines `LITLE_ENDIAN`.

In 32-bit bus mode `uart_wb.v` derives the low two bits of the register index
from *which byte lane* `SEL` selects. Without `LITLE_ENDIAN` it uses the
big-endian mapping (`SEL=0001` → register offset 3), which reverses the register
order as seen by a little-endian CPU. RISC-V is little-endian, so leaving this
undefined puts every register at the wrong address.

With it defined, a byte access at `UART_BASE + N` reaches register `N` — the
classic 16550 layout, `reg-shift = 0` in device-tree terms.

## Configuration in force

`DATA_BUS_WIDTH_8` stays commented out, so the core is in 32-bit mode:
`UART_ADDR_WIDTH = 5`, `UART_DATA_WIDTH = 32`.

Verify with:

    diff -r RTL/peripherals/uart16550 \
            RTL/perepherical_reference/uart16550_latest/uart16550/trunk/rtl/verilog
