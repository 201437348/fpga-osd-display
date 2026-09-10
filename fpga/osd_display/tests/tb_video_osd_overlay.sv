`timescale 1ns/1ps

module tb_video_osd_overlay;

reg video_clk = 1'b0;
reg rst = 1'b1;
reg vs = 1'b0;
reg de = 1'b0;
reg [23:0] rgb_in = 24'h123456;
reg display_valid = 1'b0;
reg display_test_pattern = 1'b0;
reg storage_ready = 1'b0;
reg [2:0] manager_state = 3'd0;
reg load_in_progress = 1'b0;
reg [1:0] target_image_index = 2'd0;
reg [1:0] current_image_index = 2'd0;
reg [2:0] image_count = 3'd0;
wire [23:0] rgb_out;

always #5 video_clk = ~video_clk;

video_osd_overlay dut (
    .video_clk           (video_clk),
    .rst                 (rst),
    .vs                  (vs),
    .de                  (de),
    .rgb_in              (rgb_in),
    .display_valid       (display_valid),
    .display_test_pattern(display_test_pattern),
    .storage_ready       (storage_ready),
    .manager_state       (manager_state),
    .load_in_progress    (load_in_progress),
    .target_image_index  (target_image_index),
    .current_image_index (current_image_index),
    .image_count         (image_count),
    .rgb_out             (rgb_out)
);

task automatic expect_rgb;
    input [23:0] actual;
    input [23:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint, expected, actual);
    end
endtask

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

initial begin
    repeat (2) @(posedge video_clk);
    rst = 1'b0;
    #1;

    // Blank pixels and picture-area pixels are transparent to the overlay.
    de = 1'b0;
    force dut.x = 10'd100;
    force dut.y = 10'd100;
    #1;
    expect_rgb(rgb_out, 24'h123456, "blanking remains transparent");

    de = 1'b1;
    #1;
    expect_rgb(rgb_out, 24'h123456, "picture area remains transparent");

    // A top-bar background pixel and an enabled title-font pixel are opaque.
    force dut.x = 10'd10;
    force dut.y = 10'd10;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "top bar background");
    force dut.x = 10'd18;
    force dut.y = 10'd4;
    #1;
    expect_rgb(rgb_out, 24'hF4F7FB, "title glyph pixel");

    // The ticker band is opaque, but only lit glyph bits use the ticker color.
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

    // Fallback has highest priority, then absent storage.
    display_valid = 1'b0;
    display_test_pattern = 1'b0;
    storage_ready = 1'b0;
    force dut.x = 10'd25;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hFF6B6B, "wait status text");
    force dut.x = 10'd8;
    force dut.y = 10'd464;
    #1;
    expect_rgb(rgb_out, 24'hFF6B6B, "wait status indicator");

    display_test_pattern = 1'b1;
    force dut.x = 10'd25;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "fallback status text");

    // SCAN covers an active manager scan.
    display_test_pattern = 1'b0;
    storage_ready = 1'b1;
    manager_state = 3'd1;
    display_valid = 1'b1;
    force dut.x = 10'd26;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hA7C7FF, "scan status text");
    force dut.x = 10'd49;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hA7C7FF, "scan N glyph");

    // LOAD shows the target image number, rather than the buffer number.
    manager_state = 3'd0;
    load_in_progress = 1'b1;
    target_image_index = 2'd1;
    image_count = 3'd4;
    force dut.x = 10'd66;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h7EE787, "load target digit");
    force dut.x = 10'd78;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h7EE787, "load slash glyph");

    // IMAGE reports the committed image and the scanned image count.
    load_in_progress = 1'b0;
    current_image_index = 2'd3;
    force dut.x = 10'd77;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image four digit");
    force dut.x = 10'd86;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image slash glyph");
    force dut.x = 10'd93;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image count digit");

    // The ticker moves only once for every three complete frame boundaries.
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

    dut.ticker_scroll_offset = 9'd439;
    dut.ticker_frame_divider = 2'd2;
    drive_frame_boundary;
    expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
               "ticker wraps after the 440-pixel period");

    // Image ownership changes are now handled before this OSD stage.  The
    // overlay must leave picture-area RGB untouched rather than injecting the
    // rejected black slide mask.
    current_image_index = 2'd3;
    @(posedge video_clk);
    current_image_index = 2'd0;
    @(posedge video_clk);
    force dut.x = 10'd100;
    force dut.y = 10'd100;
    #1;
    expect_rgb(rgb_out, 24'h123456, "image change leaves picture transparent");

    force dut.x = 10'd100;
    force dut.y = 10'd436;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "ticker remains stable after image change");
    force dut.x = 10'd8;
    force dut.y = 10'd464;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "status bar remains stable after image change");

    release dut.x;
    release dut.y;
    $display("PASS tb_video_osd_overlay");
    $finish;
end

endmodule
