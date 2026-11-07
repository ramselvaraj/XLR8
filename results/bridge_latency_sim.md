# Bridge latency in simulation (Phase 2)

Produced 2026-11-07 by `make test-ball-axi` and `make test-xlr8` (Verilator 5.052). Memory model:
AXI3 slave with zero wait states when `+stall=0`. These are simulation numbers, not hardware.

## Ball frame (64x64, 4096 threads) through `xlr8_top`

| Case | Cycles per frame | Bus transactions | Stall cycles |
|---|---|---|---|
| Ideal single-cycle bus (Phase 1 testbench) | 91,143 | 24,576 | 0 |
| Through the AXI bridge, 0% stalls | 192,001 | 24,576 | 102,400 |
| Through the AXI bridge, 50% stalls | 248,794 | 24,576 | 158,453 |
| Through the AXI bridge, 90% stalls | 691,568 | 24,576 | 601,035 |

Transactions are exactly 6 per pixel (5 LDR + 1 STR), as planned.

## Derived (zero-stall floor)

- Bridge adds about 4.2 stall cycles per transaction (102,400 / 24,576), so one word costs about
  5.2 cycles end to end, including the one cycle the ideal bus took.
- Frame time floor at 50 MHz: 192,001 cycles = 3.84 ms (about 260 frames per second) with an ideal
  memory. Real DDR through HP0 will be slower; measured in Phase 4.
- Roughly 52% of the frame time is bridge latency, so cutting transactions per pixel (Phase 8
  kernel arguments, bursts, coalescing) is the lever that matters.

## Single-job check (brighten, 256 threads)

512 transactions, CYCLES = 3,617, STALLS = 2,304 at 0% stalls. The CYCLES register matches the
testbench's independent start-to-done count exactly.
