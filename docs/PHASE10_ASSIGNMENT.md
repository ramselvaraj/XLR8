# Phase 10: Polish, Demo, Write-Up

## Goal

Make the project legible to someone who has five minutes.

## Tasks

1. README: one-paragraph pitch, architecture diagram, results table (from `results/` only),
   quick start with exact commands, known limitations.
2. Diagrams: system architecture, the one-frame sequence, and the kernel dataflow. Mermaid
   sources committed beside the rendered PNGs.
3. A 60 to 90 second demo video: boot, load driver, run renderer, show the animation.
4. A short write-up (blog-style) of the three hardest bugs and how they were found.
5. Reproducibility pass: a clean clone builds the simulation, the bitstream, the driver and the
   app with documented commands.
6. License file and third-party notices for vendored RAPTOR code.
7. Resume bullets, with every number traced to `results/`.
8. Add XLR8 to the FPGA and design resumes; remove or demote weaker entries.

## Exit criteria

- A friend can follow the README on a fresh machine and reproduce the simulation results.
- Every claim in the README and resume cites a file in `results/`.
