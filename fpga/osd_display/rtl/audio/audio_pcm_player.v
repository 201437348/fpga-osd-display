`timescale 1ns/1ps

module audio_pcm_player #(
    parameter integer CLK_FREQ_HZ       = 25_000_000,
    parameter integer SAMPLE_RATE_HZ    = 48_000,
    parameter [9:0]  PREFILL_FRAMES     = 10'd512
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire        fifo_empty,
    input  wire        fifo_valid,
    input  wire [9:0]  fifo_rdusedw,
    input  wire [31:0] fifo_dout,
    output reg         fifo_re,
    output reg         audio_valid,
    output reg [23:0]  audio_left_data,
    output reg [23:0]  audio_right_data
);

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
                audio_left_data  <= {fifo_dout[31:16], 8'd0};
                audio_right_data <= {fifo_dout[15:0], 8'd0};
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
