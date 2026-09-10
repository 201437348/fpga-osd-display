# Scrolling Ticker Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a frame-synchronous scrolling ASCII ticker to the HDMI image display without changing the stable image, SDRAM, TF-card, audio, key-control, or video-timing paths.

**Architecture:** Keep `video_osd_overlay` as the only video-domain compositing stage. A 24-pixel band at `y=432..455` always paints a dark background; its centered 8×7 glyph is doubled vertically and selected from a fixed 55-character circular string. A two-bit frame divider and a 9-bit circular pixel offset advance one pixel left after every third `vs` rising edge, so every image frame has a constant ticker position.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog (`iverilog` and `vvp`), Tang Dynasty GUI for final synthesis, place-and-route, and board testing.

**Spec:** `docs/superpowers/specs/2026-09-08-scrolling-ticker-overlay-design.md`

## File Structure

- `fpga/osd_display/rtl/video/video_osd_overlay.v` remains the sole OSD compositor. It owns ticker coordinates, text lookup, glyph lookup, scroll state, and the fixed-color compositing priority.
- `fpga/osd_display/tests/tb_video_osd_overlay.sv` remains the focused simulation. It forces pixel coordinates for visual assertions and drives `vs` edges for frame-rate assertions.

## Global Constraints

- Preserve the existing `video_osd_overlay` port list; do not change `top.v`, the `.al` project, constraints, generated IP, SDRAM, TF, WAV, audio, or key-control RTL.
- Keep all ticker state in the existing 25 MHz `video_clk` domain; do not add clock-domain crossings, memories, BRAM, DSP, PLLs, or external file access.
- Keep title and bottom status-bar priorities and colors unchanged outside `y=432..455`.
- Use the fixed ASCII text ` FPGA HDMI MULTIMEDIA DISPLAY / TF IMAGE / 48K AUDIO / `, including the one leading and one trailing space; it is 55 characters and has a 440-pixel circular period.
- Reuse the existing 8×7 glyph function with two vertical pixels per glyph row; add only `H`, `U`, and `8` glyph definitions.
- Advance only on a detected `vs` rising edge. Advance one pixel left only after three complete frame boundaries; reset only resets the divider and offset.
- Do not run Tang Dynasty command-line tooling or Git commands. The user performs `syn_1`, `phy_1`, JTAG, Flash, and board tests through the TD GUI.

---

### Task 1: Define ticker behavior with failing OSD assertions

**Files:**
- Modify: `fpga/osd_display/tests/tb_video_osd_overlay.sv`
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`

**Interfaces:**
- Consumes: Existing module ports and internal coordinate registers `dut.x` and `dut.y`.
- Produces: Assertions that require the RTL to expose registers named `ticker_frame_divider` and `ticker_scroll_offset`, both reset by `rst`.

- [x] **Step 1: Add a deterministic frame-boundary driver below `expect_rgb`**

```systemverilog
task automatic drive_frame_boundary;
    begin
        @(negedge video_clk);
        vs = 1'b1;
        @(posedge video_clk);
        #1;
        @(negedge video_clk);
        vs = 1'b0;
        @(posedge video_clk);
        #1;
    end
