# Single-Frame Warm-White Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unstable dual-frame crossfade with a roughly 0.53-second single-frame warm-white fade and a clearly intentional warm-gold diagonal accent.

**Architecture:** The video-domain controller fades the active frame to a full warm-white cover, changes the SDRAM display buffer only at that covered frame boundary, then fades the new frame back in. The top-level always requests one frame, and the pixel effect uses divide-by-64 interpolation with signed direction checks so neither the white fade nor gold accent can wrap.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbenches, Icarus Verilog, Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-09-single-frame-warm-white-transition-design.md`

## Global Constraints

- Keep BMP/WAV formats, FAT32, SDRAM writes, audio, PLLs, HDMI timing, OSD contents, key definitions, auto-play interval, and SDRAM addresses unchanged.
- Keep the first committed image direct, without a transition.
- Use 16 fade-out frames and 16 fade-in frames at 60 Hz, with the exact symmetric fade curve `0,1,2,4,7,11,16,23,32,41,48,53,57,60,62,63,64`.
- Change the active SDRAM buffer only while the image is fully covered at fade level 64.
- Keep OSD compositing after the transition effect so title, ticker, and status bars are never faded.
- Keep the second FIFO scheduler source file for history, but restore `frame_read_write` to the board-proven single FIFO and `frame_fifo_read` implementation.
- Use JTAG validation before writing configuration Flash.

---

### Task 1: Convert the transition controller to a covered single-frame handoff

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_transition_controller.v`
- Modify: `fpga/osd_display/tests/tb_video_transition_controller.sv`

**Interfaces:**
- Consumes: `video_clk`, `rst`, frame-level `video_read_req`, `display_valid`, and `committed_buffer_index[1:0]`.
- Produces: `active_buffer_index[1:0]`, `transition_busy`, `transition_active`, `fade_level[6:0]`, and monotonic `sweep_position[6:0]`.

- [x] **Step 1: Rewrite the controller test for two-phase fading**

Keep the first-image assertion, then require the following sequence after buffer 1 commits:

```systemverilog
pulse_read_request;
expect_bit(transition_busy, 1'b1, "single-frame fade starts");
expect_value(fade_level, 7'd0, "fade begins clear");
repeat (8) pulse_read_request;
expect_value(fade_level, 7'd32, "fade curve reaches midpoint");
repeat (7) pulse_read_request;
expect_value(fade_level, 7'd63, "last partially visible old frame");
expect_value(sweep_position, 7'd30, "accent moves forward during fade-out");
expect_value({5'd0, active_buffer_index}, 7'd0, "old buffer retained before cover");
pulse_read_request;
expect_value(fade_level, 7'd64, "covered handoff frame");
expect_value({5'd0, active_buffer_index}, 7'd1, "buffer changes under cover");
repeat (15) pulse_read_request;
expect_value(fade_level, 7'd1, "last partially covered new frame");
expect_value(sweep_position, 7'd62, "accent keeps moving during fade-in");
pulse_read_request;
expect_value(fade_level, 7'd0, "fade completes clear");
expect_bit(transition_busy, 1'b0, "playback reservation releases");
```

- [x] **Step 2: Confirm the old interface cannot satisfy the new sequence**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_controller.vvp'
iverilog -g2012 -s tb_video_transition_controller -o $tbOut fpga\osd_display\tests\tb_video_transition_controller.sv fpga\osd_display\rtl\video\video_transition_controller.v
vvp $tbOut
```

Confirmed from the prior controller and board result: it exposed dual-frame indexes and incremented through a 64-frame crossfade, so it could not provide the covered single-buffer handoff.

- [x] **Step 3: Implement the two-phase state machine**

Use `fading_in` and a 0-through-16 `phase_step` to distinguish phases. Implement a combinational `fade_curve` function returning the exact values from the global constraint. On a pending commit at a frame request, latch `target_buffer_index`, assert both active/busy outputs, and start both progress outputs at zero. Increment `phase_step` and add two to `sweep_position` per frame; at step 16 set level 64, change `active_buffer_index` to the target, and enter fade-in. Decrement `phase_step` while continuing to add two to `sweep_position`; at step zero set both fade outputs to their final values and release active/busy.

- [x] **Step 4: Run the controller test to a clean pass**

Run the commands from Step 2. Expected: `PASS tb_video_transition_controller`.

### Task 2: Implement the warm-white cover and warm-gold accent

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_transition_blender.v`
- Modify: `fpga/osd_display/tests/tb_video_transition_blender.sv`

**Interfaces:**
- Consumes: `video_clk`, `rst`, `vs`, `de`, `rgb_in[23:0]`, `transition_active`, `fade_level[6:0]`, and `sweep_position[6:0]`.
- Produces: `rgb_out[23:0]`, with exact bypass outside a transition.

- [x] **Step 1: Rewrite endpoint and accent tests**

Require `rgb_out == rgb_in` while inactive and at fade level zero, exact `24'hFFF4D6` at level 64, and the expected halfway result at level 32. Force coordinates in the 40-pixel band and verify an outer pixel moves one quarter toward `24'hFFD166`, a core pixel moves one half toward it, and a pixel at `y=470` receives only the warm-white cover.

