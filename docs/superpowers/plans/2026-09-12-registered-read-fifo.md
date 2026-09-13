# Registered Read FIFO Boundary Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the display read FIFO a deterministic registered output and preserve exact 640-pixel line alignment.

**Architecture:** Configure only the production read FIFO output register and compensate its added latency by issuing reads one clock earlier in `video_delay`. Restore all temporary presentation diagnostics to normal operation.

**Tech Stack:** Verilog-2001 RTL, generated Anlogic asynchronous FIFO model, SystemVerilog testbench, Icarus Verilog 14.0, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-registered-read-fifo-design.md`

## Global Constraints

- Use `SHOW_AHEAD_EN=0` and `OUTREG_EN="OUTREG"` for the production read FIFO.
- Issue reads from `de_d[17]`, capture data at `de_d[19]`, and output DE at `de_d[20]`.
- Do not change FIFO depth, SDRAM scheduling, frame dimensions, slide coordinates, HS, VS, or HDMI timing.
- Restore feathering, OSD selection, and marker-disabled operation.
- Keep TD closed while RTL is edited.

---

### Task 1: Prove the registered-output latency mismatch

**Files:**
- Modify: `fpga/osd_display/tests/tb_video_delay_line_boundary.sv`

**Interfaces:**
- Consumes: production `rfifo_32_32_512` with `OUTREG_EN="OUTREG"` and production `video_delay`.
- Produces: exact two-line pixel-boundary assertions.

- [x] **Step 1:** Override the test FIFO `OUTREG_EN` parameter to `"OUTREG"`.
- [x] **Step 2:** Run against the old `de_d[18]` read enable and require a first-pixel ordering failure.
- [x] **Step 3:** Keep all eight existing expected pixel assertions unchanged.

### Task 2: Implement the two-clock read contract

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/video_delay.v`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`

**Interfaces:**
- Consumes: registered FIFO data two clocks after read enable.
- Produces: unchanged `vout_data`, `de_r`, `hs_r`, and `vs_r` alignment.

- [x] **Step 1:** Change `read_en` to `de_d[17]` without moving the capture or output timing stages.
- [x] **Step 2:** Set `OUTREG_EN="OUTREG"` explicitly on the production read FIFO instance.
- [x] **Step 3:** Re-run the boundary test and require `PASS tb_video_delay_line_boundary`.

### Task 3: Restore normal presentation and regress

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`

**Interfaces:**
- Consumes: normal OSD output, feathered transition, and disabled AXIS marker.
- Produces: production-equivalent screen content with the FIFO timing fix.

- [x] **Step 1:** Feed RGB-to-AXIS from `vout_data_osd`, keep feathering enabled, and keep marker enable zero.
- [x] **Step 2:** Restore the rightmost digit to read-underflow/error priority.
- [x] **Step 3:** Run focused regressions, real/stub top elaboration, and `git diff --check`.

### Task 4: Build and board-test

**Files:**
- Generate: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: verified registered-output RTL.
- Produces: a current bitstream and final left-edge observation.

- [ ] **Step 1:** Rebuild `syn_1`, `phy_1`, and bitgen in TD.
- [ ] **Step 2:** Record the newest successful bitstream timestamp and SHA-256.
- [ ] **Step 3:** JTAG-download and verify normal OSD, normal feathering, and absence of the fixed left-edge line.
