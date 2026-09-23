`timescale 1ns/1ps

// Peak envelope for the on-screen audio meter.  Samples are already in the
// video clock domain, so this block adds no clock crossing or audio latency.
module audio_visualizer #(
    parameter integer DECAY_PER_SAMPLE = 1
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       sample_valid,
    input  wire [23:0] left_sample,
    input  wire [23:0] right_sample,
    output reg  [7:0] level
);
    wire signed [15:0] left_s  = left_sample[23:8];
    wire signed [15:0] right_s = right_sample[23:8];
    wire [15:0] left_abs  = left_s[15]  ? (~left_s + 16'd1)  : left_s;
    wire [15:0] right_abs = right_s[15] ? (~right_s + 16'd1) : right_s;
    wire [15:0] peak = (left_abs >= right_abs) ? left_abs : right_abs;
    wire [7:0] sample_level = (peak[15:8] == 8'h00 && peak != 16'd0) ?
                               8'd1 : peak[15:8];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            level <= 8'd0;
        end else if (sample_valid) begin
            if (sample_level > level)
                level <= sample_level;
            else if (level > DECAY_PER_SAMPLE[7:0])
                level <= level - DECAY_PER_SAMPLE[7:0];
            else
                level <= 8'd0;
        end
    end
endmodule
