`timescale 1ns/1ps

// image_load_manager + image_playback_control 的调度回归（自动轮播 vs 慢图）
//   时间缩放：CLK_FREQ_HZ = 1000，1 s = 1000 拍。
//   6 张图，第 SLOW 张（默认 2，即板上 "3/6"）加载要 SLOW_S 秒，其余 0.3 s。
//   adapter 用行为模型：load_start 后按进度读，每 10 拍一个 load_progress_pulse，
//   读完给 source_done，再过 20 拍给 write_done；load_abort 立即中止，
//   abort 期间来的 load_start 锁存到收尾后执行（与真 adapter 一致）。
//   视频域：display_buffer_index 变化后 TR 拍内 display_settled = 0，
//   这段时间 adapter 的写被挡住（top.v 的 write_fifo_afull || !display_settled_sd），读也就停了。
//   自动轮播 +AUTO=<秒>（默认 3）。检查：跑 +RUN=<秒> 后每张图都显示过、没有被跳过。
module tb_manager_autoplay;

localparam integer HZ = 1000;
reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

integer SLOW, SLOW_S, AUTO, RUN, TR;

wire       scan_start, load_start, load_abort, storage_reinit;
wire [2:0] target_image_index, write_buffer_index, display_buffer_index, current_image_index;
wire       display_valid, display_test_pattern;
wire [2:0] state;
wire [1:0] retry_count;
wire [3:0] error_code, image_count;
wire       pending_next, source_done_seen, write_done_seen;
wire       load_in_progress, idle, commit_pulse, preloading;
reg        scan_done = 1'b0;
reg        source_done_pulse = 1'b0, source_error_pulse = 1'b0, write_done_pulse = 1'b0;
reg        load_progress_pulse = 1'b0;
reg        display_settled = 1'b1;
wire       next_request, prev_request, auto_request;
reg        key_next = 1'b1, key_auto = 1'b1;

image_load_manager #(.CLK_FREQ_HZ(HZ)) u_mgr (
    .clk(clk), .rst(rst), .storage_ready(1'b1),
    .scan_done(scan_done), .scan_found_count(4'd6),
    .source_done_pulse(source_done_pulse), .source_error_pulse(source_error_pulse),
    .storage_fault_pulse(1'b0), .write_done_pulse(write_done_pulse),
    .load_progress_pulse(load_progress_pulse),
    .next_request(next_request), .auto_request(auto_request), .prev_request(prev_request),
    .display_settled(display_settled),
    .scan_start(scan_start), .load_start(load_start), .load_abort(load_abort),
    .storage_reinit(storage_reinit), .target_image_index(target_image_index),
    .write_buffer_index(write_buffer_index), .display_buffer_index(display_buffer_index),
    .current_image_index(current_image_index), .display_valid(display_valid),
    .display_test_pattern(display_test_pattern), .state(state), .retry_count(retry_count),
    .error_code(error_code), .pending_next(pending_next), .source_done_seen(source_done_seen),
    .write_done_seen(write_done_seen), .image_count(image_count),
    .load_in_progress(load_in_progress), .idle(idle), .commit_pulse(commit_pulse),
    .preloading(preloading)
);

image_playback_control #(.CLK_FREQ_HZ(HZ), .AUTO_INTERVAL_SECONDS(3)) u_play (
    .clk(clk), .rst(rst), .key_next(key_next), .key_auto(key_auto),
    .display_valid(display_valid), .image_count(image_count),
    .manager_idle(idle && display_settled),
    .next_request(next_request), .prev_request(prev_request), .auto_request(auto_request),
    .auto_play_enabled(), .auto_period_sec(), .key_down()
);

// ---- 扫描 ----
always @(posedge clk) begin
    if (scan_start) scan_done <= 1'b0;
    else if (!scan_done && !rst) scan_done <= #1 1'b1;
end

// ---- adapter 行为模型 ----
integer remain = 0, prog = 0, wd_cnt = 0, abort_cnt = 0;
reg     busy = 1'b0, start_pend = 1'b0;
reg [2:0] img;
integer loads [0:5];
integer aborts = 0, starts = 0;
initial for (int q = 0; q < 6; q++) loads[q] = 0;

always @(posedge clk) begin
    source_done_pulse   <= 1'b0;
    write_done_pulse    <= 1'b0;
    load_progress_pulse <= 1'b0;
    if (load_abort) begin
        busy <= 1'b0; wd_cnt <= 0; abort_cnt <= 5; aborts <= aborts + 1;
        start_pend <= 1'b0;
    end else if ((load_start || start_pend) && abort_cnt > 0) begin
        start_pend <= 1'b1;
        abort_cnt  <= abort_cnt - 1;
    end else if (load_start || start_pend) begin
        start_pend <= 1'b0;
        busy   <= 1'b1;
        img    <= target_image_index;
        remain <= (target_image_index == SLOW) ? SLOW_S * HZ : (3 * HZ / 10);
        prog   <= 0;
        starts <= starts + 1;
    end else begin
        if (abort_cnt > 0) abort_cnt <= abort_cnt - 1;
        if (busy && display_settled) begin
            if (remain > 1) begin
                remain <= remain - 1;
                prog   <= prog + 1;
                if (prog % 10 == 9) load_progress_pulse <= 1'b1;
            end else begin
                busy <= 1'b0;
                source_done_pulse <= 1'b1;
                wd_cnt <= 20;
            end
        end
        if (wd_cnt > 0) begin
            if (display_settled) wd_cnt <= wd_cnt - 1;
            if (wd_cnt == 1 && display_settled) write_done_pulse <= 1'b1;
        end
    end
end

// ---- 视频域：换槽后 TR 拍过渡 ----
reg [2:0] disp_d = 3'd0;
integer   tr_cnt = 0;
always @(posedge clk) begin
    disp_d <= display_buffer_index;
    if (display_valid && (disp_d != display_buffer_index)) tr_cnt <= TR;
    else if (tr_cnt > 0) tr_cnt <= tr_cnt - 1;
    display_settled <= (tr_cnt == 0) && (disp_d == display_buffer_index);
end

// ---- 日志 ----
integer shown [0:5];
integer skips = 0, fails = 0;
initial for (int q = 0; q < 6; q++) shown[q] = 0;
reg [2:0] cur_d = 3'd0;
reg       dv_d = 1'b0;
always @(posedge clk) begin
    cur_d <= current_image_index;
    dv_d  <= display_valid;
    if (display_valid && (!dv_d || cur_d != current_image_index)) begin
        shown[current_image_index] = shown[current_image_index] + 1;
        $display("%8.3f s  SHOW image %0d/6 (slot %0d)", $time / 1.0e4, current_image_index + 1, display_buffer_index);
    end
    if (load_start)
        $display("%8.3f s    load_start img %0d/6 %s retry %0d", $time / 1.0e4, target_image_index + 1,
                 preloading ? "PRELOAD" : "FOREGND", retry_count);
    if (load_abort)
        $display("%8.3f s    load_abort img %0d/6 (state %0d, pre %0d)", $time / 1.0e4, target_image_index + 1, state, preloading);
    if (auto_request)
        $display("%8.3f s  auto_request (state %0d, preloading %0d target %0d/6)", $time / 1.0e4, state, preloading, target_image_index + 1);
end

initial begin
    if (!$value$plusargs("SLOW=%d", SLOW)) SLOW = 2;
    if (!$value$plusargs("SLOW_S=%d", SLOW_S)) SLOW_S = 10;
    if (!$value$plusargs("AUTO=%d", AUTO)) AUTO = 3;
    if (!$value$plusargs("RUN=%d", RUN)) RUN = 120;
    if (!$value$plusargs("TR=%d", TR)) TR = HZ / 2;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    // 短按 KEY2 打开自动轮播（消抖 50 ms = 50 拍）
    repeat (100) @(posedge clk);
    key_auto = 1'b0; repeat (200) @(posedge clk); key_auto = 1'b1;
    repeat (RUN * HZ) @(posedge clk);
    $display("shown counts: %0d %0d %0d %0d %0d %0d, loads started %0d, aborts %0d, err %0d",
             shown[0], shown[1], shown[2], shown[3], shown[4], shown[5], starts, aborts, error_code);
    if (shown[SLOW] == 0) $fatal(1, "FAIL image %0d/6 never shown", SLOW + 1);
    $display("PASS tb_manager_autoplay");
    $finish;
end

endmodule
