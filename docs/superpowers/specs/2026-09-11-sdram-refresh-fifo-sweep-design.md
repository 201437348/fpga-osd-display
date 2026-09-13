# SDRAM Refresh FIFO Sweep Design

## Goal

Measure the read path's behavior under periodic SDRAM refresh stalls for five
stall lengths and compare 512, 1024, and 4096-word read FIFOs at the worst
stall length.

## Test Matrix

All runs use a 125 MHz memory clock, 25 MHz pixel clock, 977 memory-clock
cycles between refresh stalls, 15 gap cycles after each 128-word SDRAM return
burst, and an upper bound of 24 video frames.

| Run | FIFO depth | FIFO level bits | Refresh stall cycles |
| --- | ---: | ---: | ---: |
| refresh_stall_1_depth_512 | 512 | 9 | 1 |
| refresh_stall_2_depth_512 | 512 | 9 | 2 |
| refresh_stall_4_depth_512 | 512 | 9 | 4 |
| refresh_stall_8_depth_512 | 512 | 9 | 8 |
| refresh_stall_16_depth_512 | 512 | 9 | 16 |
| refresh_stall_16_depth_1024 | 1024 | 10 | 16 |
| refresh_stall_16_depth_4096 | 4096 | 12 | 16 |

## Architecture

Keep production RTL unchanged. A parameterized Verilog testbench connects
`sdram_model_refresh.Sdr_busy` to the DUT and passes matching FIFO depth and
level-width parameters into `frame_read_write`. The behavioral read FIFO gains
overridable depth and address-width parameters; the testbench applies them to
the existing `dut.read_buf` instance with `defparam`, because production RTL
instantiates the vendor-compatible module without a parameter override.

A PowerShell runner compiles each matrix row independently with Icarus
Verilog, runs it, stores its full log, and emits CSV and console summaries.
Each testbench run prints per-frame raw underflow cycles, episode counts, the
RTL saturating episode counter, dropped SDRAM commands, and a final structured
`RESULT` record.

## Result Semantics

A normal run completes after 24 frame request edges. `dropped_commands > 0`
proves a read command coincided with modeled refresh busy. `scheduler_stuck=1`
is a terminal result asserted only when the scheduler is in `S_WAIT_RETURN`
after a dropped command and the SDRAM latency pipe and return queue have both
remained empty for 64 memory-clock cycles; no future return can then satisfy
the chunk. A run fails infrastructure validation if compilation fails, the
process exceeds the wall-clock timeout, or no structured `RESULT` line is
produced. The structured result is the runtime success marker because Windows
PowerShell does not populate `Start-Process.ExitCode` reliably when both
output streams are redirected. Underflow and scheduler deadlock are measured
outcomes, not script failures.

## Scope

This is simulation-only instrumentation. It does not change controller
protocol behavior, vendor IP, or synthesizable production RTL.
