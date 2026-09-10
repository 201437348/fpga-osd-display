# Line-Buffer Horizontal Slide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the warm-white/gold transition with a 28-frame right-to-left horizontal push that uses one output FIFO and at most 672 SDRAM reads per image line.

**Architecture:** A video-domain controller locks old/new buffer indexes and emits an eased 0-to-640 slide position once per frame. A new memory-domain line scheduler serially reads the visible old segment and new segment into the existing single asynchronous FIFO; in the central 32-pixel overlap it caches old pixels and blends them as the corresponding new pixels return. The OSD remains after the image path and never moves.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, Icarus Verilog, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-09-line-buffer-horizontal-slide-design.md`

## Global Constraints

- Keep the 125 MHz SDRAM clocks at `DIV=8`, `CPHASE=7/3`, phase 0/180 degrees, and keep `SDR_CLK_PERIOD=1000000000/125000000`.
- Keep one production read FIFO; do not restore `read_data_old`, a second full-frame FIFO, or `frame_dual_fifo_read`.
- Keep BMP/WAV formats, FAT32, image writes, vertical flip, audio, HDMI timing, OSD text, keys, auto-play interval, and buffer base addresses unchanged.
- Use the exact 29-position table `0,2,9,20,35,54,76,100,127,156,187,219,252,286,320,354,388,421,453,484,513,540,564,586,605,620,631,638,640`.
- Disable feathering outside `16 <= slide_position <= 624`; at the endpoints output the source frame exactly.
- Do not create Git commits because the shared worktree contains unrelated, uncommitted user changes.
- Keep TD closed while source files and `osd_display.al` are edited; reopen it only after manifest validation.

---

### Task 1: Convert the frame controller to horizontal slide state

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_transition_controller.v`
- Modify: `fpga/osd_display/tests/tb_video_transition_controller.sv`

**Interfaces:**
- Consumes: `video_clk`, `rst`, frame-level `video_read_req`, `display_valid`, `committed_buffer_index[1:0]`, and synchronized `read_fault`.
- Produces: `active_buffer_index[1:0]`, `slide_old_buffer_index[1:0]`, `slide_new_buffer_index[1:0]`, `slide_active`, `transition_busy`, and `slide_position[9:0]`.

- [ ] **Step 1: Write the failing 28-step controller test**

Replace warm-white assertions with exact slide outputs. The test must assert direct first-image display, locked indexes, the midpoint and endpoint, and fault hold:

```systemverilog
pulse_read_request;
expect_position(slide_position, 10'd0, "first image direct");
committed_buffer_index = 2'd1;
@(posedge video_clk);
pulse_read_request;
expect_bit(slide_active, 1'b1, "slide starts at frame boundary");
repeat (14) pulse_read_request;
expect_position(slide_position, 10'd320, "smoothstep midpoint");
repeat (14) pulse_read_request;
expect_position(slide_position, 10'd640, "slide endpoint");
expect_index(active_buffer_index, 2'd1, "target becomes active");
```

Start a second transition, assert `read_fault`, and require `slide_active=0`, `transition_busy=1`, and `active_buffer_index` unchanged until reset.

- [ ] **Step 2: Run the controller test and confirm the old interface fails**

```powershell
$out = Join-Path $env:TEMP 'tb_video_transition_controller.vvp'
iverilog -g2012 -s tb_video_transition_controller -o $out fpga/osd_display/tests/tb_video_transition_controller.sv fpga/osd_display/rtl/video/video_transition_controller.v
```

Expected before implementation: compile errors for missing `slide_*` and `read_fault` ports.

- [ ] **Step 3: Implement locked indexes and the exact position LUT**

Use `phase_step[4:0]` and a combinational function with all 29 literal positions:

```verilog
function [9:0] slide_curve;
    input [4:0] step;
    begin
        case (step)
            5'd0: slide_curve = 10'd0;
            5'd1: slide_curve = 10'd2;
            5'd2: slide_curve = 10'd9;
            5'd3: slide_curve = 10'd20;
            5'd4: slide_curve = 10'd35;
            5'd5: slide_curve = 10'd54;
            5'd6: slide_curve = 10'd76;
            5'd7: slide_curve = 10'd100;
            5'd8: slide_curve = 10'd127;
            5'd9: slide_curve = 10'd156;
            5'd10: slide_curve = 10'd187;
            5'd11: slide_curve = 10'd219;
            5'd12: slide_curve = 10'd252;
            5'd13: slide_curve = 10'd286;
            5'd14: slide_curve = 10'd320;
            5'd15: slide_curve = 10'd354;
            5'd16: slide_curve = 10'd388;
            5'd17: slide_curve = 10'd421;
            5'd18: slide_curve = 10'd453;
            5'd19: slide_curve = 10'd484;
            5'd20: slide_curve = 10'd513;
            5'd21: slide_curve = 10'd540;
            5'd22: slide_curve = 10'd564;
            5'd23: slide_curve = 10'd586;
            5'd24: slide_curve = 10'd605;
            5'd25: slide_curve = 10'd620;
            5'd26: slide_curve = 10'd631;
            5'd27: slide_curve = 10'd638;
            5'd28: slide_curve = 10'd640;
            default: slide_curve = 10'd640;
        endcase
    end
endfunction
```

