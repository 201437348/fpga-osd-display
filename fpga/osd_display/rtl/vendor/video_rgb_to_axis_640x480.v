
module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,
    input  wire        I_video_ready,
    input  wire        I_marker_enable,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data,
    output reg  [3:0]  O_backpressure_count
);

reg        S_vs_1d;
reg        S_de_1d;
reg        S_frame_arm;
reg [10:0] S_x_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
        O_backpressure_count <= 4'd0;
    end
    else begin
        if (O_video_valid && !I_video_ready &&
            (O_backpressure_count != 4'hF))
            O_backpressure_count <= O_backpressure_count + 4'd1;

        S_vs_1d <= I_vs;
        S_de_1d <= I_de;

        O_video_user  <= 1'b0;
        O_video_valid <= I_de;
        O_video_last  <= 1'b0;
        O_video_data  <= I_rgb;

        if (I_de && I_marker_enable &&
            ((!S_de_1d) || (S_x_cnt < 11'd16)))
            O_video_data <= 24'hFFFFFF;

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin
                // 一行首像素
                // Pixel zero transfers now; track the next active index so
                // the final pixel observes 639 and asserts TLAST.
                S_x_cnt <= 11'd1;
                if (S_frame_arm) begin
                    O_video_user <= 1'b1;
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

            // 640x480 最后一个有效像素
            if (S_x_cnt == 11'd639)
                O_video_last <= 1'b1;
        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule
