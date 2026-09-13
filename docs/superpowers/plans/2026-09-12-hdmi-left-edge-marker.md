# HDMI Left-Edge Marker Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a board-testable transition that places a known white 16-pixel marker at the final AXIS left edge.

**Architecture:** The existing RGB-to-AXIS register performs the diagnostic override using its existing line-start state and horizontal counter. The production top enables the marker only from `slide_active`, leaving all steady frames unchanged.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-hdmi-left-edge-marker-design.md`

## Global Constraints

- Override exactly x=0 through x=15 with `24'hFFFFFF` only when marker enable is high.
- Do not change valid, ready monitoring, SOF, TLAST, FIFO, SDRAM, OSD, or HDMI timing.
- Keep hard-cut transition mode enabled for comparison with the previous board result.
- Keep TD closed while RTL is edited.

---

### Task 1: Specify marker behavior

**Files:**
- Test: `fpga/osd_display/tests/tb_video_rgb_to_axis_line_boundary.sv`

**Interfaces:**
- Consumes: `I_marker_enable` at the RGB-to-AXIS boundary.
- Produces: exact pixel assertions for disabled and enabled rows.

- [x] **Step 1:** Drive one complete marker-disabled line and require all 640 original pixels.
- [x] **Step 2:** Drive two complete marker-enabled lines and require white at x=0..15 plus original RGB at x=16..639.
- [x] **Step 3:** Preserve the existing ready-high, injected-backpressure, saturation, SOF, TLAST, and total-valid assertions.
- [x] **Step 4:** Compile before implementation and require failure for the missing marker port.

### Task 2: Implement and integrate the marker

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/video_rgb_to_axis_640x480.v`
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`

**Interfaces:**
- Consumes: `I_marker_enable=slide_active` in the video clock domain.
- Produces: white AXIS data for the first sixteen active pixels of each enabled row.

- [x] **Step 1:** Add the marker-enable input and override only `O_video_data` for the defined columns.
- [x] **Step 2:** Connect the production top and update its compile stub.
- [x] **Step 3:** Run the focused test to `PASS tb_video_rgb_to_axis_line_boundary`.
- [x] **Step 4:** Run the transition, slide, line-boundary, real-top, and stub-top regressions plus `git diff --check`.

### Task 3: Build and observe

**Files:**
- Generate: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: verified marker RTL.
- Produces: a current bitstream and a visual classification of the physical left edge.

- [ ] **Step 1:** Rebuild `syn_1`, `phy_1`, and bitgen in TD.
- [ ] **Step 2:** Record the newest successful bitstream timestamp and SHA-256.
- [ ] **Step 3:** JTAG-download, trigger a slide, and classify the white band using the spec's three outcomes.