On transition start, lock active/target indexes and set position zero. On each later frame request increment through step 28. At step 28 atomically set `active_buffer_index` to the locked new index and release `slide_active/transition_busy`. On `read_fault`, cancel the slide without changing `active_buffer_index` and hold `transition_busy=1` until reset.

- [ ] **Step 4: Run the controller test to a clean pass**

Run the Step 2 compile followed by `vvp $out`. Expected: `PASS tb_video_transition_controller`.

### Task 2: Build the serial line-segment reader and overlap blender

**Files:**
- Create: `fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v`
- Create: `fpga/osd_display/tests/tb_frame_slide_fifo_read.sv`

**Interfaces:**
- Consumes: memory clock/reset/init/busy signals, `Sdr_rd_en/Sdr_rd_dout`, frame request metadata, four base addresses, old/new indexes, `slide_active`, `slide_position`, and final FIFO `wrusedw`.
- Produces: `App_rd_en/App_rd_addr`, request ACK/finish, FIFO clear/write/data signals, read-busy, and sticky `read_fault`.

Use this exact production boundary:

```verilog
module frame_slide_fifo_read #(
    parameter ADDR_BITS=21, FRAME_WIDTH=640, FRAME_HEIGHT=480,
    parameter FIFO_DEPTH=512, FIFO_LEVEL_BITS=9,
    parameter MAX_BURST=128, FEATHER_WIDTH=32
) (
    input mem_clk, input rst, input Sdr_init_done, input Sdr_busy,
    input App_wr_busy, input Sdr_rd_en, input [31:0] Sdr_rd_dout,
    input read_req, output reg read_req_ack, output reg read_finish,
    input [20:0] read_addr_0, read_addr_1, read_addr_2, read_addr_3,
    input [1:0] old_buffer_index, input [1:0] new_buffer_index,
    input slide_active, input [9:0] slide_position,
    output reg fifo_aclr, input [8:0] wrusedw,
    output reg fifo_write_en, output reg [31:0] fifo_write_data,
    output reg App_rd_en, output reg [20:0] App_rd_addr,
    output read_busy, output reg read_fault
);
```

- [ ] **Step 1: Write a small-frame scheduler test with delayed returns**

Instantiate `FRAME_WIDTH=8`, `FRAME_HEIGHT=2`, `FEATHER_WIDTH=4`, and use old base 0/new base 64. Model SDRAM by queueing each `App_rd_addr` and returning the address-derived pixel after a variable delay.

At position 4, require the first line read sequence `2,3,4,5,6,7,64,65,66,67,68,69`; require eight FIFO outputs ordered as two direct old pixels, four blended overlap pixels, and two direct new pixels. At positions 0 and 8 require exactly eight reads and exact old/new output. Require `read_finish` only after 16 final output pixels and latch `read_fault` when a new request arrives before completion.

- [ ] **Step 2: Run the scheduler test and confirm the module is absent**

```powershell
$out = Join-Path $env:TEMP 'tb_frame_slide_fifo_read.vvp'
iverilog -g2012 -s tb_frame_slide_fifo_read -o $out fpga/osd_display/tests/tb_frame_slide_fifo_read.sv fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v
```

Expected before implementation: file/module-not-found failure.

- [ ] **Step 3: Implement request metadata capture and row geometry**

Synchronize `read_req`, indexes, active flag, and position into `mem_clk`. In ACK state wait for synchronized request-low, then atomically latch all metadata and calculate per-row phases. For `16 <= p <= 624`, use old start `old_base+y*640+p-16`, old direct `640-p-16`, overlap 32, new overlap 32, and new direct `p-16`; otherwise use old length `640-p` and new length `p` without overlap.

- [ ] **Step 4: Implement bounded serial bursts and return counting**

Issue no more than `MAX_BURST` addresses per chunk and start a FIFO-producing chunk only when `wrusedw < FIFO_DEPTH-MAX_BURST`. Keep the segment route unchanged until the number of real `Sdr_rd_en` returns equals the issued count. Advance rows only after all segment returns have arrived.

- [ ] **Step 5: Implement 32-pixel overlap cache and bounded RGB blend**

Cache old overlap `Sdr_rd_dout[31:8]`. For each new overlap return, use a literal 0-to-64 coefficient LUT and direction-aware channel interpolation:

