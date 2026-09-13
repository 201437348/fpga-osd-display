# Video-Clock Slide Bypass Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a board diagnostic that substitutes a moving video-clock pattern only during image slides.

**Architecture:** A standalone registered pattern generator emits one uniform color derived only from slide position. The top selects its RGB during `slide_active` before the unchanged OSD and HDMI pipeline.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-video-clock-slide-bypass-design.md`

## Global Constraints

- Replace RGB only while `display_valid && slide_active`.
- Keep DE, HS, VS, SDRAM, FIFO, OSD, AXIS, and HDMI control unchanged.
- Keep static image display on the real image path.
- Keep TD and the downloader closed while files are edited.

---

### Task 1: Add and verify the moving pattern

**Files:**
- Create: `fpga/osd_display/tests/tb_video_slide_diagnostic_pattern.sv`
- Create: `fpga/osd_display/rtl/video/video_slide_diagnostic_pattern.v`

**Interfaces:**
- Consumes: `video_clk`, `rst`, `vs`, `de`, and 10-bit `slide_position`.
- Produces: registered 24-bit `rgb` aligned to active video.

- [x] **Step 1:** Write exact x=0, adjacent-pixel, next-line, and changed-position assertions.
- [x] **Step 2:** Run before adding the module and require elaboration to fail with an unknown module.
- [x] **Step 3:** Implement x/y tracking and the moving RGB ramp.
- [x] **Step 4:** Run the focused test and require `PASS tb_video_slide_diagnostic_pattern`.

### Task 2: Integrate the diagnostic boundary

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/osd_display.al`
- Modify: `fpga/osd_display/td_project/osd_display.al`

**Interfaces:**
- Consumes: diagnostic RGB, `slide_active`, and `display_valid`.
- Produces: diagnostic RGB to the existing OSD only during a slide.

- [x] **Step 1:** Instantiate the pattern from delayed display timing and current slide position.
- [x] **Step 2:** Select diagnostic RGB only for `display_valid && slide_active`.
- [x] **Step 3:** Add the RTL source to both TD project manifests.

### Task 3: Regress and build

**Files:**
- Test: focused video, scheduler, wrapper, and top-level RTL suites.
- Generate: the normal `phy_1` bitstream through TD.

**Interfaces:**
- Consumes: integrated diagnostic source.
- Produces: a board observation that locates the defect relative to the RGB selection.

- [x] **Step 1:** Run focused regressions and real/stub top elaboration.
- [x] **Step 2:** Run `git diff --check` and verify both manifests reference the new source.
- [x] **Step 3:** Rebuild `syn_1`, `phy_1`, and Generate Bitstream.
- [x] **Step 4:** Board test found no left-edge line during the moving uniform
  diagnostic pattern; the visible color propagation was display scan/phone
  rolling-shutter behavior.
