`ifndef BRIGHTNESS_CONTRAST_ADJUST_V
`define BRIGHTNESS_CONTRAST_ADJUST_V
`timescale 1ns/1ps

// ===========================================================================
// brightness_contrast_adjust -- 第13课：实时亮度/对比度调节
//
// 插入位置：top.v 的显示复用器 (vout_data) 与 video_osd_overlay 之间，
//           使 OSD 标题/状态栏/字幕保持全亮，只调图片本身。
//
// 为什么是纯组合、不打拍：
//   video_clk 只有 25 MHz (40ns)，6 个 8x8 乘法器 + 加减 + 饱和链完全跑得动。
//   一旦打拍，就必须把 de/vs 同步延一拍分别送给 video_osd_overlay、
//   video_rgb_to_axis_640x480 和 video_fallback_pattern 三处，对齐极易出错。
//   不打拍 => 零对齐风险，也不需要 out_de 端口。
//
// 参数生效（第13课 2.5）：
//   控制域 (sd_card_clk 100MHz) 的值经 2FF 进来，用 cfg_toggle 边沿做多比特
//   握手，在 vs 上升沿提交。这样一帧之内参数恒定，不会出现上下半帧分界线。
//
// 亮度： (rgb*b + rgb) >> 8  ==  rgb*(b+1)/256
//   b=255 时 (255+1)/256 = 1，逐位精确旁路（第13课 3.2.3 验收第 1 条）；
//   b=0   时输出全黑。用 (b+1) 而不是 b 是刻意的：若用 b/256，b=255 只有
//   0.996，做不到"与输入完全一致"，那条验收直接过不了。
//
// 对比度： sat( floor((bright-128)*c/128) + 128 )，c=128 时逐位等于输入。
//
//   本工程刻意不用 $signed / >>> 算术右移：docs/综合资源超限-原因与修复.md
//   记录过，若综合器的符号处理有出入，结果是"算出错的像素值"而不是报错，
//   比资源问题难查得多。这里用 |d| + 按方向分支实现 floor 取整，与课程参考
//   答案的 $signed 版本逐位等价：
//     d >= 0:  floor(d*c/128) = (d*c) >> 7
//     d <  0:  floor(d*c/128) = -ceil(|d|*c/128) = -((|d|*c + 127) >> 7)
//   （floor(-x) == -ceil(x)，所以两者逐位一致。）
//
// 淡入淡出（fade_gain 0..64，来自 video_transition_controller，只在场消隐里变）：
//   不另加乘法器（DSP 已 29/29 用满），把增益并进每帧只算一次的两个标量里：
//     f9    = ((b+1) * g) >> 6               0..256，g=64 时就是 b+1
//     bright = (x * f9) >> 8                  g=64 时与原式 (x*b + x)>>8 逐位相同
//     c_eff = c >= 128 ? c : c + (((128-c)*(64-g)) >> 6)
//   c<128 时对比度会把黑抬成 128-c 的灰，所以淡到底时把 c 一起拉回 128，保证真黑。
//   两个标量的乘法用移位加（g 只有 7 位），打一拍寄存，不在像素路径上。
// ===========================================================================
module brightness_contrast_adjust (
    input  wire        video_clk,
    input  wire        rst,             // 高有效异步复位（本工程 rst_all 风格）
    input  wire        vs,              // 帧边界
    input  wire [7:0]  brightness_in,   // 控制域来的亮度，已 2FF
    input  wire [7:0]  contrast_in,     // 控制域来的对比度，已 2FF
    input  wire [1:0]  menu_channel_in, // 控制域来的当前通道，已 2FF
    input  wire        menu_active_in,  // 控制域来的菜单显示标志，已 2FF
    input  wire        cfg_toggle,      // 控制域每次改值翻转一次，已 2FF
    input  wire [6:0]  fade_gain,       // 切图淡入淡出增益 0..64，video_clk 域
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,         // 像素路径纯组合，与 rgb_in 同拍
    output reg  [7:0]  brightness_q,    // 帧边界锁存后的亮度（供 OSD 显示）
    output reg  [7:0]  contrast_q,      // 帧边界锁存后的对比度
    output reg  [1:0]  menu_channel_q,  // 帧边界锁存后的当前通道（供 OSD 高亮）
    output reg         menu_active_q    // 帧边界锁存后的菜单显示标志
);

    // ------------------------------------------------------------------
    // 参数：toggle 握手 + 帧边界提交
    // ------------------------------------------------------------------
    reg       vs_d;
    reg       cfg_toggle_d;
    reg [7:0] pend_brightness;
    reg [7:0] pend_contrast;
    reg [1:0] pend_channel;
    reg       pend_active;
    reg       pend_valid;

    wire cfg_event   = (cfg_toggle != cfg_toggle_d);
    wire frame_start = (vs && !vs_d);
    wire commit      = (frame_start && (pend_valid || cfg_event));

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_d            <= 1'b0;
            cfg_toggle_d    <= 1'b0;
            pend_brightness <= 8'd255;
            pend_contrast   <= 8'd128;
            pend_channel    <= 2'b00;
            pend_active     <= 1'b0;
            pend_valid      <= 1'b0;
            brightness_q    <= 8'd255;   // 复位即逐位旁路
            contrast_q      <= 8'd128;
            menu_channel_q  <= 2'b00;
            menu_active_q   <= 1'b0;
        end else begin
            vs_d         <= vs;
            cfg_toggle_d <= cfg_toggle;

            if (commit) begin
                // 帧边界生效；同一拍刚到的新值优先，避免白等一帧。
                // 四个字段一起提交 => 不会出现"亮度已更新、菜单状态还没更新"的撕裂帧。
                brightness_q   <= cfg_event ? brightness_in   : pend_brightness;
                contrast_q     <= cfg_event ? contrast_in     : pend_contrast;
                menu_channel_q <= cfg_event ? menu_channel_in : pend_channel;
                menu_active_q  <= cfg_event ? menu_active_in  : pend_active;
                pend_valid     <= 1'b0;
            end else if (cfg_event) begin
                // 帧中间只挂起，绝不改当前值 => 一帧内参数恒定
                pend_brightness <= brightness_in;
                pend_contrast   <= contrast_in;
                pend_channel    <= menu_channel_in;
                pend_active     <= menu_active_in;
                pend_valid      <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 淡入淡出标量（每拍从寄存器重算一次；输入只在场消隐里变，行内恒定）
    //   a * g，g 为 0..64 的 7 位数：按 g 的每一位移位相加，不推断乘法器
    // ------------------------------------------------------------------
    function [15:0] mul_by_gain;
        input [8:0] a;
        input [6:0] g;
        begin
            mul_by_gain = (g[0] ? {7'd0, a}       : 16'd0)
                        + (g[1] ? {6'd0, a, 1'b0} : 16'd0)
                        + (g[2] ? {5'd0, a, 2'b0} : 16'd0)
                        + (g[3] ? {4'd0, a, 3'b0} : 16'd0)
                        + (g[4] ? {3'd0, a, 4'b0} : 16'd0)
                        + (g[5] ? {2'd0, a, 5'b0} : 16'd0)
                        + (g[6] ? {1'd0, a, 6'b0} : 16'd0);
        end
    endfunction

    wire [6:0]  gain_lim = (fade_gain > 7'd64) ? 7'd64 : fade_gain;
    wire [15:0] f9_prod  = mul_by_gain({1'b0, brightness_q} + 9'd1, gain_lim);
    wire [15:0] cr_prod  = mul_by_gain({1'b0, 8'd128 - contrast_q}, 7'd64 - gain_lim);

    reg  [8:0] f9_q;       // (b+1)*g/64，0..256
    reg  [7:0] c_eff_q;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            f9_q    <= 9'd256;
            c_eff_q <= 8'd128;
        end else begin
            f9_q    <= f9_prod[14:6];
            c_eff_q <= contrast_q[7] ? contrast_q : (contrast_q + cr_prod[13:6]);
        end
    end

    // ------------------------------------------------------------------
    // 亮度：x * f9 / 256（f9 = b+1 时即 x*(b+1)/256）
    //   mul 最大 255*256 = 65280 < 65536，16 位不回绕
    // ------------------------------------------------------------------
    wire [15:0] mul_r = rgb_in[23:16] * f9_q;
    wire [15:0] mul_g = rgb_in[15:8]  * f9_q;
    wire [15:0] mul_b = rgb_in[7:0]   * f9_q;

    wire [7:0] bright_r = mul_r[15:8];
    wire [7:0] bright_g = mul_g[15:8];
    wire [7:0] bright_b = mul_b[15:8];

    // ------------------------------------------------------------------
    // 对比度：以 128 为中心拉伸，再饱和截断到 0..255
    // ------------------------------------------------------------------
    function [7:0] contrast_channel;
        input [7:0] x;
        input [7:0] c;
        reg         dir_ge;
        reg  [7:0]  d_abs;
        reg  [15:0] prod;
        reg  [15:0] prod_ceil;
        reg  [8:0]  sum_hi;
        begin
            dir_ge = (x >= 8'd128);
            d_abs  = dir_ge ? (x - 8'd128) : (8'd128 - x);
            prod   = d_abs * c;

            if (dir_ge) begin
                // 128 + floor(prod/128)；d_abs<=127 => prod<=32385 => 商<=253
                // 9 位加法最大 128+253=381 < 512，不回绕
                sum_hi = 9'd128 + {1'b0, prod[14:7]};
                contrast_channel = (sum_hi > 9'd255) ? 8'd255 : sum_hi[7:0];
            end else begin
                // 128 - ceil(prod/128)；d_abs<=128 => prod<=32640 => ceil<=255
                prod_ceil = (prod + 16'd127) >> 7;
                contrast_channel = (prod_ceil >= 16'd128) ? 8'd0
                                                          : (8'd128 - prod_ceil[7:0]);
            end
        end
    endfunction

    wire [7:0] final_r = contrast_channel(bright_r, c_eff_q);
    wire [7:0] final_g = contrast_channel(bright_g, c_eff_q);
    wire [7:0] final_b = contrast_channel(bright_b, c_eff_q);

    assign rgb_out = {final_r, final_g, final_b};

endmodule
`endif
