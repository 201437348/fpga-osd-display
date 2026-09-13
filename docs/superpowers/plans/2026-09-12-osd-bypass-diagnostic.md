# OSD Bypass Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a normal feathered transition whose HDMI input bypasses only the OSD overlay.

**Architecture:** Change three production-top selections without modifying module implementations. The OSD remains instantiated but its output is not selected by the RGB-to-AXIS input.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog tests, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-osd-bypass-diagnostic-design.md`

## Global Constraints

- Set `SLIDE_FEATHER_ENABLE` to one.
- Set `I_marker_enable` to constant zero.
- Feed RGB-to-AXIS from `vout_data`, not `vout_data_osd`.
- Do not modify module implementations or the TD project manifest.
- Keep TD closed while the top file is edited.

---

### Task 1: Select the OSD-bypass data path

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`

**Interfaces:**
- Consumes: pre-OSD `vout_data` and existing transition/AXIS signals.
- Produces: feathered, marker-free image pixels at the HDMI AXIS input.

- [x] **Step 1:** Set `.SLIDE_FEATHER_ENABLE(1)` on `frame_read_write_m0`.
- [x] **Step 2:** Connect `.I_rgb(vout_data)` on the RGB-to-AXIS instance.
- [x] **Step 3:** Connect `.I_marker_enable(1'b0)`.
- [x] **Step 4:** Assert these exact connections from the top source.

### Task 2: Verify unchanged module behavior

**Files:**
- Test: `fpga/osd_display/tests/tb_frame_slide_full_line.sv`
- Test: `fpga/osd_display/tests/tb_video_delay_line_boundary.sv`
- Test: `fpga/osd_display/tests/tb_video_rgb_to_axis_line_boundary.sv`
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`

**Interfaces:**
- Consumes: existing production RTL and test vectors.
- Produces: unchanged PASS results plus real/stub top elaboration.

- [x] **Step 1:** Run both feathered slide and transition-controller tests.
- [x] **Step 2:** Run FIFO/video-delay, RGB-to-AXIS, and OSD tests.
- [x] **Step 3:** Elaborate the real and stub top configurations.
- [x] **Step 4:** Run `git diff --check`.

### Task 3: Build and observe

**Files:**
- Generate: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: verified OSD-bypass top.
- Produces: a current bitstream and fixed-left-line observation without OSD bars.

- [ ] **Step 1:** Rebuild `syn_1`, `phy_1`, and bitgen in TD.
- [ ] **Step 2:** Record the newest successful bitstream timestamp and SHA-256.
- [ ] **Step 3:** JTAG-download and report whether the fixed left-edge line remains during feathered motion.
