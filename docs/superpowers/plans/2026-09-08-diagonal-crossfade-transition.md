# Diagonal Crossfade Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the black slide mask with a true old/new-frame crossfade and diagonal highlight, without changing media formats, the image loader, or the stable HDMI/TF/audio behavior outside the short transition interval.

**Architecture:** The video-domain controller retains the last displayed SDRAM buffer and starts a 17-step transition only at a video-frame read request. The SDRAM read wrapper gets a second asynchronous FIFO and a burst scheduler that preserves the existing 256-word SDRAM burst length while alternating complete old/new bursts only when transition mode is latched for a frame. Two delayed RGB streams enter a 25 MHz blender; it uses alpha values 0..16 and a diagonal highlight before the existing OSD composites title, ticker, and status information.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, existing Anlogic asynchronous FIFO IP, Icarus Verilog (`iverilog` and `vvp`), Tang Dynasty GUI for final synthesis/place-and-route/JTAG board tests.

**Spec:** `docs/superpowers/specs/2026-09-08-diagonal-crossfade-transition-design.md`

## File Structure

- Create `fpga/osd_display/rtl/video/video_transition_controller.v`: frame-safe ownership of current/old/new buffer indexes, alpha step, and busy status.
- Create `fpga/osd_display/rtl/video/video_transition_blender.v`: dual RGB alpha composition and diagonal highlight before OSD.
- Create `fpga/osd_display/rtl/vendor/SD/frame_dual_fifo_read.v`: SDRAM-clock-domain frame request synchronizer and complete-burst old/new scheduler.
- Modify `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`: retain its write path; replace its single read scheduler with `frame_dual_fifo_read`; add the old-frame FIFO/output.
- Modify `fpga/osd_display/rtl/top/top.v`: connect controller, two `video_delay` paths, double reader outputs, blender, and the transition-busy playback interlock.
- Modify `fpga/osd_display/rtl/video/video_osd_overlay.v`: remove rejected black-mask state and restore OSD-only responsibility.
- Modify `fpga/osd_display/osd_display.al` and `fpga/osd_display/tests/top_compile_stubs.v`: add new files and black-box ports.
- Create focused tests under `fpga/osd_display/tests/` and update `tb_video_osd_overlay.sv`.

## Global Constraints

- Preserve FAT32 BMP/WAV loading, image-load manager states, SDRAM write path, audio FIFO/player, HDMI timing, PLL configuration, board key definitions, and existing OSD text/status priorities.
- Only 640x480, 24-bit pixel output and the existing two SDRAM image buffers are in scope.
- In non-transition frames, preserve the single-frame SDRAM read behavior and direct RGB output.
- A transition begins only after a committed display-buffer change, at the next `video_read_req` edge; reset and a first commit to buffer zero do not transition.
- Use 17 alpha values (`0..16`). At alpha 0 output old RGB; at alpha 16 output new RGB; do not output a black interstitial frame.
- During `transition_busy`, gate the `manager_idle` input of `image_playback_control`; do not modify the image manager state machine or silently queue new manual/auto requests.
- Dual fetch preserves the existing complete 256-word bursts. Do not switch FIFO destination while a burst response is pending.
- Do not run Tang Dynasty command-line tooling or Git commands. The user alone performs TD GUI `syn_1`, `phy_1`, JTAG, Flash, and board testing.

---

### Task 1: Build and verify the video-domain transition controller

**Files:**
- Create: `fpga/osd_display/rtl/video/video_transition_controller.v`
- Create: `fpga/osd_display/tests/tb_video_transition_controller.sv`

**Interfaces:**
- Consumes: `video_clk`, `rst`, one-cycle `video_read_req`, `display_valid`, and synchronized `committed_buffer_index[1:0]`.
- Produces: `active_buffer_index[1:0]`, `old_buffer_index[1:0]`, `new_buffer_index[1:0]`, `dual_read_active`, `transition_busy`, and `alpha_step[4:0]`.

- [x] **Step 1: Write controller testbench reset, first-frame, and commit tests**

```systemverilog
// First buffer-zero presentation is direct; it must not create a transition.
display_valid = 1'b1;
committed_buffer_index = 2'd0;
pulse_read_request();
expect_bit(dual_read_active, 1'b0, "first image is direct");
expect_value(active_buffer_index, 2'd0, "first active buffer");

// A committed buffer-one image waits until the next frame request.
committed_buffer_index = 2'd1;
tick();
expect_bit(dual_read_active, 1'b0, "commit waits for frame request");
pulse_read_request();
expect_bit(dual_read_active, 1'b1, "next frame starts dual read");
expect_value(old_buffer_index, 2'd0, "old buffer remains readable");
expect_value(new_buffer_index, 2'd1, "new buffer locked");
expect_value(alpha_step, 5'd0, "transition starts at old image");
```

