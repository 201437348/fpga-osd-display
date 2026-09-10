`timescale 1ns/1ps

module hdmi_audio_acr #(
    parameter [19:0] ACR_N = 20'd6144,
    parameter [7:0]  AUDIO_DIV = 8'd48
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        audio_valid,
    output reg         acr_valid,
    output reg [19:0]  acr_cts,
    output reg [19:0]  acr_n
);

reg [7:0]  audio_sample_count;
reg [19:0] cts_count;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        audio_sample_count <= 8'd0;
        cts_count          <= 20'd0;
        acr_valid          <= 1'b0;
        acr_cts            <= 20'd0;
        acr_n              <= 20'd0;
    end else begin
        acr_valid <= 1'b0;
        acr_cts   <= 20'd0;
        acr_n     <= 20'd0;
        cts_count <= cts_count + 20'd1;

        if (audio_valid) begin
            if (audio_sample_count == (AUDIO_DIV - 8'd1)) begin
                audio_sample_count <= 8'd0;
                acr_valid          <= 1'b1;
                acr_cts            <= cts_count + 20'd1;
                acr_n              <= ACR_N;
                cts_count          <= 20'd0;
            end else begin
                audio_sample_count <= audio_sample_count + 8'd1;
            end
        end
    end
end

endmodule
