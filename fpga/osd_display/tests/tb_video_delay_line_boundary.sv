`timescale 1ns/1ps

module tb_video_delay_line_boundary;

reg         clk = 1'b0;
reg         rst = 1'b1;
reg         fifo_we = 1'b0;
reg  [31:0] fifo_di = 32'd0;
reg         de_in = 1'b0;
wire        fifo_re;
wire [31:0] fifo_dout;
wire        fifo_valid;
wire        de_out;
wire [23:0] rgb_out;

reg [23:0] expected [0:7];
reg [23:0] observed [0:7];
integer observed_count = 0;
integer i;

always #5 clk = ~clk;

rfifo_32_32_512 #(
    .SHOW_AHEAD_EN (1'b0),
    .OUTREG_EN     ("OUTREG")
) fifo (
    .clkr       (clk),
    .clkw       (clk),
    .rst        (rst),
    .we         (fifo_we),
    .re         (fifo_re),
    .di         (fifo_di),
    .empty_flag (),
    .full_flag  (),
    .afull      (),
    .aempty     (),
    .wrusedw    (),
    .rdusedw    (),
    .valid      (fifo_valid),
    .dout       (fifo_dout)
);

video_delay delay (
    .video_clk (clk),
    .rst       (rst),
    .read_en   (fifo_re),
    .read_data (fifo_dout[31:8]),
    .read_data_valid (fifo_valid),
    .hs        (1'b0),
    .vs        (1'b0),
    .de        (de_in),
    .hs_r      (),
    .vs_r      (),
    .de_r      (de_out),
    .vout_data (rgb_out)
);

task automatic push_pixel(input [23:0] rgb);
    begin
        @(negedge clk);
        fifo_di = {rgb, 8'h00};
        fifo_we = 1'b1;
        @(negedge clk);
        fifo_we = 1'b0;
    end
endtask

task automatic drive_line(input integer width);
    integer x;
    begin
        @(negedge clk);
        de_in = 1'b1;
        for (x = 0; x < width; x = x + 1)
            @(negedge clk);
        de_in = 1'b0;
    end
endtask

always @(posedge clk) begin
    #1;
    if (de_out) begin
        if (observed_count >= 8)
            $fatal(1, "FAIL extra delayed active pixel %h", rgb_out);
        observed[observed_count] = rgb_out;
        observed_count = observed_count + 1;
    end
end

initial begin
    expected[0] = 24'h110001;
    expected[1] = 24'h110002;
    expected[2] = 24'h110003;
    expected[3] = 24'hAA00F1;
    expected[4] = 24'h22B001;
    expected[5] = 24'h22B002;
    expected[6] = 24'h22B003;
    expected[7] = 24'h00CCF2;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (4) @(negedge clk);

    for (i = 0; i < 8; i = i + 1)
        push_pixel(expected[i]);

    repeat (4) @(negedge clk);
    drive_line(4);
    repeat (5) @(negedge clk);
    drive_line(4);

    wait (observed_count == 8);
    repeat (3) @(negedge clk);

    if (delay.align_underflow !== 1'b0)
        $fatal(1, "FAIL alignment queue underflowed");
    if (delay.align_overflow !== 1'b0)
        $fatal(1, "FAIL alignment queue overflowed");
    if (delay.align_count !== 3'd0)
        $fatal(1, "FAIL alignment queue retained %0d pixels", delay.align_count);

    for (i = 0; i < 8; i = i + 1) begin
        if (observed[i] !== expected[i]) begin
            if ((i == 4) && (observed[i] === expected[3]))
                $fatal(1, "FAIL row2 x=0 contains previous-row final pixel");
            if ((i == 4) && (observed[i] === expected[5]))
                $fatal(1, "FAIL row2 x=0 skipped current-row first pixel");
            $fatal(1, "FAIL pixel %0d expected %h got %h",
                   i, expected[i], observed[i]);
        end
    end

    $display("PASS tb_video_delay_line_boundary");
    $finish;
end

initial begin
    #10000;
    $fatal(1, "FAIL timeout observed_count=%0d", observed_count);
end

endmodule
