`timescale 1ns/1ps

module video_slide_diagnostic_pattern (
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire [9:0]  slide_position,
    output reg  [23:0] rgb
);

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        rgb <= 24'd0;
    end else begin
        if (!de) begin
            rgb <= 24'd0;
        end else begin
            rgb <= {
                slide_position[7:0],
                ~slide_position[7:0],
                slide_position[6:0], 1'b0
            };
        end
    end
end

endmodule
