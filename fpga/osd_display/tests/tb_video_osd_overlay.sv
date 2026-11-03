`timescale 1ns/1ps
// video_osd_overlay 测试：真实 de/vs 时序逐帧扫描，与参考模型逐像素比对。
//   参考模型直接读 rtl/video/osd_font16.dat（与 RTL 同一份字库），按版面算出每个像素的
//   期望值：顶栏信息行 / 滚动字幕（自定义 RAM 内容 + 滚动偏移）/ 状态栏 5 种状态 / 时钟。
//   另用一个 CLK_HZ = 10 的实例单独测走时与校时。
// 运行（在 fpga/osd_display 下）：
//   iverilog -g2012 -s tb_video_osd_overlay -o o.vvp tests/tb_video_osd_overlay.sv \
//            rtl/video/video_osd_overlay.v rtl/video/osd_font_rom.v && vvp o.vvp
module tb_video_osd_overlay;

reg clk = 1'b0;
reg rst = 1'b1;
always #20 clk = ~clk;

reg        vs = 1'b0, de = 1'b0;
reg [9:0]  px = 10'd0, py = 10'd0;
wire [23:0] rgb_in = {px[7:0], py[7:0], px[9:2] ^ py[9:2]};

reg        display_valid = 1'b1;
reg        display_test_pattern = 1'b0;
reg        storage_ready = 1'b1;
reg [2:0]  manager_state = 3'd2;
reg        load_in_progress = 1'b0;
reg [2:0]  target_image_index = 3'd1;
reg [2:0]  current_image_index = 3'd3;
reg [3:0]  image_count = 4'd6;
reg        ticker_enable = 1'b1;
reg        ticker_custom = 1'b1;
reg        ticker_wr_en = 1'b0;
reg [5:0]  ticker_wr_addr = 6'd0;
reg [7:0]  ticker_wr_data = 8'd0;
reg        time_set = 1'b0;
reg [4:0]  time_h = 5'd0;
reg [5:0]  time_m = 6'd0;
reg [5:0]  time_s = 6'd0;

// 顶栏 40 字符（含小写、标点，验证整套 ASCII 都走字库）
localparam string INFO = "OUT 640X480  IMG 1280X960  scale 0.50 ok";
// 字幕 64 字符：含 RAM 里可能出现的非 ASCII 码（0x9F、0x0A 必须按空格画）
localparam string TICK = "Hello FPGA! (OSD) 2026-10-30 +/-=_ [x] @home {ok} ~ JQVZ jqvz 01";
wire [5:0] info_addr;
reg  [7:0] info_ram [0:63];          // iverilog 不支持对 string 按信号下标做连续赋值，先展开
wire [7:0] info_char = info_ram[info_addr];

wire [10:0] font_addr;
wire [15:0] font_q;
wire [23:0] rgb_out;

osd_font_rom u_font (
    .clk(clk), .addr_a(11'd0), .dout_a(), .addr_b(font_addr), .dout_b(font_q)
);

video_osd_overlay dut (
    .video_clk            (clk),
    .rst                  (rst),
    .vs                   (vs),
    .de                   (de),
    .rgb_in               (rgb_in),
    .display_valid        (display_valid),
    .display_test_pattern (display_test_pattern),
    .storage_ready        (storage_ready),
    .manager_state        (manager_state),
    .load_in_progress     (load_in_progress),
    .target_image_index   (target_image_index),
    .current_image_index  (current_image_index),
    .image_count          (image_count),
    .info_addr            (info_addr),
    .info_char            (info_char),
    .time_set             (time_set),
    .time_h               (time_h),
    .time_m               (time_m),
    .time_s               (time_s),
    .ticker_enable        (ticker_enable),
    .ticker_custom        (ticker_custom),
    .ticker_wr_clk        (clk),
    .ticker_wr_en         (ticker_wr_en),
    .ticker_wr_addr       (ticker_wr_addr),
    .ticker_wr_data       (ticker_wr_data),
    .font_addr            (font_addr),
    .font_q               (font_q),
    .rgb_out              (rgb_out)
);

// ---- 走时专用实例：CLK_HZ = 10，每 10 拍 1 秒 ----
reg  [4:0] t_h; reg [5:0] t_m, t_s;
video_osd_overlay #(.CLK_HZ(10)) dut_clk (
    .video_clk(clk), .rst(rst), .vs(1'b0), .de(1'b0), .rgb_in(24'd0),
    .display_valid(1'b1), .display_test_pattern(1'b0), .storage_ready(1'b1),
    .manager_state(3'd2), .load_in_progress(1'b0), .target_image_index(3'd0),
    .current_image_index(3'd0), .image_count(4'd1), .info_addr(), .info_char(8'h20),
    .time_set(time_set), .time_h(time_h), .time_m(time_m), .time_s(time_s),
    .ticker_enable(1'b1), .ticker_custom(1'b0), .ticker_wr_clk(clk), .ticker_wr_en(1'b0),
    .ticker_wr_addr(6'd0), .ticker_wr_data(8'd0), .font_addr(), .font_q(16'd0), .rgb_out()
);

// ---------------------------------------------------------------------------
// 参考模型
// ---------------------------------------------------------------------------
reg [15:0] font [0:2047];
reg [7:0]  tick_ram [0:63];
string     status_str;
reg [23:0] status_col;
string     clock_str;

localparam [23:0] BAR_RGB = 24'h10213A;

function automatic [23:0] blend(input [23:0] img);
    blend[23:16] = {2'b00, BAR_RGB[23:18]} + {1'b0, BAR_RGB[23:17]} + {2'b00, img[23:18]};
    blend[15:8]  = {2'b00, BAR_RGB[15:10]} + {1'b0, BAR_RGB[15:9]}  + {2'b00, img[15:10]};
    blend[7:0]   = {2'b00, BAR_RGB[7:2]}   + {1'b0, BAR_RGB[7:1]}   + {2'b00, img[7:2]};
endfunction

function automatic bit glyph(input [7:0] code, input integer row, input integer col);
    reg [6:0] g;
    g = ((code < 8'h20) || code[7]) ? 7'h20 : code[6:0];
    glyph = font[{g, row[3:0]}][15 - col];
endfunction

function automatic [7:0] str_at(input string s, input integer i);
    str_at = (i < s.len()) ? s[i] : 8'h20;
endfunction

function automatic [23:0] expect_px(input integer x, input integer y, input [23:0] img,
                                    input integer off, input bit ticker_on);
    integer p;
    expect_px = img;
    if (y < 24) begin
        expect_px = blend(img);
        if ((y >= 4) && (y < 20) && (x >= 16) && (x < 336) &&
            glyph(str_at(INFO, (x - 16) / 8), y - 4, (x - 16) % 8))
            expect_px = 24'hF4F7FB;
    end else if (ticker_on && (y >= 432) && (y < 456)) begin
        expect_px = blend(img);
        p = (x + off) % 512;
        if ((y >= 436) && (y < 452) && (x != 0) &&
            glyph(tick_ram[p / 8], y - 436, p % 8))
            expect_px = 24'hFFD166;
    end else if (y >= 456) begin
        expect_px = blend(img);
        if (((y >= 464) && (y < 472) && (x >= 8) && (x < 16)) ||
            ((y >= 460) && (y < 476) && (x >= 24) && (x < 104) &&
             glyph(str_at(status_str, (x - 24) / 8), y - 460, (x - 24) % 8)))
            expect_px = status_col;
        else if ((y >= 460) && (y < 476) && (x >= 552) && (x < 616) &&
                 glyph(str_at(clock_str, (x - 552) / 8), y - 460, (x - 552) % 8))
            expect_px = 24'hF4F7FB;
    end
endfunction

// ---------------------------------------------------------------------------
integer errors = 0;
integer lit;                         // 本帧亮起的文字像素数（防止"全不画也通过"）

task automatic fail(input string msg);
    begin
        errors = errors + 1;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    end
endtask

// 跑一帧并逐像素比对
task automatic frame(input string tag);
    integer l, c, off;
    reg [23:0] exp_rgb;
    begin
        lit = 0;
        @(negedge clk); vs = 1'b1;
        repeat (2 * 672) @(negedge clk);
        vs = 1'b0;
        repeat (32) @(negedge clk);
        off = dut.ticker_scroll_offset;
        for (l = 0; l < 480; l = l + 1) begin
            for (c = 0; c < 640; c = c + 1) begin
                px = c; py = l; de = 1'b1;
                #1;
                exp_rgb = expect_px(c, l, rgb_in, off, ticker_enable);
                if (rgb_out !== exp_rgb)
                    fail($sformatf("%s x=%0d y=%0d got %h expect %h", tag, c, l, rgb_out, exp_rgb));
                if ((exp_rgb == 24'hF4F7FB) || (exp_rgb == 24'hFFD166) || (exp_rgb == status_col))
                    lit = lit + 1;
                @(negedge clk);
            end
            de = 1'b0;
            #1;
            if (rgb_out !== rgb_in) fail($sformatf("%s blanking y=%0d", tag, l));
            repeat (32) @(negedge clk);
        end
        if (lit < 500) fail($sformatf("%s: only %0d text pixels lit", tag, lit));
    end
endtask

task automatic set_time(input [4:0] h, input [5:0] m, input [5:0] s);
    begin
        @(negedge clk);
        time_h = h; time_m = m; time_s = s; time_set = 1'b1;
        @(negedge clk);
        time_set = 1'b0;
    end
endtask

integer i;
initial begin
    $readmemb("rtl/video/osd_font16.dat", font);
    for (i = 0; i < 64; i = i + 1) tick_ram[i] = str_at(TICK, i);
    for (i = 0; i < 64; i = i + 1) info_ram[i] = str_at(INFO, i);
    tick_ram[5]  = 8'h9F;            // 非 ASCII -> 空格
    tick_ram[17] = 8'h0A;            // 控制字符 -> 空格

    repeat (3) @(negedge clk);
    rst = 1'b0;
    // 写字幕 RAM
    for (i = 0; i < 64; i = i + 1) begin
        @(negedge clk);
        ticker_wr_en = 1'b1; ticker_wr_addr = i; ticker_wr_data = tick_ram[i];
    end
    @(negedge clk);
    ticker_wr_en = 1'b0;
    set_time(5'd12, 6'd34, 6'd56);
    clock_str = "12:34:56";

    // 1) IMAGE 4/6（滚动偏移 0）
    status_str = "IMAGE 4/6"; status_col = 24'h54E3E3;
    frame("image");

    // 2) 滚动偏移不是 8 的倍数时字幕按像素滚动
    dut.ticker_scroll_offset = 9'd509;
    dut.ticker_frame_divider = 2'd0;
    load_in_progress = 1'b1; target_image_index = 3'd1;
    status_str = "LOAD 2/6"; status_col = 24'h7EE787;
    frame("load+scroll");

    // 3) SCAN / WAIT / FALLBACK 三种状态与颜色
    load_in_progress = 1'b0; manager_state = 3'd1;
    status_str = "SCAN"; status_col = 24'hA7C7FF;
    frame("scan");
    storage_ready = 1'b0;
    status_str = "WAIT TF"; status_col = 24'hFF6B6B;
    frame("wait");
    display_test_pattern = 1'b1;
    status_str = "FALLBACK"; status_col = 24'hFFD166;
    set_time(5'd23, 6'd5, 6'd9);
    clock_str = "23:05:09";
    frame("fallback");

    // 4) 关字幕：字幕带透明
    display_test_pattern = 1'b0; storage_ready = 1'b1; manager_state = 3'd2;
    status_str = "IMAGE 4/6"; status_col = 24'h54E3E3;
    ticker_enable = 1'b0;
    frame("ticker off");    // 字幕开关有 2 拍同步，帧前早已生效
    ticker_enable = 1'b1;

    // 5) 字幕每 3 帧滚 1 像素、512 回绕
    dut.ticker_scroll_offset = 9'd511;
    dut.ticker_frame_divider = 2'd0;
    for (i = 0; i < 3; i = i + 1) begin
        @(negedge clk); vs = 1'b1; @(negedge clk); vs = 1'b0;
    end
    if (dut.ticker_scroll_offset !== 9'd0)
        fail($sformatf("ticker should wrap to 0 after 3 frames, got %0d", dut.ticker_scroll_offset));

    // 6) 走时（CLK_HZ = 10）：23:59:58 -> 59 -> 00:00:00；超范围校时忽略
    set_time(5'd23, 6'd59, 6'd58);
    if ({dut_clk.clk_h, dut_clk.clk_m, dut_clk.clk_s} !== {5'd23, 6'd59, 6'd58}) fail("time_set load");
    repeat (10) @(negedge clk);
    if (dut_clk.clk_s !== 6'd59) fail($sformatf("second tick: %0d", dut_clk.clk_s));
    repeat (10) @(negedge clk);
    if ({dut_clk.clk_h, dut_clk.clk_m, dut_clk.clk_s} !== 17'd0) fail("midnight wrap");
    set_time(5'd24, 6'd0, 6'd0);
    if (dut_clk.clk_h === 5'd24) fail("out-of-range time accepted");

    if (errors == 0) $display("PASS tb_video_osd_overlay");
    else             $display("FAIL tb_video_osd_overlay: %0d errors", errors);
    $finish;
end

endmodule
