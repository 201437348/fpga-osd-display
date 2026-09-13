`timescale 1ns/1ps

module tb_video_slide_diagnostic_pattern;

reg video_clk = 1'b0;
reg rst = 1'b1;
reg vs = 1'b0;
reg de = 1'b0;
reg [9:0] slide_position = 10'd2;
wire [23:0] rgb;

always #5 video_clk = ~video_clk;

video_slide_diagnostic_pattern dut (
    .video_clk      (video_clk),
    .rst            (rst),
    .vs             (vs),
    .de             (de),
    .slide_position (slide_position),
    .rgb            (rgb)
);

function automatic [23:0] expected_rgb;
    input integer position;
    begin
        expected_rgb = {
            position[7:0],
            ~position[7:0],
            position[6:0], 1'b0
        };
    end
endfunction

task automatic check_active_pixel;
    input integer x;
    input integer y;
    input integer position;
    begin
        @(negedge video_clk);
        de = 1'b1;
        @(posedge video_clk);
        #1;
        if (rgb !== expected_rgb(position))
            $fatal(1, "FAIL position=%0d row=%0d x=%0d expected=%h got=%h",
                   position, y, x, expected_rgb(position), rgb);
    end
endtask

task automatic end_line;
    begin
        @(negedge video_clk);
        de = 1'b0;
        @(posedge video_clk);
        #1;
        if (rgb !== 24'd0)
            $fatal(1, "FAIL blanking pixel expected black got=%h", rgb);
    end
endtask

initial begin
    repeat (3) @(posedge video_clk);
    rst = 1'b0;

    check_active_pixel(0, 0, 2);
    check_active_pixel(1, 0, 2);
    check_active_pixel(2, 0, 2);
    check_active_pixel(3, 0, 2);
    end_line;

    check_active_pixel(0, 1, 2);
    check_active_pixel(1, 1, 2);
    check_active_pixel(2, 1, 2);
    end_line;

    slide_position = 10'd35;
    check_active_pixel(0, 2, 35);
    check_active_pixel(1, 2, 35);
    check_active_pixel(2, 2, 35);
    end_line;

    $display("PASS tb_video_slide_diagnostic_pattern");
    $finish;
end

endmodule