endtask
```

- [x] **Step 2: Add ticker visual assertions before the existing bottom-status tests**

```systemverilog
// The full subtitle band is opaque, but only lit glyph bits use TICKER_RGB.
force dut.x = 10'd0;
force dut.y = 10'd432;
#1;
expect_rgb(rgb_out, 24'h10213A, "ticker band background");

force dut.x = 10'd9;
force dut.y = 10'd436;
#1;
expect_rgb(rgb_out, 24'hFFD166, "ticker F glyph pixel");

force dut.x = 10'd8;
force dut.y = 10'd436;
#1;
expect_rgb(rgb_out, 24'h10213A, "ticker glyph transparent pixel");

force dut.x = 10'd100;
force dut.y = 10'd431;
#1;
expect_rgb(rgb_out, 24'h123456, "ticker upper boundary remains transparent");

force dut.x = 10'd100;
force dut.y = 10'd456;
#1;
expect_rgb(rgb_out, 24'h10213A, "bottom bar remains above ticker priority");
```

- [x] **Step 3: Add scroll-rate, wrap, and status-independence assertions after the IMAGE assertions**

```systemverilog
expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
           "ticker offset resets to zero");
drive_frame_boundary;
drive_frame_boundary;
expect_rgb({22'd0, dut.ticker_frame_divider}, 24'h000002,
           "ticker waits for third frame");
expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
           "ticker offset holds before third frame");
drive_frame_boundary;
expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000001,
           "ticker advances one pixel on third frame");

storage_ready = 1'b0;
drive_frame_boundary;
drive_frame_boundary;
drive_frame_boundary;
expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000002,
           "wait state does not reset ticker");
storage_ready = 1'b1;

// Use a one-time procedural assignment so the third-frame RTL update is visible.
dut.ticker_scroll_offset = 9'd439;
dut.ticker_frame_divider = 2'd2;
drive_frame_boundary;
expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
           "ticker wraps after the 440-pixel period");
```

- [x] **Step 4: Run the focused simulation to prove the new ticker checks fail**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_osd_overlay.vvp'
iverilog -g2012 -s tb_video_osd_overlay -o $tbOut `
  fpga\osd_display\tests\tb_video_osd_overlay.sv `
  fpga\osd_display\rtl\video\video_osd_overlay.v
vvp $tbOut
```

Expected: compilation fails because `ticker_scroll_offset` and `ticker_frame_divider` do not yet exist, or the first ticker RGB assertion fails because `y=432..455` is still transparent.

### Task 2: Add fixed ticker composition and scrolling state

**Files:**
- Modify: `fpga/osd_display/rtl/video/video_osd_overlay.v`
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`

**Interfaces:**
- Consumes: `video_clk`, `rst`, `vs`, `de`, and the internal pixel coordinates `x`/`y` already generated by `video_osd_overlay`.
- Produces: `ticker_scroll_offset[8:0]`, `ticker_frame_divider[1:0]`, and ticker combinational signals used only inside `video_osd_overlay`.

- [x] **Step 1: Add ticker geometry, colors, and state declarations next to the existing OSD constants and registers**

```verilog
localparam [9:0] TICKER_BAR_Y       = 10'd432;
localparam [9:0] TICKER_BAR_HEIGHT  = 10'd24;
localparam [9:0] TICKER_TEXT_Y      = 10'd436;
localparam [9:0] TICKER_PERIOD_PX   = 10'd440;
localparam [23:0] TICKER_RGB        = 24'hFFD166;

reg [1:0] ticker_frame_divider;
reg [8:0] ticker_scroll_offset;
```

- [x] **Step 2: Add ticker coordinate and glyph wires after the existing title/status wire declarations**

```verilog
wire ticker_active;
wire ticker_text_active;
wire [10:0] ticker_x_sum;
wire [9:0] ticker_period_x;
wire [9:0] ticker_y_offset;
wire [5:0] ticker_char_index;
wire [2:0] ticker_column;
wire [2:0] ticker_row;
wire [7:0] ticker_glyph;
wire ticker_pixel;

assign ticker_active = (y >= TICKER_BAR_Y) &&
                       (y < (TICKER_BAR_Y + TICKER_BAR_HEIGHT));
assign ticker_text_active = (y >= TICKER_TEXT_Y) &&
                            (y < (TICKER_TEXT_Y + 10'd16));
assign ticker_x_sum = {1'b0, x} + {2'b00, ticker_scroll_offset};
assign ticker_period_x = (ticker_x_sum >= 11'd880) ? ticker_x_sum - 11'd880 :
                         (ticker_x_sum >= 11'd440) ? ticker_x_sum - 11'd440 :
                                                       ticker_x_sum[9:0];
assign ticker_y_offset = y - TICKER_TEXT_Y;
assign ticker_char_index = ticker_period_x[8:3];
assign ticker_column = ticker_period_x[2:0];
assign ticker_row = ticker_y_offset[3:1];
assign ticker_glyph = glyph_row(ticker_char(ticker_char_index), ticker_row);
assign ticker_pixel = ticker_text_active && ticker_glyph[7 - ticker_column];
```

- [x] **Step 3: Add the fixed 55-character text lookup before `status_char`**

```verilog
function [7:0] ticker_char;
    input [5:0] char_index;
    begin
        case (char_index)
            6'd0: ticker_char = 8'h20;
            6'd1: ticker_char = 8'h46;
            6'd2: ticker_char = 8'h50;
            6'd3: ticker_char = 8'h47;
            6'd4: ticker_char = 8'h41;
            6'd5: ticker_char = 8'h20;
            6'd6: ticker_char = 8'h48;
            6'd7: ticker_char = 8'h44;
            6'd8: ticker_char = 8'h4D;
            6'd9: ticker_char = 8'h49;
            6'd10: ticker_char = 8'h20;
            6'd11: ticker_char = 8'h4D;
            6'd12: ticker_char = 8'h55;
            6'd13: ticker_char = 8'h4C;
            6'd14: ticker_char = 8'h54;
            6'd15: ticker_char = 8'h49;
            6'd16: ticker_char = 8'h4D;
            6'd17: ticker_char = 8'h45;
            6'd18: ticker_char = 8'h44;
            6'd19: ticker_char = 8'h49;
            6'd20: ticker_char = 8'h41;
            6'd21: ticker_char = 8'h20;
            6'd22: ticker_char = 8'h44;
            6'd23: ticker_char = 8'h49;
            6'd24: ticker_char = 8'h53;
            6'd25: ticker_char = 8'h50;
            6'd26: ticker_char = 8'h4C;
            6'd27: ticker_char = 8'h41;
            6'd28: ticker_char = 8'h59;
            6'd29: ticker_char = 8'h20;
            6'd30: ticker_char = 8'h2F;
            6'd31: ticker_char = 8'h20;
            6'd32: ticker_char = 8'h54;
            6'd33: ticker_char = 8'h46;
            6'd34: ticker_char = 8'h20;
            6'd35: ticker_char = 8'h49;
            6'd36: ticker_char = 8'h4D;
            6'd37: ticker_char = 8'h41;
            6'd38: ticker_char = 8'h47;
            6'd39: ticker_char = 8'h45;
            6'd40: ticker_char = 8'h20;
            6'd41: ticker_char = 8'h2F;
            6'd42: ticker_char = 8'h20;
            6'd43: ticker_char = 8'h34;
            6'd44: ticker_char = 8'h38;
            6'd45: ticker_char = 8'h4B;
            6'd46: ticker_char = 8'h20;
            6'd47: ticker_char = 8'h41;
            6'd48: ticker_char = 8'h55;
            6'd49: ticker_char = 8'h44;
            6'd50: ticker_char = 8'h49;
            6'd51: ticker_char = 8'h4F;
            6'd52: ticker_char = 8'h20;
            6'd53: ticker_char = 8'h2F;
            6'd54: ticker_char = 8'h20;
            default: ticker_char = 8'h20;
        endcase
    end
endfunction
```

Fill the lookup exactly with this indexed sequence so the 440-pixel period and test coordinates remain correct:

```text
0:' '  1:F  2:P  3:G  4:A  5:' '  6:H  7:D  8:M  9:I  10:' '
11:M 12:U 13:L 14:T 15:I 16:M 17:E 18:D 19:I 20:A 21:' '
22:D 23:I 24:S 25:P 26:L 27:A 28:Y 29:' ' 30:/ 31:' ' 32:T
33:F 34:' ' 35:I 36:M 37:A 38:G 39:E 40:' ' 41:/ 42:' ' 43:4
44:8 45:K 46:' ' 47:A 48:U 49:D 50:I 51:O 52:' ' 53:/ 54:' '
```

- [x] **Step 4: Add the three missing 8×7 glyph cases to `glyph_row`**

```verilog
8'h48: case (row) // H
    3'd0: glyph_row = 8'b01000010;
    3'd1: glyph_row = 8'b01000010;
    3'd2: glyph_row = 8'b01000010;
    3'd3: glyph_row = 8'b01111110;
    3'd4: glyph_row = 8'b01000010;
    3'd5: glyph_row = 8'b01000010;
    3'd6: glyph_row = 8'b01000010;
endcase
8'h55: case (row) // U
    3'd0: glyph_row = 8'b01000010;
    3'd1: glyph_row = 8'b01000010;
    3'd2: glyph_row = 8'b01000010;
    3'd3: glyph_row = 8'b01000010;
    3'd4: glyph_row = 8'b01000010;
    3'd5: glyph_row = 8'b01000010;
    3'd6: glyph_row = 8'b00111100;
endcase
8'h38: case (row) // 8
    3'd0: glyph_row = 8'b00111100;
    3'd1: glyph_row = 8'b01000010;
    3'd2: glyph_row = 8'b01000010;
    3'd3: glyph_row = 8'b00111100;
    3'd4: glyph_row = 8'b01000010;
    3'd5: glyph_row = 8'b01000010;
    3'd6: glyph_row = 8'b00111100;
endcase
```

- [x] **Step 5: Extend the existing sequential block with reset and frame-boundary scroll logic**

```verilog
if (rst) begin
    x                    <= 10'd0;
    y                    <= 10'd0;
    de_d                 <= 1'b0;
    vs_d                 <= 1'b0;
    ticker_frame_divider <= 2'd0;
    ticker_scroll_offset <= 9'd0;
end else begin
    de_d <= de;
    vs_d <= vs;

    if (vs && !vs_d) begin
        if (ticker_frame_divider == 2'd2) begin
            ticker_frame_divider <= 2'd0;
            if (ticker_scroll_offset == 9'd439)
                ticker_scroll_offset <= 9'd0;
            else
                ticker_scroll_offset <= ticker_scroll_offset + 9'd1;
        end else begin
            ticker_frame_divider <= ticker_frame_divider + 2'd1;
        end
        x <= 10'd0;
        y <= 10'd0;
    end else if (de) begin
        x <= x + 10'd1;
    end else if (de_d) begin
        x <= 10'd0;
        y <= y + 10'd1;
    end
end
```

- [x] **Step 6: Insert ticker composition between the top and bottom-bar branches**

```verilog
if (y < TOP_BAR_HEIGHT) begin
    rgb_out_r = BAR_RGB;
    if (title_pixel)
        rgb_out_r = TITLE_RGB;
end else if (ticker_active) begin
    rgb_out_r = BAR_RGB;
    if (ticker_pixel)
        rgb_out_r = TICKER_RGB;
end else if (y >= BOTTOM_BAR_Y) begin
    rgb_out_r = BAR_RGB;
    if (indicator_active || status_pixel)
        rgb_out_r = status_rgb;
end
```

- [x] **Step 7: Run the focused simulation and require a clean pass**

Run:

```powershell
$tbOut = Join-Path $env:TEMP 'tb_video_osd_overlay.vvp'
iverilog -g2012 -s tb_video_osd_overlay -o $tbOut `
  fpga\osd_display\tests\tb_video_osd_overlay.sv `
  fpga\osd_display\rtl\video\video_osd_overlay.v
vvp $tbOut
```

Expected: exit code `0` and output containing `PASS tb_video_osd_overlay`.

### Task 3: Inspect the change and perform FPGA integration validation

**Files:**
- Modify: none
- Test: `fpga/osd_display/tests/tb_video_osd_overlay.sv`

**Interfaces:**
- Consumes: passing Icarus unit simulation and the existing TD GUI project.
- Produces: user-observed confirmation that the visual-only OSD addition preserves the proven playback paths.

- [x] **Step 1: Check only the intended RTL and test for syntax/whitespace defects**

Run:

```powershell
rg -n "[ \t]+$" fpga\osd_display\rtl\video\video_osd_overlay.v `
  fpga\osd_display\tests\tb_video_osd_overlay.sv
```

Expected: no output. Do not stage, commit, reset, clean, or otherwise alter the dirty worktree.

- [ ] **Step 2: Ask the user to run TD GUI `syn_1` and `phy_1`**

Expected: both GUI stages complete successfully. Record resource and timing figures exactly as reported; do not claim timing closure when setup slack remains negative.

- [ ] **Step 3: Ask the user to JTAG-download and board-test the feature**

Test checklist:

```text
1. The 24-pixel subtitle band is visible from power-up and scrolls smoothly left.
2. KEY2 single and rapid image switching remains normal.
3. KEY4 automatic image cycling remains normal.
4. HDMI audio plays continuously and loops normally.
5. TF removal shows WAIT TF and preserves the scrolling subtitle.
6. TF reinsertion recovers image/audio automatically and the subtitle never resets or freezes.
```

Expected: all six checks pass before considering Flash programming. If a check fails, preserve the reported OSD text/state and return to the smallest relevant RTL/test assertion; do not modify SDRAM, TF, audio, or timing RTL as part of ticker debugging.
