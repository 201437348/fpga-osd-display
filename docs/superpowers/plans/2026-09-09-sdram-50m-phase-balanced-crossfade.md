# 50 MHz Phase-Balanced SDRAM Crossfade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the accepted dual-frame crossfade positive SDRAM DQ setup
margin while preserving more read bandwidth than a conventional 45.45 MHz,
180-degree clock pair.

**Architecture:** Derate C1/C2 to 50 MHz, keep C2's measured absolute rising
edge at 8 ns by setting it to 144 degrees, and match the controller refresh
period to 20 ns.  No media or transition RTL changes.

**Tech Stack:** Anlogic EG4S20 PLL configuration, Verilog-2001, SystemVerilog,
Icarus Verilog, Tang Dynasty 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-09-sdram-50m-phase-balanced-crossfade-design.md`

## Global Constraints

- Keep C0 at 100 MHz and keep the separate video PLL unchanged.
- Keep the pure 32-frame blend, 64-word bursts, 4096-word dual FIFOs, and
  sticky fault diagnostics unchanged.
- Preserve unrelated working-tree changes and do not create a Git commit.
- Use JTAG only; preserve the accepted configuration Flash image.

---

### Task 1: Apply and Check the Phase-Balanced Clock Pair

**Files:**
- Modify: `fpga/osd_display/ip/anlogic/sys_pll.v`
- Modify: `fpga/osd_display/ip/anlogic/sys_pll.ipc`
- Modify: `fpga/osd_display/rtl/vendor/include/global_def.v`

**Interfaces:**
- Consumes: 50 MHz board reference clock and the existing C0 feedback path.
- Produces: C0=100 MHz, C1=50 MHz at 0 degrees, and C2=50 MHz at 144 degrees.

- [x] **Step 1: Detect the incorrect 216-degree generated clock**

Read the 21:08 TD derived-clock line and both DQ groups.  Require evidence that
`CLKC2_CPHASE=11` generated phase 216 with a 12 ns rising edge, leaving DQ read
setup at `-2.565ns` while DQ write setup became `+5.130ns`.

- [x] **Step 2: Correct only the C2 coarse phase tap**

Keep C1 at `CLKC1_DIV(20), CLKC1_CPHASE(19)` and change C2 from the incorrect
`CLKC2_CPHASE(11)` to `CLKC2_CPHASE(7)`.  Keep the IPC at 50 MHz / 144 degrees
and the active period macro at `1000000000/50000000`.

- [x] **Step 3: Run the source check again**

Expected: C0 remains `DIV/CPHASE=10/9`; C1 is `20/19`, C2 is `20/7`;
the IPC remains 50 MHz / 144 degrees;
the calculated refresh intervals are 31.248 us at 125 MHz, 31.248 us at
62.5 MHz, and approximately 31.24 us at 50 MHz.  The corrected TD build must
later report phase 144 and a C2 rising edge at 8 ns.

### Task 2: Run RTL Regression and Record the Handoff

**Files:**
- Test: `fpga/osd_display/tests/tb_video_transition_controller.sv`
- Test: `fpga/osd_display/tests/tb_video_transition_blender.sv`
- Test: `fpga/osd_display/tests/tb_frame_dual_fifo_read.sv`
- Test: `fpga/osd_display/tests/tb_frame_read_write_dual.sv`
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`
- Modify: `docs/project-roadmap.md`
- Modify: `docs/osd-display-migration.md`

**Interfaces:**
- Consumes: unchanged transition, dual-reader, FIFO, storage, audio, and OSD RTL.
- Produces: source-level evidence that the clock-only edit did not alter their contracts.

- [x] **Step 1: Run the five focused tests**

Compile each named test with its production RTL using `iverilog -g2012`, then
run it with `vvp`.  Expected: five `PASS` markers; the existing write-FIFO
`rdusedw` padding warning may remain.

- [x] **Step 2: Elaborate the real top level**

Compile `top.v` with `-DOSD_USE_REAL_FRAME_READ_WRITE`, the real frame wrapper,
both generated asynchronous FIFO sources, project control/storage/audio/video
RTL, and `tests/top_compile_stubs.v`.  Expected: exit code zero; existing FIFO
padding and 24-to-21-bit address warnings may remain.

- [x] **Step 3: Record the failed 216-degree build and corrected handoff**

Record the 21:08 bit hash, actual 216-degree clock, routed DQ slacks, successful
image writes, failed visual result, corrected C2 tap, completed source
regressions, and the board stop conditions in both project status documents.

### Task 3: TD and Board Acceptance

**Files:**
- Inspect: `fpga/osd_display/osd_display_Runs/phy_1/final_timing.rpt`
- Inspect: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: the checked 50 MHz source revision.
- Produces: routed timing evidence and a JTAG board acceptance result.

- [ ] **Step 1: Rebuild in TD 6.2.1**

Run `syn_1`, `phy_1`, and bitstream generation.  Confirm C1/C2 are 50 MHz and
C2 is 144 degrees.  Record global `SWNS/STNS/HWNS/HTNS`, both DQ setup/hold
groups, utilization, timestamp, and SHA256.

- [ ] **Step 2: Run the JTAG-only board regression**

Verify first image without `341100/341002`, at least ten manual transitions,
several automatic cycles, audio, OSD, and TF removal/reinsertion.  Observe the
last digit after any corruption.

- [ ] **Step 3: Apply the stop condition**

Accept only with clean transitions and a zero diagnostic digit.  A nonzero
digit or zero-code corruption rejects this final dual-frame experiment and
requires the documented single-frame fallback.  Do not write Flash on failure.
