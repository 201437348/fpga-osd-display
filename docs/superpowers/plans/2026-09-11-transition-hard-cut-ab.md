# Transition Hard-Cut A/B Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a board-testable bitstream that removes feather blending while preserving horizontal motion.

**Architecture:** A compile-time parameter controls only whether the slide scheduler enters its existing overlap-cache and blend phases. The parameter is passed from the production top through `frame_read_write`, while the full-line test supplies either value directly.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-11-transition-hard-cut-ab-design.md`

## Global Constraints

- Do not alter slide positions, frame dimensions, SDRAM command scheduling, FIFO depth, HDMI timing, or OSD behavior.
- Keep feathering enabled by default in reusable modules.
- Select hard-cut mode explicitly only in the production top for this diagnostic build.
- Keep TD closed while source files are edited.

---

### Task 1: Add the hard-cut control

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`

**Interfaces:**
- Consumes: constant integer parameter `FEATHER_ENABLE` / `SLIDE_FEATHER_ENABLE`.
- Produces: unchanged pixel and SDRAM interfaces; hard-cut scheduling when the parameter is zero.

- [ ] **Step 1:** Add `FEATHER_ENABLE=1` to `frame_slide_fifo_read` and include it in the latched feather-enable condition.
- [ ] **Step 2:** Add `SLIDE_FEATHER_ENABLE=1` to `frame_read_write` and pass it into the slide reader.
- [ ] **Step 3:** Set `SLIDE_FEATHER_ENABLE=0` at the production top instance.

### Task 2: Verify both composition modes

**Files:**
- Modify: `fpga/osd_display/tests/tb_frame_slide_full_line.sv`

**Interfaces:**
- Consumes: top-level test parameter `FEATHER_ENABLE`.
- Produces: exact expected pixels for either feathered or hard-cut composition.

- [ ] **Step 1:** Parameterize the testbench and DUT instance with `FEATHER_ENABLE`.
- [ ] **Step 2:** Select the existing blend expectation only when feathering is enabled; otherwise use the hard boundary expectation.
- [ ] **Step 3:** Run the default test and `-Ptb_frame_slide_full_line.FEATHER_ENABLE=0`; require both to print `PASS tb_frame_slide_full_line`.
- [ ] **Step 4:** Run the focused regression suite and real-top elaboration; require every test to pass.

### Task 3: Build and hand off

**Files:**
- Generate: `fpga/osd_display/osd_display_Runs/phy_1/seed_2/osd_display.bit`

**Interfaces:**
- Consumes: source-complete diagnostic RTL.
- Produces: a seed-2 bitstream with recorded timestamp, size, and SHA-256.

- [ ] **Step 1:** Run TD synthesis and require successful completion.
- [ ] **Step 2:** Run seed-2 physical implementation and bit generation; require zero routing overflow.
- [ ] **Step 3:** Record bitstream identity and ask for one JTAG board observation of the fixed left-edge line during motion.

