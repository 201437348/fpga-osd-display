# Dual-Frame SDRAM Return Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep SDRAM return data routed to its selected old or new frame FIFO until the complete burst has actually returned.

**Architecture:** Replace the command-completion fixed wait in the dual-frame scheduler with a count of real `Sdr_rd_en` return-valid cycles.  The outer frame reader passes the existing SDRAM valid signal to that scheduler; no other pipeline interface changes.

**Tech Stack:** Verilog-2001 RTL, existing Anlogic asynchronous FIFO IP, Icarus Verilog testbenches.

**Spec:** `docs/superpowers/specs/2026-09-09-dual-frame-return-routing-design.md`

## Global Constraints

- Keep SDRAM commands and returned data in the existing `mem_clk` domain.
- Do not alter image loading, audio, OSD, TF recovery, FIFO IP, or memory map.
- Preserve normal single-frame reads and complete-burst FIFO capacity checks.

---

### Task 1: Verify variable-latency return routing

**Files:**
- Modify: `fpga/osd_display/tests/tb_frame_dual_fifo_read.sv`

**Interfaces:**
- Consumes: scheduler `App_rd_en`, `route_old_fifo`.
- Produces: delayed `Sdr_rd_en` input and assertions comparing each returned word route to its originating command burst.

- [x] **Step 1: Add a delayed SDRAM-return model**

Shift each `App_rd_en` and its `route_old_fifo` value through a six-cycle
pipeline.  Drive `Sdr_rd_en` from the final valid stage.

- [x] **Step 2: Add return-route assertions**

On each `Sdr_rd_en`, compare `route_old_fifo` with the saved target at the
final pipeline stage.  Fail when a late return word changes destination.

- [x] **Step 3: Run the scheduler test**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_frame_dual_fifo_read.vvp'
iverilog -g2012 -s tb_frame_dual_fifo_read -o $tbOut fpga\osd_display\tests\tb_frame_dual_fifo_read.sv fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v
vvp $tbOut
```

Expected: failure before the RTL implements return-word accounting.

### Task 2: Account for actual SDRAM returns

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_dual_fifo_read.v`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`

**Interfaces:**
- Consumes: `Sdr_rd_en` from `frame_read_write`.
- Produces: stable `route_old_fifo` from the first command until the final returned word of the burst.

- [x] **Step 1: Add the scheduler input and integration connection**

Add `input Sdr_rd_en` to `frame_dual_fifo_read` and connect the existing
`frame_read_write.Sdr_rd_en` signal by name.

- [x] **Step 2: Replace fixed delay state with return accounting**

Clear `burst_return_count` when a target FIFO is selected.  Increment it only
for `Sdr_rd_en` while the selected burst is active.  Advance after the final
returned word, rather than after a clock-count constant.

- [x] **Step 3: Run the targeted test to a clean pass**

Run the command in Task 1.  Expected: `PASS tb_frame_dual_fifo_read`.

### Task 3: Check integration syntax and hand off board validation

**Files:**
- Modify: `fpga/osd_display/tests/top_compile_stubs.v` only if its scheduler stub needs the new port.

- [x] **Step 1: Compile the focused RTL tests**

```powershell
$tests = @(
  @{ n='tb_frame_dual_fifo_read'; f='fpga\osd_display\tests\tb_frame_dual_fifo_read.sv'; r='fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v' },
  @{ n='tb_video_transition_blender'; f='fpga\osd_display\tests\tb_video_transition_blender.sv'; r='fpga\osd_display\rtl\video\video_transition_blender.v' },
  @{ n='tb_video_transition_controller'; f='fpga\osd_display\tests\tb_video_transition_controller.sv'; r='fpga\osd_display\rtl\video\video_transition_controller.v' }
)
foreach ($test in $tests) {
  $out = Join-Path $env:TEMP ($test.n + '.vvp')
  iverilog -g2012 -s $test.n -o $out $test.f $test.r
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  vvp $out
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: all three testbenches print their `PASS` markers.

- [ ] **Step 2: Run TD `syn_1` and `phy_1`, then JTAG-test**

Check a normal first image, repeated KEY2 changes, KEY4 auto cycling, and TF
removal/reinsertion.  The visual acceptance condition is a complete old image
that smoothly transitions to a complete new image with no blocks or isolated
diagonal line.
