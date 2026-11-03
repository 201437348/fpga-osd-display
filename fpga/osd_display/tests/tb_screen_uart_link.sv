`timescale 1ns/1ps
// screen_uart_link 行为测试：1 MHz 时钟 + 100 kbaud（每位 10 拍），1 ms = 1000 拍。
// 屏幕侧用任务模拟：发 A5/EE 帧；监视 FPGA 发出的帧；自动应答读控件和读 RTC。
module tb_screen_uart_link;

reg clk = 1'b0;
reg rst = 1'b1;
always #500 clk = ~clk;

localparam integer BIT = 10;

reg        rx_line = 1'b1;
wire       tx_line;

reg  [7:0] brightness = 8'd255;
reg  [7:0] contrast   = 8'd128;
reg  [3:0] volume     = 4'd3;
reg  [3:0] tone_vol   = 4'd3;
reg        auto_play_enabled = 1'b1;
reg  [2:0] auto_period_sec   = 3'd3;
reg        display_valid     = 1'b1;
reg  [2:0] current_image_index = 3'd0;
reg  [3:0] image_count       = 4'd6;
reg        name_wr = 1'b0;
reg  [2:0] name_slot = 3'd0;
reg  [87:0] name_data = 88'd0;
reg        bgm_track_now   = 1'b0;
reg  [1:0] bgm_track_count = 2'd2;
wire       bgm_track_sel;

wire       cmd_next, cmd_prev, cmd_auto_toggle, cmd_period_valid;
wire [2:0] cmd_period;
wire       bc_cmd_valid, bc_cmd_target;
wire [7:0] bc_cmd_value;
wire       vol_cmd_valid, vol_cmd_target;
wire [3:0] vol_cmd_value;
wire       user_mute, visualizer_en, ticker_en, transition_fade, ticker_custom;
wire       ticker_wr_en;
wire [5:0] ticker_wr_addr;
wire [7:0] ticker_wr_data;
wire       screen_off, rtc_valid, time_toggle;
wire [4:0] time_h;
wire [5:0] time_m, time_s;

screen_uart_link #(
    .CLK_FREQ_HZ(1_000_000), .BAUD(100_000),
    .BOOT_MS(5), .RESYNC_MS(300), .DEBOUNCE_MS(3)
) dut (
    .clk(clk), .rst(rst), .uart_rx(rx_line), .uart_tx(tx_line),
    .brightness(brightness), .contrast(contrast), .volume(volume),
    .auto_play_enabled(auto_play_enabled), .auto_period_sec(auto_period_sec),
    .display_valid(display_valid), .current_image_index(current_image_index),
    .image_count(image_count),
    .name_wr(name_wr), .name_slot(name_slot), .name_data(name_data),
    .bgm_track_now(bgm_track_now), .bgm_track_count(bgm_track_count),
    .bgm_track_sel(bgm_track_sel),
    .cmd_next(cmd_next), .cmd_prev(cmd_prev), .cmd_auto_toggle(cmd_auto_toggle),
    .cmd_period_valid(cmd_period_valid), .cmd_period(cmd_period),
    .bc_cmd_valid(bc_cmd_valid), .bc_cmd_target(bc_cmd_target), .bc_cmd_value(bc_cmd_value),
    .vol_cmd_valid(vol_cmd_valid), .vol_cmd_target(vol_cmd_target), .vol_cmd_value(vol_cmd_value),
    .user_mute(user_mute), .visualizer_en(visualizer_en), .ticker_en(ticker_en),
    .transition_fade(transition_fade), .ticker_custom(ticker_custom),
    .ticker_wr_en(ticker_wr_en), .ticker_wr_addr(ticker_wr_addr), .ticker_wr_data(ticker_wr_data),
    .screen_off(screen_off), .rtc_valid(rtc_valid), .time_toggle(time_toggle),
    .time_h(time_h), .time_m(time_m), .time_s(time_s)
);

integer errors = 0;
task automatic fail(input string msg);
    begin
        errors = errors + 1;
        $display("FAIL @%0t: %s", $time, msg);
    end
endtask

// ---------------- 参数控制器行为模型 ----------------
always @(posedge clk) begin
    if (bc_cmd_valid) begin
        if (bc_cmd_target) contrast   <= bc_cmd_value;
        else               brightness <= bc_cmd_value;
    end
    if (vol_cmd_valid) begin
        if (vol_cmd_target) tone_vol <= vol_cmd_value;
        else                volume   <= vol_cmd_value;
    end
end

// ---------------- 命令脉冲计数 ----------------
integer n_next = 0, n_prev = 0, n_toggle = 0, n_period = 0, n_bc = 0, n_vol = 0;
reg [2:0] last_period;
reg       last_bc_target;
reg [7:0] last_bc_value;
reg [3:0] last_vol;
always @(posedge clk) begin
    if (cmd_next)         n_next   = n_next + 1;
    if (cmd_prev)         n_prev   = n_prev + 1;
    if (cmd_auto_toggle)  n_toggle = n_toggle + 1;
    if (cmd_period_valid) begin n_period = n_period + 1; last_period = cmd_period; end
    if (bc_cmd_valid)     begin n_bc = n_bc + 1; last_bc_target = bc_cmd_target; last_bc_value = bc_cmd_value; end
    if (vol_cmd_valid)    begin n_vol = n_vol + 1; last_vol = vol_cmd_value; end
end

// ---------------- OSD 字幕 RAM 模型 ----------------
reg [7:0] ticker_ram [0:63];
always @(posedge clk)
    if (ticker_wr_en)
        ticker_ram[ticker_wr_addr] <= ticker_wr_data;

// ---------------- 屏 -> FPGA 发送 ----------------
reg rx_lock = 1'b0;

task automatic uart_byte(input [7:0] b);
    integer i;
    begin
        rx_line = 1'b0;
        repeat (BIT) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            rx_line = b[i];
            repeat (BIT) @(posedge clk);
        end
        rx_line = 1'b1;
        repeat (BIT) @(posedge clk);
    end
endtask

function automatic [3:0] hexnib(input [7:0] c);
    begin
        if (c >= "0" && c <= "9")      hexnib = c - "0";
        else if (c >= "A" && c <= "F") hexnib = c - "A" + 10;
        else                           hexnib = c - "a" + 10;
    end
endfunction

task automatic lock_rx;
    begin
        while (rx_lock) @(posedge clk);
        rx_lock = 1'b1;
    end
endtask

task automatic unlock_rx;
    begin
        rx_lock = 1'b0;
        repeat (3 * BIT) @(posedge clk);
    end
endtask

// 发送十六进制串，例如 "A5 5A 03 20 02 22"
task automatic send_hex_raw(input string s);
    integer i;
    reg [7:0] b;
    begin
        i = 0;
        while (i + 1 < s.len() + 1) begin
            if (s[i] == 8'h20) begin
                i = i + 1;
            end else begin
                b = {hexnib(s[i]), hexnib(s[i + 1])};
                uart_byte(b);
                i = i + 2;
            end
        end
    end
endtask

task automatic send_hex(input string s);
    begin
        lock_rx;
        send_hex_raw(s);
        unlock_rx;
    end
endtask

// EE B1 11 00 PP 00 CC 11 <text> 00 FF FC FF FF
task automatic send_text_raw(input [7:0] page, input [7:0] ctrl, input string txt);
    integer i;
    begin
        uart_byte(8'hEE); uart_byte(8'hB1); uart_byte(8'h11);
        uart_byte(8'h00); uart_byte(page); uart_byte(8'h00); uart_byte(ctrl);
        uart_byte(8'h11);
        for (i = 0; i < txt.len(); i = i + 1)
            uart_byte(txt[i]);
        uart_byte(8'h00);
        uart_byte(8'hFF); uart_byte(8'hFC); uart_byte(8'hFF); uart_byte(8'hFF);
    end
endtask

task automatic send_button(input [7:0] page, input [7:0] ctrl, input [7:0] st);
    begin
        lock_rx;
        uart_byte(8'hEE); uart_byte(8'hB1); uart_byte(8'h11);
        uart_byte(8'h00); uart_byte(page); uart_byte(8'h00); uart_byte(ctrl);
        uart_byte(8'h10); uart_byte(8'h01); uart_byte(st);
        uart_byte(8'hFF); uart_byte(8'hFC); uart_byte(8'hFF); uart_byte(8'hFF);
        unlock_rx;
    end
endtask

task automatic send_slider(input [7:0] ctrl, input [31:0] v);
    begin
        lock_rx;
        uart_byte(8'hEE); uart_byte(8'hB1); uart_byte(8'h11);
        uart_byte(8'h00); uart_byte(8'h03); uart_byte(8'h00); uart_byte(ctrl);
        uart_byte(8'h13);
        uart_byte(v[31:24]); uart_byte(v[23:16]); uart_byte(v[15:8]); uart_byte(v[7:0]);
        uart_byte(8'hFF); uart_byte(8'hFC); uart_byte(8'hFF); uart_byte(8'hFF);
        unlock_rx;
    end
endtask

// ---------------- FPGA -> 屏 监视 ----------------
string frames[$];
string cur = "";
reg [31:0] tail4 = 32'd0;

string hexd = "0123456789ABCDEF";
initial begin : tx_mon
    integer i;
    reg [7:0] b, h1, h0;
    forever begin
        @(negedge tx_line);
        repeat (BIT / 2) @(posedge clk);
        if (tx_line !== 1'b0) fail("TX start bit glitch");
        for (i = 0; i < 8; i = i + 1) begin
            repeat (BIT) @(posedge clk);
            b[i] = tx_line;
        end
        repeat (BIT) @(posedge clk);
        if (tx_line !== 1'b1) fail("TX stop bit missing");
        h1 = hexd[b[7:4]];
        h0 = hexd[b[3:0]];
        if (cur.len() == 0) cur = $sformatf("%c%c", h1, h0);
        else                cur = $sformatf("%s %c%c", cur, h1, h0);
        tail4 = {tail4[23:0], b};
        if (tail4 == 32'hFFFCFFFF) begin
            frames.push_back(cur);
            cur = "";
            tail4 = 32'd0;
        end
    end
end

// 从 idx 起查找某帧
function automatic integer find_frame(input string f, input integer from);
    integer i;
    begin
        find_frame = -1;
        for (i = from; i < frames.size(); i = i + 1)
            if ((find_frame < 0) && (frames[i] == f))
                find_frame = i;
    end
endfunction

task automatic expect_frame(input string f, input integer from, input integer timeout_ms);
    integer t, n, found;
    begin
        t = 0;
        n = from;
        found = 0;
        while (!found && (t < timeout_ms * 1000)) begin
            if (n < frames.size()) begin
                if (frames[n] == f) found = 1;
                n = n + 1;
            end else begin
                @(posedge clk);
                t = t + 1;
            end
        end
        if (!found)
            fail($sformatf("missing frame: %s", f));
    end
endtask

task automatic expect_no_frame(input string f, input integer from);
    begin
        if (find_frame(f, from) >= 0)
            fail($sformatf("unexpected frame: %s", f));
    end
endtask

// ---------------- 屏幕自动应答 ----------------
string ans_sub = "hello, ";      // 字幕输入框内容（中文用 GBK 字节另拼）
reg    ans_sub_gbk = 1'b1;       // 结尾附加一个 GBK 汉字
string ans_sh = "8", ans_sm = "00", ans_eh = "12", ans_em = "0";
reg [7:0] rtc_hh = 8'h12, rtc_mm = 8'h34, rtc_ss = 8'h56;
reg    rtc_answer = 1'b0;
integer seen = 0;

initial begin : responder
    string f;
    forever begin
        @(posedge clk);
        if (seen < frames.size()) begin
            f = frames[seen];
            seen = seen + 1;
            if (f == "EE 82 FF FC FF FF" && rtc_answer) begin
                lock_rx;
                uart_byte(8'hEE); uart_byte(8'hF7);
                uart_byte(8'h26); uart_byte(8'h09); uart_byte(8'h05); uart_byte(8'h26);
                uart_byte(rtc_hh); uart_byte(rtc_mm); uart_byte(rtc_ss);
                uart_byte(8'hFF); uart_byte(8'hFC); uart_byte(8'hFF); uart_byte(8'hFF);
                unlock_rx;
            end else if (f == "EE B1 11 00 04 00 01 FF FC FF FF") begin
                lock_rx;
                if (ans_sub_gbk) begin
                    // "hello, " + 汉字"世"(CA C0) + "x"
                    uart_byte(8'hEE); uart_byte(8'hB1); uart_byte(8'h11);
                    uart_byte(8'h00); uart_byte(8'h04); uart_byte(8'h00); uart_byte(8'h01);
                    uart_byte(8'h11);
                    for (int i = 0; i < ans_sub.len(); i++) uart_byte(ans_sub[i]);
                    uart_byte(8'hCA); uart_byte(8'hC0); uart_byte("x");
                    uart_byte(8'h00);
                    uart_byte(8'hFF); uart_byte(8'hFC); uart_byte(8'hFF); uart_byte(8'hFF);
                end else begin
                    send_text_raw(8'h04, 8'h01, ans_sub);
                end
                unlock_rx;
            end else if (f == "EE B1 11 00 05 00 01 FF FC FF FF") begin
                lock_rx; send_text_raw(8'h05, 8'h01, ans_sh); unlock_rx;
            end else if (f == "EE B1 11 00 05 00 09 FF FC FF FF") begin
                lock_rx; send_text_raw(8'h05, 8'h09, ans_sm); unlock_rx;
            end else if (f == "EE B1 11 00 05 00 06 FF FC FF FF") begin
                lock_rx; send_text_raw(8'h05, 8'h06, ans_eh); unlock_rx;
            end else if (f == "EE B1 11 00 05 00 0C FF FC FF FF") begin
                lock_rx; send_text_raw(8'h05, 8'h0C, ans_em); unlock_rx;
            end
        end
    end
end

task automatic wait_ms(input integer n);
    begin
        repeat (n * 1000) @(posedge clk);
    end
endtask

// ---------------- 主流程 ----------------
integer mark, i0;
reg dump_frames = 1'b0;
initial begin
    for (i0 = 0; i0 < 64; i0 = i0 + 1) ticker_ram[i0] = 8'h00;
    repeat (20) @(posedge clk);
    rst = 1'b0;

    // 1. 上电同步
    expect_frame("EE 60 00 FF FC FF FF", 0, 100);
    expect_frame("EE B1 10 00 01 00 07 31 30 30 25 FF FC FF FF", 0, 100);   // 首页亮度 100%
    expect_frame("EE B1 10 00 03 00 01 00 00 00 64 FF FC FF FF", 0, 100);   // 亮度滑块 100
    expect_frame("EE B1 10 00 03 00 0D 35 30 25 FF FC FF FF", 0, 100);      // 对比度 50%
    expect_frame("EE B1 10 00 01 00 08 33 38 25 FF FC FF FF", 0, 100);      // 首页音量 38%（默认 3 档）
    expect_frame("EE B1 10 00 03 00 12 00 00 00 26 FF FC FF FF", 0, 100);   // 提示音滑块 38
    expect_frame("EE B1 10 00 03 00 13 33 38 25 FF FC FF FF", 0, 100);      // 提示音 38%
    expect_frame("EE 70 31 FF FC FF FF", 0, 100);                           // 关触摸蜂鸣
    expect_frame("EE B1 23 00 01 00 0C 00 FF FC FF FF", 0, 100);            // 首页图标
    expect_frame("EE B1 10 00 01 00 0D 2D FF FC FF FF", 0, 100);            // 无文件名
    expect_frame("EE B1 10 00 02 00 0E 30 31 20 2F 20 30 36 FF FC FF FF", 0, 100); // 01 / 06
    expect_frame("EE B1 10 00 02 00 10 00 FF FC FF FF", 0, 100);            // 切图效果 = 滑动（默认）
    expect_frame("EE B1 10 00 02 00 11 33 53 FF FC FF FF", 0, 100);         // 间隔 3S
    expect_frame("EE B1 10 00 02 00 14 42 47 4D 20 31 2F 32 FF FC FF FF", 0, 100); // BGM 1/2
    expect_frame("EE B1 10 00 01 00 09 FF FC FF FF", 0, 100);               // 首页字幕（空）
    expect_frame("EE B1 10 00 01 00 0A 52 54 43 20 45 52 52 FF FC FF FF", 0, 100); // RTC ERR
    $display("step1 boot sync: %0d frames", frames.size());
    rtc_answer = 1'b1;
    if (dump_frames) for (i0 = 0; i0 < frames.size() && i0 < 40; i0 = i0 + 1) $display("  [%0d] %s", i0, frames[i0]);

    // 2. A5 业务帧
    send_hex("A5 5A 03 20 02 22");
    send_hex("A5 5A 03 20 03 23");
    send_hex("A5 5A 03 20 01 21");
    send_hex("A5 5A 03 20 04 24");
    repeat (10) @(posedge clk);
    if (last_period !== 3'd5) fail("interval cycle 3 -> 5");
    send_hex("A5 5A 03 20 12 32");
    repeat (10) @(posedge clk);
    if (last_period !== 3'd2) fail("interval set 2");
    send_hex("A5 5A 03 20 02 23");   // 校验错，丢弃
    send_hex("A5 5A 03 20 02");      // 半帧，后接新帧
    send_hex("A5 5A 03 20 02 22");
    repeat (10) @(posedge clk);
    if (n_next != 2 || n_prev != 1 || n_toggle != 1 || n_period != 2)
        fail($sformatf("A5 counts next=%0d prev=%0d toggle=%0d period=%0d", n_next, n_prev, n_toggle, n_period));

    // 切歌：A5 20 05 以实际曲目取反；21/22 直接选曲；曲目变化回写 "BGM 2/2"
    send_hex("A5 5A 03 20 05 25");
    repeat (10) @(posedge clk);
    if (bgm_track_sel !== 1'b1) fail("bgm toggle -> sel should be 1");
    mark = frames.size();
    bgm_track_now = 1'b1;
    expect_frame("EE B1 10 00 02 00 14 42 47 4D 20 32 2F 32 FF FC FF FF", mark, 50);
    send_hex("A5 5A 03 20 05 25");
    repeat (10) @(posedge clk);
    if (bgm_track_sel !== 1'b0) fail("bgm toggle -> sel should be 0");
    send_hex("A5 5A 03 20 22 42");
    repeat (10) @(posedge clk);
    if (bgm_track_sel !== 1'b1) fail("bgm select 2 -> sel should be 1");
    send_hex("A5 5A 03 20 21 41");
    repeat (10) @(posedge clk);
    if (bgm_track_sel !== 1'b0) fail("bgm select 1 -> sel should be 0");
    mark = frames.size();
    bgm_track_now = 1'b0;
    bgm_track_count = 2'd0;
    expect_frame("EE B1 10 00 02 00 14 42 47 4D 20 2D 2F 30 FF FC FF FF", mark, 50); // BGM -/0
    bgm_track_count = 2'd2;

    // 间隔变化回写
    mark = frames.size();
    auto_period_sec = 3'd5;
    expect_frame("EE B1 10 00 02 00 11 35 53 FF FC FF FF", mark, 50);

    // 3. 亮度 -1%
    mark = frames.size();
    send_hex("A5 5A 03 30 01 31");
    repeat (10) @(posedge clk);
    if (last_bc_target !== 1'b0 || last_bc_value !== 8'd253)
        fail($sformatf("brightness -1%% -> %0d", last_bc_value));
    expect_frame("EE B1 10 00 03 00 01 00 00 00 63 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 03 00 0C 39 39 25 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 01 00 07 39 39 25 FF FC FF FF", mark, 50);

    // 4. 对比度滑块 30、音量滑块 50
    mark = frames.size();
    send_slider(8'h06, 32'd30);
    repeat (10) @(posedge clk);
    if (last_bc_target !== 1'b1 || last_bc_value !== 8'd77)
        fail($sformatf("contrast slider 30 -> %0d", last_bc_value));
    send_slider(8'h07, 32'd50);
    repeat (10) @(posedge clk);
    if (last_vol !== 4'd4) fail($sformatf("volume slider 50 -> %0d", last_vol));
    expect_frame("EE B1 10 00 03 00 0D 33 30 25 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 01 00 08 35 30 25 FF FC FF FF", mark, 50);
    send_slider(8'h01, 32'd250);     // 超范围按 100
    expect_frame("EE B1 10 00 01 00 07 31 30 30 25 FF FC FF FF", mark, 50);
    if (brightness !== 8'd255) fail("slider clamp");

    // 音量 +1 档：4 -> 5 = 63%
    mark = frames.size();
    send_hex("A5 5A 03 30 06 36");
    expect_frame("EE B1 10 00 01 00 08 36 33 25 FF FC FF FF", mark, 50);
    if (volume !== 4'd5) fail("volume +1 level");

    // 5. 外部改动（KEY3）回写
    mark = frames.size();
    wait_ms(2);
    brightness = 8'd128;
    expect_frame("EE B1 10 00 01 00 07 35 30 25 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 03 00 01 00 00 00 32 FF FC FF FF", mark, 50);
    volume = 4'd2;
    expect_frame("EE B1 10 00 01 00 08 32 35 25 FF FC FF FF", mark, 50);

    // 5b. 提示音音量：按钮 08 +1 / 07 -1，滑块 CC=12；不能动到音乐音量
    mark = frames.size();
    send_hex("A5 5A 03 30 08 38");
    expect_frame("EE B1 10 00 03 00 13 35 30 25 FF FC FF FF", mark, 50);   // 3 -> 4 = 50%
    if (tone_vol !== 4'd4 || volume !== 4'd2) fail($sformatf("tone +1: tone=%0d vol=%0d", tone_vol, volume));
    mark = frames.size();
    send_hex("A5 5A 03 30 07 37");
    send_hex("A5 5A 03 30 07 37");
    expect_frame("EE B1 10 00 03 00 13 32 35 25 FF FC FF FF", mark, 50);   // 4 -> 2 = 25%
    if (tone_vol !== 4'd2) fail($sformatf("tone -2: %0d", tone_vol));
    mark = frames.size();
    send_slider(8'h12, 32'd100);
    expect_frame("EE B1 10 00 03 00 13 31 30 30 25 FF FC FF FF", mark, 50);
    if (tone_vol !== 4'd8 || volume !== 4'd2) fail($sformatf("tone slider: tone=%0d vol=%0d", tone_vol, volume));
    $display("step5b tone volume ok");

    // 6. 播放页开关
    send_button(8'h02, 8'h07, 8'h01);
    send_button(8'h02, 8'h08, 8'h00);
    send_button(8'h02, 8'h09, 8'h00);
    send_button(8'h02, 8'h10, 8'h00);
    repeat (10) @(posedge clk);
    if (user_mute !== 1'b1 || visualizer_en !== 1'b0 || ticker_en !== 1'b0 || transition_fade !== 1'b0)
        fail("play page switches");

    // 7. RTC
    wait (rtc_valid === 1'b1);
    if (time_h !== 5'd12 || time_m !== 6'd34 || time_s !== 6'd56)
        fail($sformatf("rtc %0d:%0d:%0d", time_h, time_m, time_s));
    mark = frames.size();
    expect_frame("EE B1 10 00 01 00 0A 4F 46 46 FF FC FF FF", 0, 50);       // OFF
    $display("step7 rtc ok");

    // 8. 字幕：发送 -> 读 -> 提交
    mark = frames.size();
    send_button(8'h04, 8'h0A, 8'h01);
    send_button(8'h04, 8'h0A, 8'h00);
    expect_frame("EE B1 11 00 04 00 01 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 04 00 07 BD F6 D6 A7 B3 D6 D3 A2 CE C4 FF FC FF FF", mark, 100);
    expect_frame("EE B1 10 00 01 00 09 48 45 4C 4C 4F 2C 20 58 FF FC FF FF", mark, 100);  // "HELLO, X"
    expect_frame("EE B1 10 00 04 00 06 48 45 4C 4C 4F 2C 20 58 FF FC FF FF", mark, 100);
    if (!ticker_custom) fail("ticker_custom");
    if (ticker_ram[0] !== "H" || ticker_ram[6] !== " " || ticker_ram[7] !== "X" || ticker_ram[8] !== " " || ticker_ram[63] !== " ")
        fail("ticker ram content");
    // 纯 ASCII 再发一次 -> 发送成功
    ans_sub_gbk = 1'b0;
    ans_sub = "abc";
    mark = frames.size();
    send_button(8'h04, 8'h0A, 8'h01);
    expect_frame("EE B1 10 00 04 00 07 B7 A2 CB CD B3 C9 B9 A6 FF FC FF FF", mark, 100);
    expect_frame("EE B1 10 00 01 00 09 41 42 43 FF FC FF FF", mark, 100);
    $display("step8 subtitle ok");

    // 9. 文件名 / 换图
    mark = frames.size();
    @(posedge clk);
    name_slot = 3'd1; name_data = {"IMG2    ", "BMP"}; name_wr = 1'b1;
    @(posedge clk);
    name_wr = 1'b0;
    current_image_index = 3'd1;
    expect_frame("EE B1 10 00 01 00 0D 49 4D 47 32 2E 42 4D 50 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 02 00 0D 49 4D 47 32 2E 42 4D 50 FF FC FF FF", mark, 50);
    expect_frame("EE B1 23 00 02 00 0C 01 FF FC FF FF", mark, 50);
    expect_frame("EE B1 10 00 01 00 0E 30 32 20 2F 20 30 36 FF FC FF FF", mark, 50);

    // 10. 定时：08:00-12:00，当前 12:34 -> 窗口外息屏
    mark = frames.size();
    send_button(8'h05, 8'h07, 8'h01);
    expect_frame("EE B1 10 00 05 00 07 01 FF FC FF FF", mark, 200);
    expect_frame("EE B1 10 00 01 00 0A 30 38 3A 30 30 2D 31 32 3A 30 30 FF FC FF FF", mark, 200);
    expect_frame("EE 60 FF FF FC FF FF", mark, 1500);
    if (!screen_off) fail("screen_off");
    // 时间回到窗口内 -> 亮屏
    mark = frames.size();
    rtc_hh = 8'h09;
    expect_frame("EE 60 00 FF FC FF FF", mark, 1500);
    if (screen_off) fail("screen_on");
    // 非法字段 -> 开关写回 00
    ans_em = "7a";
    mark = frames.size();
    send_button(8'h05, 8'h07, 8'h01);
    expect_frame("EE B1 10 00 05 00 07 00 FF FC FF FF", mark, 200);
    $display("step10 schedule ok");

    // 11. 复位报告 -> 重新同步
    mark = frames.size();
    send_hex("EE 07 FF FC FF FF");
    expect_frame("EE B1 10 00 02 00 10 00 FF FC FF FF", mark, 200);

    // 12. RTC 断连 -> rtc_valid 掉
    rtc_answer = 1'b0;
    wait_ms(4500);
    if (rtc_valid) fail("rtc_valid should drop");

    if (errors == 0) $display("PASS tb_screen_uart_link (%0d frames)", frames.size());
    else             $display("FAIL tb_screen_uart_link: %0d errors", errors);
    $finish;
end

initial begin
    #9_000_000_000;
    $display("FAIL timeout");
    $finish;
end

endmodule
