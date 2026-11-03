`timescale 1ns/1ps

module tb_image_playback_control;

reg clk = 1'b0;
reg rst = 1'b1;
reg key_next = 1'b1;
reg key_auto = 1'b1;
reg display_valid = 1'b1;
reg [3:0] image_count = 4'd3;
reg manager_idle = 1'b1;
wire next_request;
wire prev_request;
wire auto_request;
wire auto_play_enabled;
wire [2:0] auto_period_sec;
integer next_seen = 0;
integer prev_seen = 0;
integer auto_seen = 0;
integer cycle = 0;
integer last_auto_cycle = 0;
integer auto_gap = 0;

always #5 clk = ~clk;

always @(posedge clk) begin
    cycle <= cycle + 1;
    if (next_request) next_seen <= next_seen + 1;
    if (prev_request) prev_seen <= prev_seen + 1;
    if (auto_request) begin
        auto_seen       <= auto_seen + 1;
        auto_gap        <= cycle - last_auto_cycle;
        last_auto_cycle <= cycle;
    end
end

// 1 kHz：1 周期 = 1 ms。消抖 50，长按 800，1 秒 = 1000 周期
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
    .cmd_next(1'b0), .cmd_prev(1'b0), .cmd_auto_toggle(1'b0),
    .cmd_period_valid(1'b0), .cmd_period(3'd0), .hold(1'b0),
    .next_request(next_request),
    .prev_request(prev_request),
    .auto_request(auto_request),
    .auto_play_enabled(auto_play_enabled),
    .auto_period_sec(auto_period_sec)
);

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

task automatic expect_int;
    input integer actual;
    input integer expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic hold_next;
    input integer cycles;
    begin
        key_next = 1'b0;
        repeat (cycles) tick();
        key_next = 1'b1;
        repeat (60) tick();
    end
endtask

task automatic hold_auto;
    input integer cycles;
    begin
        key_auto = 1'b0;
        repeat (cycles) tick();
        key_auto = 1'b1;
        repeat (60) tick();
    end
endtask

task automatic clear_counts;
    begin
        next_seen = 0; prev_seen = 0; auto_seen = 0;
    end
endtask

initial begin
    repeat (2) tick();
    rst = 1'b0;
    tick();
    expect_int(auto_period_sec, 1, "default period");

    hold_next(100);
    expect_int(next_seen, 1, "short KEY1 = next");
    expect_int(prev_seen, 0, "short KEY1 is not prev");

    clear_counts();
    manager_idle = 1'b0;
    hold_next(100);
    hold_next(900);
    expect_int(next_seen + prev_seen, 0, "KEY1 ignored while loading");
    manager_idle = 1'b1;

    clear_counts();
    key_next = 1'b0;
    repeat (870) tick();
    expect_int(prev_seen, 1, "long KEY1 fires prev while held");
    repeat (500) tick();
    key_next = 1'b1;
    repeat (60) tick();
    expect_int(prev_seen, 1, "long KEY1 fires prev once");
    expect_int(next_seen, 0, "long KEY1 release adds no next");

    clear_counts();
    image_count = 4'd1;
    hold_next(900);
    expect_int(prev_seen, 0, "prev needs two images");
    image_count = 4'd3;

    hold_auto(100);
    expect_int(auto_play_enabled, 1, "short KEY2 enables auto");
    clear_counts();
    repeat (2100) tick();
    expect_int(auto_seen, 2, "1 s period: two requests in 2.1 s");
    expect_int(auto_gap, 1000, "1 s period gap");

    hold_auto(900);
    expect_int(auto_period_sec, 2, "long KEY2 cycles period to 2");
    expect_int(auto_play_enabled, 1, "long KEY2 keeps auto on");
    clear_counts();
    repeat (4100) tick();
    expect_int(auto_seen, 2, "2 s period: two requests in 4.1 s");
    expect_int(auto_gap, 2000, "2 s period gap");

    hold_auto(900);
    expect_int(auto_period_sec, 3, "period 3");
    hold_auto(900);
    expect_int(auto_period_sec, 5, "period 5");
    hold_auto(900);
    expect_int(auto_period_sec, 1, "period wraps to 1");

    clear_counts();
    manager_idle = 1'b0;
    repeat (1500) tick();
    expect_int(auto_seen, 0, "auto waits while loading");
    manager_idle = 1'b1;

    hold_auto(100);
    expect_int(auto_play_enabled, 0, "short KEY2 disables auto");
    clear_counts();
    repeat (1500) tick();
    expect_int(auto_seen, 0, "no auto when disabled");

    $display("PASS tb_image_playback_control");
    $finish;
end

endmodule
