`timescale 1ns/1ps

module tb_video_transition_blender;

reg video_clk = 1'b0;
reg rst = 1'b0;
reg vs = 1'b0;
reg de = 1'b1;
reg [23:0] rgb_in = 24'hE02010;
reg transition_active = 1'b0;
reg [6:0] fade_level = 7'd0;
reg [6:0] sweep_position = 7'd0;
wire [23:0] rgb_out;

always #5 video_clk = ~video_clk;

video_transition_blender dut (
    .video_clk        (video_clk),
    .rst              (rst),
    .vs               (vs),
    .de               (de),
    .rgb_in           (rgb_in),
    .transition_active(transition_active),
    .fade_level       (fade_level),
    .sweep_position   (sweep_position),
    .rgb_out          (rgb_out)
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
    #1;
    expect_rgb(rgb_out, 24'hE02010, "inactive effect is exact bypass");

    transition_active = 1'b1;
    fade_level = 7'd0;
    #1;
    expect_rgb(rgb_out, 24'hE02010, "zero fade is exact source");

    fade_level = 7'd32;
    #1;
    expect_rgb(rgb_out, 24'hEF8A73, "half fade moves toward warm white");

    fade_level = 7'd64;
    #1;
    expect_rgb(rgb_out, 24'hFFF4D6, "full cover is exact warm white");

    fade_level = 7'd32;
    sweep_position = 7'd20;
    force dut.x = 10'd210;
    force dut.y = 10'd160;
    #1;
    expect_rgb(rgb_out, 24'hF39B70, "outer band moves one quarter toward gold");

    force dut.x = 10'd200;
    #1;
    expect_rgb(rgb_out, 24'hF7AD6D, "core band moves one half toward gold");

    force dut.x = 10'd0;
    force dut.y = 10'd470;
    #1;
    expect_rgb(rgb_out, 24'hEF8A73, "status area receives no gold accent");

    transition_active = 1'b0;
    fade_level = 7'd64;
    #1;
    expect_rgb(rgb_out, 24'hE02010, "inactive full-level state still bypasses");

    release dut.x;
    release dut.y;
    $display("PASS tb_video_transition_blender");
    $finish;
end

endmodule
