# Image Slide Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a frame-synchronous right-to-left image reveal after each committed image change while preserving the proven media and storage paths.

**Architecture:** Detect a change in the synchronized `current_image_index` inside `video_osd_overlay`. For the next 20 `vs` frame boundaries, reveal the incoming `rgb_in` image from right to left in 32-pixel increments and paint the unrevealed picture area black. Keep the title, ticker, and status bars outside the transition mask.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog (`iverilog` and `vvp`), Tang Dynasty GUI for final synthesis, place-and-route, and board testing.

**Spec:** `docs/superpowers/specs/2026-09-08-image-slide-transition-design.md`

## File Structure

- `fpga/osd_display/rtl/video/video_osd_overlay.v` owns the transition detector, frame counter, reveal boundary, and picture-area mask.
- `fpga/osd_display/tests/tb_video_osd_overlay.sv` drives image-index changes and `vs` edges to verify mask timing and existing OSD priorities.

## Global Constraints

- Preserve the existing `video_osd_overlay` port list and all existing top-level, SDRAM, TF, audio, key-control, PLL, and video-timing RTL.
- Keep transition state in the 25 MHz `video_clk` domain; update it only on `vs && !vs_d`.
- Trigger only when synchronized `current_image_index` changes; reset initializes the remembered index and does not start a transition.
- Apply the mask only to image pixels with `y >= 24` and `y < 432`; ticker `y=432..455`, bottom status bar `y>=456`, and top title bar remain unchanged.
- Use a 20-frame transition with 32-pixel increments. During frame counter values 0..19, the left boundary is `640 - ((counter + 1) * 32)`; at value 20 the mask is inactive.
- Do not run Tang Dynasty command-line tooling or Git commands. The user performs `syn_1`, `phy_1`, JTAG, Flash, and board tests through the TD GUI.

---

### Task 1: Add failing transition assertions

