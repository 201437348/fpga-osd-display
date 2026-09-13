# Slide Display Multi-Frame Diagnostic Implementation Plan

> **For agentic workers:** Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify consecutive moving frames across the real scheduler, asynchronous FIFO model, and video-delay path.

**Architecture:** A self-checking SystemVerilog test supplies address-encoded SDRAM returns to `frame_slide_fifo_read`, writes its output into the project FIFO model, and consumes it through `video_delay` on an independent clock.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0.

**Spec:** `docs/superpowers/specs/2026-09-12-slide-display-multiframe-design.md`

## Global Constraints

- Use 125 MHz memory and 25 MHz video clocks.
- Check all pixels at positions 0, 2, 20, 35, 48, 62, and 64.
- Do not enable or depend on any white marker.
- Keep TD and the downloader closed while files are edited.

---

### Task 1: Add the integration regression

**Files:**
- Create: `fpga/osd_display/tests/tb_frame_slide_display_multiframe.sv`

**Interfaces:**
- Consumes: scheduler FIFO write interface and video-delay FIFO read enable.
- Produces: exact per-pixel cross-frame assertions.

- [x] **Step 1:** Build address-encoded SDRAM returns and expected slide composition.
- [x] **Step 2:** Connect the real scheduler, asynchronous FIFO model, and video delay on independent clocks.
- [x] **Step 3:** Run seven consecutive frame positions and require all 896 pixels to match.

### Task 2: Diagnose or fix

**Files:**
- Modify only if the focused regression exposes a production RTL defect.

**Interfaces:**
- Consumes: the first exact mismatch from Task 1.
- Produces: either a tested RTL fix or evidence that modeled RTL is coherent.

- [x] **Step 1:** Run the modeled chain and document its clean 896-pixel result.
- [x] **Step 2:** Inspect physical timing and identify the failing write-FIFO-to-read-scheduler arbitration path.

### Task 3: Register write FIFO readiness

**Files:**
- Create: `fpga/osd_display/tests/tb_frame_fifo_write_arbiter.sv`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_fifo_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`

**Interfaces:**
- Consumes: write FIFO `rdusedw`, write progress, and `App_rd_busy`.
- Produces: registered FIFO readiness and an early `O_wr_busy` arbitration warning.

- [x] **Step 1:** Add a focused test proving FIFO-level changes cannot propagate asynchronously to `O_wr_busy`.
- [x] **Step 2:** Register the FIFO-ready comparison in `frame_fifo_write` while retaining final read-busy arbitration.
- [x] **Step 3:** Disable the read-FIFO white marker in the production top-level configuration.
- [x] **Step 4:** Run focused and full RTL regressions.
- [x] **Step 5:** Rebuild `syn_1` and `phy_1`, then confirm the repaired path in the new timing report before board interpretation.

### Task 4: Close residual scheduler timing

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v`

**Interfaces:**
- Consumes: address-encoded SDRAM returns and per-row old/new frame bases.
- Produces: the identical ordered pixel stream with registered cache output and shorter row-address arithmetic.

- [x] **Step 1:** Record that the write-FIFO path is absent from the first post-fix physical report.
- [x] **Step 2:** Add a common raw-pixel stage before difference calculation and increase pipeline FIFO reserve to four.
- [x] **Step 3:** Replace cascaded base-plus-row-offset expressions with incrementing current-row base registers.
- [x] **Step 4:** Re-run exact scheduler, full-line, multi-frame, downstream video, wrapper, and top-level regressions.
- [x] **Step 5:** Rebuild physical implementation and require the three residual `ext_mem_clk` same-clock paths to be absent or non-negative.
