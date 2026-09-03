module video_fallback_pattern(
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    output reg [23:0] rgb
);

reg [9:0] x;
reg [9:0] y;
reg       de_d;
reg       vs_d;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x    <= 10'd0;
        y    <= 10'd0;
        de_d <= 1'b0;
        vs_d <= 1'b0;
        rgb  <= 24'd0;
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

        if (!de) begin
            rgb <= 24'd0;
        end else begin
            case (x[9:7])
                3'd0: rgb <= 24'hFF0000;
                3'd1: rgb <= 24'hFFFF00;
                3'd2: rgb <= 24'h00FF00;
                3'd3: rgb <= 24'h00FFFF;
                3'd4: rgb <= 24'h0000FF;
                3'd5: rgb <= 24'hFF00FF;
                3'd6: rgb <= 24'hFFFFFF;
                default: rgb <= 24'h202020;
            endcase
        end
    end
end

endmodule
