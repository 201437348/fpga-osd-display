`timescale 1ns/1ps

module tb_video_osd_overlay;

reg video_clk = 1'b0;
reg rst = 1'b1;
reg vs = 1'b0;
reg de = 1'b0;
reg [23:0] rgb_in = 24'h123456;
reg display_valid = 1'b0;
reg display_test_pattern = 1'b0;
reg [1:0] display_buffer_index = 2'd0;
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
    .display_buffer_index(display_buffer_index),
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

    // Bottom status follows only the video-domain display state.
    display_valid = 1'b0;
    display_test_pattern = 1'b0;
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

    display_test_pattern = 1'b0;
    display_valid = 1'b1;
    display_buffer_index = 2'd0;
    force dut.x = 10'd82;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image buffer zero digit");

    display_buffer_index = 2'd1;
    force dut.x = 10'd83;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image buffer one digit");

    release dut.x;
    release dut.y;
    $display("PASS tb_video_osd_overlay");
    $finish;
end

endmodule
