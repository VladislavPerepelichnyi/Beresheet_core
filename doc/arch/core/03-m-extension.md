# 3. Multiply and divide (the M extension)

Previous: [2. The three-stage pipeline](02-pipeline.md) | [Book index](../README.md) | Next: [4. Atomics](04-a-extension.md)

The M extension adds eight instructions: four multiplies (`MUL`, `MULH`,
`MULHSU`, `MULHU`) and four divides (`DIV`, `DIVU`, `REM`, `REMU`). They are
R-type, opcode `OP`, with `funct7 = 0000001`; `funct3` picks the operation. A
32 x 32 multiply is too slow for one 41.7 ns cycle on this FPGA, and a divide
much more so, so both are **multi-cycle** units that hold their instruction in
stage 2 until the result is ready. The interesting part of this chapter is
less the arithmetic than the handshake that lets a slow unit live inside a
pipeline.

## 3.1 The handshake: `req`, `stall`, `hold`

`muldiv` is the wrapper that stage 2 sees. It has a three-state machine,
`ST_IDLE`, `ST_BUSY` and `ST_DONE`, and three signals:

- `req` is high for as long as an M instruction is in stage 2 (`is_muldiv & valid`).
- `stall` (exported as `muldiv_stall`) is high from the first cycle of the
  request until the result is ready. The control unit answers it with "hold
  stage 2, bubble stage 3" ([2.6](02-pipeline.md#26-stalls-and-flushes)).
- `hold` (the control unit's `pipeline_hold`) says that something *more
  important* is holding the pipeline: a memory stall, a fetch stall, a pending
  trap, a CSR access.

`hold` gates both ends of the operation:

- **The start.** Operands are latched only when nothing is holding the
  pipeline. If the instruction ahead is a load still waiting for memory, the
  register file's bypass has not delivered the loaded value yet, and `rs1`/`rs2`
  would be stale. Starting then would compute the right operation on the wrong
  numbers.
- **The finish.** In `ST_DONE` the result is presented for one cycle with
  `stall` low, so the instruction leaves stage 2 carrying it. If something else
  holds the pipeline in that very cycle, the unit stays in `ST_DONE` rather
  than returning to idle and losing the result.

The result leaves through the ordinary ALU-result bus (`alu_result`), so
EX/MEM and the write-back multiplexer do not know that the instruction took
more than one cycle.

## 3.2 The multiplier

All four multiplies come out of **one signed 33 x 33-bit multiplication**. Each
operand is widened by one bit: sign-extended if that operand is signed for this
instruction, zero-extended if not.

| Instruction | rs1 treated as | rs2 treated as | Result bits |
|---|---|---|---|
| `MUL` | signed | signed | 31:0 |
| `MULH` | signed | signed | 63:32 |
| `MULHSU` | signed | unsigned | 63:32 |
| `MULHU` | unsigned | unsigned | 63:32 |

A 33-bit signed number can hold any 32-bit signed or unsigned value, so the
low 64 bits of the 66-bit product are the correct two's-complement result in
every case. (For `MUL` the signedness does not matter for the low half; the
RTL treats it as signed.)

`mul_unit` has two register stages: stage A captures the widened operands,
stage B registers the product. The multiplication between them maps onto the
FPGA's hard multiplier blocks. `done` rises two cycles after `start`.

## 3.3 The divider

`div_unit` is a textbook **restoring divider** working on magnitudes, one
quotient bit per cycle (see Harris & Harris chapter 5 for the array form of the
same algorithm). On entry it strips the signs; each of 32 iterations shifts the
next dividend bit into the partial remainder and subtracts the divisor if it
fits; on exit the signs are put back:

- the quotient is negative when the operand signs differ;
- a non-zero remainder has the sign of the dividend.

Two cases skip the loop and finish in one cycle, with the results the
specification requires (unprivileged specification, M chapter, division by
zero and overflow table):

| Case | Quotient | Remainder |
|---|---|---|
| Divide by zero | all ones (`-1`) | the dividend |
| Signed overflow, `-2^31 / -1` | `-2^31` | 0 |

No exception is raised in either case: RISC-V division never traps.

One bit per cycle is a deliberate area choice. In a static count of the Linux
kernel image, divide and remainder instructions are a few hundred out of about
three quarters of a million, roughly a third as common as multiplies.

## 3.4 Latency

Counting the cycles an M instruction spends in stage 2, from the cycle it
arrives to the cycle it leaves (with no other stalls):

| Operation | Unit latency (`start` to `done`) | Cycles in stage 2 |
|---|---|---|
| Multiply (any) | 2 | 4 |
| Divide or remainder, general case | 34 (1 set-up, 32 iterations, 1 sign fix-up) | 36 |
| Divide by zero or signed overflow | 1 | 3 |

The two extra cycles in stage 2 come from the wrapper: one to latch the
sub-unit's result into `result_q`, one in `ST_DONE` to hand it over.

## 3.5 Interaction with interrupts

An interrupt is never taken while an M operation is in progress: the
interrupt boundary condition in the control unit includes `!muldiv_stall`.
Abandoning a divide half-way would throw away work with nothing to resume
from, and taking the interrupt before the instruction *starts* or after it
*leaves* stage 2 is just as correct. Test `18_div_irq` in `tests/rv32i`
exercises exactly this case.

## Where this is in the RTL

| What | File | Names |
|---|---|---|
| Wrapper, start/finish protocol | `RTL/core/muldiv.v` | `muldiv`, `req`, `hold`, `stall`, `ST_IDLE/BUSY/DONE`, `result_q` |
| Multiplier | `RTL/core/mul_unit.v` | `a_wide`, `b_wide`, `product_q`, `valid_q` |
| Divider | `RTL/core/div_unit.v` | `div_by_zero`, `overflow`, `rem_shifted`, `step_fits`, `ST_DIVIDE`, `ST_FINISH` |
| Instantiation, request, result bus | `RTL/core/decode_exec.v` | `muldiv_inst`, `is_muldiv`, `muldiv_result` |
| Decode, stall, interrupt boundary | `RTL/core/control_unit.v` | `F7_MULDIV`, `muldiv_stall`, `pipeline_hold`, `irq_boundary` |
| Tests | `tests/rv32i/06_muldiv.S`, `07_muldiv_random.S`, `18_div_irq.S` | |
