# Phase 4 Progress

## Done on hardware (SLVERR_EN=1 bitstream)

- Bitstream loads through PYNQ, ID register reads `0x584C5238`.
- 1,000 ball frames exact in real DDR, 9.09 ms per frame (454,630 cycles at 50 MHz).
- Error paths (START/program write while BUSY, unmapped read, bad MEM_LIMIT, soft reset) behave
  as specified.
- Cache coherence characterized: cacheable buffers are stale without invalidation.
- Details and commands: `results/hw_bringup.md`.

## Decision

The SLVERR response kills the accessing process with SIGBUS, so the Linux bitstream is built with
`SLVERR_EN=0`.

## Open

- Re-run the soak and error tests on the `SLVERR_EN=0` bitstream (building).
- Interrupt-driven operation is exercised in Phase 5 (polling only here, as specified).
