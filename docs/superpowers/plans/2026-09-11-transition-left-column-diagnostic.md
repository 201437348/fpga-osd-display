# Transition Left-Column Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify and correct the fixed `x=0` colored column visible during horizontal transitions.

**Architecture:** Verify the production FIFO-to-RGB line boundary first, then verify the RGB-to-AXIS line packet boundary. Apply a minimal correction only at the first stage whose marker test fails, preserving SDRAM scheduling and transition composition.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-11-transition-left-column-diagnostic-design.md`

## Global Constraints

- Do not change SDRAM scheduling, FIFO depth, slide positions, feather blending, frame buffers, HDMI timings, or OSD layout.
- Do not mask, repaint, crop, or duplicate the first visible column.
- Keep TD closed while RTL and project files are edited.
- Require exact first/second/last pixel ordering and exactly one end-of-line indication per 640-pixel active line.

---

### Task 1: Verify FIFO-to-RGB line boundaries

**Files:**
- Create: `fpga/osd_display/tests/tb_video_delay_line_boundary.sv`
- Read: `fpga/osd_display/rtl/vendor/SD/video_delay.v`
- Read: `fpga/osd_display/ip/anlogic/afifo_32_16_256.v`

**Interfaces:**
- Consumes: production `rfifo_32_32_512`, production `video_delay`, marker pixels, and two short active lines separated by blanking.
- Produces: assertions for ordered output pixels while delayed `de` is high.

- [x] **Step 1:** Preload eight distinct marker pixels into the production FIFO, representing two four-pixel rows whose row-end and next-row start are deliberately different.
- [x] **Step 2:** Drive two four-cycle `de` intervals with sufficient blanking and capture each `vout_data` value on delayed `de`.
- [x] **Step 3:** Assert eight outputs in exact FIFO order, specifically checking row 1 `x=3`, row 2 `x=0`, and row 2 `x=1`; report previous-row leakage, duplication, or skipping separately.
- [x] **Step 4:** Compile with the production FIFO and `video_delay`, then run to `PASS tb_video_delay_line_boundary` or retain the precise failing assertion as diagnostic evidence.

### Task 2: Verify RGB-to-AXIS line packet boundaries

**Files:**
- Create: `fpga/osd_display/tests/tb_video_rgb_to_axis_line_boundary.sv`
- Modify only if the test fails: `fpga/osd_display/rtl/vendor/video_rgb_to_axis_640x480.v`

**Interfaces:**
- Consumes: two 640-pixel lines with unique first and final marker pixels.
- Produces: AXIS pixel ordering plus `O_video_valid`, `O_video_user`, and `O_video_last` assertions.

- [x] **Step 1:** Drive two exact 640-cycle active lines and distinct marker RGB values at each line's `x=0`, `x=1`, and `x=639`.
- [x] **Step 2:** Assert that AXIS data preserves both lines exactly, `O_video_user` occurs only on the first frame pixel, and `O_video_last` occurs exactly on pixel 639 of each line.
- [x] **Step 3:** Run the test before editing RTL. The expected current failure is missing or misplaced `O_video_last`, because the first active pixel resets `S_x_cnt` without advancing it and the final pixel therefore observes count 638 rather than 639.
- [x] **Step 4:** Correct the line counter so its value represents the current active pixel at the cycle used for `O_video_last`; do not alter RGB data or valid latency.
- [x] **Step 5:** Re-run the test to `PASS tb_video_rgb_to_axis_line_boundary`.

### Task 3: Regress the complete affected surface

**Files:**
- Test: `fpga/osd_display/tests/tb_video_transition_controller.sv`
- Test: `fpga/osd_display/tests/tb_frame_slide_fifo_read.sv`
- Test: `fpga/osd_display/tests/tb_frame_read_write_underflow.sv`
- Test: `tmp_investigate2/run_refresh_sweep.ps1`

**Interfaces:**
- Consumes: corrected video packetization and existing SDRAM/transition RTL.
- Produces: simulation evidence suitable for TD synthesis and board testing.

- [x] **Step 1:** Run both new line-boundary tests and the transition controller, slide scheduler, and frame-read underflow regressions.
- [x] **Step 2:** Compile the real top-level source set to catch integration or interface regressions.
- [x] **Step 3:** Run the seven-case refresh sweep and require `underflow=0`, `dropped=0`, and `scheduler_stuck=0` for every case.
- [x] **Step 4:** Run `git diff --check` and inspect the scoped RTL diff.
- [x] **Step 5:** Rebuild `syn_1`, run physical implementation with seed 2, and generate a current bitstream.
- [ ] **Step 6:** Test the fixed left column on hardware.

### Task 4: Close the 125 MHz feather datapath timing violation

**Files:**
- Create: `fpga/osd_display/tests/tb_frame_slide_full_line.sv`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v`
- Inspect: `fpga/osd_display/osd_display_Runs/phy_1/seed_2/osd_display_pr.timing`

**Interfaces:**
- Consumes: ordered SDRAM return words and the existing phase metadata.
- Produces: one ordered FIFO word per direct/blended output pixel after a
  fixed pipeline delay.

- [x] **Step 1:** Add a 640-pixel-wide marker test covering disabled feather,
  enabled feather, both endpoints, and exact `x=0`, `x=1`, seam, and `x=639`
  values for two rows.
- [x] **Step 2:** Run it against the current implementation and retain the
  passing functional baseline; the expected failure is physical timing, not
  RTL pixel arithmetic.
- [x] **Step 3:** Register blend operands, multiplication, and final add/sub
  in separate stages while carrying direct pixels through the same ordered
  valid pipeline.
- [x] **Step 4:** Reserve pipeline occupancy in FIFO room accounting and hold
  the final scheduler state until all pipeline valids drain.
- [x] **Step 5:** Run the full-line test, existing focused tests, seven-case
  refresh sweep, real-top elaboration, and `git diff --check`.
- [x] **Step 6:** Rebuild seed 2 and confirm the former -4.746 ns scheduler
  path is absent or non-negative before generating the board-test bitstream.
- [ ] **Step 7:** Ask for a board test of the newly generated bitstream.
