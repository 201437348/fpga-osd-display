`timescale 1ns/1ps

module tb_video_rgb_to_axis_line_boundary;

reg         clk = 1'b0;
reg         rst = 1'b1;
reg         vs = 1'b0;
reg         de = 1'b0;
reg  [23:0] rgb = 24'd0;
reg         axis_ready = 1'b1;
reg         marker_enable = 1'b0;
wire        axis_user;
wire        axis_valid;
wire        axis_last;
wire [23:0] axis_data;
wire [3:0]  backpressure_count;

integer observed_line = 0;
integer observed_x = 0;
integer valid_count = 0;
integer user_count = 0;
integer last_count = 0;

always #5 clk = ~clk;

video_rgb_to_axis_640x480 dut (
    .I_clk         (clk),
    .I_rst         (rst),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (rgb),
    .I_video_ready (axis_ready),
    .I_marker_enable(marker_enable),
    .O_video_user  (axis_user),
    .O_video_valid (axis_valid),
    .O_video_last  (axis_last),
    .O_video_data  (axis_data),
    .O_backpressure_count(backpressure_count)
);

function automatic [23:0] marker(input integer line, input integer x);
    reg [7:0] sum;
    begin
        sum = line + x;
        marker = {line[7:0], x[7:0], sum};
    end
endfunction

task automatic drive_line(
    input integer line,
    input integer stall_start,
    input integer stall_length,
    input integer enable_marker
);
    integer x;
    begin
        @(negedge clk);
        de = 1'b1;
        marker_enable = enable_marker;
        for (x = 0; x < 640; x = x + 1) begin
            rgb = marker(line, x);
            axis_ready = !((x >= stall_start) &&
                           (x < (stall_start + stall_length)));
            @(negedge clk);
        end
        de = 1'b0;
        rgb = 24'd0;
        axis_ready = 1'b1;
        marker_enable = 1'b0;
    end
endtask

always @(posedge clk) begin
    #1;
    if (axis_valid) begin
        if (axis_data !== (((observed_line != 0) &&
                            (observed_x < 16)) ?
                           24'hFFFFFF :
                           marker(observed_line, observed_x)))
            $fatal(1, "FAIL line %0d x=%0d expected %h got %h",
                   observed_line, observed_x,
                   ((observed_line != 0) && (observed_x < 16)) ?
                   24'hFFFFFF : marker(observed_line, observed_x),
                   axis_data);

        if (axis_user !== ((observed_line == 0) && (observed_x == 0)))
            $fatal(1, "FAIL SOF line %0d x=%0d user=%b",
                   observed_line, observed_x, axis_user);

        if (axis_last !== (observed_x == 639))
            $fatal(1, "FAIL TLAST line %0d x=%0d last=%b",
                   observed_line, observed_x, axis_last);

        valid_count = valid_count + 1;
        if (axis_user)
            user_count = user_count + 1;
        if (axis_last)
            last_count = last_count + 1;

        if (observed_x == 639) begin
            observed_x = 0;
            observed_line = observed_line + 1;
        end else begin
            observed_x = observed_x + 1;
        end
    end
end

initial begin
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (3) @(negedge clk);

    drive_line(0, 0, 0, 0);
    repeat (2) @(negedge clk);
    if (backpressure_count !== 4'd0)
        $fatal(1, "FAIL ready-high line counted %0d stalls",
               backpressure_count);
    repeat (8) @(negedge clk);
    drive_line(1, 100, 3, 1);
    repeat (2) @(negedge clk);
    if (backpressure_count !== 4'd3)
        $fatal(1, "FAIL expected 3 stalls got %0d", backpressure_count);
    repeat (8) @(negedge clk);
    drive_line(2, 200, 20, 1);
    repeat (4) @(negedge clk);

    if (backpressure_count !== 4'hF)
        $fatal(1, "FAIL expected saturated stall count F got %0h",
               backpressure_count);
    if (valid_count != 1920)
        $fatal(1, "FAIL expected 1920 valid pixels got %0d", valid_count);
    if (user_count != 1)
        $fatal(1, "FAIL expected one SOF got %0d", user_count);
    if (last_count != 3)
        $fatal(1, "FAIL expected three TLAST pulses got %0d", last_count);

    $display("PASS tb_video_rgb_to_axis_line_boundary");
    $finish;
end

initial begin
    #50000;
    $fatal(1, "FAIL timeout line=%0d x=%0d", observed_line, observed_x);
end

endmodule