```verilog
if (target >= source)
    mixed = source + (((target-source) * alpha) >> 6);
else
    mixed = source - (((source-target) * alpha) >> 6);
```

Write `{mixed_r,mixed_g,mixed_b,8'd0}` to the final FIFO. Direct phases forward `Sdr_rd_dout` unchanged.

- [ ] **Step 6: Run scheduler tests to a clean pass**

Run the Step 2 command and `vvp $out`. Expected: `PASS tb_frame_slide_fifo_read` with all request, output-count, endpoint, overlap, delayed-return, and overrun assertions passing.

### Task 3: Integrate one-FIFO slide reading into the production top

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/osd_display.al`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`

**Interfaces:**
- Consumes: controller old/new indexes, `slide_active`, and `slide_position`.
- Produces: one read FIFO pixel stream, synchronized read fault, direct image RGB to OSD, and no warm-white/gold pixel stage.

- [ ] **Step 1: Add source-level failing integration assertions**

```powershell
$top = Get-Content -Raw fpga/osd_display/rtl/top/top.v
if ($top -match 'video_transition_blender_m0|transition_fade_level|transition_sweep_position') { throw 'old visual effect remains' }
$reader = Get-Content -Raw fpga/osd_display/rtl/vendor/SD/frame_read_write.v
if ($reader -notmatch 'frame_slide_fifo_read\s*#') { throw 'slide reader missing' }
if (($reader | Select-String -AllMatches 'rfifo_32_32_512').Matches.Count -ne 1) { throw 'production must have one read FIFO' }
```

- [ ] **Step 2: Rewire the frame wrapper around the new scheduler**

Add `read_addr_index_old`, `slide_active`, `slide_position`, and `read_fault` ports. Change the read FIFO write side from raw `Sdr_rd_en/Sdr_rd_dout` to scheduler `fifo_write_en/fifo_write_data`. Instantiate `frame_slide_fifo_read`; retain the board-proven write FIFO and `frame_fifo_write` unchanged.

- [ ] **Step 3: Rewire top and remove the color-effect stage**

Connect controller slide outputs to `frame_read_write`. Synchronize sticky `read_fault` into `video_clk` and feed it to the controller. Feed `vout_data_raw` directly into the display-valid selection before OSD; remove the production `video_transition_blender` instance and all warm-white/gold wires. Keep `transition_busy` playback interlock.

- [ ] **Step 4: Update the TD project manifest and compile stub**

Add active `rtl/vendor/SD/frame_slide_fifo_read.v`, keep `frame_dual_fifo_read.v`, `frame_fifo_read.v`, and `video_transition_blender.v` as `AutoExcluded=true`, and keep `frame_read_write.v`, both generated FIFO IPs, `frame_fifo_write.v`, controller, and top active. Update the stub to match the new wrapper ports.

- [ ] **Step 5: Run architecture assertions and real top elaboration**

Compile top with `-DOSD_USE_REAL_FRAME_READ_WRITE`, real `frame_read_write`, `frame_slide_fifo_read`, `frame_fifo_write`, both generated FIFO sources, project control/storage/audio/video modules, and `tests/top_compile_stubs.v`. Expected: exit code zero, one `rfifo_32_32_512` instance, no unresolved ports, and only established width/address warnings.

### Task 4: Regress stable subsystems and record the TD handoff

**Files:**
- Modify: `docs/project-roadmap.md`
- Modify: `docs/osd-display-migration.md`
- Test: controller, line scheduler, OSD, media manager/storage, and real top.

**Interfaces:**
- Consumes: final integrated RTL and manifest.
- Produces: reproducible source verification and a JTAG-only acceptance checklist.

- [ ] **Step 1: Run focused simulation regression**

Run `tb_video_transition_controller`, `tb_frame_slide_fifo_read`, `tb_video_osd_overlay`, `tb_image_load_manager`, and `tb_image_storage_adapter`. Expected: five PASS markers.

- [ ] **Step 2: Check fixed clock and architecture invariants**

Require PLL C1/C2 `DIV=8`, `CPHASE=7/3`, IPC 125 MHz/0/180 degrees, the 125 MHz refresh macro, one production read FIFO, no old full-frame read output, and no production gold/diagonal blender.

- [ ] **Step 3: Run repository and manifest checks**

Run `git diff --check`; assert each active production source appears exactly once in `osd_display.al`; confirm TD remains closed so the manifest cannot be overwritten during edits.

- [ ] **Step 4: Update progress documents**

Record the exact 28-step curve, 32-pixel overlap, 640/672 per-line read counts, passing simulations, and status `source-complete, TD/JTAG-pending`. The board checklist is ten manual transitions, several automatic cycles, audio, fixed OSD, and one TF removal/reinsert. Do not claim board success or write configuration Flash before that test passes.
