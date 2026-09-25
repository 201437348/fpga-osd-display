`timescale 1ns/1ps

module audio_pcm_player #(
    parameter integer CLK_FREQ_HZ       = 25_000_000,
    parameter integer SAMPLE_RATE_HZ    = 48_000,
    parameter [9:0]  PREFILL_FRAMES     = 10'd512
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire [3:0]  volume,       // 0 = 静音，1..8 每档 6 dB，8 = 原音量
    input  wire        fifo_empty,
    input  wire        fifo_valid,
    input  wire [9:0]  fifo_rdusedw,
    input  wire [31:0] fifo_dout,
    output reg         fifo_re,
    output reg         audio_valid,
    output reg [23:0]  audio_left_data,
    output reg [23:0]  audio_right_data
);

// 音量：算术右移 (8 - volume) 位。volume 来自 sd_card_clk 域，变化极慢；
// 连续两拍采到同一个值才采用，避开多位总线跨域时的中间值。
reg [3:0] volume_s0;
reg [3:0] volume_s1;
reg [3:0] volume_q;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        volume_s0 <= 4'd8;
        volume_s1 <= 4'd8;
        volume_q  <= 4'd8;
    end else begin
        volume_s0 <= volume;
        volume_s1 <= volume_s0;
        if (volume_s0 == volume_s1)
            volume_q <= volume_s1;
    end
end

function [15:0] apply_volume;
    input [15:0] x;
    input [3:0]  v;
    begin
        case (v)
            4'd0:    apply_volume = 16'd0;
            4'd1:    apply_volume = {{7{x[15]}}, x[15:7]};
            4'd2:    apply_volume = {{6{x[15]}}, x[15:6]};
            4'd3:    apply_volume = {{5{x[15]}}, x[15:5]};
            4'd4:    apply_volume = {{4{x[15]}}, x[15:4]};
            4'd5:    apply_volume = {{3{x[15]}}, x[15:3]};
            4'd6:    apply_volume = {{2{x[15]}}, x[15:2]};
            4'd7:    apply_volume = {x[15], x[15:1]};
            default: apply_volume = x;
        endcase
    end
endfunction

reg [31:0] sample_phase;
reg        playback_active;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_phase     <= 32'd0;
        playback_active  <= 1'b0;
        fifo_re          <= 1'b0;
        audio_valid      <= 1'b0;
        audio_left_data  <= 24'd0;
        audio_right_data <= 24'd0;
    end else begin
        fifo_re     <= 1'b0;
        audio_valid <= 1'b0;

        if (sample_phase >= (CLK_FREQ_HZ - SAMPLE_RATE_HZ)) begin
            sample_phase <= sample_phase + SAMPLE_RATE_HZ - CLK_FREQ_HZ;
            audio_valid  <= 1'b1;

            if (!enable) begin
                playback_active  <= 1'b0;
                audio_left_data  <= 24'd0;
                audio_right_data <= 24'd0;
            end else if (!playback_active) begin
                if (fifo_valid && (fifo_rdusedw >= PREFILL_FRAMES))
                    playback_active <= 1'b1;
                audio_left_data  <= 24'd0;
                audio_right_data <= 24'd0;
            end else if (!fifo_empty && fifo_valid) begin
                fifo_re          <= 1'b1;
                // HDMI/I2S PCM samples are left-justified in the 24-bit
                // interface. Scale the 16-bit media sample to that format by
                // appending eight zero LSBs; sign extension would attenuate
                // the signal by 48 dB.
                audio_left_data  <= {apply_volume(fifo_dout[31:16], volume_q), 8'd0};
                audio_right_data <= {apply_volume(fifo_dout[15:0], volume_q), 8'd0};
            end else begin
                playback_active  <= 1'b0;
                audio_left_data  <= 24'd0;
                audio_right_data <= 24'd0;
            end
        end else begin
            sample_phase <= sample_phase + SAMPLE_RATE_HZ;
        end
    end
end

endmodule
