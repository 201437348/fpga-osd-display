`timescale 1ns/1ps

module tb_image_playback_control;

reg clk = 1'b0;
reg rst = 1'b1;
reg key_next = 1'b1;
reg key_auto = 1'b1;
reg display_valid = 1'b1;
reg [2:0] image_count = 3'd3;
reg manager_idle = 1'b1;
wire next_request;
wire auto_request;
wire auto_play_enabled;
reg next_request_seen = 1'b0;

always #5 clk = ~clk;

always @(posedge clk) begin
    if (rst)
        next_request_seen <= 1'b0;
    else if (next_request)
        next_request_seen <= 1'b1;
end

image_playback_control #(
    .CLK_FREQ_HZ(1000),
    .AUTO_INTERVAL_SECONDS(1)
) dut (
    .clk(clk),
    .rst(rst),
    .key_next(key_next),
    .key_auto(key_auto),
    .display_valid(display_valid),
    .image_count(image_count),
    .manager_idle(manager_idle),
    .next_request(next_request),
    .auto_request(auto_request),
    .auto_play_enabled(auto_play_enabled)
);

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

task automatic expect_bit;
    input actual;
    input expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0b, got %0b", checkpoint, expected, actual);
    end
endtask

task automatic press_next;
    integer count;
    begin
        key_next = 1'b0;
        for (count = 0; count < 55; count = count + 1)
            tick();
        key_next = 1'b1;
        repeat (4) tick();
    end
endtask

task automatic press_auto;
    integer count;
    begin
        key_auto = 1'b0;
        for (count = 0; count < 55; count = count + 1)
            tick();
        key_auto = 1'b1;
        repeat (4) tick();
    end
endtask

task automatic wait_for_auto_request;
    integer count;
    begin
        count = 0;
        while (!auto_request && (count < 1010)) begin
            tick();
            count = count + 1;
        end
        if (!auto_request)
            $fatal(1, "FAIL automatic request did not arrive");
    end
endtask

initial begin
    repeat (2) tick();
    rst = 1'b0;
    tick();

    press_next();
    expect_bit(next_request_seen, 1'b1, "debounced next key requests an image");

    next_request_seen = 1'b0;
    manager_idle = 1'b0;
    press_next();
    expect_bit(next_request_seen, 1'b0, "next key is ignored while an image load is active");
    manager_idle = 1'b1;

    tick();
    press_auto();
    expect_bit(auto_play_enabled, 1'b1, "debounced auto key enables playback");
    wait_for_auto_request();

    dut.auto_counter = 32'd999;
    force dut.u_key_auto.press_pulse = 1'b1;
    tick();
    release dut.u_key_auto.press_pulse;
    expect_bit(auto_play_enabled, 1'b0, "auto key disables playback");
    expect_bit(auto_request, 1'b0, "auto key suppresses simultaneous timer request");

    $display("PASS tb_image_playback_control");
    $finish;
end

endmodule
