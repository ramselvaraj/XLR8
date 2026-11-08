# Phase 4: Hardware Bring-Up from Userspace

## Goal

Prove the design works on the real board before writing any kernel code, by driving it from
Python or C through `/dev/mem` or UIO.

## Starting points

- Phase 3 `.bit` and `.hwh`
- PYNQ image on the board

## Tasks

1. Load the bitstream with PYNQ `Overlay` (or `fpgautil`) and read the `ID` register. Expect
   `0x584C5238`.
2. Reserve a contiguous buffer: PYNQ `allocate` for now. Record its physical address.
3. Write `tools/bringup.py`: load a kernel through the program window, write the parameter block,
   set `MEM_BASE`, `MEM_LIMIT`, `THREADS`, `SRC`, `DST`, `START`, poll `STATUS`.
4. Run `gradient` first, then `ball`. Compare each frame to the golden model.
5. Read `CYCLES`, `BUS_XACTS`, `BUS_STALLS` and compute real `L`.
6. Test error paths on hardware: bad `MEM_LIMIT`, START while BUSY, program write while BUSY.
7. Cache coherence check: verify the CPU sees fresh GPU pixels. If the buffer is cacheable, confirm
   what happens and fix it. Record the finding.
8. Soak: 1,000 frames, zero mismatches.
9. If a mismatch appears, add an ILA build option and capture it.

## Exit criteria

- ID register reads back correctly.
- 1,000 ball frames exact on hardware.
- Measured `L` and frame time recorded in `results/hw_bringup.md`.
- The cache-coherence behavior is documented with evidence.
