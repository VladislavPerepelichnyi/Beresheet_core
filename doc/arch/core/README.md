# Part I: The processor core

Back to the [book index](../README.md).

1. [Overview](00-overview.md)
2. [Instructions and formats](01-isa-and-formats.md)
3. [The three-stage pipeline](02-pipeline.md)
4. [Multiply and divide (M)](03-m-extension.md)
5. [Atomics (A)](04-a-extension.md)
6. [Privilege, CSRs and traps](05-privilege-and-traps.md)
7. [Virtual memory (Sv32)](06-virtual-memory.md)
8. [Caches](07-caches.md)
9. [Counters and timers](08-counters-and-timers.md)
10. [From reset to a shell](09-boot.md)
11. [Limitations and known issues](10-limitations.md)

## Figures

| Figure | Chapter |
|---|---|
| [SoC block diagram](figures/soc-block-diagram.svg) | 0 |
| [Instruction formats and immediates](figures/instruction-formats.svg) | 1 |
| [Pipeline datapath](figures/pipeline-datapath.svg) | 2 |
| [Pipeline timing: bypass, mispredict, holds, stalls](figures/pipeline-timing.svg) | 2 |
| [Trap and interrupt flowchart](figures/trap-flowchart.svg) | 5 |
| [Privilege mode transitions](figures/privilege-modes.svg) | 5 |
| [Sv32 translation, with a worked example](figures/sv32-translation.svg) | 6 |
| [TLB organisation and page walker](figures/tlb-organisation.svg) | 6 |
| [Cache organisation and pseudo-LRU](figures/cache-organisation.svg) | 7 |
| [Cache state machine](figures/cache-fsm.svg) | 7 |
| [Boot flow and memory map](figures/boot-flow.svg) | 9 |

Colours mean the same thing in every figure:

| Colour | Meaning |
|---|---|
| Blue | Stage 1 (Fetch), instruction side |
| Green | Stage 2 (Decode/Execute) |
| Orange | Stage 3 (Memory/Writeback); the orange arrow is the register write-back bypass |
| Purple | Control: control unit, CSRs, privilege; dashed purple lines are control signals |
| Yellow | Memory system: TLBs, caches |
| Red | Faults and traps |
| Grey | Registers, pipeline registers, bus blocks, devices |
