# Crossfade Read-Margin Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Increase dual-frame read buffering and expose sticky board-visible evidence for FIFO underflow and frame-read overrun without changing the accepted crossfade.

**Architecture:** Two generated asynchronous read FIFOs remain the memory-to-video boundary but grow to 4096 words each.  `frame_read_write` detects read attempts while either FIFO is empty, while `frame_dual_fifo_read` detects a new frame request before the current command set completes; the top level synchronizes and displays their combined sticky flags.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, Anlogic asynchronous FIFO IP, Icarus Verilog, Tang Dynasty 6.2.1 GUI.

**Spec:** `docs/superpowers/specs/2026-09-09-crossfade-read-margin-diagnostics-design.md`

## Global Constraints

- Keep the existing 32-frame alpha sequence and RGB blend unchanged.
- Keep the SDRAM clocks at 125 MHz, 0/180 degrees.
- Keep the accepted configuration Flash image unchanged; test this revision by JTAG only.
- Preserve unrelated working-tree changes and do not create a Git commit.

---

### Task 1: Read-Fault Tests

**Files:**
- Modify: `fpga/osd_display/tests/tb_frame_dual_fifo_read.sv`
- Modify: `fpga/osd_display/tests/tb_frame_read_write_dual.sv`

**Interfaces:**
- Consumes: existing `frame_dual_fifo_read` and `frame_read_write` test interfaces.
- Produces: assertions for `frame_overrun_seen` and `read_fault_flags[2:0]`.

- [x] **Step 1: Add the scheduler-overrun assertion**

Connect `frame_overrun_seen`, prove it remains zero for completed requests,
then issue a second synchronized `read_req` while a gapped-return transaction
is still active and require the output to latch high.

- [x] **Step 2: Add FIFO-underflow assertions**

Connect `read_fault_flags`, first require `3'b000` after normal paired reads,
then reset both FIFOs to a known-empty state, request a paired pixel, and
require bits 0 and 1 to latch.

- [x] **Step 3: Run tests to verify the new ports fail before implementation**

```powershell
$schedOut = Join-Path $env:TEMP 'tb_frame_dual_fifo_read.vvp'
$frameOut = Join-Path $env:TEMP 'tb_frame_read_write_dual.vvp'
iverilog -g2012 -s tb_frame_dual_fifo_read -o $schedOut fpga\osd_display\tests\tb_frame_dual_fifo_read.sv fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v
iverilog -g2012 -s tb_frame_read_write_dual -o $frameOut fpga\osd_display\tests\tb_frame_read_write_dual.sv fpga\osd_display\rtl\vendor\SD\frame_read_write.v fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v fpga\osd_display\rtl\vendor\SD\frame_fifo_write.v fpga\osd_display\ip\anlogic\afifo_32_16_256.v fpga\osd_display\ip\anlogic\afifo_16_32_256.v
```

Expected: elaboration fails because the new diagnostic ports do not exist.

### Task 2: Sticky Fault Detection and Read-Margin Increase

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_dual_fifo_read.v`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`

**Interfaces:**
- Consumes: `read_req_d2`, scheduler progress counters, FIFO `empty_flag`, pixel read enables, and `dual_read_mode`.
- Produces: sticky `frame_overrun_seen` and `read_fault_flags[2:0]`.

- [x] **Step 1: Latch an incomplete-frame overrun**

Add `frame_overrun_seen` to the scheduler interface, clear it only on global
reset, and set it when synchronized `read_req` is high outside IDLE/ACK/END
while either required read count remains below `read_len_latched`.

- [x] **Step 2: Observe FIFO empties at the pixel boundary**

Connect both generated FIFO `empty_flag` outputs.  In the `read_clk` domain,
latch bit 0 for `read_en && new_fifo_empty` and bit 1 for
`dual_read_mode && read_en_old && old_fifo_empty`.  Combine these with the
scheduler's sticky overrun as bit 2.

- [x] **Step 3: Increase both FIFO address widths**

Change `READ_FIFO_DEPTH` to 4096 and `READ_FIFO_LEVEL_BITS` to 12.  Retain the
64-word burst and `FIFO_DEPTH - BURST_SIZE` admission rule.

- [x] **Step 4: Run focused tests**

Run both commands from Task 1 followed by `vvp $schedOut` and
`vvp $frameOut`.  Expected output contains `PASS tb_frame_dual_fifo_read` and
`PASS tb_frame_read_write_dual`.

### Task 3: Board-Visible Diagnostic and Regression

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`
- Modify: `docs/project-roadmap.md`
- Modify: `docs/osd-display-migration.md`

**Interfaces:**
- Consumes: `frame_read_write.read_fault_flags[2:0]`.
- Produces: two-stage `clk`-domain synchronization and last-digit fault code override.

- [x] **Step 1: Synchronize and display the sticky flags**

Add two three-bit synchronizer registers in `top.v`.  Keep `seg_digit_x` on
the existing `error_code` when flags are zero; otherwise display
`{1'b0, flags}`.

- [x] **Step 2: Update the compile stub and elaborate the real top level**

Add the diagnostic output to the stub signature, then run the established
top-level Icarus elaboration using the real `frame_read_write`, generated FIFO
sources, and transition modules.  Expected: no unresolved port or module
errors; pre-existing width and vendor RAM warnings may remain.

- [x] **Step 3: Run the five focused regressions**

Run `tb_video_transition_controller`, `tb_video_transition_blender`,
`tb_frame_dual_fifo_read`, `tb_frame_read_write_dual`, and
`tb_video_osd_overlay`.  Expected: all print `PASS`.

- [x] **Step 4: Record the handoff**

Document the latest failed board result, the unchanged visual design, the
new buffer depth, diagnostic code meanings, and the required JTAG-only TD
build.  Do not claim the issue fixed until the board shows no corruption.
