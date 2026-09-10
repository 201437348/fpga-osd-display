# Smooth Crossfade Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a roughly one-second, visibly continuous diagonal crossfade without transition-only FIFO corruption or a dominant colored stripe.

**Architecture:** The video controller advances a 0-through-64 alpha once per frame.  The blender uses divide-by-64 RGB weighting and a subtle soft-white diagonal accent, while the SDRAM reader alternates shorter 128-word return-confirmed bursts so neither frame FIFO waits through a 256-word partner burst.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, Icarus Verilog, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-09-smooth-crossfade-stability-design.md`

## Global Constraints

- Keep image loading, FAT32, TF recovery, audio, OSD, HDMI timing, SDRAM frequency, and the memory map unchanged.
- Keep the first committed image direct, without a transition.
- Retain real-`Sdr_rd_en` return accounting before changing old/new FIFO routes.
- Use JTAG board validation before writing a new Flash image.

---

### Task 1: Extend the frame-based alpha ramp

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_transition_controller.v`
- Modify: `fpga/osd_display/tests/tb_video_transition_controller.sv`
- Modify: `fpga/osd_display/rtl/top/top.v`

**Interfaces:**
- Consumes: one rising edge of `video_read_req` per frame.
- Produces: `alpha_step[6:0]` spanning `7'd0` through `7'd64` while `dual_read_active` remains asserted.

- [x] **Step 1: Change the controller test to require 64 increments**

Assert the start value `0`, midpoint value `32`, last mixed value `63`, full-new value `64`, and release only on the following frame request.

- [x] **Step 2: Run the controller test and verify width/endpoint failures**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_controller.vvp'
iverilog -g2012 -s tb_video_transition_controller -o $tbOut fpga\osd_display\tests\tb_video_transition_controller.sv fpga\osd_display\rtl\video\video_transition_controller.v
vvp $tbOut
```

Expected: failure because the existing controller stops at `5'd16`.

- [x] **Step 3: Implement the 7-bit frame ramp**

Change the controller and top-level alpha signals to `[6:0]`, initialize to
`7'd64`, start at `7'd0`, increment while below `7'd64`, then release the
reserved old frame on the next frame request.

- [x] **Step 4: Run the controller test to a clean pass**

Run the command from Step 2.  Expected: `PASS tb_video_transition_controller`.

### Task 2: Replace the hard colored stripe with a smooth blend accent

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_transition_blender.v`
- Modify: `fpga/osd_display/tests/tb_video_transition_blender.sv`

**Interfaces:**
- Consumes: `alpha_step[6:0]`, old/new 24-bit RGB, current active coordinates.
- Produces: divide-by-64 blended RGB plus a 32-pixel soft-white band whose inner and outer regions lift channels by one eighth and one sixteenth toward white.

- [x] **Step 1: Expand endpoint, midpoint, and highlight tests**

Require exact old RGB at alpha `0`, exact new RGB at alpha `64`, exact
`24'h784078` at alpha `32`, and a non-wrapping lightened value inside both
the highlight core and edge.

- [x] **Step 2: Run the blender test and verify the old 5-bit interface fails**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_blender.vvp'
iverilog -g2012 -s tb_video_transition_blender -o $tbOut fpga\osd_display\tests\tb_video_transition_blender.sv fpga\osd_display\rtl\video\video_transition_blender.v
vvp $tbOut
```

Expected: failure on the new 32/64 alpha cases.

- [x] **Step 3: Implement 64-denominator mixing and the soft-white accent**

Use 7-bit old/new weights that sum to 64, select result bits `[13:6]`, and
compute the diagonal center as `alpha_step * 18` using shifts.  Replace
target-color subtraction with `(8'hff - mixed_channel) >> 3` in the core and
`>> 4` at the edges so the result cannot underflow or wrap.

- [x] **Step 4: Run the blender test to a clean pass**

Run the command from Step 2.  Expected: `PASS tb_video_transition_blender`.

### Task 3: Reduce dual-frame FIFO service gaps

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/tests/tb_frame_dual_fifo_read.sv`

**Interfaces:**
- Consumes: existing 256-word write burst parameter and real `Sdr_rd_en` read returns.
- Produces: independent 128-word display read bursts with unchanged frame addresses and lengths.

- [x] **Step 1: Preserve the delayed-return routing regression**

Keep the small-parameter scheduler test at four words and add a production
integration source check that `frame_read_write` passes a read burst size of
128 rather than the 256-word write burst size.

- [x] **Step 2: Separate display read burst size from frame write burst size**

Define `READ_BURST_SIZE = 128` in `frame_read_write` and pass it only to
`frame_dual_fifo_read`.  Keep `BURST_SIZE = 256` for `frame_fifo_write`.

- [x] **Step 3: Run scheduler and syntax regressions**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_frame_dual_fifo_read.vvp'
iverilog -g2012 -s tb_frame_dual_fifo_read -o $tbOut fpga\osd_display\tests\tb_frame_dual_fifo_read.sv fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v
vvp $tbOut
```

Expected: `PASS tb_frame_dual_fifo_read`, followed by clean elaboration of
`frame_read_write` with its existing FIFO IP sources.

### Task 4: Run integration regression and board handoff

**Files:**
- Test: all transition RTL and the existing top-level syntax harness.

- [x] **Step 1: Run all focused simulations and top-level elaboration**

Run the three testbenches from Tasks 1 through 3 and elaborate `top.v` with
`tests/top_compile_stubs.v`, the project control/storage/audio/video RTL, and
the two generated FIFO Verilog sources.

- [ ] **Step 2: Run TD and JTAG board validation**

Run `syn_1`, `phy_1`, and bitstream generation.  JTAG-test at least ten KEY2
transitions, several KEY4 automatic cycles, audio continuity, OSD stability,
and one TF removal/reinsertion.  Do not write Flash unless all visual checks
pass.