**Files:**
- Modify: `fpga/osd_display/tests/tb_video_osd_overlay.sv`
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`

**Interfaces:**
- Consumes: Existing OSD ports, forced `dut.x`/`dut.y`, and the existing `drive_frame_boundary` task.
- Produces: Assertions requiring internal `transition_frame`, `previous_image_index`, and `transition_pending` state.

- [x] **Step 1: Add transition setup and mask assertions before releasing forced coordinates**

```systemverilog
// Capture the currently displayed image, then emulate a committed next image.
current_image_index = 2'd3;
@(posedge video_clk);
current_image_index = 2'd0;
@(posedge video_clk);
drive_frame_boundary;
force dut.x = 10'd100;
force dut.y = 10'd100;
expect_rgb(rgb_out, 24'h000000, "slide transition masks left picture area");
force dut.x = 10'd620;
expect_rgb(rgb_out, 24'h123456, "slide transition reveals right edge");
expect_rgb({19'd0, dut.transition_frame}, 24'h000000,
           "slide transition starts at frame zero");
```

- [x] **Step 2: Add frame-progress and completion assertions**

```systemverilog
drive_frame_boundary;
expect_rgb({19'd0, dut.transition_frame}, 24'h000001,
           "slide transition advances on one frame edge");
force dut.x = 10'd100;
expect_rgb(rgb_out, 24'h000000, "left area remains masked early");

storage_ready = 1'b0;
load_in_progress = 1'b1;
drive_frame_boundary;
expect_rgb({19'd0, dut.transition_frame}, 24'h000002,
           "storage state does not reset transition");
storage_ready = 1'b1;
load_in_progress = 1'b0;

repeat (18) drive_frame_boundary;
expect_rgb({19'd0, dut.transition_frame}, 24'h000014,
           "slide transition reaches terminal count");
expect_rgb(rgb_out, 24'h123456, "full picture restores after transition");

force dut.y = 10'd436;
expect_rgb(rgb_out, 24'h10213A, "ticker remains stable during transition");
force dut.y = 10'd460;
expect_rgb(rgb_out, 24'h54E3E3, "status bar remains stable during transition");
```

- [x] **Step 3: Run the focused simulation and confirm the new checks fail**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_osd_overlay.vvp'
iverilog -g2012 -s tb_video_osd_overlay -o $tbOut `
  fpga\osd_display\tests\tb_video_osd_overlay.sv `
  fpga\osd_display\rtl\video\video_osd_overlay.v
vvp $tbOut
```

Expected: compilation fails because `transition_frame` is not yet present, or the first picture-area assertion sees the unmasked `rgb_in`.

### Task 2: Implement the video-domain slide mask

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_osd_overlay.v`
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`

**Interfaces:**
- Consumes: Existing `current_image_index`, `vs`, `de`, `rgb_in`, and pixel coordinates.
- Produces: Internal `transition_frame[4:0]`, `previous_image_index[1:0]`, and a combinational `transition_pixel_visible` mask.

- [x] **Step 1: Add transition state and wires near the existing ticker state**

```verilog
reg [4:0] transition_frame;
reg [1:0] previous_image_index;
reg       transition_pending;
wire transition_active;
wire [9:0] transition_left_boundary;
wire transition_pixel_visible;

assign transition_active = (transition_frame < 5'd20);
assign transition_left_boundary = 10'd640 -
                                  {(transition_frame + 5'd1), 5'd0};
assign transition_pixel_visible = !transition_active ||
                                  (x >= transition_left_boundary);
```

- [x] **Step 2: Extend the existing reset and sequential `vs` branch**

```verilog
if (rst) begin
    previous_image_index <= current_image_index;
    transition_pending   <= 1'b0;
    transition_frame     <= 5'd20;
end else begin
    if (current_image_index != previous_image_index) begin
        previous_image_index <= current_image_index;
        transition_pending    <= 1'b1;
    end
    if (vs && !vs_d) begin
        if (transition_pending) begin
            transition_pending <= 1'b0;
            transition_frame   <= 5'd0;
        end else if (transition_frame < 5'd20) begin
            transition_frame <= transition_frame + 5'd1;
        end
    end
end
```

Merge this with the existing `always @(posedge video_clk or posedge rst)` block so `vs_d`, coordinate counters, ticker divider, and transition state remain single-driver registers. Keep current ticker update behavior unchanged.

- [x] **Step 3: Gate only the picture-area branch with the reveal mask**

```verilog
end else if (ticker_active) begin
    rgb_out_r = BAR_RGB;
    if (ticker_pixel)
        rgb_out_r = TICKER_RGB;
end else if (y >= BOTTOM_BAR_Y) begin
    rgb_out_r = BAR_RGB;
    if (indicator_active || status_pixel)
        rgb_out_r = status_rgb;
end else if (transition_active && !transition_pixel_visible) begin
    rgb_out_r = 24'h000000;
end
```

Place the mask branch after the top/ticker/bottom-bar branches, inside the existing `if (de)` block. It must not affect blanking, bars, or any pixel once `transition_frame == 20`.

- [x] **Step 4: Run the focused simulation and require a clean pass**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_osd_overlay.vvp'
iverilog -g2012 -s tb_video_osd_overlay -o $tbOut `
  fpga\osd_display\tests\tb_video_osd_overlay.sv `
  fpga\osd_display\rtl\video\video_osd_overlay.v
vvp $tbOut
```

Expected: exit code `0` and output containing `PASS tb_video_osd_overlay`.

### Task 3: Integration validation gate

**Files:**
- Modify: none
- Test: TD GUI project and board

**Interfaces:**
- Consumes: Passing OSD simulation and existing `.al` project.
- Produces: JTAG board confirmation before any Flash update.

- [x] **Step 1: Check the focused files for trailing whitespace**

Run:

```powershell
rg -n "[ \t]+$" fpga\osd_display\rtl\video\video_osd_overlay.v `
  fpga\osd_display\tests\tb_video_osd_overlay.sv
```

Expected: no output.

- [ ] **Step 2: Ask the user to run TD GUI `syn_1` and `phy_1`**

Expected: both stages complete. Record timing/resource reports without claiming setup closure when the report retains negative slack.

- [ ] **Step 3: Ask the user to JTAG-download and board-test the transition**

Test checklist:

```text
1. Initial image appears normally with no transition.
2. Each KEY2 image change slides in from the right over about 0.33 seconds.
3. KEY4 automatic cycling shows the same slide transition.
4. The title bar, scrolling ticker, and status bar remain stable and readable.
5. HDMI audio remains continuous through every transition.
6. TF removal/reinsertion behavior remains unchanged, including WAIT TF and recovery.
```

Expected: all six checks pass. If any fail, preserve the observed OSD state and debug only the transition test/overlay logic; do not alter SDRAM, TF, audio, or key-control paths.
