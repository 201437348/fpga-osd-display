# Clean Dual-Frame Crossfade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the warm-white single-frame transition with a clean 0.53-second old/new image crossfade and no color or geometric accent.

**Architecture:** A video-domain controller locks the current and committed buffer indexes for 32 frames and emits a 0..63 eased alpha sequence. A memory-domain scheduler fills two 1024-word asynchronous FIFOs with 64-word return-confirmed bursts, and a pure RGB blender combines the aligned streams before the existing OSD.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, Icarus Verilog, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-09-clean-dual-frame-crossfade-design.md`

## Global Constraints

- Keep FAT32, BMP/WAV loading, SDRAM writes, audio, PLLs, HDMI timing, keys, OSD content, and the two frame-buffer addresses unchanged.
- Use exactly 32 transition frames and alpha values `0,1,2,3,4,5,7,9,11,13,15,17,20,23,26,29,32,35,38,41,44,47,49,51,53,55,57,59,60,61,62,63`; the following frame is direct new-image output.
- Do not add white, yellow, gold, diagonal, blur, translation, scaling, or other decoration.
- Keep OSD after the image blender and keep the playback-manager busy interlock.
- Use 64-word display-read bursts and 1024-word old/new read FIFOs; keep the existing write burst unchanged.
- Hold FIFO routing until all real `Sdr_rd_en` returns for the selected burst complete.
- Do not create a Git commit. TD and board validation use JTAG before any Flash update.

---

### Task 1: Restore a frame-locked dual-image controller

**Files:**
- Modify: `fpga/osd_display/tests/tb_video_transition_controller.sv`
- Modify: `fpga/osd_display/rtl/video/video_transition_controller.v`

**Interfaces:**
- Consumes: `video_clk`, `rst`, `video_read_req`, `display_valid`, `committed_buffer_index[1:0]`.
- Produces: `active_buffer_index[1:0]`, `old_buffer_index[1:0]`, `new_buffer_index[1:0]`, `dual_read_active`, `transition_busy`, `alpha_step[6:0]`.

- [x] **Step 1: Rewrite the controller test for the dual-image contract**

Require the first committed image to be direct. After buffer 1 commits, pulse one frame request and assert old index 0, new index 1, dual mode active, busy active, and alpha 0. Pulse 16 more frame requests and require alpha 32; pulse 15 more and require alpha 63; pulse once more and require dual mode/busy low, active/new index 1, and alpha 64.

```systemverilog
pulse_read_request;
expect_bit(dual_read_active, 1'b1, "crossfade starts at frame boundary");
expect_index(old_buffer_index, 2'd0, "old buffer locks current image");
expect_index(new_buffer_index, 2'd1, "new buffer locks committed image");
expect_alpha(alpha_step, 7'd0, "first crossfade frame is old image");
repeat (16) pulse_read_request;
expect_alpha(alpha_step, 7'd32, "crossfade reaches equal weighting");
repeat (15) pulse_read_request;
expect_alpha(alpha_step, 7'd63, "last mixed frame is almost new");
pulse_read_request;
expect_bit(dual_read_active, 1'b0, "single read resumes on new image");
expect_index(active_buffer_index, 2'd1, "new image becomes active");
```

- [x] **Step 2: Run the controller test and confirm the single-frame interface fails**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_controller.vvp'
iverilog -g2012 -s tb_video_transition_controller -o $tbOut fpga\osd_display\tests\tb_video_transition_controller.sv fpga\osd_display\rtl\video\video_transition_controller.v
vvp $tbOut
```

Expected: compile failure because the current controller exposes `fade_level` and `sweep_position` instead of dual-frame indexes and alpha.

- [x] **Step 3: Implement the controller and exact alpha lookup**

Use a 5-bit phase `0..31`, an edge detector on `video_read_req`, and this lookup signature:

```verilog
function [6:0] alpha_curve;
    input [4:0] step;
    begin
        case (step)
            5'd0: alpha_curve = 7'd0;
            5'd1: alpha_curve = 7'd1;
            5'd2: alpha_curve = 7'd2;
            5'd3: alpha_curve = 7'd3;
            5'd4: alpha_curve = 7'd4;
            5'd5: alpha_curve = 7'd5;
            5'd6: alpha_curve = 7'd7;
            5'd7: alpha_curve = 7'd9;
            5'd8: alpha_curve = 7'd11;
            5'd9: alpha_curve = 7'd13;
            5'd10: alpha_curve = 7'd15;
            5'd11: alpha_curve = 7'd17;
            5'd12: alpha_curve = 7'd20;
            5'd13: alpha_curve = 7'd23;
            5'd14: alpha_curve = 7'd26;
            5'd15: alpha_curve = 7'd29;
            5'd16: alpha_curve = 7'd32;
            5'd17: alpha_curve = 7'd35;
            5'd18: alpha_curve = 7'd38;
            5'd19: alpha_curve = 7'd41;
            5'd20: alpha_curve = 7'd44;
            5'd21: alpha_curve = 7'd47;
            5'd22: alpha_curve = 7'd49;
            5'd23: alpha_curve = 7'd51;
            5'd24: alpha_curve = 7'd53;
            5'd25: alpha_curve = 7'd55;
            5'd26: alpha_curve = 7'd57;
            5'd27: alpha_curve = 7'd59;
            5'd28: alpha_curve = 7'd60;
            5'd29: alpha_curve = 7'd61;
            5'd30: alpha_curve = 7'd62;
            5'd31: alpha_curve = 7'd63;
            default: alpha_curve = 7'd64;
        endcase
    end
endfunction
```

On transition start, assign `old_buffer_index <= active_buffer_index` and `new_buffer_index <= target_buffer_index`. Do not change either until completion. At phase 31, the next frame request assigns active/new to the target, alpha 64, and clears dual/busy.

- [x] **Step 4: Run the controller test to a clean pass**

Run the Step 2 command. Expected: `PASS tb_video_transition_controller`.

### Task 2: Replace the color effect with a pure RGB crossfade

**Files:**
- Modify: `fpga/osd_display/tests/tb_video_transition_blender.sv`
- Modify: `fpga/osd_display/rtl/video/video_transition_blender.v`

**Interfaces:**
- Consumes: `rgb_old[23:0]`, `rgb_new[23:0]`, `dual_read_active`, `alpha_step[6:0]`.
- Produces: combinational `rgb_out[23:0]` with no coordinate or timing dependency.

- [x] **Step 1: Rewrite exact endpoint and midpoint tests**

```systemverilog
rgb_old = 24'hE02010;
rgb_new = 24'h1060E0;
dual_read_active = 1'b1;
alpha_step = 7'd0;
expect_rgb(rgb_out, 24'hE02010, "alpha zero is exact old image");
alpha_step = 7'd32;
expect_rgb(rgb_out, 24'h784078, "alpha midpoint averages both images");
alpha_step = 7'd63;
expect_rgb(rgb_out, 24'h135FDC, "last mixed frame remains bounded");
dual_read_active = 1'b0;
expect_rgb(rgb_out, 24'h1060E0, "single mode is exact current image");
```

Also assert that changing former coordinate-like inputs is impossible because the new module has no `vs`, `de`, `fade_level`, or `sweep_position` ports.

- [x] **Step 2: Run the blender test and confirm the old interface fails**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_blender.vvp'
iverilog -g2012 -s tb_video_transition_blender -o $tbOut fpga\osd_display\tests\tb_video_transition_blender.sv fpga\osd_display\rtl\video\video_transition_blender.v
vvp $tbOut
```

Expected: compile failure on the removed single-image warm-white ports.

- [x] **Step 3: Implement one widened multiply-add per RGB channel**

```verilog
wire [6:0] alpha = (alpha_step > 7'd64) ? 7'd64 : alpha_step;
wire [6:0] old_weight = 7'd64 - alpha;
wire [14:0] sum_r = (rgb_old[23:16] * old_weight) +
                    (rgb_new[23:16] * alpha);
wire [7:0] mixed_r = sum_r[13:6];
assign rgb_out = !dual_read_active ? rgb_new : {mixed_r, mixed_g, mixed_b};
```

Use the same widths and calculation for green and blue. Add exact alpha 0 and alpha 64 endpoint bypasses if required to keep synthesis and simulation unambiguous.

- [x] **Step 4: Run the blender test to a clean pass**

Run the Step 2 command. Expected: `PASS tb_video_transition_blender`.

### Task 3: Harden the two-FIFO SDRAM display reader

**Files:**
- Modify: `fpga/osd_display/tests/tb_frame_dual_fifo_read.sv`
- Create: `fpga/osd_display/tests/tb_frame_read_write_dual.sv`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_dual_fifo_read.v`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`

**Interfaces:**
- `frame_dual_fifo_read` consumes 10-bit old/new FIFO write-side levels, locked old/new buffer indexes, `dual_read_mode`, and real `Sdr_rd_en`.
- `frame_read_write` adds `dual_read_mode`, `read_addr_index_old`, `read_en_old`, and `read_data_old[31:0]`; its existing `read_addr_index` is the new/current FIFO index.

- [x] **Step 1: Extend the scheduler test before changing RTL**

Keep delayed return checking and add gaps inside the emulated return stream. Set old level higher than new and assert the next eligible burst targets new; invert the levels and assert old is selected. In dual mode require the exact address groups old 10..13 then new 100..103 when levels tie. In single mode require only new addresses.

Also start a request with single mode/index 0, wait for acknowledgement, then
change to dual mode/index 1 on the same edge that drops the request. Require the
current transaction to issue 16 paired commands rather than 8 single commands.

```systemverilog
if (Sdr_rd_en && route_old_fifo !== return_target_old)
    $fatal(1, "FAIL returned word changed fifo route");

old_wrusedw = 10'd10;
new_wrusedw = 10'd0;
// Next dual burst must refill the lower new FIFO.
```

- [x] **Step 2: Run the scheduler test and verify the new width/priority assertions fail**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_frame_dual_fifo_read.vvp'
iverilog -g2012 -s tb_frame_dual_fifo_read -o $tbOut fpga\osd_display\tests\tb_frame_dual_fifo_read.sv fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v
vvp $tbOut
```

Expected: failure because the current scheduler uses 9-bit levels and alternating preference without lower-watermark priority.

- [x] **Step 3: Implement lower-watermark scheduling with return-locked routing**

Set production defaults `BURST_SIZE=64`, `FIFO_DEPTH=1024`, and `FIFO_LEVEL_BITS=10`. Start no burst unless the selected FIFO has at least 64 free words. When both FIFOs are eligible, select the lower `wrusedw`; use `next_target_old` only on a tie. Increment `burst_return_count` only on `Sdr_rd_en`, and never change `selected_old` in `S_READ_BURST` or `S_WAIT_RETURN`.

While in `S_ACK`, sample mode, indexes, and length on every memory clock. On the
first cycle where synchronized `read_req_d2` is low, latch those values once
more, reset both read counters, assert the matching FIFO clears, and only then
enter `S_CHECK_FIFO`. This captures metadata updated by the video controller as
the acknowledged request is retired.

- [x] **Step 4: Integrate two 1024-word FIFO instances without changing writes**

Instantiate both read FIFOs with:

```verilog
rfifo_32_32_512 #(
    .ADDR_WIDTH_W (10),
    .ADDR_WIDTH_R (10),
    .AL_FULL_NUM  (10'd1016)
) new_read_buf (...);
```

Use identical parameters for `old_read_buf`. Gate write enables with `Sdr_rd_en && !route_old_fifo` and `Sdr_rd_en && route_old_fifo`; drive both read enables from their respective top-level ports. Leave `wfifo_32_32_512`, `frame_fifo_write`, `BURST_SIZE=256`, and every write-side port unchanged.

- [x] **Step 5: Run scheduler and frame-wrapper data tests**

Run the Step 2 test, then:

```powershell
$frameOut = Join-Path $env:TEMP 'frame_read_write_compile.vvp'
iverilog -g2012 -s tb_frame_read_write_dual -o $frameOut fpga\osd_display\tests\tb_frame_read_write_dual.sv fpga\osd_display\rtl\vendor\SD\frame_read_write.v fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v fpga\osd_display\rtl\vendor\SD\frame_fifo_write.v fpga\osd_display\ip\anlogic\afifo_32_16_256.v fpga\osd_display\ip\anlogic\afifo_16_32_256.v
vvp $frameOut
```

Expected: the tests print `PASS tb_frame_dual_fifo_read` and
`PASS tb_frame_read_write_dual`, with no unresolved module or port error.

The wrapper-level test drives distinguishable `A0000000..A0000007` old pixels
and `B0000000..B0000007` new pixels through the generated FIFO model, then
reads both ports together and requires exact order and alignment.

### Task 4: Wire aligned old/new video paths and run integration regression

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`
- Modify: `fpga/osd_display/osd_display.al`
- Modify: `docs/project-roadmap.md`
- Modify: `docs/osd-display-migration.md`

**Interfaces:**
- Top connects `new_buffer_index` to `frame_read_write.read_addr_index` and `old_buffer_index` to `read_addr_index_old`.
- Both FIFO outputs use the same `video_read_en`; two identical `video_delay` instances produce `rgb_new` and `rgb_old`, and only the new path supplies HS/VS/DE.
- `video_transition_blender.rgb_out` remains before `video_osd_overlay.rgb_in`.

- [x] **Step 1: Add the new top-level wires and source assertions**

Require `video_read_data_old`, `video_read_en_old`, both buffer indexes, and `dual_read_active`. Add source checks that reject all warm-white interface names and verify the new-buffer connection:

```powershell
$top = Get-Content -Raw fpga\osd_display\rtl\top\top.v
if ($top -match 'transition_fade_level|transition_sweep_position') { throw 'warm-white ports remain' }
if ($top -notmatch '\.read_addr_index\s*\(new_buffer_index\)') { throw 'new FIFO is not tied to target/current index' }
if ($top -notmatch '\.read_addr_index_old\s*\(old_buffer_index\)') { throw 'old FIFO index is missing' }
```

- [x] **Step 2: Rewire controller, reader, delays, and blender**

Connect controller outputs by name. Use `video_delay_m0` for the new/current FIFO and add `video_delay_old_m0` with the same timing inputs; leave its timing outputs open. Connect both delayed RGB values to the pure blender. Keep fallback selection before OSD and leave audio/OSD modules unchanged.

- [x] **Step 3: Enable the scheduler in the TD project and adjust syntax stubs**

Remove only `<Attr Name="AutoExcluded" Val="true"/>` from the `frame_dual_fifo_read.v` entry. Add the four new ports to the `frame_read_write` black box in `top_compile_stubs.v`. Keep `frame_fifo_read.v` listed because it remains a historical source but is no longer instantiated.

- [x] **Step 4: Run all focused tests and top-level elaboration**

```powershell
$tests = @(
  @{ n='tb_video_transition_controller'; s=@('fpga\osd_display\tests\tb_video_transition_controller.sv','fpga\osd_display\rtl\video\video_transition_controller.v') },
  @{ n='tb_video_transition_blender'; s=@('fpga\osd_display\tests\tb_video_transition_blender.sv','fpga\osd_display\rtl\video\video_transition_blender.v') },
  @{ n='tb_frame_dual_fifo_read'; s=@('fpga\osd_display\tests\tb_frame_dual_fifo_read.sv','fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v') },
  @{ n='tb_frame_read_write_dual'; s=@('fpga\osd_display\tests\tb_frame_read_write_dual.sv','fpga\osd_display\rtl\vendor\SD\frame_read_write.v','fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v','fpga\osd_display\rtl\vendor\SD\frame_fifo_write.v','fpga\osd_display\ip\anlogic\afifo_32_16_256.v','fpga\osd_display\ip\anlogic\afifo_16_32_256.v') },
  @{ n='tb_video_osd_overlay'; s=@('fpga\osd_display\tests\tb_video_osd_overlay.sv','fpga\osd_display\rtl\video\video_osd_overlay.v') }
)
foreach ($test in $tests) {
  $out = Join-Path $env:TEMP ($test.n + '.vvp')
  iverilog -g2012 -s $test.n -o $out $test.s
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  vvp $out
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Then elaborate `top.v` once with the real frame wrapper, both generated FIFO sources, project RTL dependencies, and `tests/top_compile_stubs.v`. Expected: five PASS markers and no unresolved transition/reader ports.

- [x] **Step 5: Record the implementation and JTAG handoff**

Document the exact 32-frame alpha curve, 64-word reads, 1024-word FIFO depth, passing simulations, and that board validation is still pending. The user runs TD `syn_1`, `phy_1`, and bitstream generation, then checks at least ten KEY2 transitions, multiple KEY4 cycles, audio, OSD, and TF recovery. Do not mark the crossfade stable or write Flash until that JTAG result passes.
