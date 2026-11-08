# Phase 5: Linux Kernel Driver

## Goal

Replace `/dev/mem` poking with a proper kernel driver that exposes the GPU as `/dev/xlr8`.

## Starting points

- Phase 4 hardware behavior and register map
- The pinned PYNQ image and its kernel headers (Phase 0, `docs/TOOLCHAIN.md`)

## Device tree

`dts/xlr8.dtsi` (or overlay) node:

- `compatible = "ramselvaraj,xlr8-1.0"`
- `reg` for the register block, `interrupts` for `IRQ_F2P[0]`
- `memory-region` pointing at a reserved CMA region if `dma_alloc_coherent` is not used

VERIFY how the PYNQ image loads overlays (runtime device-tree overlay vs static DTB) and pick the
method that works there.

## Driver design

| Piece | Design |
|---|---|
| Binding | platform driver, `of_match_table` |
| Device | `miscdevice` named `xlr8` |
| Registers | `devm_platform_ioremap_resource` |
| IRQ | `devm_request_irq`, handler clears `IRQ_STATUS`, wakes a waitqueue |
| Memory | one coherent DMA buffer per open file, programmed into `MEM_BASE`/`MEM_LIMIT` |
| Mapping | `mmap` of the buffer with a matching cache policy |
| Concurrency | one job at a time; a mutex serializes submitters; second opener allowed, jobs queue |
| Timeout | job watchdog with `SOFT_RESET` recovery |

## ioctl ABI (`driver/xlr8_uapi.h`)

| ioctl | Meaning |
|---|---|
| `XLR8_IOC_LOAD_PROG` | copy N instructions into the program window |
| `XLR8_IOC_SET_BUF` | allocate or resize the buffer, returns size |
| `XLR8_IOC_SUBMIT` | `{threads, src, dst, prog_base}`, starts a job |
| `XLR8_IOC_WAIT` | block until DONE or timeout, returns status and counters |
| `XLR8_IOC_GET_INFO` | ID, version, counters |

The header is versioned and uses `__u32`/`__u64` fixed-width types only. Reserved fields must be
zero. Unknown ioctl returns `-ENOTTY`.

## Tasks

1. Write the device-tree node and confirm Linux binds the driver on boot.
2. Implement probe, remove, open, release, ioctl, mmap, poll.
3. Handle process exit mid-job: soft reset, free buffer, no stuck BUSY.
4. Write `driver/tests/`: open/close loop, concurrent submitters, bad arguments, oversized
   program, bad buffer size, wait timeout, kill during job.
5. Run the 1,000-frame soak through the driver.
6. Check `dmesg` is clean and there are no leaks after 10,000 open/close cycles.

## Exit criteria

- Module loads and unloads cleanly, `/dev/xlr8` appears.
- 1,000 ball frames exact through the driver, interrupt-driven (no polling).
- Killing a process mid-job leaves the device usable.
- `dmesg` shows no warnings, oopses, or leaked allocations.
