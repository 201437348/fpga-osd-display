# Slide Endpoint Hold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the one-frame two-pixel remnant at horizontal-slide completion.

**Architecture:** Make the last active slide frame a full-new-image endpoint by changing curve step 27 to 640. Preserve the following frame-boundary ownership commit and transition release.

**Tech Stack:** Verilog-2001, SystemVerilog, Icarus Verilog 14.0

**Spec:** `docs/superpowers/specs/2026-09-11-slide-endpoint-hold-design.md`

## Global Constraints

- Preserve the 28-request transition lifecycle and frame-boundary buffer commit.
- Do not modify SDRAM, FIFO, line scheduler, HDMI, OSD, or audio behavior.
- Require identical full-new-image content immediately before and after transition release.

---

### Task 1: Specify the endpoint hold

**Files:**
- Modify: `fpga/osd_display/tests/tb_video_transition_controller.sv`
- Test: `fpga/osd_display/tests/tb_video_transition_controller.sv`

**Interfaces:**
- Consumes: `slide_position`, `slide_active`, `transition_busy`, and `active_buffer_index`.
- Produces: terminal-step assertions for the endpoint hold and ownership commit.

- [x] **Step 1:** Change expected curve step 27 from 638 to 640.
- [x] **Step 2:** Assert that step 27 remains active/busy with the old active buffer.
- [x] **Step 3:** Run against unchanged RTL and require failure at step 27.

### Task 2: Advance the full endpoint

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_transition_controller.v`
- Test: `fpga/osd_display/tests/tb_video_transition_controller.sv`

**Interfaces:**
- Consumes: frame request progression through `phase_step=27`.
- Produces: curve value 640 at step 27 and unchanged step-28 commit behavior.

- [x] **Step 1:** Change `slide_curve(27)` to `10'd640`.
- [x] **Step 2:** Run the controller test and require `PASS tb_video_transition_controller`.

### Task 3: Regression verification

**Files:**
- Test: `fpga/osd_display/tests/tb_frame_slide_fifo_read.sv`
- Test: `fpga/osd_display/tests/tb_frame_read_write_underflow.sv`

**Interfaces:**
- Consumes: existing scheduler endpoint, SDRAM busy, and underflow assertions.
- Produces: unchanged passing read-path behavior.

- [x] **Step 1:** Run the line scheduler and frame underflow tests.
- [x] **Step 2:** Compile the refresh-sweep integration test at the production FIFO depth.
- [x] **Step 3:** Run `git diff --check` and inspect the scoped diff.
