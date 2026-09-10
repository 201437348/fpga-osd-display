`ifndef VIDEO_TRANSITION_BLENDER_V
`define VIDEO_TRANSITION_BLENDER_V
`timescale 1ns/1ps

// Single-frame warm-white cover with a warm-gold diagonal accent.
module video_transition_blender (
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        transition_active,
    input  wire [6:0]  fade_level,
    input  wire [6:0]  sweep_position,
    output wire [23:0] rgb_out
);

localparam [23:0] WARM_WHITE = 24'hFFF4D6;
localparam [23:0] GOLD       = 24'hFFD166;

reg [9:0] x;
reg [9:0] y;
reg       de_d;
reg       vs_d;

wire [6:0]  fade_clamped;
wire [10:0] diagonal_position;
wire [10:0] band_center;
wire [10:0] band_distance;
wire        accent_region;
wire        accent_core;
wire [7:0]  faded_r;
wire [7:0]  faded_g;
wire [7:0]  faded_b;
wire [7:0]  accented_r;
wire [7:0]  accented_g;
wire [7:0]  accented_b;

function [7:0] interpolate_channel;
    input [7:0] source;
    input [7:0] target;
    input [6:0] amount;
    reg [7:0]  difference;
    reg [14:0] scaled_difference;
    reg [7:0]  adjustment;
    begin
        if (target >= source) begin
            difference        = target - source;
            scaled_difference = difference * amount;
            adjustment        = scaled_difference[13:6];
            interpolate_channel = source + adjustment;
        end else begin
            difference        = source - target;
            scaled_difference = difference * amount;
            adjustment        = scaled_difference[13:6];
            interpolate_channel = source - adjustment;
        end
    end
endfunction

function [7:0] accent_channel;
    input [7:0] source;
    input [7:0] target;
    input       half_strength;
    reg [7:0] difference;
    reg [7:0] adjustment;
    begin
        if (target >= source) begin
            difference = target - source;
            adjustment = half_strength ? (difference >> 1) : (difference >> 2);
            accent_channel = source + adjustment;
        end else begin
            difference = source - target;
            adjustment = half_strength ? (difference >> 1) : (difference >> 2);
            accent_channel = source - adjustment;
        end
    end
endfunction

assign fade_clamped = (fade_level > 7'd64) ? 7'd64 : fade_level;
assign faded_r = interpolate_channel(rgb_in[23:16], WARM_WHITE[23:16], fade_clamped);
assign faded_g = interpolate_channel(rgb_in[15:8],  WARM_WHITE[15:8],  fade_clamped);
assign faded_b = interpolate_channel(rgb_in[7:0],   WARM_WHITE[7:0],   fade_clamped);

assign diagonal_position = {1'b0, x} + {1'b0, y};
assign band_center = ({4'd0, sweep_position} << 4) +
                     ({4'd0, sweep_position} << 1);
assign band_distance = (diagonal_position >= band_center) ?
                       (diagonal_position - band_center) :
                       (band_center - diagonal_position);
assign accent_region = transition_active && de &&
                       (sweep_position > 7'd0) &&
                       (sweep_position < 7'd64) &&
                       (y >= 10'd24) && (y < 10'd432) &&
                       (band_distance < 11'd20);
assign accent_core = band_distance < 11'd8;

assign accented_r = accent_channel(faded_r, GOLD[23:16], accent_core);
assign accented_g = accent_channel(faded_g, GOLD[15:8],  accent_core);
assign accented_b = accent_channel(faded_b, GOLD[7:0],   accent_core);

assign rgb_out = !transition_active ? rgb_in :
                 accent_region ? {accented_r, accented_g, accented_b} :
                                 {faded_r, faded_g, faded_b};

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x    <= 10'd0;
        y    <= 10'd0;
        de_d <= 1'b0;
        vs_d <= 1'b0;
    end else begin
        de_d <= de;
        vs_d <= vs;

        if (vs && !vs_d) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (de) begin
            x <= x + 10'd1;
        end else if (de_d) begin
            x <= 10'd0;
            y <= y + 10'd1;
        end
    end
end

endmodule
`endif
