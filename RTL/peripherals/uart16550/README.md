# uart16550

Third-party UART from the OpenCores `uart16550` project
(<https://opencores.org/projects/uart16550>), distributed under the GNU Lesser
General Public License; see the notice at the top of each file. The files are
kept as close to upstream as possible so that a diff shows only local changes.

`uart_wb_slave.v` is not part of upstream: it is this project's wrapper that
connects the core to the SoC bus and ties off the unused modem-control pins.

## Local change

`uart_defines.v` defines `LITLE_ENDIAN` (upstream spelling).

In 32-bit bus mode `uart_wb.v` derives the low two bits of the register index
from the byte lane selected by `SEL`. Without `LITLE_ENDIAN` it uses the
big-endian mapping (`SEL=0001` selects register offset 3), which reverses the
register order seen by a little-endian CPU. With it defined, a byte access at
`UART_BASE + N` reaches register `N`: the standard 16550 layout, `reg-shift = 0`
and `reg-io-width = 1` in device-tree terms.

## Configuration

`DATA_BUS_WIDTH_8` is left undefined, so the core is built in 32-bit bus mode
(`UART_ADDR_WIDTH = 5`, `UART_DATA_WIDTH = 32`).
