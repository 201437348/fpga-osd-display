`timescale 1ns/1ps

module tb_video_transition_controller;

reg video_clk = 1'b0;
reg rst = 1'b1;
reg video_read_req = 1'b0;
reg display_valid = 1'b0;
reg [1:0] committed_buffer_index = 2'd0;
reg read_fault = 1'b0;
wire [1:0] active_buffer_index;
wire [1:0] slide_old_buffer_index;
wire [1:0] slide_new_buffer_index;
wire slide_active;
wire transition_busy;
wire [9:0] slide_position;
reg [9:0] expected_position [0:28];
integer step;

always #5 video_clk = ~video_clk;

video_transition_controller dut (
    .video_clk               (video_clk),
    .rst                     (rst),
    .video_read_req          (video_read_req),
    .display_valid           (display_valid),
    .committed_buffer_index  (committed_buffer_index),
    .read_fault              (read_fault),
    .active_buffer_index     (active_buffer_index),
    .slide_old_buffer_index  (slide_old_buffer_index),
    .slide_new_buffer_index  (slide_new_buffer_index),
    .slide_active            (slide_active),
    .transition_busy         (transition_busy),
    .slide_position          (slide_position)
);

task automatic expect_bit;
    input actual;
    input expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %b, got %b", checkpoint, expected, actual);
    end
endtask

task automatic expect_index;
    input [1:0] actual;
    input [1:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic expect_position;
    input [9:0] actual;
    input [9:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic pulse_read_request;
    begin
        @(negedge video_clk);
        video_read_req = 1'b1;
        @(posedge video_clk);
        #1;
        @(negedge video_clk);
        video_read_req = 1'b0;
        @(posedge video_clk);
        #1;
    end
endtask

initial begin
    expected_position[0]  = 10'd0;
    expected_position[1]  = 10'd2;
    expected_position[2]  = 10'd9;
    expected_position[3]  = 10'd20;
    expected_position[4]  = 10'd35;
    expected_position[5]  = 10'd54;
    expected_position[6]  = 10'd76;
    expected_position[7]  = 10'd100;
    expected_position[8]  = 10'd127;
    expected_position[9]  = 10'd156;
    expected_position[10] = 10'd187;
    expected_position[11] = 10'd219;
    expected_position[12] = 10'd252;
    expected_position[13] = 10'd286;
    expected_position[14] = 10'd320;
    expected_position[15] = 10'd354;
    expected_position[16] = 10'd388;
    expected_position[17] = 10'd421;
    expected_position[18] = 10'd453;
    expected_position[19] = 10'd484;
    expected_position[20] = 10'd513;
    expected_position[21] = 10'd540;
    expected_position[22] = 10'd564;
    expected_position[23] = 10'd586;
    expected_position[24] = 10'd605;
    expected_position[25] = 10'd620;
    expected_position[26] = 10'd631;
    expected_position[27] = 10'd640;
    expected_position[28] = 10'd640;

    repeat (2) @(posedge video_clk);
    rst = 1'b0;
    display_valid = 1'b1;

    pulse_read_request;
    expect_bit(slide_active, 1'b0, "first image is direct");
    expect_bit(transition_busy, 1'b0, "first image is not busy");
    expect_index(active_buffer_index, 2'd0, "first active buffer");
    expect_position(slide_position, 10'd0, "first image position");

    committed_buffer_index = 2'd1;
    @(posedge video_clk);
    #1;
    expect_bit(slide_active, 1'b0, "commit waits for frame request");

    pulse_read_request;
    expect_bit(slide_active, 1'b1, "slide starts at frame boundary");
    expect_bit(transition_busy, 1'b1, "slide reserves both buffers");
    expect_index(slide_old_buffer_index, 2'd0, "slide locks old buffer");
    expect_index(slide_new_buffer_index, 2'd1, "slide locks new buffer");
    expect_position(slide_position, 10'd0, "slide begins at zero");
    expect_index(active_buffer_index, 2'd0, "old buffer remains active");

    for (step = 1; step <= 28; step = step + 1) begin
        pulse_read_request;
        expect_position(slide_position, expected_position[step],
                        "exact smoothstep position");
        if (step == 27) begin
            expect_bit(slide_active, 1'b1, "full endpoint remains active");
            expect_bit(transition_busy, 1'b1, "full endpoint keeps reservation");
            expect_index(active_buffer_index, 2'd0,
                         "full endpoint precedes ownership commit");
        end
    end
    expect_position(slide_position, 10'd640, "slide endpoint");
    expect_index(active_buffer_index, 2'd1, "target becomes active");
    expect_bit(slide_active, 1'b0, "slide disables at endpoint");
    expect_bit(transition_busy, 1'b0, "reservation releases at endpoint");

    committed_buffer_index = 2'd2;
    @(posedge video_clk);
    #1;
    pulse_read_request;
    expect_bit(slide_active, 1'b1, "second slide starts");
    read_fault = 1'b1;
    @(posedge video_clk);
    #1;
    expect_bit(slide_active, 1'b0, "fault cancels slide");
    expect_bit(transition_busy, 1'b1, "fault holds busy");
    expect_index(active_buffer_index, 2'd1, "fault keeps active buffer");
    read_fault = 1'b0;
    repeat (2) pulse_read_request;
    expect_index(active_buffer_index, 2'd1, "fault remains latched until reset");

    $display("PASS tb_video_transition_controller");
    $finish;
end

endmodule
