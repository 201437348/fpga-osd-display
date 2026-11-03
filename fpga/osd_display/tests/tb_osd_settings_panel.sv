`timescale 1ns/1ps
// osd_settings_panel 测试：640x480 简化时序（每行 640 de + 32 消隐，vs 占 2 行）
//   1) 上电静默期内参数变化不弹出
//   2) 静默期后改亮度 -> 淡入到满级，面板外像素与输入完全相同
//   3) 给了 +PPM=<文件> 时把满级那一帧写成 PPM，用于肉眼检查版面
//   4) 计时结束后淡出，输出恢复为输入
// 运行：iverilog -g2012 -s tb_osd_settings_panel -o p.vvp tests/tb_osd_settings_panel.sv \
//        rtl/video/osd_settings_panel.v rtl/video/osd_font_rom.v   （在 fpga/osd_display 下运行 vvp）
module tb_osd_settings_panel;

reg clk = 1'b0;
reg rst = 1'b1;
always #20 clk = ~clk;

reg        vs = 1'b0, de = 1'b0;
reg [9:0]  px = 10'd0, py = 10'd0;
reg [7:0]  brightness = 8'd191;     // 75%
reg [7:0]  contrast   = 8'd128;     // 50%
reg [1:0]  channel    = 2'b00;
// {volume, mute, bgm_now, bgm_count, auto_on, period}
reg [11:0] status_sd  = {4'd3, 1'b0, 1'b0, 2'd2, 1'b1, 3'd3};

// 背景：模拟一张风景图（上蓝下绿的渐变 + 竖条纹理）
wire [23:0] rgb_in = {px[9:2] ^ {py[8:5], 4'd0}, 8'd96 + py[8:2], 8'd200 - py[8:1]};
wire [23:0] rgb_out;
wire [10:0] font_addr;
wire [15:0] font_q;

osd_font_rom u_font (
    .clk(clk), .addr_a(font_addr), .dout_a(font_q), .addr_b(11'd0), .dout_b()
);

osd_settings_panel #(
    .SHOW_FRAMES (6),
    .BOOT_FRAMES (3),
    .FADE_FRAMES (1)
) dut (
    .video_clk  (clk),
    .rst        (rst),
    .vs         (vs),
    .de         (de),
    .rgb_in     (rgb_in),
    .brightness (brightness),
    .contrast   (contrast),
    .channel    (channel),
    .status_sd  (status_sd),
    .font_addr  (font_addr),
    .font_q     (font_q),
    .rgb_out    (rgb_out)
);

integer errors = 0;
integer fd = 0;
integer diff_in, diff_out;          // 本帧面板内 / 外与输入不同的像素数
reg     dump = 1'b0;
string  ppm;

task automatic fail(input string msg);
    begin
        errors = errors + 1;
        $display("FAIL @%0t: %s", $time, msg);
    end
endtask

// 跑一帧：vs 2 行，然后 480 行有效
task automatic frame;
    integer l, c;
    begin
        diff_in = 0; diff_out = 0;
        @(negedge clk); vs = 1'b1;
        repeat (2 * 672) @(negedge clk);
        vs = 1'b0;
        repeat (32) @(negedge clk);
        for (l = 0; l < 480; l = l + 1) begin
            for (c = 0; c < 640; c = c + 1) begin
                px = c; py = l; de = 1'b1;
                #1;
                if (rgb_out !== rgb_in) begin
                    if ((c >= 176) && (c < 464) && (l >= 132) && (l < 336)) diff_in = diff_in + 1;
                    else diff_out = diff_out + 1;
                end
                if (dump) $fwrite(fd, "%c%c%c", rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
                @(negedge clk);
            end
            de = 1'b0;
            repeat (32) @(negedge clk);
        end
    end
endtask

integer f;
initial begin
    if (!$value$plusargs("PPM=%s", ppm)) ppm = "";
    repeat (5) @(negedge clk);
    rst = 1'b0;

    // 1) 静默期：改亮度不弹出
    frame();
    brightness = 8'd200;
    frame();
    frame();
    if (diff_in != 0) fail("panel must stay hidden during boot quiet period");

    // 2) 静默期后改亮度 -> 弹出并淡入
    frame();
    brightness = 8'd191;
    for (f = 0; f < 5; f = f + 1) frame();
    if (dut.lvl != 2'd2) fail($sformatf("fade-in should reach level 2, got %0d", dut.lvl));
    if (dut.hl != 5'b00001) fail($sformatf("brightness row should be highlighted, hl=%b", dut.hl));
    if (diff_in < 20000) fail($sformatf("panel area mostly unchanged (%0d px)", diff_in));
    if (diff_out != 0) fail($sformatf("%0d pixels outside the panel were modified", diff_out));

    // 3) 满级一帧（给了 +PPM= 时写成 PPM）
    if (ppm != "") begin
        fd = $fopen(ppm, "wb");
        $fwrite(fd, "P6\n640 480\n255\n");
        dump = 1'b1;
    end
    frame();
    if (ppm != "") begin
        dump = 1'b0;
        $fclose(fd);
    end

    // 串口屏改曲目 -> 背景音乐行高亮
    status_sd[6] = 1'b1;
    frame(); frame();
    if (dut.hl != 5'b01000) fail($sformatf("bgm row should be highlighted, hl=%b", dut.hl));
    // 拨码切到"亮度+对比度" -> 两行高亮
    channel = 2'b10;
    frame();
    if (dut.hl != 5'b00011) fail($sformatf("channel 10 should highlight two rows, hl=%b", dut.hl));

    // 4) 计时结束后淡出
    for (f = 0; f < 14; f = f + 1) frame();
    if (dut.lvl != 2'd0) fail($sformatf("panel should fade out, lvl=%0d", dut.lvl));
    if (diff_in != 0) fail("hidden panel must pass input through");

    if (errors == 0) $display("PASS tb_osd_settings_panel");
    else             $display("FAIL tb_osd_settings_panel: %0d errors", errors);
    $finish;
end

endmodule