- [x] **Step 2: Add alpha progression, completion, and busy-state checks**

```systemverilog
repeat (15) pulse_read_request();
expect_value(alpha_step, 5'd15, "last mixed alpha step");
expect_bit(transition_busy, 1'b1, "busy before final new frame");
pulse_read_request();
expect_value(alpha_step, 5'd16, "final new alpha step");
expect_bit(dual_read_active, 1'b1, "final new frame still has paired data");
pulse_read_request();
expect_bit(dual_read_active, 1'b0, "single read resumes after final frame");
expect_value(active_buffer_index, 2'd1, "new buffer becomes active");
```

- [x] **Step 3: Run the failing controller test**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_controller.vvp'
iverilog -g2012 -s tb_video_transition_controller -o $tbOut `
  fpga\osd_display\tests\tb_video_transition_controller.sv `
  fpga\osd_display\rtl\video\video_transition_controller.v
vvp $tbOut
```

Expected: compilation fails before the controller exists.

- [x] **Step 4: Implement the controller state machine**

```verilog
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        active_buffer_index <= 2'd0;
        old_buffer_index    <= 2'd0;
        new_buffer_index    <= 2'd0;
        observed_buffer     <= 2'd0;
        alpha_step          <= 5'd16;
        dual_read_active    <= 1'b0;
        transition_busy     <= 1'b0;
        transition_pending  <= 1'b0;
        first_frame_seen    <= 1'b0;
    end else begin
        if (display_valid && (committed_buffer_index != observed_buffer)) begin
            observed_buffer    <= committed_buffer_index;
            transition_pending <= first_frame_seen;
            if (!first_frame_seen)
                active_buffer_index <= committed_buffer_index;
        end
        if (video_read_req) begin
            if (transition_pending) begin
                old_buffer_index   <= active_buffer_index;
                new_buffer_index   <= committed_buffer_index;
                alpha_step         <= 5'd0;
                dual_read_active   <= 1'b1;
                transition_busy    <= 1'b1;
                transition_pending <= 1'b0;
            end else if (dual_read_active && (alpha_step < 5'd16)) begin
                alpha_step <= alpha_step + 5'd1;
            end else if (dual_read_active) begin
                active_buffer_index <= new_buffer_index;
                dual_read_active    <= 1'b0;
                transition_busy     <= 1'b0;
            end
            if (display_valid)
                first_frame_seen <= 1'b1;
        end
    end
end
```

Add an edge detector for `video_read_req` if it can remain asserted for more than one video clock; the controller must advance at most once per frame request.

- [x] **Step 5: Run the controller test to a clean pass**

Run the command from Step 3.

Expected: output contains `PASS tb_video_transition_controller`.

### Task 2: Build and verify RGB composition and diagonal highlight

**Files:**
- Create: `fpga/osd_display/rtl/video/video_transition_blender.v`
- Create: `fpga/osd_display/tests/tb_video_transition_blender.sv`

**Interfaces:**
- Consumes: `video_clk`, `rst`, `vs`, `de`, `rgb_old[23:0]`, `rgb_new[23:0]`, `dual_read_active`, and `alpha_step[4:0]`.
- Produces: `rgb_out[23:0]`, transparent to timing/blanking values when `de=0`.

- [x] **Step 1: Write endpoint and midpoint mixing assertions**

```systemverilog
dual_read_active = 1'b1;
rgb_old = 24'hE02010;
rgb_new = 24'h1060E0;
alpha_step = 5'd0;
expect_rgb(rgb_out, 24'hE02010, "alpha zero uses old frame");
alpha_step = 5'd16;
expect_rgb(rgb_out, 24'h1060E0, "alpha sixteen uses new frame");
alpha_step = 5'd8;
expect_rgb(rgb_out, 24'h784088, "half alpha averages channels");
dual_read_active = 1'b0;
expect_rgb(rgb_out, 24'h1060E0, "single frame bypasses blender");
```

- [x] **Step 2: Add coordinate tests for highlight isolation**

```systemverilog
force dut.x = 10'd320;
force dut.y = 10'd240;
alpha_step = 5'd8;
expect_not_rgb(rgb_out, 24'h784088, "diagonal highlighter changes center edge");
force dut.y = 10'd470;
expect_rgb(rgb_out, 24'h784088, "non-picture rows do not receive highlighter");
```

- [x] **Step 3: Run the failing blender test**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_blender.vvp'
iverilog -g2012 -s tb_video_transition_blender -o $tbOut `
  fpga\osd_display\tests\tb_video_transition_blender.sv `
  fpga\osd_display\rtl\video\video_transition_blender.v
vvp $tbOut
```

Expected: compilation fails before the blender exists.

- [x] **Step 4: Implement alpha mixing with exact endpoint bypasses**

```verilog
wire [8:0] old_weighted_r = rgb_old[23:16] * (5'd16 - alpha_step);
wire [8:0] new_weighted_r = rgb_new[23:16] * alpha_step;
wire [8:0] mix_r = (old_weighted_r + new_weighted_r) >> 4;
// Repeat for G and B. When !dual_read_active, assign rgb_out = rgb_new.
```

Register `vs` and count `x`/`y` exactly as `video_osd_overlay` does. Define a 40-pixel diagonal highlight band from `x + y` and an `alpha_step` lookup table; brighten its mixed RGB by one quarter toward `24'hFFD166` only for `de && y >= 24 && y < 432 && dual_read_active`.

- [x] **Step 5: Run the blender test to a clean pass**

Run the command from Step 3.

Expected: output contains `PASS tb_video_transition_blender`.

### Task 3: Build and verify complete-burst dual FIFO scheduling

**Files:**
- Create: `fpga/osd_display/rtl/vendor/SD/frame_dual_fifo_read.v`
- Create: `fpga/osd_display/tests/tb_frame_dual_fifo_read.sv`

**Interfaces:**
- Consumes: `mem_clk`, `rst`, `Sdr_init_done`, `App_wr_busy`, video-domain `read_req`, `dual_read_mode`, `new_buffer_index`, `old_buffer_index`, base addresses, `read_len`, and both FIFO write-side levels.
- Produces: `read_req_ack`, `read_finish`, `new_fifo_aclr`, `old_fifo_aclr`, `App_rd_en`, `App_rd_addr`, and `route_old_fifo`.

- [x] **Step 1: Make the scheduler test use small parameters**

```systemverilog
frame_dual_fifo_read #(
    .ADDR_BITS(10), .BURST_SIZE(4), .FIFO_DEPTH(16), .READ_DELAY(2)
) dut (...);
```

Drive a single read request and assert that addresses are `new_base+0..3` in single mode. Drive dual mode and assert complete address groups `old_base+0..3`, then `new_base+0..3`, with `route_old_fifo` constant within each four-command burst. Set each emulated FIFO level to 15 and assert no new burst begins until its level is below `FIFO_DEPTH-BURST_SIZE`.

- [x] **Step 2: Run the failing scheduler test**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_frame_dual_fifo_read.vvp'
iverilog -g2012 -s tb_frame_dual_fifo_read -o $tbOut `
  fpga\osd_display\tests\tb_frame_dual_fifo_read.sv `
  fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v
vvp $tbOut
```

Expected: compilation fails before the scheduler exists.

- [x] **Step 3: Implement request synchronizers and latches**

Synchronize `read_req`, `dual_read_mode`, both buffer indexes, and `read_len` into `mem_clk` with the same two/three-stage pattern used by `frame_fifo_read`. On request acknowledgement, clear the new FIFO and additionally clear the old FIFO only in dual mode; latch all request metadata until `read_finish`.

- [x] **Step 4: Implement the complete-burst selector**

```verilog
if (!dual_mode_latched) begin
    selected_old <= 1'b0;
end else if ((next_target_old && old_remaining != 0 && old_fifo_room) ||
             (new_remaining == 0)) begin
    selected_old <= 1'b1;
end else begin
    selected_old <= 1'b0;
end
```

Issue exactly `BURST_SIZE` contiguous `App_rd_en` cycles at the selected buffer base plus its completed-word count. Do not change `selected_old` until `READ_DELAY` cycles after the final command. Then add `BURST_SIZE` to the selected count and toggle `next_target_old`. Finish only when the new count is complete and, in dual mode, the old count is complete.

- [x] **Step 5: Run the scheduler test to a clean pass**

Run the command from Step 2.

Expected: output contains `PASS tb_frame_dual_fifo_read`.

### Task 4: Integrate the second FIFO and video pipeline

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/rtl/video/video_osd_overlay.v`
- Modify: `fpga/osd_display/tests/tb_video_osd_overlay.sv`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v`
- Modify: `fpga/osd_display/osd_display.al`

**Interfaces:**
- `frame_read_write` gains `dual_read_mode`, `read_addr_index_old`, `read_en_old`, and `read_data_old`; existing single output names retain their meaning for new/current data.
- `video_transition_controller` owns reader selection; `video_transition_blender` replaces `vout_data_raw` only before OSD.

- [x] **Step 1: Remove the rejected black-mask test and state from OSD**

Delete `transition_frame`, `previous_image_index`, `transition_pending`, transition wires, sequential updates, and `rgb_out_r = 24'h000000` mask branch. Replace the old OSD transition assertions with one assertion that changing `current_image_index` leaves a normal picture-area pixel equal to `rgb_in`; OSD must be only title/ticker/status composition.

- [x] **Step 2: Add the old-frame asynchronous FIFO in `frame_read_write`**

Use the existing `rfifo_32_32_512` IP with the same clocks as `read_buf`. Drive its write enable with `Sdr_rd_en && route_old_fifo`; drive the existing `read_buf` only with `Sdr_rd_en && !route_old_fifo`. Connect `new_fifo_aclr` and `old_fifo_aclr` from the scheduler separately. In single mode `route_old_fifo` is always `0`, preserving the existing read FIFO behavior.

- [x] **Step 3: Wire transition controller and dual reader signals in `top.v`**

Create a controlled video-domain display buffer index rather than directly using `disp_buf_idx_video_sync`. Feed controller `committed_buffer_index=disp_buf_idx_video_sync` and `video_read_req`. Feed frame reader `read_addr_index=active_buffer_index`, `read_addr_index_old=old_buffer_index`, and `dual_read_mode=dual_read_active`. Instantiate a second `video_delay` for `read_data_old[31:8]`; feed both delayed RGB paths into `video_transition_blender`; connect blender output to `video_osd_overlay.rgb_in`.

- [x] **Step 4: Gate playback control while dual read is active**

Synchronize `transition_busy` from `video_clk` into `sd_card_clk` using two flip-flops. Replace only the `image_playback_control.manager_idle` connection with:

```verilog
assign playback_manager_idle = manager_idle && !transition_busy_sd_sync;
```

Leave `image_load_manager` ports and behavior unchanged.

- [x] **Step 5: Update TD project and syntax stubs**

Add the three new RTL files to `.al` with `UsedInSyn=true`, `UsedInP&R=true`, and compile orders before `top.v` references. Add black-box declarations/ports for the changed frame reader and two new video modules in `top_compile_stubs.v`.

- [x] **Step 6: Run focused regressions**

Run:

```powershell
$tests = @(
  @{ n='tb_video_transition_controller'; f='fpga\osd_display\tests\tb_video_transition_controller.sv'; r='fpga\osd_display\rtl\video\video_transition_controller.v' },
  @{ n='tb_video_transition_blender'; f='fpga\osd_display\tests\tb_video_transition_blender.sv'; r='fpga\osd_display\rtl\video\video_transition_blender.v' },
  @{ n='tb_frame_dual_fifo_read'; f='fpga\osd_display\tests\tb_frame_dual_fifo_read.sv'; r='fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v' },
  @{ n='tb_video_osd_overlay'; f='fpga\osd_display\tests\tb_video_osd_overlay.sv'; r='fpga\osd_display\rtl\video\video_osd_overlay.v' }
)
foreach ($test in $tests) {
  $out = Join-Path $env:TEMP ($test.n + '.vvp')
  iverilog -g2012 -s $test.n -o $out $test.f $test.r
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  vvp $out
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: all four testbenches print their `PASS` markers.

### Task 5: Project integration validation

**Files:**
- Modify: `docs/contest-delivery-guide.md` only after successful board test
- Test: TD GUI project and board

**Interfaces:**
- Consumes: passing focused regressions and the existing TD project.
- Produces: board-verified visual quality before Flash update.

- [x] **Step 1: Check focused RTL and test files for trailing whitespace**

Run:

```powershell
rg -n "[ \t]+$" fpga\osd_display\rtl\video\video_transition_controller.v `
  fpga\osd_display\rtl\video\video_transition_blender.v `
  fpga\osd_display\rtl\vendor\SD\frame_dual_fifo_read.v `
  fpga\osd_display\rtl\vendor\SD\frame_read_write.v `
  fpga\osd_display\rtl\top\top.v
```

Expected: no output.

- [ ] **Step 2: Ask the user to run TD GUI `syn_1` and `phy_1`**

Expected: both complete. Record new LUT/REG/BRAM/DSP totals and timing values. Do not claim timing closure while setup slack remains negative.

- [ ] **Step 3: Ask the user to JTAG-download and board-test**

Test checklist:

```text
1. First image appears directly, with no black flash or transition.
2. KEY2 transition keeps old image visible while new image fades in; no black gap, tearing, stripes, or flicker.
3. A warm diagonal highlight sweeps through the crossfade; OSD title, ticker, and status stay sharp.
4. Rapid KEY2 presses retain stable images and do not corrupt the transition.
5. KEY4 automatic cycling, continuous HDMI audio, and WAV looping remain normal.
6. TF fast/mid/long removal and reinsertion retain WAIT TF and recovery behavior without HDMI loss.
```

Expected: all checks pass before considering Flash. On any SDRAM visual artifact, preserve the current JTAG result and investigate dual scheduler/FIFO tests before changing FAT32, audio, or image-manager RTL.
