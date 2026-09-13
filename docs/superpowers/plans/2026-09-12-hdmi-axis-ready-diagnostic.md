# HDMI AXIS Ready Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose any HDMI AXIS backpressure during valid video as a persistent board-visible count.

**Architecture:** The RGB-to-AXIS source observes the HDMI core's ready signal without changing its current raster output. A saturating diagnostic counter crosses through the existing status synchronization pattern and exclusively drives the rightmost seven-segment digit.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-hdmi-axis-ready-diagnostic-design.md`

## Global Constraints

- Do not gate, delay, recolor, or reorder AXIS video in this diagnostic revision.
- Count only cycles where registered AXIS valid is high and HDMI ready is low.
- Saturate at `4'hF` and retain the value until reset.
- Keep TD closed while RTL is edited.

---

### Task 1: Monitor the AXIS transfer contract

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/video_rgb_to_axis_640x480.v`
- Test: `fpga/osd_display/tests/tb_video_rgb_to_axis_line_boundary.sv`

**Interfaces:**
- Consumes: `I_video_ready` alongside the existing registered AXIS output.
- Produces: `O_backpressure_count[3:0]`, sticky and saturating.

- [x] **Step 1:** Extend the testbench connection and verify zero count with ready continuously high.
- [x] **Step 2:** Inject three low-ready cycles while AXIS valid is high and require count `3` without changing pixel, SOF, or TLAST checks.
- [x] **Step 3:** Extend low-ready injection beyond fifteen cycles and require saturation at `F`.
- [x] **Step 4:** Implement the counter and run the test to `PASS tb_video_rgb_to_axis_line_boundary`.

### Task 2: Expose the count on hardware

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`

**Interfaces:**
- Consumes: HDMI `axis_s_ready` and `axis_backpressure_count` in `video_clk`.
- Produces: synchronized `axis_backpressure_count_sd_sync` displayed on `seg_digit_x`.

- [x] **Step 1:** Connect `axis_s_ready` to the converter ready input and its count output to a new wire.
- [x] **Step 2:** Add the same two-register diagnostic CDC pattern used by the existing read-underflow count.
- [x] **Step 3:** Reserve `seg_digit_x` exclusively for the AXIS count.
- [x] **Step 4:** Run focused regressions, interface elaboration, and `git diff --check`.

### Task 3: Build and observe

**Files:**
- Generate: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: the verified diagnostic RTL.
- Produces: a current bitstream and a rightmost-digit observation after at least one transition.

- [ ] **Step 1:** Rebuild `syn_1`, `phy_1`, and bitgen in TD.
- [ ] **Step 2:** Record the newest successful bitstream timestamp and SHA-256.
- [ ] **Step 3:** JTAG-download without power cycling, trigger several slides, and report the rightmost digit.