- [x] **Step 2: Confirm the old dual-input effect cannot satisfy the new interface**

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_transition_blender.vvp'
iverilog -g2012 -s tb_video_transition_blender -o $tbOut fpga\osd_display\tests\tb_video_transition_blender.sv fpga\osd_display\rtl\video\video_transition_blender.v
vvp $tbOut
```

Confirmed from the prior source: it required `rgb_old`, `rgb_new`, `dual_read_active`, and `alpha_step`, so it could not provide the single-frame warm-white effect.

- [x] **Step 3: Implement channel interpolation without unsigned wrap**

For each channel, compute the absolute difference between source and `WARM_WHITE = 8'hff/8'hf4/8'hd6`, scale it by `fade_level`, shift right six, and add or subtract according to the target direction. Apply the gold accent after the cover with the same direction-aware interpolation toward `GOLD = 24'hFFD166`; use a right shift of one in the 16-pixel core and two in the outer band.

Calculate the moving band center as `sweep_position * 18`; enable it only for `transition_active && de && sweep_position > 0 && sweep_position < 64 && y >= 24 && y < 432`. Use a 40-pixel band with the middle 16 pixels as the core.

- [x] **Step 4: Run the blender test to a clean pass**

Run the commands from Step 2. Expected: `PASS tb_video_transition_blender`.

### Task 3: Fix the top-level to the single-frame display path

**Files:**
- Modify: `fpga/osd_display/rtl/top/top.v`
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_read_write.v`
- Modify: `fpga/osd_display/osd_display.al`
- Modify: `fpga/osd_display/tests/top_compile_stubs.v` only if the controller or blender stub boundary requires it.

**Interfaces:**
- Consumes: controller `active_buffer_index`, `transition_active`, `fade_level`, and `sweep_position`.
- Produces: `frame_read_write.read_addr_index=active_buffer_index`, no dual-frame ports, a single instantiated read FIFO and `frame_fifo_read`, and the post-effect RGB stream feeding OSD.

- [x] **Step 1: Add source-level integration assertions**

Use PowerShell `Select-String` checks to require literal connections for single-frame mode and to reject `video_delay_old_m0` from `top.v`:

```powershell
$top = Get-Content -Raw fpga\osd_display\rtl\top\top.v
if ($top -match 'dual_read_mode|read_en_old|read_data_old') { throw 'dual-frame top ports must be removed' }
if ($top -match 'video_delay_old_m0') { throw 'old video path must not be instantiated' }
$reader = Get-Content -Raw fpga\osd_display\rtl\vendor\SD\frame_read_write.v
if ($reader -notmatch 'frame_fifo_read\s*#') { throw 'stable single reader must be instantiated' }
if ($reader -match 'old_read_buf|frame_dual_fifo_read\s*#|dual_read_mode|read_en_old|read_data_old') { throw 'dual reader interface must be removed' }
```

- [x] **Step 2: Rewire controller, effect, and frame reader**

Remove old/new buffer and RGB-path wires that are no longer consumed. Connect `frame_read_write.read_addr_index` directly to `active_buffer_index`, remove its dual and old-read ports, feed `vout_data_raw` into `video_transition_blender.rgb_in`, and connect the controller's new transition outputs by name. In `frame_read_write`, remove the old FIFO, `frame_dual_fifo_read` instance, and compatibility ports; restore the original `frame_fifo_read` instance with the existing `BURST_SIZE`. Remove `AutoExcluded` from the `frame_fifo_read.v` project entry so TD compiles the restored dependency. Retain `transition_busy` synchronization and playback interlock unchanged.

- [x] **Step 3: Run the source assertions**

Run the Step 1 script. Expected: no output and exit code zero.

- [x] **Step 4: Elaborate the top-level syntax harness**

Compile `top.v` with `tests/top_compile_stubs.v` plus the project control, storage, audio, video, and button modules already required by the existing harness. Expected: clean elaboration with no unresolved transition ports.

### Task 4: Run regression and update the handoff record

**Files:**
- Modify: `docs/project-roadmap.md`
- Modify: `docs/osd-display-migration.md`
- Test: transition controller, transition blender, dual-reader regression, OSD regression, and top-level syntax harness.

**Interfaces:**
- Consumes: the final single-frame RTL.
- Produces: reproducible simulation results and an exact JTAG acceptance checklist.

- [x] **Step 1: Run focused simulations**

Run `tb_video_transition_controller`, `tb_video_transition_blender`, `tb_frame_dual_fifo_read`, and `tb_video_osd_overlay` with Icarus. The retained dual-reader test must still pass even though top-level production use is disabled.

- [x] **Step 2: Run repository checks**

Run `git diff --check`, inspect `git diff` for only intended files, and confirm no generated TD run outputs changed during local verification.

- [x] **Step 3: Record the board-test handoff**

Append the latest observation, the architectural fallback, the 0.53-second timing, the gold accent behavior, and the next JTAG test procedure to both progress documents. Do not claim board success before the new bitstream is downloaded.

- [ ] **Step 4: Perform TD and board validation**

In TD 6.2.1 run `syn_1`, `phy_1`, and bitstream generation. JTAG-test at least ten `KEY2` transitions, several `KEY4` automatic cycles, audio continuity, OSD stability, and one TF removal/reinsertion. Write configuration Flash only after there are no transition blocks, tearing, black frames, HDMI loss, or ambiguous pale diagonal lines.
