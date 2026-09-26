`timescale 1ns/1ps

// audio_pcm_player 提示音：
//   1) key_down 上升沿 -> BEEP 个 2 kHz 正弦采样（相位 0,2,4,...），之后静音；
//      按住不放不重复响，松开再按才再响；
//   2) no_card 短于 HOLD 个采样不响；持续无卡后连续输出 1 kHz 测试音
//      （相位 0,1,2,...,47,0,1,... 不间断）；no_card 撤掉立即停；
//   3) 与音乐叠加时饱和，不回绕；音乐帧照常消耗（不停 FIFO）；
//   4) 音乐音量 / 提示音音量各自独立生效。
module tb_audio_tone;

localparam integer BEEP = 10, HOLD = 20, TONE_CHECK = 120;   // 核对 2.5 个完整周期

reg clk = 1'b0;
reg rst = 1'b1;
reg key_down = 1'b0;
reg no_card = 1'b0;
reg enable = 1'b0;
reg [31:0] music = 32'd0;
reg [3:0]  mus_vol = 4'd8;
reg [3:0]  tone_vol = 4'd8;
integer    tone_shift = 0;      // 期望值 = 正弦 >>> tone_shift
reg fifo_has = 1'b0;
wire fifo_re;
wire audio_valid;
wire [23:0] l, r;
integer reads = 0;

always #5 clk = ~clk;

audio_pcm_player #(
    .CLK_FREQ_HZ(4), .SAMPLE_RATE_HZ(1), .PREFILL_FRAMES(10'd1),
    .BEEP_SAMPLES(BEEP), .ALARM_HOLDOFF_SAMPLES(HOLD)
) dut (
    .clk(clk), .rst(rst), .enable(enable), .volume(mus_vol), .tone_volume(tone_vol),
    .key_down(key_down), .no_card(no_card),
    .fifo_empty(!fifo_has), .fifo_valid(fifo_has),
    .fifo_rdusedw(fifo_has ? 10'd100 : 10'd0), .fifo_dout(music),
    .fifo_re(fifo_re), .audio_valid(audio_valid),
    .audio_left_data(l), .audio_right_data(r)
);

always @(posedge clk) if (fifo_re) reads = reads + 1;

function integer sine_ref(input integer p);
    real v;
    begin
        v = 11585.0 * $sin(2.0 * 3.14159265358979 * p / 48.0);
        sine_ref = (v >= 0.0) ? $rtoi(v + 0.5) : -$rtoi(-v + 0.5);
        // 相位 4/20/28/44 恰为 5792.5，RTL 表取 5792（向下）
        if (sine_ref == 5793 || sine_ref == -5793) sine_ref = (sine_ref > 0) ? 5792 : -5792;
        sine_ref = sine_ref >>> tone_shift;
    end
endfunction

integer sl, sr, i, n, waited, exp;

task automatic next_sample;
    begin
        @(posedge clk);
        while (!audio_valid) @(posedge clk);
        #1;
        if (l[7:0] !== 8'd0 || r[7:0] !== 8'd0) $fatal(1, "FAIL low byte not zero");
        sl = $signed(l[23:8]);
        sr = $signed(r[23:8]);
    end
endtask

task automatic expect_silence(input integer cnt, input [255:0] what);
    for (i = 0; i < cnt; i = i + 1) begin
        next_sample();
        if (sl != 0 || sr != 0) $fatal(1, "FAIL %0s: sample %0d = %0d/%0d", what, i, sl, sr);
    end
endtask

// 等第一个非零采样（应为相位 step），再逐点核对到第 cnt-1 个相位
task automatic expect_burst(input integer cnt, input integer step, input integer max_wait,
                            input [255:0] what);
    begin
        waited = 0;
        next_sample();
        while (sl == 0) begin
            if (waited >= max_wait) $fatal(1, "FAIL %0s: never started", what);
            next_sample();
            waited = waited + 1;
        end
        for (n = 1; n < cnt; n = n + 1) begin
            if (n > 1) next_sample();
            exp = sine_ref((n * step) % 48);
            if (sl != exp || sr != exp)
                $fatal(1, "FAIL %0s: phase %0d = %0d/%0d, expected %0d", what, n * step, sl, sr, exp);
        end
    end
endtask

integer reads0, peak, holdoff;
initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;
    expect_silence(5, "idle");

    // 1) 按键音
    @(negedge clk); key_down = 1'b1;
    expect_burst(BEEP, 2, 3, "beep");
    expect_silence(8, "after beep, key still held");
    @(negedge clk); key_down = 1'b0;
    expect_silence(4, "released");
    @(negedge clk); key_down = 1'b1;
    expect_burst(BEEP, 2, 3, "second beep");
    expect_silence(4, "after second beep");
    @(negedge clk); key_down = 1'b0;

    // 2) 短时间无卡不响
    @(negedge clk); no_card = 1'b1;
    expect_silence(HOLD - 4, "short no_card");
    @(negedge clk); no_card = 1'b0;
    expect_silence(HOLD + 4, "short no_card never alarms");

    // 3) 持续无卡：连续 1 kHz 测试音，跨过相位回绕也不间断
    @(negedge clk); no_card = 1'b1;
    expect_burst(TONE_CHECK, 1, HOLD + 6, "test tone");
    holdoff = waited;
    if (holdoff < HOLD - 1) $fatal(1, "FAIL test tone started too early (%0d samples)", holdoff);
    @(negedge clk); no_card = 1'b0;
    repeat (3) next_sample();                        // 2FF 同步 + 流水
    expect_silence(60, "test tone stops when card is back");

    // 4) 叠加音乐 + 饱和
    music = {16'h7000, 16'h7000};
    fifo_has = 1'b1;
    enable = 1'b1;
    repeat (10) next_sample();
    if (sl != 16'h7000 || sr != 16'h7000) $fatal(1, "FAIL music not playing: %0d", sl);
    reads0 = reads;
    peak = 0;
    @(negedge clk); key_down = 1'b1;
    for (n = 0; n < BEEP + 4; n = n + 1) begin
        next_sample();
        if (sl < 16'h7000 - 11585 || sl > 32767) $fatal(1, "FAIL mix out of range %0d", sl);
        if (sl > peak) peak = sl;
    end
    if (peak != 32767) $fatal(1, "FAIL expected saturation at 32767, peak=%0d", peak);
    if (sl != 16'h7000) $fatal(1, "FAIL music not restored after beep: %0d", sl);
    if (reads - reads0 < BEEP + 3) $fatal(1, "FAIL FIFO stalled during beep (%0d reads)", reads - reads0);

    @(negedge clk); key_down = 1'b0;

    // 5) 音量独立：音乐 0 档 + 提示音 7 档 -> 只剩半幅按键音
    mus_vol = 4'd0; tone_vol = 4'd7; tone_shift = 1;
    repeat (2) next_sample();                     // 音量跨域同步要几拍
    expect_silence(10, "music muted");
    @(negedge clk); key_down = 1'b1;
    expect_burst(BEEP, 2, 3, "beep at tone volume 7");
    expect_silence(4, "after half beep");
    @(negedge clk); key_down = 1'b0;
    //    音乐 7 档 + 提示音 0 档 -> 音乐减半，按键不出声
    mus_vol = 4'd7; tone_vol = 4'd0;
    repeat (4) next_sample();
    @(negedge clk); key_down = 1'b1;
    for (n = 0; n < BEEP + 4; n = n + 1) begin
        next_sample();
        if (sl != 16'h3800 || sr != 16'h3800) $fatal(1, "FAIL tone volume 0 / music 7: %0d", sl);
    end
    @(negedge clk); key_down = 1'b0;

    $display("PASS tb_audio_tone (test tone holdoff %0d samples)", holdoff);
    $finish;
end

initial begin
    #1_000_000;
    $fatal(1, "FAIL tb_audio_tone timeout");
end

endmodule
