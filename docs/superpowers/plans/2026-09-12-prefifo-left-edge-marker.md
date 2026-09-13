# Pre-FIFO Left-Edge Marker Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert a configurable marker immediately before the asynchronous display FIFO and use a 64-pixel build to classify the remaining line.

**Architecture:** `frame_read_write` separates the scheduler data wire from the FIFO input wire and applies a parameter-controlled marker using a row-position counter. The production top enables the parameter only for this diagnostic build.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-prefifo-left-edge-marker-design.md`

## Global Constraints

- Override x=0 through `READ_FIFO_MARKER_WIDTH-1` with `32'hFFFFFF00` before the asynchronous read FIFO.
- Reset marker x on `read_fifo_aclr` and wrap at `FRAME_WIDTH-1`.
- Default the parameter off and enable it explicitly only in the production top.
- Keep final AXIS marker off, OSD on, feathering on, and registered FIFO output on.
- Keep TD closed while RTL is edited.

---

### Task 1: Specify marker placement

**Files:**
- Create: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`
- Reuse stubs: `fpga/osd_display/tests/tb_frame_read_write_underflow.sv`

**Interfaces:**
- Consumes: hierarchical scheduler test injection and `READ_FIFO_MARKER_ENABLE=1`.
- Produces: exact assertions for forty words across two 20-pixel rows.

- [x] **Step 1:** Inject distinct words at x=0..19 for two rows.
- [x] **Step 2:** Require white output for x=0..15 and original output for x=16..19 on each row.
- [x] **Step 3:** Compile before implementation and require failure for the missing parameter or internal marker path.

### Task 2: Implement the pre-FIFO marker

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_write_underflow.sv`

**Interfaces:**
- Consumes: scheduler `fifo_write_en/data` and frame width.
- Produces: parameter-controlled marked FIFO input.

- [x] **Step 1:** Split scheduler data from FIFO input, add the x counter, and implement the marker mux.
- [x] **Step 2:** Add the parameter to production and test stubs.
- [x] **Step 3:** Enable the parameter in the production top.
- [x] **Step 4:** Run the new focused test to PASS.

### Task 3: Regress and build

**Files:**
- Generate: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: verified diagnostic RTL.
- Produces: current bitstream and a pre-FIFO marker observation.

- [x] **Step 1:** Run focused regressions, real/stub top elaboration, and `git diff --check`.
- [x] **Step 2:** Rebuild `syn_1`, `phy_1`, and bitgen in TD.
- [x] **Step 3:** Record the bitstream identity, and classify the left edge during motion.

### Task 4: Expand the marker to 64 pixels

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`

**Interfaces:**
- Consumes: `READ_FIFO_MARKER_ENABLE` and scheduler row position.
- Produces: `READ_FIFO_MARKER_WIDTH`, set to 64 in this diagnostic stage.

- [x] **Step 1:** Extend the focused test to require white at x=0..63 and original data at x=64..67.
- [x] **Step 2:** Add the width parameter and make the marker comparison use it.
- [x] **Step 3:** Run focused regressions, real/stub top elaboration, and `git diff --check`.
- [x] **Step 4:** Rebuild `syn_1`, `phy_1`, and bitgen in TD and classify whether the line is covered or moves to x=64.

### Task 5: Bisect with a 32-pixel marker

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`

**Interfaces:**
- Consumes: verified configurable marker support.
- Produces: a 32-pixel diagnostic build that distinguishes x=16..31 from x=32..63.

- [x] **Step 1:** Configure the focused test and production top for a 32-pixel marker.
- [x] **Step 2:** Run the marker, scheduler, display-chain, underflow, and top-level regressions.
- [x] **Step 3:** Rebuild `syn_1`, `phy_1`, and bitgen in TD and observe whether the color line returns.

### Task 6: Bisect with a 24-pixel marker

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`

**Interfaces:**
- Consumes: the x=16..31 bound from the 32-pixel board result.
- Produces: a 24-pixel build distinguishing x=16..23 from x=24..31.

- [x] **Step 1:** Configure the focused test and production top for a 24-pixel marker.
- [x] **Step 2:** Run the marker, scheduler, display-chain, underflow, and top-level regressions.
- [x] **Step 3:** Rebuild `syn_1`, `phy_1`, and bitgen in TD and observe whether the color line returns.

### Task 7: Confirm the x=24..25 bound

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`

**Interfaces:**
- Consumes: the approximately x=24..25 bound from the 24-pixel board result.
- Produces: a 26-pixel diagnostic build confirming whether both remaining pixels are covered.

- [x] **Step 1:** Configure the focused test and production top for a 26-pixel marker.
- [x] **Step 2:** Run the marker, scheduler, display-chain, underflow, and top-level regressions.
- [x] **Step 3:** Rebuild `syn_1`, `phy_1`, and bitgen in TD and confirm whether the color line disappears completely.

### Task 8: Test the x=31 boundary

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`

**Interfaces:**
- Consumes: the x=26..31 bound from the 26-pixel board result.
- Produces: a 31-pixel build distinguishing x=31 from x=26..30.

- [x] **Step 1:** Configure the focused test and production top for a 31-pixel marker.
- [x] **Step 2:** Run the marker, scheduler, display-chain, underflow, and top-level regressions.
- [x] **Step 3:** Rebuild `syn_1`, `phy_1`, and bitgen in TD and observe whether one color pixel remains.

### Task 9: Isolate the x=26..30 window

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`
- Modify: `fpga/osd_display/tests/tb_frame_read_fifo_marker.sv`

**Interfaces:**
- Consumes: the x=26..30 bound and existing marker width parameter.
- Produces: `READ_FIFO_MARKER_START`, with top configured for start 26 and width 5.

- [x] **Step 1:** Add a failing focused test requiring only x=26..30 to be white.
- [x] **Step 2:** Implement marker start support in RTL and stubs and configure the production top.
- [x] **Step 3:** Run the marker, scheduler, display-chain, underflow, and top-level regressions.
- [ ] **Step 4:** Rebuild and observe whether earlier left-edge color lines return.
