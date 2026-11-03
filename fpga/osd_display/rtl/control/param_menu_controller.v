`ifndef PARAM_MENU_CONTROLLER_V
`define PARAM_MENU_CONTROLLER_V
`timescale 1ns/1ps

// ===========================================================================
// param_menu_controller -- 亮度/对比度参数菜单控制器（第13课）
//
// 时钟域：sd_card_clk (100 MHz)
// 复位  ：rst_all，高有效异步（与本工程既有写法一致）
//
// 硬件极性（依据官方例程 HX4S20_Contest_202606：KEY 与 SW 的 .adc 全部
// PULLTYPE = PULLUP，见 cnt10.adc:10-12,21-24）：
//   key : 低有效（按下 = 0）
//   sw  : 低有效（合上 = 0）；顶层已取反，送入本模块的是"逻辑值"，1 = 合上
//
// 拨码定义（sw 为逻辑值，1 = 拨上，依据开发板手册 2.19 节）：
//   sw[1:0] : 00 = 调亮度   01 = 调对比度
//             10 = 亮度+对比度一起调   11 = 恢复默认 + 音量档
//   sw[3:2] : 00 = 步长 1   01 = 步长 4     10 = 步长 16   11 = 步长 32
//
// 注意：四个通道档位全部有实际作用，**不设"保留"档**。早期版本把 11 做成
// "保留/按键忽略"，结果"四个开关全拨上"这个最自然的位置按什么都没反应，
// 上板时被误判成功能坏了。
//
// 按键（KEY3）：
//   短按（松手时未达长按阈值）              -> 当前通道 += 步长
//   长按（按住 >= LONG_PRESS_MS，松手时判定）-> 当前通道 -= 步长
//   sw[1:0] = 11 时：拨进该档时亮度/对比度恢复一次默认值，KEY3 短按 = 音量 +1 档，长按 = -1 档
//   （0..8 档，0 = 静音，8 = 原音量，每档 6 dB；默认 VOLUME_DEFAULT）
//
// 音量命令口（给串口屏用，同一时钟域的单拍命令，优先于 KEY3）：
//   vol_cmd_valid 单拍有效；vol_cmd_target 0 = 音乐音量，1 = 提示音音量；
//   vol_cmd_op    00 = 设为 vol_cmd_value（>8 按 8），01 = +1 档，10 = -1 档，11 = 恢复默认
//   两路音量都是 0..8 档饱和，不回绕。
//
// 亮度/对比度命令口（给串口屏用，同域单拍命令）：
//   bc_cmd_valid 单拍有效；bc_cmd_target 0 = 亮度，1 = 对比度；bc_cmd_value 为目标值 0..255。
//   命令先挂起，等 cfg_toggle 最小间隔到了再和按键一起提交，不会因间隔未到而丢失。
//   sw[1:0] = 11（恢复默认）时命令照常生效：默认值只在拨进 11 时恢复一次。
//
// ---------------------------------------------------------------------------
// 三个必须守住的设计点（都是踩过坑才写进来的）：
//
// 1. 长按只在"松手那一刻"判定：按住期间只打 long_fired 标记。
//    否则按住 1 秒会先减一次、松手又减一次，一次长按扣两次。
//
// 2. 加/减两端都饱和钳位（上限 255 / 下限 0），绝不用回绕 ——
//    回绕会让 255+1 变成 0，屏幕直接黑掉。
//
// 3. 跨时钟域握手：cfg_toggle 每翻转一次代表配置包变化一次。接收端(video_clk
//    25MHz)靠"本次采样值 != 上次采样值"检边沿，所以**两次翻转之间必须留够时间**，
//    否则偶数次翻转会被接收端看成没变化，更新直接丢失。为此做两道保险：
//      a) menu_active 与亮度/对比度在同一拍内一起提交（不是晚一拍），
//         保证"一次操作 = 一次翻转"；
//      b) TOGGLE_SPACING_CYCLES 限制两次翻转的最小间隔（16 个 100MHz 周期
//         = 160ns > 4 个 video_clk 周期），极端情况下也不会连翻两次。
//    拨码开关也必须消抖（见下），否则机械抖动会在几毫秒内产生成千上万次翻转。
// ===========================================================================
module param_menu_controller #(
    parameter integer CLK_FREQ_HZ     = 100_000_000,
    parameter integer DEBOUNCE_MS     = 20,     // 按键消抖
    parameter integer SW_DEBOUNCE_MS  = 10,     // 拨码采样周期（连续两次一致才认）
    parameter integer LONG_PRESS_MS   = 1000,
    parameter integer MENU_HOLD_MS    = 5000,
    parameter [7:0]   BRIGHTNESS_DEFAULT = 8'd255,
    parameter [7:0]   CONTRAST_DEFAULT   = 8'd128,
    parameter [3:0]   VOLUME_DEFAULT     = 4'd3,   // 3 档 = 屏显 38%
    parameter [3:0]   TONE_VOLUME_DEFAULT = 4'd3
)(
    input  wire       clk,
    input  wire       rst,           // 高有效异步
    input  wire       key,           // KEY3，低有效
    input  wire [3:0] sw,            // 逻辑值，1 = 合上
    output wire [7:0] brightness,
    output wire [7:0] contrast,
    output wire [1:0] menu_channel,  // 当前调节通道，供 OSD 高亮
    output wire       menu_active,   // 最近一次操作后保持 MENU_HOLD_MS
    output wire       cfg_toggle,    // 每次配置变化翻转一次（跨时钟域握手）
    output reg  [3:0] volume,        // 音量档 0..8（慢变，接收端两次采样一致即可）
    output wire       key_down,      // KEY3 已消抖按下（给按键提示音）
    input  wire       vol_cmd_valid,
    input  wire       vol_cmd_target,
    input  wire [1:0] vol_cmd_op,
    input  wire [3:0] vol_cmd_value,
    output reg  [3:0] tone_volume,   // 提示音音量档 0..8
    input  wire       bc_cmd_valid,
    input  wire       bc_cmd_target,
    input  wire [7:0] bc_cmd_value
);

    localparam integer DEBOUNCE_CYCLES   = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer SW_TICK_CYCLES    = (CLK_FREQ_HZ / 1000) * SW_DEBOUNCE_MS;
    localparam integer LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
    localparam integer MENU_HOLD_CYCLES  = (CLK_FREQ_HZ / 1000) * MENU_HOLD_MS;

    // 两次 cfg_toggle 翻转之间的最小间隔（100MHz 周期数）
    // 16 个周期 = 160ns，远大于 video_clk 的 40ns 周期，接收端一定能采到中间值
    localparam [4:0] TOGGLE_SPACING = 5'd16;

    // ------------------------------------------------------------------
    // 拨码开关消抖：每 SW_DEBOUNCE_MS 采样一次，连续两次一致才认可
    // （机械抖动通常 < 1ms，10ms 采样周期足够滤掉）
    // ------------------------------------------------------------------
    reg [31:0] sw_tick;
    reg [3:0]  sw_prev;
    reg [3:0]  sw_stable;

    wire sw_tick_pulse = (sw_tick >= SW_TICK_CYCLES - 1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_tick   <= 32'd0;
            sw_prev   <= 4'd0;
            sw_stable <= 4'd0;
        end else if (sw_tick_pulse) begin
            sw_tick <= 32'd0;
            sw_prev <= sw;
            if (sw == sw_prev)
                sw_stable <= sw;
        end else begin
            sw_tick <= sw_tick + 32'd1;
        end
    end

    reg [3:0] sw_stable_d;
    always @(posedge clk or posedge rst) begin
        if (rst) sw_stable_d <= 4'd0;
        else     sw_stable_d <= sw_stable;
    end
    wire sw_changed = (sw_stable != sw_stable_d);

    wire [1:0] sel_ch = sw_stable[1:0];

    // ------------------------------------------------------------------
    // 按键：2FF 同步 + 消抖（低有效，空闲 = 1）
    // ------------------------------------------------------------------
    reg        key_s0;
    reg        key_s1;
    reg        key_stable;
    reg [31:0] db_counter;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_s0     <= 1'b1;
            key_s1     <= 1'b1;
            key_stable <= 1'b1;      // 空闲电平 = 松开
            db_counter <= 32'd0;
        end else begin
            key_s0 <= key;
            key_s1 <= key_s0;

            if (key_s1 == key_stable) begin
                db_counter <= 32'd0;
            end else if (db_counter >= DEBOUNCE_CYCLES - 1) begin
                key_stable <= key_s1;
                db_counter <= 32'd0;
            end else begin
                db_counter <= db_counter + 32'd1;
            end
        end
    end

    // 松手沿（key_stable_d 复位为 1，避免复位释放时产生一次假"松手"）
    reg key_stable_d;
    always @(posedge clk or posedge rst) begin
        if (rst) key_stable_d <= 1'b1;
        else     key_stable_d <= key_stable;
    end
    wire key_release = (key_stable && !key_stable_d);
    assign key_down  = !key_stable;

    // ------------------------------------------------------------------
    // 长按计时：按住期间只打标记，松手才用
    // ------------------------------------------------------------------
    reg [31:0] hold_counter;
    reg        long_fired;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hold_counter <= 32'd0;
            long_fired   <= 1'b0;
        end else if (!key_stable) begin
            if (hold_counter < LONG_PRESS_CYCLES)
                hold_counter <= hold_counter + 32'd1;
            if (hold_counter >= LONG_PRESS_CYCLES - 1)
                long_fired <= 1'b1;
        end else begin
            hold_counter <= 32'd0;
            long_fired   <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 菜单保持窗口：复位后视为已超时（不显示），有操作就重新计时
    // ------------------------------------------------------------------
    reg [31:0] menu_timer;

    // 一次"操作"：拨码变化，或按键松手（11 档调音量也算，便于数码管显示）
    wire menu_event = sw_changed || key_release;

    function [3:0] vol_apply;
        input [3:0] cur;
        input [1:0] op;
        input [3:0] val;
        input [3:0] dflt;
        begin
            case (op)
                2'b00:   vol_apply = (val > 4'd8) ? 4'd8 : val;
                2'b01:   vol_apply = (cur < 4'd8) ? cur + 4'd1 : 4'd8;
                2'b10:   vol_apply = (cur != 4'd0) ? cur - 4'd1 : 4'd0;
                default: vol_apply = dflt;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            volume      <= VOLUME_DEFAULT;
            tone_volume <= TONE_VOLUME_DEFAULT;
        end else if (vol_cmd_valid) begin
            if (vol_cmd_target)
                tone_volume <= vol_apply(tone_volume, vol_cmd_op, vol_cmd_value, TONE_VOLUME_DEFAULT);
            else
                volume      <= vol_apply(volume, vol_cmd_op, vol_cmd_value, VOLUME_DEFAULT);
        end else if (key_release && (sel_ch == 2'b11)) begin
            if (long_fired) begin
                if (volume != 4'd0)
                    volume <= volume - 4'd1;
            end else if (volume < 4'd8) begin
                volume <= volume + 4'd1;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            menu_timer <= MENU_HOLD_CYCLES;
        end else if (menu_event) begin
            menu_timer <= 32'd0;
        end else if (menu_timer < MENU_HOLD_CYCLES) begin
            menu_timer <= menu_timer + 32'd1;
        end
    end

    wire menu_active_now = (menu_timer < MENU_HOLD_CYCLES);

    // ------------------------------------------------------------------
    // 步长与加减（两端钳位）
    // ------------------------------------------------------------------
    function [7:0] step_lut;
        input [1:0] sel;
        begin
            case (sel)
                2'b00:   step_lut = 8'd1;
                2'b01:   step_lut = 8'd4;
                2'b10:   step_lut = 8'd16;
                default: step_lut = 8'd32;
            endcase
        end
    endfunction

    wire [7:0] step = step_lut(sw_stable[3:2]);

    // ------------------------------------------------------------------
    // cfg 寄存器：{menu_channel[1:0], menu_active, contrast[7:0], brightness[7:0]}
    // ------------------------------------------------------------------
    reg [18:0] cfg;
    reg        cfg_toggle_r;
    reg [4:0]  spacing;

    wire [7:0] cur_b  = cfg[7:0];
    wire [7:0] cur_c  = cfg[15:8];
    wire [1:0] cur_ch = cfg[18:17];

    // 时序（100 MHz）：加减钳位先寄存一拍，不再和 next_cfg 比较、cfg 使能串在
    // 一拍里（原来 -1.05ns）。cur_b/cur_c 每次变化后有 TOGGLE_SPACING 拍间隔，
    // 这期间按键本来就不会提交，所以晚一拍不影响结果。
    reg [7:0] b_plus;
    reg [7:0] b_minus;
    reg [7:0] c_plus;
    reg [7:0] c_minus;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            b_plus  <= 8'd0;
            b_minus <= 8'd0;
            c_plus  <= 8'd0;
            c_minus <= 8'd0;
        end else begin
            b_plus  <= (cur_b > (8'd255 - step)) ? 8'd255 : (cur_b + step);
            b_minus <= (cur_b > step)            ? (cur_b - step) : 8'd0;
            c_plus  <= (cur_c > (8'd255 - step)) ? 8'd255 : (cur_c + step);
            c_minus <= (cur_c > step)            ? (cur_c - step) : 8'd0;
        end
    end

    reg [7:0] next_b;
    reg [7:0] next_c;
    reg [1:0] next_ch;
    reg       next_active;

    // 串口屏命令挂起（见文件头）
    reg       bc_pend_b;
    reg       bc_pend_c;
    reg [7:0] bc_val_b;
    reg [7:0] bc_val_c;
    reg       def_pend;        // 刚拨进 11，待恢复默认

    always @* begin
        next_b  = cur_b;
        next_c  = cur_c;
        next_ch = cur_ch;

        // 关键：本拍有操作事件就立刻点亮菜单，与数值变化同一拍提交，
        // 保证"一次操作 = cfg 变化一次 = cfg_toggle 翻转一次"
        next_active = menu_event ? 1'b1 : menu_active_now;

        if (sel_ch == 2'b11) begin
            // 恢复默认：只在拨进 11 的那一次恢复默认值，之后串口屏命令照常生效
            // （早期版本持续强制默认值，四个开关全拨上时串口屏调不了亮度/对比度）
            if (def_pend) begin
                next_b = BRIGHTNESS_DEFAULT;
                next_c = CONTRAST_DEFAULT;
            end
            next_ch = 2'b11;
            if (bc_pend_b)
                next_b = bc_val_b;
            if (bc_pend_c)
                next_c = bc_val_c;
        end else begin
            next_ch = sel_ch;
            if (key_release) begin
                // 00 = 只调亮度，01 = 只调对比度，10 = 两个一起调
                if (sel_ch != 2'b01)
                    next_b = long_fired ? b_minus : b_plus;
                if (sel_ch != 2'b00)
                    next_c = long_fired ? c_minus : c_plus;
            end
            if (bc_pend_b)
                next_b = bc_val_b;
            if (bc_pend_c)
                next_c = bc_val_c;
        end
    end

    wire [18:0] next_cfg   = {next_ch, next_active, next_c, next_b};
    wire        cfg_change = (next_cfg != cfg);
    wire        spacing_ok = (spacing == 5'd0);

    // 间隔到了的那一拍，挂起值要么随 next_cfg 提交、要么与当前值相同，都可以清掉
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bc_pend_b <= 1'b0;
            bc_pend_c <= 1'b0;
            bc_val_b  <= 8'd0;
            bc_val_c  <= 8'd0;
            def_pend  <= 1'b0;
        end else begin
            if (sw_changed && (sel_ch == 2'b11) && (sw_stable_d[1:0] != 2'b11))
                def_pend <= 1'b1;
            else if (spacing_ok)
                def_pend <= 1'b0;
            if (bc_cmd_valid && !bc_cmd_target) begin
                bc_pend_b <= 1'b1;
                bc_val_b  <= bc_cmd_value;
            end else if (spacing_ok) begin
                bc_pend_b <= 1'b0;
            end
            if (bc_cmd_valid && bc_cmd_target) begin
                bc_pend_c <= 1'b1;
                bc_val_c  <= bc_cmd_value;
            end else if (spacing_ok) begin
                bc_pend_c <= 1'b0;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cfg          <= {2'b00, 1'b0, CONTRAST_DEFAULT, BRIGHTNESS_DEFAULT};
            cfg_toggle_r <= 1'b0;
            spacing      <= 5'd0;
        end else begin
            if (spacing != 5'd0)
                spacing <= spacing - 5'd1;

            // 最小间隔未到就先不改：next_cfg 是组合值，间隔一到自然提交
            if (cfg_change && spacing_ok) begin
                cfg          <= next_cfg;
                cfg_toggle_r <= ~cfg_toggle_r;
                spacing      <= TOGGLE_SPACING;
            end
        end
    end

    assign brightness   = cfg[7:0];
    assign contrast     = cfg[15:8];
    assign menu_active  = cfg[16];
    assign menu_channel = cfg[18:17];
    assign cfg_toggle   = cfg_toggle_r;

endmodule

// ===========================================================================
// screen_uart_link -- 大彩 DC80480A070 串口屏链路（sd_card_clk 100 MHz 域）
//
// 协议依据：串口屏工程 VisualTFT工程/FPGA接口文档.md（V4.0，与本模块同步修订）
//   串口 115200 8N1，无 CRC，多字节大端。
//   屏 -> FPGA：
//     A5 5A 03 GG CC SS          固定 6 字节业务帧，SS = GG + CC
//       GG=20: 01 轮播开关  02 下一张  03 上一张  04 间隔循环 1/2/3/5 s
//              11/12/13/15 直接设间隔 1/2/3/5 s
//              05 切歌（两首之间切换）  21/22 直接选曲目 1/2
//       GG=30: 01/02 亮度 -/+1%   03/04 对比度 -/+1%   05/06 音量 -/+1 档
//     EE B1 11 00 PP 00 CC 10 01 ST FF FC FF FF   按钮/开关
//     EE B1 11 00 03 00 CC 13 V3 V2 V1 V0 ...     滑块（0..100）
//     EE B1 11 00 PP 00 CC 11 <TEXT> 00 ...       文本
//     EE F7 YY MM WW DD hh mm ss FF FC FF FF      RTC（BCD）
//     EE 07 FF FC FF FF                           屏幕复位报告 -> 重新同步
//   FPGA -> 屏：B1 10 写控件、B1 11 读控件、B1 23 图标帧、82 读 RTC、60 背光。
//
// 结构：
//   uart_rx/uart_tx（2FF 同步、中点采样）-> 帧解析 -> 事件处理（寄存器 + 单拍命令）
//   回写：NMSG 个 dirty 位，一个发送状态机按优先级逐条发送，每字节 4 拍流水生成。
//
// 数值映射（只用移位加法，DSP 已用满）：
//   亮度/对比度  p(0..100) -> v(0..255)：v = (p*653 + 128) >> 8
//                v -> p：p = (v*401 + 512) >> 10，v*401 = v<<8 + v<<7 + v<<4 + v
//   音量         p -> 档(0..8)：按 6/19/31/44/56/69/81/94 阈值取整
//                档 -> p：0 13 25 38 50 63 75 88 100
// ===========================================================================
module screen_uart_link #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD        = 115200,
    parameter integer BOOT_MS     = 500,     // 上电后首次全量同步
    parameter integer RESYNC_MS   = 1500,    // 第二次全量同步
    parameter integer DEBOUNCE_MS = 100      // 滑块拖动停止后才回写
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx,
    output reg         uart_tx,

    // ---- 系统状态（同域）----
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [3:0]  volume,
    input  wire        auto_play_enabled,
    input  wire [2:0]  auto_period_sec,
    input  wire        display_valid,
    input  wire [2:0]  current_image_index,
    input  wire [3:0]  image_count,
    input  wire        name_wr,
    input  wire [2:0]  name_slot,
    input  wire [87:0] name_data,
    input  wire        bgm_track_now,     // 实际在播曲目 0/1（存储适配器回报）
    input  wire [1:0]  bgm_track_count,   // 卡上曲目数 0..2
    output reg         bgm_track_sel,     // 选曲电平，送存储适配器

    // ---- 单拍命令 ----
    output reg         cmd_next,
    output reg         cmd_prev,
    output reg         cmd_auto_toggle,
    output reg         cmd_period_valid,
    output reg  [2:0]  cmd_period,
    output reg         bc_cmd_valid,
    output reg         bc_cmd_target,
    output reg  [7:0]  bc_cmd_value,
    output reg         vol_cmd_valid,
    output reg         vol_cmd_target,    // 0 = 音乐音量，1 = 提示音音量
    output reg  [3:0]  vol_cmd_value,

    // ---- 电平状态 ----
    output reg         user_mute,
    output reg         visualizer_en,
    output reg         ticker_en,
    output reg         transition_fade,   // 1 = 淡入淡出，0 = 左右滑动
    output reg         ticker_custom,
    output reg         ticker_wr_en,
    output reg  [5:0]  ticker_wr_addr,
    output reg  [7:0]  ticker_wr_data,
    output reg         screen_off,        // 定时息屏
    output reg         rtc_valid,
    output reg         time_toggle,       // 每次得到有效 RTC 时间翻转一次
    output reg  [4:0]  time_h,
    output reg  [5:0]  time_m,
    output reg  [5:0]  time_s
);

localparam integer BIT_CYCLES  = CLK_FREQ_HZ / BAUD;
localparam integer HALF_CYCLES = BIT_CYCLES / 2;
localparam integer MS_CYCLES   = CLK_FREQ_HZ / 1000;
// 位计数器 10 位：BIT_CYCLES 须 < 1024（100 MHz / 115200 = 868）

// ===========================================================================
// 1 ms 节拍
// ===========================================================================
reg [16:0] ms_div;
reg        ms_tick;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_div  <= 17'd0;
        ms_tick <= 1'b0;
    end else begin
        ms_tick <= 1'b0;
        if (ms_div == MS_CYCLES - 1) begin
            ms_div  <= 17'd0;
            ms_tick <= 1'b1;
        end else begin
            ms_div <= ms_div + 17'd1;
        end
    end
end

// ===========================================================================
// UART 接收：2FF 同步，起始位中点确认，之后每 BIT_CYCLES 采样一位
// ===========================================================================
reg [1:0]  rx_sync;
reg [1:0]  rx_state;
reg [9:0]  rx_cnt;
reg [2:0]  rx_bit;
reg [7:0]  rx_shift;
reg        rx_valid;
reg [7:0]  rx_byte;
wire       rx_s = rx_sync[1];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx_sync  <= 2'b11;
        rx_state <= 2'd0;
        rx_cnt   <= 10'd0;
        rx_bit   <= 3'd0;
        rx_shift <= 8'd0;
        rx_valid <= 1'b0;
        rx_byte  <= 8'd0;
    end else begin
        rx_sync  <= {rx_sync[0], uart_rx};
        rx_valid <= 1'b0;
        case (rx_state)
            2'd0: begin                         // 等起始位
                rx_cnt <= 10'd0;
                if (!rx_s)
                    rx_state <= 2'd1;
            end
            2'd1: begin                         // 起始位中点确认
                if (rx_cnt == HALF_CYCLES - 1) begin
                    rx_cnt <= 10'd0;
                    rx_bit <= 3'd0;
                    rx_state <= rx_s ? 2'd0 : 2'd2;
                end else begin
                    rx_cnt <= rx_cnt + 10'd1;
                end
            end
            2'd2: begin                         // 8 个数据位，LSB 先
                if (rx_cnt == BIT_CYCLES - 1) begin
                    rx_cnt   <= 10'd0;
                    rx_shift <= {rx_s, rx_shift[7:1]};
                    if (rx_bit == 3'd7)
                        rx_state <= 2'd3;
                    rx_bit <= rx_bit + 3'd1;
                end else begin
                    rx_cnt <= rx_cnt + 10'd1;
                end
            end
            default: begin                      // 停止位
                if (rx_cnt == BIT_CYCLES - 1) begin
                    rx_cnt   <= 10'd0;
                    rx_state <= 2'd0;
                    if (rx_s) begin
                        rx_valid <= 1'b1;
                        rx_byte  <= rx_shift;
                    end
                end else begin
                    rx_cnt <= rx_cnt + 10'd1;
                end
            end
        endcase
    end
end

// ===========================================================================
// UART 发送
// ===========================================================================
reg        tx_start;
reg [7:0]  tx_data;
reg        tx_busy;
reg [9:0]  tx_cnt;
reg [3:0]  tx_bit;
reg [8:0]  tx_shift;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        uart_tx  <= 1'b1;
        tx_busy  <= 1'b0;
        tx_cnt   <= 10'd0;
        tx_bit   <= 4'd0;
        tx_shift <= 9'h1FF;
    end else if (!tx_busy) begin
        uart_tx <= 1'b1;
        if (tx_start) begin
            tx_busy  <= 1'b1;
            uart_tx  <= 1'b0;                   // 起始位
            tx_shift <= {1'b1, tx_data};        // 数据 + 停止位
            tx_cnt   <= 10'd0;
            tx_bit   <= 4'd0;
        end
    end else if (tx_cnt == BIT_CYCLES - 1) begin
        tx_cnt <= 10'd0;
        if (tx_bit == 4'd9) begin
            tx_busy <= 1'b0;                    // 停止位已发满
        end else begin
            uart_tx  <= tx_shift[0];
            tx_shift <= {1'b1, tx_shift[8:1]};
            tx_bit   <= tx_bit + 4'd1;
        end
    end else begin
        tx_cnt <= tx_cnt + 10'd1;
    end
end

// ===========================================================================
// 帧解析
// ===========================================================================
localparam [1:0] P_IDLE = 2'd0, P_A5 = 2'd1, P_EE = 2'd2;

reg [1:0]  p_state;
reg [7:0]  p_idx;           // 当前字节在帧内的序号（帧头 = 0）
reg [23:0] p_tail;          // 本帧前 3 个字节，用来认帧尾
reg [4:0]  p_idle_ms;       // 帧内字节间超时
reg [7:0]  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11;
reg [7:0]  a_grp, a_code;
reg        a5_evt;          // A5 帧收完
reg [7:0]  a5_grp, a5_code;
reg        ee_evt;          // EE 帧收完（字段在 f1..f11，下一帧开始前保持）
reg [7:0]  ee_len;          // 帧总字节数

// 文本段（B1 11 ... 11 <TEXT> 00）
reg        t_done;          // 已遇到 00
reg        t_gbk_skip;      // GBK 双字节的第二字节
reg [6:0]  t_cnt;           // 已存入的 ASCII 字符数（字幕）
reg [2:0]  t_dig_cnt;       // 原始字符数（定时字段，封顶 7）
reg [3:0]  t_d0, t_d1;
reg        t_bad;           // 定时字段出现非数字
reg        t_nonascii;      // 字幕里出现过非 ASCII（已丢弃）

// 字幕草稿 RAM（64 x 8）
reg [7:0]  draft_ram [0:63];
reg        draft_we;
reg [5:0]  draft_wa;
reg [7:0]  draft_wd;

wire in_text   = (p_state == P_EE) && (p_idx >= 8'd8) && (f1 == 8'hB1) &&
                 (f2 == 8'h11) && (f7 == 8'h11) && !t_done;
wire text_sub  = (f4 == 8'h04) && (f6 == 8'h01);
wire [7:0] rx_upper = ((rx_byte >= 8'h61) && (rx_byte <= 8'h7A)) ? (rx_byte - 8'h20) :
                      (rx_byte < 8'h20) ? 8'h20 : rx_byte;
wire is_digit  = (rx_byte >= 8'h30) && (rx_byte <= 8'h39);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        p_state   <= P_IDLE;
        p_idx     <= 8'd0;
        p_tail    <= 24'd0;
        p_idle_ms <= 5'd0;
        f1 <= 8'd0; f2 <= 8'd0; f3 <= 8'd0; f4 <= 8'd0; f5 <= 8'd0; f6 <= 8'd0;
        f7 <= 8'd0; f8 <= 8'd0; f9 <= 8'd0; f10 <= 8'd0; f11 <= 8'd0;
        a_grp     <= 8'd0;
        a_code    <= 8'd0;
        a5_evt    <= 1'b0;
        a5_grp    <= 8'd0;
        a5_code   <= 8'd0;
        ee_evt    <= 1'b0;
        ee_len    <= 8'd0;
        t_done    <= 1'b0;
        t_gbk_skip<= 1'b0;
        t_cnt     <= 7'd0;
        t_dig_cnt <= 3'd0;
        t_d0      <= 4'd0;
        t_d1      <= 4'd0;
        t_bad     <= 1'b0;
        t_nonascii<= 1'b0;
        draft_we  <= 1'b0;
        draft_wa  <= 6'd0;
        draft_wd  <= 8'd0;
    end else begin
        a5_evt   <= 1'b0;
        ee_evt   <= 1'b0;
        draft_we <= 1'b0;

        if (rx_valid) begin
            p_idle_ms <= 5'd0;
        end else if (ms_tick && (p_state != P_IDLE)) begin
            if (p_idle_ms == 5'd30)
                p_state <= P_IDLE;               // 字节间超时，丢弃半帧
            else
                p_idle_ms <= p_idle_ms + 5'd1;
        end

        if (rx_valid) begin
            case (p_state)
                P_IDLE: begin
                    p_idx  <= 8'd1;              // 下一个字节的序号
                    p_tail <= {16'd0, rx_byte};
                    t_done     <= 1'b0;
                    t_gbk_skip <= 1'b0;
                    t_cnt      <= 7'd0;
                    t_dig_cnt  <= 3'd0;
                    t_bad      <= 1'b0;
                    t_nonascii <= 1'b0;
                    if (rx_byte == 8'hA5)
                        p_state <= P_A5;
                    else if (rx_byte == 8'hEE)
                        p_state <= P_EE;
                end

                P_A5: begin
                    p_idx <= p_idx + 8'd1;
                    case (p_idx)
                        8'd1: if (rx_byte != 8'h5A) p_state <= P_IDLE;
                        8'd2: if (rx_byte != 8'h03) p_state <= P_IDLE;
                        8'd3: a_grp  <= rx_byte;
                        8'd4: a_code <= rx_byte;
                        default: begin
                            p_state <= P_IDLE;
                            if ((rx_byte != a_grp + a_code) && (rx_byte == 8'hA5)) begin
                                p_state <= P_A5;         // 半帧后紧跟新帧：这个 A5 当新帧头
                                p_idx   <= 8'd1;
                            end
                            if (rx_byte == a_grp + a_code) begin
                                a5_evt  <= 1'b1;
                                a5_grp  <= a_grp;
                                a5_code <= a_code;
                            end
                        end
                    endcase
                end

                default: begin                   // P_EE
                    p_idx  <= p_idx + 8'd1;
                    p_tail <= {p_tail[15:0], rx_byte};
                    case (p_idx)
                        8'd1:  f1  <= rx_byte;
                        8'd2:  f2  <= rx_byte;
                        8'd3:  f3  <= rx_byte;
                        8'd4:  f4  <= rx_byte;
                        8'd5:  f5  <= rx_byte;
                        8'd6:  f6  <= rx_byte;
                        8'd7:  f7  <= rx_byte;
                        8'd8:  f8  <= rx_byte;
                        8'd9:  f9  <= rx_byte;
                        8'd10: f10 <= rx_byte;
                        8'd11: f11 <= rx_byte;
                        default: ;
                    endcase

                    if (in_text) begin
                        if (rx_byte == 8'h00) begin
                            t_done <= 1'b1;
                        end else if (t_gbk_skip) begin
                            t_gbk_skip <= 1'b0;
                        end else if (rx_byte >= 8'h81) begin
                            t_gbk_skip <= 1'b1;
                            t_nonascii <= 1'b1;
                            t_bad      <= 1'b1;
                        end else begin
                            if (t_dig_cnt != 3'd7)
                                t_dig_cnt <= t_dig_cnt + 3'd1;
                            if (!is_digit)
                                t_bad <= 1'b1;
                            if (t_dig_cnt == 3'd0) t_d0 <= rx_byte[3:0];
                            if (t_dig_cnt == 3'd1) t_d1 <= rx_byte[3:0];
                            if (text_sub && (t_cnt < 7'd64)) begin
                                draft_we <= 1'b1;
                                draft_wa <= t_cnt[5:0];
                                draft_wd <= rx_upper;
                                t_cnt    <= t_cnt + 7'd1;
                            end
                        end
                    end

                    if ((p_idx >= 8'd5) && ({p_tail, rx_byte} == 32'hFFFCFFFF)) begin
                        p_state <= P_IDLE;
                        ee_evt  <= 1'b1;
                        ee_len  <= p_idx + 8'd1;
                    end else if (p_idx == 8'd255) begin
                        p_state <= P_IDLE;       // 超长，丢弃
                    end
                end
            endcase
        end
    end
end

always @(posedge clk) begin
    if (draft_we)
        draft_ram[draft_wa] <= draft_wd;
end

// ===========================================================================
// 数值映射
// ===========================================================================
function [7:0] pct2val;
    input [6:0] p;
    reg   [16:0] s;
    begin
        // round(p * 2.55) = (p*653 + 128) >> 8，653 = 512 + 128 + 8 + 4 + 1
        s = {1'b0, p, 9'd0} + {3'd0, p, 7'd0} + {7'd0, p, 3'd0} + {8'd0, p, 2'd0} +
            {10'd0, p} + 17'd128;
        pct2val = s[16] ? 8'd255 : s[15:8];
    end
endfunction

function [6:0] val2pct;
    input [7:0] v;
    reg   [17:0] s;
    begin
        s = {2'd0, v, 8'd0} + {3'd0, v, 7'd0} + {6'd0, v, 4'd0} + {10'd0, v} + 18'd512;
        val2pct = s[16:10];
    end
endfunction

function [3:0] pct2lvl;
    input [6:0] p;
    begin
        pct2lvl = (p >= 7'd94) ? 4'd8 : (p >= 7'd81) ? 4'd7 : (p >= 7'd69) ? 4'd6 :
                  (p >= 7'd56) ? 4'd5 : (p >= 7'd44) ? 4'd4 : (p >= 7'd31) ? 4'd3 :
                  (p >= 7'd19) ? 4'd2 : (p >= 7'd6)  ? 4'd1 : 4'd0;
    end
endfunction

function [6:0] lvl2pct;
    input [3:0] l;
    begin
        case (l)
            4'd0: lvl2pct = 7'd0;
            4'd1: lvl2pct = 7'd13;
            4'd2: lvl2pct = 7'd25;
            4'd3: lvl2pct = 7'd38;
            4'd4: lvl2pct = 7'd50;
            4'd5: lvl2pct = 7'd63;
            4'd6: lvl2pct = 7'd75;
            4'd7: lvl2pct = 7'd88;
            default: lvl2pct = 7'd100;
        endcase
    end
endfunction

function [2:0] next_period;
    input [2:0] p;
    begin
        case (p)
            3'd1:    next_period = 3'd2;
            3'd2:    next_period = 3'd3;
            3'd3:    next_period = 3'd5;
            default: next_period = 3'd1;
        endcase
    end
endfunction

// 0..99 -> 十位/个位（比较链，不用除法）
function [3:0] dec_tens;
    input [6:0] v;
    begin
        dec_tens = (v >= 7'd90) ? 4'd9 : (v >= 7'd80) ? 4'd8 : (v >= 7'd70) ? 4'd7 :
                   (v >= 7'd60) ? 4'd6 : (v >= 7'd50) ? 4'd5 : (v >= 7'd40) ? 4'd4 :
                   (v >= 7'd30) ? 4'd3 : (v >= 7'd20) ? 4'd2 : (v >= 7'd10) ? 4'd1 : 4'd0;
    end
endfunction

function [3:0] dec_units;
    input [6:0] v;
    input [3:0] t;      // dec_tens(v)
    reg   [6:0] r;
    begin
        r = v - {t, 3'b000} - {2'b00, t, 1'b0};
        dec_units = r[3:0];
    end
endfunction

// BCD -> 二进制：t*10 + u = (t<<3) + (t<<1) + u
function [6:0] bcd2bin;
    input [7:0] b;
    begin
        bcd2bin = {b[7:4], 3'b000} + {2'b00, b[7:4], 1'b0} + {3'b000, b[3:0]};
    end
endfunction

function bcd_ok;
    input [7:0] b;
    input [7:0] lim;    // 上限（BCD 形式，开区间）
    begin
        bcd_ok = (b[7:4] <= 4'd9) && (b[3:0] <= 4'd9) && (b < lim);
    end
endfunction

// ===========================================================================
// 消息编号（数字越小越优先）
// ===========================================================================
localparam integer NMSG = 36;
localparam [5:0] M_BL       = 6'd0,  M_RTC      = 6'd1,  M_RD_SUB   = 6'd2,
                 M_RD_SH    = 6'd3,  M_RD_SM    = 6'd4,  M_RD_EH    = 6'd5,
                 M_RD_EM    = 6'd6,  M_SUB_STAT = 6'd7,  M_SW_SCHED = 6'd8,
                 M_HOME_SCH = 6'd9,  M_SLD_B    = 6'd10, M_PCT_B    = 6'd11,
                 M_HOME_B   = 6'd12, M_SLD_C    = 6'd13, M_PCT_C    = 6'd14,
                 M_SLD_V    = 6'd15, M_PCT_V    = 6'd16, M_HOME_V   = 6'd17,
                 M_ICON1    = 6'd18, M_ICON2    = 6'd19, M_NAME1    = 6'd20,
                 M_NAME2    = 6'd21, M_IDX1     = 6'd22, M_IDX2     = 6'd23,
                 M_SW_MUTE  = 6'd24, M_SW_VIS   = 6'd25, M_SW_SUB   = 6'd26,
                 M_SW_TRANS = 6'd27, M_INTERVAL = 6'd28, M_PREVIEW  = 6'd29,
                 M_HOME_SUB = 6'd30, M_PROG     = 6'd31,
                 M_SLD_T    = 6'd32, M_PCT_T    = 6'd33, M_TOUCH    = 6'd34,
                 M_BGM      = 6'd35;

localparam [NMSG-1:0] ONE = 1;

// 全量同步：除读控件外全部（含 M_SLD_T / M_PCT_T / M_TOUCH / M_BGM）
localparam [NMSG-1:0] SYNC_MASK = {4'b1111, 32'hFFFF_FF83};
localparam [NMSG-1:0] MASK_B    = (ONE << M_SLD_B) | (ONE << M_PCT_B) | (ONE << M_HOME_B);
localparam [NMSG-1:0] MASK_C    = (ONE << M_SLD_C) | (ONE << M_PCT_C);
localparam [NMSG-1:0] MASK_V    = (ONE << M_SLD_V) | (ONE << M_PCT_V) | (ONE << M_HOME_V);
localparam [NMSG-1:0] MASK_T    = (ONE << M_SLD_T) | (ONE << M_PCT_T);
localparam [NMSG-1:0] MASK_IMG  = (ONE << M_ICON1) | (ONE << M_ICON2) | (ONE << M_NAME1) |
                              (ONE << M_NAME2) | (ONE << M_IDX1)  | (ONE << M_IDX2);
localparam [NMSG-1:0] MASK_SCH  = (ONE << M_SW_SCHED) | (ONE << M_HOME_SCH);
localparam [NMSG-1:0] MASK_SUBC = (ONE << M_SUB_STAT) | (ONE << M_PREVIEW) | (ONE << M_HOME_SUB);
localparam [NMSG-1:0] MASK_RDT  = (ONE << M_RD_SH) | (ONE << M_RD_SM) |
                              (ONE << M_RD_EH) | (ONE << M_RD_EM);

// 字幕发送状态
localparam [1:0] SS_SENDING = 2'd0, SS_OK = 2'd1, SS_ASCII = 2'd2, SS_FAIL = 2'd3;

// ===========================================================================
// 事件处理 / 状态寄存器
// ===========================================================================
reg [NMSG-1:0] dirty;
reg [NMSG-1:0] dirty_set;       // 本拍要置位的消息（组合汇总后统一写入）
reg        boot_fire;       // 本拍触发首次同步
wire[NMSG-1:0] dirty_clr;       // 发送状态机本拍取走的消息

reg [6:0]  b_pct, c_pct, v_pct, t_pct;
reg [7:0]  b_seen, c_seen;
reg [3:0]  v_seen;
reg [7:0]  bright_d, contr_d;
reg [3:0]  vol_d;
reg [7:0]  b_exp, c_exp;    // 本模块认为的当前亮度/对比度（= 最近一次下发值或外部值）
reg [3:0]  v_exp;           // 当前音量档
reg [3:0]  t_exp;           // 当前提示音档（只由本模块改，复位值须与 TONE_VOLUME_DEFAULT 一致）
reg [4:0]  guard;          // 发出命令后的静默期（ms），期间不做"外部改动"检测
reg [3:0]  par_dirty;       // 亮度/对比度/音量/提示音待回写
reg [6:0]  deb_ms;

reg [11:0] boot_ms;
reg        boot1_done, boot2_done;
reg [9:0]  sec_ms;          // 1 s 节拍（RTC 轮询）
reg        rtc_wait;
reg [1:0]  rtc_miss;

reg [1:0]  sub_status;
reg        sub_pending;
reg [8:0]  sub_ms;
reg        commit_run;
reg [6:0]  commit_cnt;
reg [6:0]  com_len;
reg [6:0]  draft_len;
reg        draft_nonascii;
reg [7:0]  draft_q;
reg        commit_wr;
reg [5:0]  commit_wa;
reg        commit_pad;
reg [7:0]  com_ram [0:63];
reg        com_we;
reg [5:0]  com_wa;
reg [7:0]  com_wd;

reg        sched_en;
reg        sched_req;
reg [8:0]  sched_ms;
reg [3:0]  sched_mask;
reg [4:0]  s_sh, s_eh;
reg [5:0]  s_sm, s_em;
reg [4:0]  rtc_h;
reg [5:0]  rtc_m;

reg [2:0]  img_idx_d;
reg [3:0]  img_cnt_d;
reg        bgm_now_d;
reg [1:0]  bgm_cnt_d;
reg        img_valid_d;
reg [2:0]  period_d;
reg [6:0]  prog_pct;
reg [5:0]  prog_ms;
reg [6:0]  prog_sent;
reg [5:0]  prog_gap;

// 文本字段解析结果（定时）
wire       t_len_ok = (t_dig_cnt == 3'd1) || (t_dig_cnt == 3'd2);
wire [6:0] t_val    = (t_dig_cnt == 3'd1) ? {3'd0, t_d0} :
                      ({t_d0, 3'b000} + {2'b00, t_d0, 1'b0} + {3'b000, t_d1});
wire       t_ok_h   = t_len_ok && !t_bad && (t_val < 7'd24);
wire       t_ok_m   = t_len_ok && !t_bad && (t_val < 7'd60);

// 帧字段别名
wire       ee_b111  = (f1 == 8'hB1) && (f2 == 8'h11) && (f3 == 8'h00) && (f5 == 8'h00);
wire [7:0] ev_page  = f4;
wire [7:0] ev_ctrl  = f6;
wire [7:0] ev_type  = f7;
wire [7:0] ev_st    = f9;
wire [6:0] sld_val  = ((f8 | f9 | f10) != 8'd0) ? 7'd100 :
                      (f11 > 8'd100) ? 7'd100 : f11[6:0];

// 定时窗口：{时,分} 拼接后单调，可直接比较
wire [10:0] now_hm   = {rtc_h, rtc_m};
wire [10:0] start_hm = {s_sh, s_sm};
wire [10:0] sleep_hm = {s_eh, s_em};
wire        win_on   = (start_hm == sleep_hm) ? 1'b1 :
                       (start_hm <  sleep_hm) ? ((now_hm >= start_hm) && (now_hm < sleep_hm)) :
                                                ((now_hm >= start_hm) || (now_hm < sleep_hm));

wire [9:0]  prog_step_ms = (auto_period_sec == 3'd1) ? 10'd10 :
                           (auto_period_sec == 3'd2) ? 10'd20 :
                           (auto_period_sec == 3'd3) ? 10'd30 : 10'd50;

// 亮度/对比度命令共用一个 pct2val：A5 ±1（01/02 亮度，03/04 对比度）或滑块值
// 时序：a5_code / ee_evt 与事件同拍更新，一拍内串 选源 + ±1 + pct2val 跑不到 100 MHz。
// 拆两级流水：第 1 拍锁存 bc_pct_r，第 2 拍锁存 bc_val_r / sld_lvl_r，
// 事件同样打两拍（a5_go / ee_go）再处理。f1..f11、a5_code 在下一帧字节到来前不变。
wire       a5_is_c  = (a5_code[2:0] == 3'd3) || (a5_code[2:0] == 3'd4);
wire       a5_up    = a5_is_c ? a5_code[2] : a5_code[1];
wire [6:0] a5_src   = a5_is_c ? c_pct : b_pct;
wire [6:0] a5_step  = a5_up ? ((a5_src == 7'd100) ? 7'd100 : a5_src + 7'd1)
                            : ((a5_src == 7'd0)   ? 7'd0   : a5_src - 7'd1);
wire [3:0] v_up     = (v_exp == 4'd8) ? 4'd8 : v_exp + 4'd1;
wire [3:0] v_dn     = (v_exp == 4'd0) ? 4'd0 : v_exp - 4'd1;
wire [3:0] t_up     = (t_exp == 4'd8) ? 4'd8 : t_exp + 4'd1;
wire [3:0] t_dn     = (t_exp == 4'd0) ? 4'd0 : t_exp - 4'd1;
reg        a5_go1, ee_go1, a5_go, ee_go;
reg  [6:0] bc_pct_r;
reg  [7:0] bc_val_r;
reg  [3:0] sld_lvl_r;

// 外部改动：bright_q / contr_q 比 bright_d / contr_d 晚一拍，ext_*_pct 与之同拍锁存，
// 检测到变化时直接取寄存器，不在同一拍里做 val2pct
reg  [7:0] bright_q, contr_q;
reg  [6:0] ext_b_pct, ext_c_pct;

always @(posedge clk) begin
    bc_pct_r  <= ee_evt ? sld_val : a5_step;
    bc_val_r  <= pct2val(bc_pct_r);
    sld_lvl_r <= pct2lvl(bc_pct_r);
    ext_b_pct <= val2pct(bright_d);
    ext_c_pct <= val2pct(contr_d);
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        dirty            <= {NMSG{1'b0}};
        cmd_next         <= 1'b0;
        cmd_prev         <= 1'b0;
        cmd_auto_toggle  <= 1'b0;
        cmd_period_valid <= 1'b0;
        cmd_period       <= 3'd3;
        bc_cmd_valid     <= 1'b0;
        bc_cmd_target    <= 1'b0;
        bc_cmd_value     <= 8'd0;
        vol_cmd_valid    <= 1'b0;
        vol_cmd_target   <= 1'b0;
        vol_cmd_value    <= 4'd3;
        user_mute        <= 1'b0;
        visualizer_en    <= 1'b1;
        ticker_en        <= 1'b1;
        transition_fade  <= 1'b0;   // 默认滑动转场
        ticker_custom    <= 1'b0;
        ticker_wr_en     <= 1'b0;
        ticker_wr_addr   <= 6'd0;
        ticker_wr_data   <= 8'd0;
        screen_off       <= 1'b0;
        rtc_valid        <= 1'b0;
        time_toggle      <= 1'b0;
        time_h           <= 5'd0;
        time_m           <= 6'd0;
        time_s           <= 6'd0;
        b_pct            <= 7'd100;   // 亮度默认 255
        c_pct            <= 7'd50;    // 对比度默认 128
        v_pct            <= 7'd38;    // 音量默认 3 档（= VOLUME_DEFAULT）
        t_pct            <= 7'd38;    // 提示音默认 3 档（= TONE_VOLUME_DEFAULT）
        b_seen           <= 8'd255;
        c_seen           <= 8'd128;
        v_seen           <= 4'd3;
        bright_d         <= 8'd255;
        contr_d          <= 8'd128;
        bright_q         <= 8'd255;
        contr_q          <= 8'd128;
        a5_go1           <= 1'b0;
        ee_go1           <= 1'b0;
        a5_go            <= 1'b0;
        ee_go            <= 1'b0;
        vol_d            <= 4'd3;
        b_exp            <= 8'd255;
        c_exp            <= 8'd128;
        v_exp            <= 4'd3;
        t_exp            <= 4'd3;
        guard            <= 5'd0;
        par_dirty        <= 4'd0;
        deb_ms           <= 7'd0;
        boot_ms          <= 12'd0;
        boot1_done       <= 1'b0;
        boot2_done       <= 1'b0;
        sec_ms           <= 10'd0;
        rtc_wait         <= 1'b0;
        rtc_miss         <= 2'd0;
        sub_status       <= SS_OK;
        sub_pending      <= 1'b0;
        sub_ms           <= 9'd0;
        commit_run       <= 1'b0;
        commit_cnt       <= 7'd0;
        com_len          <= 7'd0;
        draft_len        <= 7'd0;
        draft_nonascii   <= 1'b0;
        commit_wr        <= 1'b0;
        commit_wa        <= 6'd0;
        commit_pad       <= 1'b0;
        com_we           <= 1'b0;
        com_wa           <= 6'd0;
        com_wd           <= 8'd0;
        sched_en         <= 1'b0;
        sched_req        <= 1'b0;
        sched_ms         <= 9'd0;
        sched_mask       <= 4'd0;
        s_sh             <= 5'd8;
        s_sm             <= 6'd0;
        s_eh             <= 5'd22;
        s_em             <= 6'd0;
        rtc_h            <= 5'd0;
        rtc_m            <= 6'd0;
        img_idx_d        <= 3'd0;
        img_cnt_d        <= 4'd0;
        bgm_now_d        <= 1'b0;
        bgm_cnt_d        <= 2'd0;
        bgm_track_sel    <= 1'b0;
        img_valid_d      <= 1'b0;
        period_d         <= 3'd0;
        prog_pct         <= 7'd0;
        prog_ms          <= 6'd0;
        prog_sent        <= 7'd0;
        prog_gap         <= 6'd0;
    end else begin
        cmd_next         <= 1'b0;
        cmd_prev         <= 1'b0;
        cmd_auto_toggle  <= 1'b0;
        cmd_period_valid <= 1'b0;
        bc_cmd_valid     <= 1'b0;
        vol_cmd_valid    <= 1'b0;
        ticker_wr_en     <= 1'b0;
        com_we           <= 1'b0;

        dirty_set = {NMSG{1'b0}};
        boot_fire = 1'b0;

        if (ms_tick && (guard != 5'd0))
            guard <= guard - 5'd1;

        // ---------------- 上电 / 复位报告后的全量同步 ----------------
        if (ms_tick && !boot2_done) begin
            boot_ms <= boot_ms + 12'd1;
            if (!boot1_done && (boot_ms == BOOT_MS - 1)) begin
                boot1_done <= 1'b1;
                boot_fire  = 1'b1;
                dirty_set  = dirty_set | SYNC_MASK;
            end
            if (boot_ms == RESYNC_MS - 1) begin
                boot2_done <= 1'b1;
                dirty_set  = dirty_set | SYNC_MASK;
            end
        end

        // ---------------- RTC 每秒轮询 ----------------
        if (ms_tick && boot1_done) begin
            if (sec_ms == 10'd999) begin
                sec_ms <= 10'd0;
                dirty_set = dirty_set | (ONE << M_RTC);
                rtc_wait <= 1'b1;
                if (rtc_wait) begin               // 上一秒的查询没有回应
                    if (rtc_miss == 2'd2) begin
                        if (rtc_valid) begin
                            rtc_valid <= 1'b0;
                            dirty_set = dirty_set | (ONE << M_HOME_SCH);
                        end
                    end else begin
                        rtc_miss <= rtc_miss + 2'd1;
                    end
                end
            end else begin
                sec_ms <= sec_ms + 10'd1;
            end
        end

        // ---------------- 外部（KEY3 等）改动参数的检测 ----------------
        bright_d <= brightness;
        contr_d  <= contrast;
        vol_d    <= volume;
        bright_q <= bright_d;
        contr_q  <= contr_d;
        a5_go1   <= a5_evt;
        ee_go1   <= ee_evt;
        a5_go    <= a5_go1;
        ee_go    <= ee_go1;
        if (guard == 5'd0) begin
            if (bright_q != b_seen) begin
                b_seen <= bright_q;
                if (bright_q != b_exp) begin
                    b_pct <= ext_b_pct;
                    b_exp <= bright_q;
                    par_dirty[0] <= 1'b1;
                    deb_ms <= DEBOUNCE_MS;
                end
            end
            if (contr_q != c_seen) begin
                c_seen <= contr_q;
                if (contr_q != c_exp) begin
                    c_pct <= ext_c_pct;
                    c_exp <= contr_q;
                    par_dirty[1] <= 1'b1;
                    deb_ms <= DEBOUNCE_MS;
                end
            end
            if (vol_d != v_seen) begin
                v_seen <= vol_d;
                if (vol_d != v_exp) begin
                    v_exp <= vol_d;
                    v_pct <= lvl2pct(vol_d);
                    par_dirty[2] <= 1'b1;
                    deb_ms <= DEBOUNCE_MS;
                end
            end
        end

        // ---------------- 回写去抖 ----------------
        if (ms_tick && (deb_ms != 7'd0)) begin
            deb_ms <= deb_ms - 7'd1;
        end else if (deb_ms == 7'd0 && (par_dirty != 4'd0)) begin
            if (par_dirty[0]) dirty_set = dirty_set | MASK_B;
            if (par_dirty[1]) dirty_set = dirty_set | MASK_C;
            if (par_dirty[2]) dirty_set = dirty_set | MASK_V;
            if (par_dirty[3]) dirty_set = dirty_set | MASK_T;
            par_dirty <= 4'd0;
        end

        // ---------------- 图片状态 ----------------
        img_idx_d   <= current_image_index;
        img_cnt_d   <= image_count;
        img_valid_d <= display_valid;
        period_d    <= auto_period_sec;
        if ((img_idx_d != current_image_index) || (img_cnt_d != image_count) ||
            (img_valid_d != display_valid)) begin
            dirty_set = dirty_set | MASK_IMG;
        end
        if (period_d != auto_period_sec)
            dirty_set = dirty_set | (ONE << M_INTERVAL);

        // ---------------- 背景音乐曲目 ----------------
        bgm_now_d <= bgm_track_now;
        bgm_cnt_d <= bgm_track_count;
        if ((bgm_now_d != bgm_track_now) || (bgm_cnt_d != bgm_track_count))
            dirty_set = dirty_set | (ONE << M_BGM);

        // 进度：每 period*10 ms 走 1%，换图 / 停轮播 / 息屏时归零
        if ((img_idx_d != current_image_index) || !auto_play_enabled || screen_off) begin
            prog_pct <= 7'd0;
            prog_ms  <= 6'd0;
        end else if (ms_tick) begin
            if ({4'd0, prog_ms} + 10'd1 >= prog_step_ms) begin
                prog_ms <= 6'd0;
                if (prog_pct != 7'd100)
                    prog_pct <= prog_pct + 7'd1;
            end else begin
                prog_ms <= prog_ms + 6'd1;
            end
        end
        // 每 50 ms 最多发一次进度
        if (ms_tick) begin
            if (prog_gap == 6'd49) begin
                prog_gap <= 6'd0;
                if (prog_pct != prog_sent) begin
                    prog_sent <= prog_pct;
                    dirty_set = dirty_set | (ONE << M_PROG);
                end
            end else begin
                prog_gap <= prog_gap + 6'd1;
            end
        end

        // ---------------- 文件名更新 ----------------
        if (name_wr)
            dirty_set = dirty_set | (ONE << M_NAME1) | (ONE << M_NAME2);

        // ---------------- 字幕提交：草稿 -> 已提交副本 + OSD 字幕 RAM ----------------
        // commit_cnt 为读地址，读数据下一拍到，写端用打一拍的地址
        commit_wr <= 1'b0;
        if (commit_run) begin
            commit_cnt <= commit_cnt + 7'd1;
            commit_wr  <= 1'b1;
            commit_wa  <= commit_cnt[5:0];
            commit_pad <= (commit_cnt >= draft_len);
            if (commit_cnt == 7'd63)
                commit_run <= 1'b0;
        end
        if (commit_wr) begin
            ticker_wr_en   <= 1'b1;
            ticker_wr_addr <= commit_wa;
            ticker_wr_data <= commit_pad ? 8'h20 : draft_q;
            com_we         <= 1'b1;
            com_wa         <= commit_wa;
            com_wd         <= commit_pad ? 8'h20 : draft_q;
            if (commit_wa == 6'd63) begin
                ticker_custom <= (draft_len != 7'd0);   // 发空字幕 = 恢复默认滚动字
                com_len       <= draft_len;
                sub_status    <= draft_nonascii ? SS_ASCII : SS_OK;
                dirty_set     = dirty_set | MASK_SUBC;
            end
        end

        if (sub_pending && ms_tick) begin
            if (sub_ms == 9'd300) begin
                sub_pending <= 1'b0;
                sub_status  <= SS_FAIL;
                dirty_set   = dirty_set | (ONE << M_SUB_STAT);
            end else begin
                sub_ms <= sub_ms + 9'd1;
            end
        end

        // ---------------- 定时启用：等四个字段读回 ----------------
        if (sched_req) begin
            if (sched_mask == 4'hF) begin
                sched_req <= 1'b0;
                sched_en  <= rtc_valid;
                dirty_set = dirty_set | MASK_SCH;
            end else if (ms_tick) begin
                if (sched_ms == 9'd500) begin
                    sched_req <= 1'b0;
                    sched_en  <= 1'b0;
                    dirty_set = dirty_set | MASK_SCH;
                end else begin
                    sched_ms <= sched_ms + 9'd1;
                end
            end
        end
        if (sched_en && !rtc_valid) begin
            sched_en  <= 1'b0;
            dirty_set = dirty_set | MASK_SCH;
        end

        // 息屏判定（RTC 更新或设置变化后自然生效）
        if ((sched_en && rtc_valid && !win_on) != screen_off) begin
            screen_off <= sched_en && rtc_valid && !win_on;
            dirty_set  = dirty_set | (ONE << M_BL);
        end

        // ---------------- A5 固定业务帧 ----------------
        if (a5_go) begin
            if (a5_grp == 8'h20) begin
                case (a5_code)
                    8'h01: cmd_auto_toggle <= 1'b1;
                    8'h02: cmd_next        <= 1'b1;
                    8'h03: cmd_prev        <= 1'b1;
                    8'h04: begin
                        cmd_period_valid <= 1'b1;
                        cmd_period       <= next_period(auto_period_sec);
                    end
                    8'h11, 8'h12, 8'h13, 8'h15: begin
                        cmd_period_valid <= 1'b1;
                        cmd_period       <= a5_code[2:0];
                    end
                    // 切歌以实际在播曲目为基准取反：只有一首时 sel 与 now 不同，
                    // 存储侧找不到目标曲目就保持不动，下次再按仍得到同一个 sel
                    8'h05: bgm_track_sel <= !bgm_track_now;
                    8'h21: bgm_track_sel <= 1'b0;
                    8'h22: bgm_track_sel <= 1'b1;
                    default: ;
                endcase
            end else if (a5_grp == 8'h30) begin
                case (a5_code)
                    8'h01, 8'h02: begin
                        b_pct         <= a5_step;
                        b_exp         <= bc_val_r;
                        bc_cmd_valid  <= 1'b1;
                        bc_cmd_target <= 1'b0;
                        bc_cmd_value  <= bc_val_r;
                        par_dirty[0] <= 1'b1;
                        guard  <= 5'd20;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    8'h03, 8'h04: begin
                        c_pct         <= a5_step;
                        c_exp         <= bc_val_r;
                        bc_cmd_valid  <= 1'b1;
                        bc_cmd_target <= 1'b1;
                        bc_cmd_value  <= bc_val_r;
                        par_dirty[1] <= 1'b1;
                        guard  <= 5'd20;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    8'h05, 8'h06: begin
                        // 音量只有 9 档，按钮一次走一档
                        if (a5_code[0] == 1'b0) begin               // 06：+1 档
                            v_exp         <= v_up;
                            v_pct         <= lvl2pct(v_up);
                            vol_cmd_value <= v_up;
                        end else begin                              // 05：-1 档
                            v_exp         <= v_dn;
                            v_pct         <= lvl2pct(v_dn);
                            vol_cmd_value <= v_dn;
                        end
                        vol_cmd_valid  <= 1'b1;
                        vol_cmd_target <= 1'b0;
                        par_dirty[2]   <= 1'b1;
                        guard  <= 5'd20;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    8'h07, 8'h08: begin
                        // 提示音音量：07 -1 档，08 +1 档
                        if (a5_code[0] == 1'b0) begin
                            t_exp         <= t_up;
                            t_pct         <= lvl2pct(t_up);
                            vol_cmd_value <= t_up;
                        end else begin
                            t_exp         <= t_dn;
                            t_pct         <= lvl2pct(t_dn);
                            vol_cmd_value <= t_dn;
                        end
                        vol_cmd_valid  <= 1'b1;
                        vol_cmd_target <= 1'b1;
                        par_dirty[3]   <= 1'b1;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    default: ;
                endcase
            end
        end

        // ---------------- EE 标准帧 ----------------
        if (ee_go) begin
            if ((f1 == 8'h07) && (ee_len == 8'd6)) begin
                // 屏幕复位：重新走上电同步
                boot_ms    <= 12'd0;
                boot1_done <= 1'b0;
                boot2_done <= 1'b0;
            end else if (f1 == 8'hF7) begin
                // RTC：F7 YY MM WW DD hh mm ss
                if (bcd_ok(f6, 8'h24) && bcd_ok(f7, 8'h60) && bcd_ok(f8, 8'h60)) begin
                    rtc_valid   <= 1'b1;
                    rtc_wait    <= 1'b0;
                    rtc_miss    <= 2'd0;
                    rtc_h       <= bcd2bin(f6);
                    rtc_m       <= bcd2bin(f7);
                    time_h      <= bcd2bin(f6);
                    time_m      <= bcd2bin(f7);
                    time_s      <= bcd2bin(f8);
                    time_toggle <= ~time_toggle;
                    if (!rtc_valid)
                        dirty_set = dirty_set | (ONE << M_HOME_SCH);
                end
            end else if (ee_b111 && (ev_type == 8'h10) && (f8 == 8'h01)) begin
                // 按钮 / 开关
                if (ev_page == 8'h02) begin
                    case (ev_ctrl)
                        8'h07: user_mute       <= ev_st[0];
                        8'h08: visualizer_en   <= ev_st[0];
                        8'h09: ticker_en       <= ev_st[0];
                        8'h10: transition_fade <= ev_st[0];
                        default: ;
                    endcase
                end else if ((ev_page == 8'h04) && (ev_ctrl == 8'h0A) && ev_st[0]) begin
                    sub_pending <= 1'b1;
                    sub_ms      <= 9'd0;
                    sub_status  <= SS_SENDING;
                    dirty_set   = dirty_set | (ONE << M_RD_SUB) | (ONE << M_SUB_STAT);
                end else if ((ev_page == 8'h05) && (ev_ctrl == 8'h07)) begin
                    if (ev_st[0]) begin
                        sched_req  <= 1'b1;
                        sched_ms   <= 9'd0;
                        sched_mask <= 4'd0;
                        dirty_set  = dirty_set | MASK_RDT;
                    end else begin
                        sched_req <= 1'b0;
                        sched_en  <= 1'b0;
                        dirty_set = dirty_set | (ONE << M_HOME_SCH);
                    end
                end
            end else if (ee_b111 && (ev_type == 8'h13) && (ev_page == 8'h03)) begin
                // 滑块：立即生效，回写等去抖
                case (ev_ctrl)
                    8'h01: begin
                        b_pct         <= sld_val;
                        b_exp         <= bc_val_r;
                        bc_cmd_valid  <= 1'b1;
                        bc_cmd_target <= 1'b0;
                        bc_cmd_value  <= bc_val_r;
                        par_dirty[0]  <= 1'b1;
                        guard  <= 5'd20;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    8'h06: begin
                        c_pct         <= sld_val;
                        c_exp         <= bc_val_r;
                        bc_cmd_valid  <= 1'b1;
                        bc_cmd_target <= 1'b1;
                        bc_cmd_value  <= bc_val_r;
                        par_dirty[1]  <= 1'b1;
                        guard  <= 5'd20;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    8'h07: begin
                        v_pct         <= sld_val;
                        v_exp         <= sld_lvl_r;
                        vol_cmd_valid  <= 1'b1;
                        vol_cmd_target <= 1'b0;
                        vol_cmd_value  <= sld_lvl_r;
                        par_dirty[2]   <= 1'b1;
                        guard  <= 5'd20;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    8'h12: begin                    // 提示音音量滑块
                        t_pct          <= sld_val;
                        t_exp          <= sld_lvl_r;
                        vol_cmd_valid  <= 1'b1;
                        vol_cmd_target <= 1'b1;
                        vol_cmd_value  <= sld_lvl_r;
                        par_dirty[3]   <= 1'b1;
                        deb_ms <= DEBOUNCE_MS;
                    end
                    default: ;
                endcase
            end else if (ee_b111 && (ev_type == 8'h11)) begin
                // 文本
                if ((ev_page == 8'h04) && (ev_ctrl == 8'h01)) begin
                    draft_len      <= t_cnt;
                    draft_nonascii <= t_nonascii;
                    if (sub_pending) begin
                        sub_pending <= 1'b0;
                        commit_run  <= 1'b1;
                        commit_cnt  <= 7'd0;
                    end
                end else if (ev_page == 8'h05) begin
                    case (ev_ctrl)
                        8'h01: if (t_ok_h) begin s_sh <= t_val[4:0]; sched_mask[0] <= 1'b1; end
                        8'h09: if (t_ok_m) begin s_sm <= t_val[5:0]; sched_mask[1] <= 1'b1; end
                        8'h06: if (t_ok_h) begin s_eh <= t_val[4:0]; sched_mask[2] <= 1'b1; end
                        8'h0C: if (t_ok_m) begin s_em <= t_val[5:0]; sched_mask[3] <= 1'b1; end
                        default: ;
                    endcase
                    // 有非法字段：启用请求直接失败
                    if (sched_req && ((ev_ctrl == 8'h01 || ev_ctrl == 8'h06) ? !t_ok_h :
                                      (ev_ctrl == 8'h09 || ev_ctrl == 8'h0C) ? !t_ok_m : 1'b0)) begin
                        sched_req <= 1'b0;
                        sched_en  <= 1'b0;
                        dirty_set = dirty_set | MASK_SCH;
                    end else if (sched_en) begin
                        dirty_set = dirty_set | (ONE << M_HOME_SCH);
                    end
                end
            end
        end

        if (!boot1_done && !boot_fire)
            dirty_set = {NMSG{1'b0}};    // 屏幕还没起来，先不发
        dirty <= (dirty & ~dirty_clr) | dirty_set;
    end
end

always @(posedge clk) begin
    if (com_we)
        com_ram[com_wa] <= com_wd;
    draft_q <= draft_ram[commit_cnt[5:0]];
end

// ===========================================================================
// 文件名 RAM：{槽号, 字符号}，每槽 11 字节（8.3 名，已按 8+3 排好）
// ===========================================================================
reg [7:0]  fn_ram [0:127];
reg [87:0] fn_shift;
reg [3:0]  fn_cnt;
reg [2:0]  fn_slot;
reg        fn_busy;
reg [3:0]  fn_len [0:7];     // 主名去掉尾部空格后的长度
reg [7:0]  fn_valid;         // 该槽已收到文件名

function [3:0] name_len;
    input [63:0] n;           // 8 个字符，高字节在前
    begin
        name_len = (n[55:48] == 8'h20) ? 4'd1 :
                   (n[47:40] == 8'h20) ? 4'd2 :
                   (n[39:32] == 8'h20) ? 4'd3 :
                   (n[31:24] == 8'h20) ? 4'd4 :
                   (n[23:16] == 8'h20) ? 4'd5 :
                   (n[15:8]  == 8'h20) ? 4'd6 :
                   (n[7:0]   == 8'h20) ? 4'd7 : 4'd8;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        fn_shift <= 88'd0;
        fn_cnt   <= 4'd0;
        fn_slot  <= 3'd0;
        fn_busy  <= 1'b0;
        fn_valid <= 8'd0;
    end else if (name_wr) begin
        fn_valid[name_slot] <= 1'b1;
        fn_shift <= name_data;
        fn_cnt   <= 4'd0;
        fn_slot  <= name_slot;
        fn_busy  <= 1'b1;
    end else if (fn_busy) begin
        fn_shift <= {fn_shift[79:0], 8'h00};
        fn_cnt   <= fn_cnt + 4'd1;
        if (fn_cnt == 4'd10)
            fn_busy <= 1'b0;
    end
end

always @(posedge clk) begin
    if (fn_busy)
        fn_ram[{fn_slot, fn_cnt}] <= fn_shift[87:80];
    if (name_wr)
        fn_len[name_slot] <= name_len(name_data[87:24]);
end

// ===========================================================================
// 发送状态机：挑最高优先级的 dirty 消息，逐字节生成并发送
// ===========================================================================
localparam [3:0] PT_NONE = 4'd0, PT_BYTE = 4'd1, PT_U32 = 4'd2, PT_PCT = 4'd3,
                 PT_SCHED = 4'd4, PT_GBK = 4'd5, PT_FNAME = 4'd6, PT_INDEX = 4'd7,
                 PT_INTV = 4'd8, PT_COM = 4'd9, PT_BGM = 4'd10;

reg [2:0]  s_state;
reg [5:0]  m_id;
reg        m_short;        // 1 = 2 字节头（EE 60 / EE 82），0 = 7 字节 B1 头
reg [7:0]  m_c1;           // 第 2 字节：B1 / 60 / 82
reg [7:0]  m_c2;           // 第 3 字节：10 / 11 / 23
reg [7:0]  m_page;
reg [7:0]  m_ctrl;
reg [3:0]  m_pt;
reg [7:0]  m_val;
reg [6:0]  m_len;          // 负载长度
reg [6:0]  m_pos;          // 当前字节号
reg [6:0]  m_q;            // 负载内偏移
reg [2:0]  m_img;          // 发送时锁存的图片序号
reg [3:0]  m_nlen;
reg [7:0]  fn_q;
reg [7:0]  com_q;
reg [6:0]  m_q_d;
reg [2:0]  m_region;       // 0 头 1 负载 2 尾 3 结束

// 最低位优先
reg [5:0]  pick_id;
reg        pick_any;
integer    pi;
always @* begin
    pick_id  = 6'd0;
    pick_any = 1'b0;
    for (pi = NMSG - 1; pi >= 0; pi = pi - 1) begin
        if (dirty[pi]) begin
            pick_id  = pi[5:0];
            pick_any = 1'b1;
        end
    end
end

reg        clr_v;          // 本拍取走 m_id 号消息
assign dirty_clr = clr_v ? (ONE << m_id) : {NMSG{1'b0}};

// 描述符：{short, c1, c2, page, ctrl, ptype}
reg        d_short;
reg [7:0]  d_c1, d_c2, d_page, d_ctrl;
reg [3:0]  d_pt;
reg [7:0]  d_val;
always @* begin
    d_short = 1'b0; d_c1 = 8'hB1; d_c2 = 8'h10; d_page = 8'h00; d_ctrl = 8'h00;
    d_pt = PT_NONE; d_val = 8'd0;
    case (pick_id)
        M_BL:       begin d_short = 1'b1; d_c1 = 8'h60; d_pt = PT_BYTE; d_val = screen_off ? 8'hFF : 8'h00; end
        M_RTC:      begin d_short = 1'b1; d_c1 = 8'h82; end
        M_RD_SUB:   begin d_c2 = 8'h11; d_page = 8'h04; d_ctrl = 8'h01; end
        M_RD_SH:    begin d_c2 = 8'h11; d_page = 8'h05; d_ctrl = 8'h01; end
        M_RD_SM:    begin d_c2 = 8'h11; d_page = 8'h05; d_ctrl = 8'h09; end
        M_RD_EH:    begin d_c2 = 8'h11; d_page = 8'h05; d_ctrl = 8'h06; end
        M_RD_EM:    begin d_c2 = 8'h11; d_page = 8'h05; d_ctrl = 8'h0C; end
        M_SUB_STAT: begin d_page = 8'h04; d_ctrl = 8'h07; d_pt = PT_GBK; d_val = {6'd0, sub_status}; end
        M_SW_SCHED: begin d_page = 8'h05; d_ctrl = 8'h07; d_pt = PT_BYTE; d_val = {7'd0, sched_en}; end
        M_HOME_SCH: begin d_page = 8'h01; d_ctrl = 8'h0A; d_pt = PT_SCHED; end
        M_SLD_B:    begin d_page = 8'h03; d_ctrl = 8'h01; d_pt = PT_U32; d_val = {1'b0, b_pct}; end
        M_PCT_B:    begin d_page = 8'h03; d_ctrl = 8'h0C; d_pt = PT_PCT; d_val = {1'b0, b_pct}; end
        M_HOME_B:   begin d_page = 8'h01; d_ctrl = 8'h07; d_pt = PT_PCT; d_val = {1'b0, b_pct}; end
        M_SLD_C:    begin d_page = 8'h03; d_ctrl = 8'h06; d_pt = PT_U32; d_val = {1'b0, c_pct}; end
        M_PCT_C:    begin d_page = 8'h03; d_ctrl = 8'h0D; d_pt = PT_PCT; d_val = {1'b0, c_pct}; end
        M_SLD_V:    begin d_page = 8'h03; d_ctrl = 8'h07; d_pt = PT_U32; d_val = {1'b0, v_pct}; end
        M_PCT_V:    begin d_page = 8'h03; d_ctrl = 8'h0E; d_pt = PT_PCT; d_val = {1'b0, v_pct}; end
        M_HOME_V:   begin d_page = 8'h01; d_ctrl = 8'h08; d_pt = PT_PCT; d_val = {1'b0, v_pct}; end
        M_ICON1:    begin d_c2 = 8'h23; d_page = 8'h01; d_ctrl = 8'h0C; d_pt = PT_BYTE;
                          d_val = display_valid ? {5'd0, current_image_index} : 8'd0; end
        M_ICON2:    begin d_c2 = 8'h23; d_page = 8'h02; d_ctrl = 8'h0C; d_pt = PT_BYTE;
                          d_val = display_valid ? {5'd0, current_image_index} : 8'd0; end
        M_NAME1:    begin d_page = 8'h01; d_ctrl = 8'h0D; d_pt = PT_FNAME; end
        M_NAME2:    begin d_page = 8'h02; d_ctrl = 8'h0D; d_pt = PT_FNAME; end
        M_IDX1:     begin d_page = 8'h01; d_ctrl = 8'h0E; d_pt = PT_INDEX; end
        M_IDX2:     begin d_page = 8'h02; d_ctrl = 8'h0E; d_pt = PT_INDEX; end
        M_SW_MUTE:  begin d_page = 8'h02; d_ctrl = 8'h07; d_pt = PT_BYTE; d_val = {7'd0, user_mute}; end
        M_SW_VIS:   begin d_page = 8'h02; d_ctrl = 8'h08; d_pt = PT_BYTE; d_val = {7'd0, visualizer_en}; end
        M_SW_SUB:   begin d_page = 8'h02; d_ctrl = 8'h09; d_pt = PT_BYTE; d_val = {7'd0, ticker_en}; end
        M_SW_TRANS: begin d_page = 8'h02; d_ctrl = 8'h10; d_pt = PT_BYTE; d_val = {7'd0, transition_fade}; end
        M_INTERVAL: begin d_page = 8'h02; d_ctrl = 8'h11; d_pt = PT_INTV; d_val = {5'd0, auto_period_sec}; end
        M_PREVIEW:  begin d_page = 8'h04; d_ctrl = 8'h06; d_pt = PT_COM; end
        M_HOME_SUB: begin d_page = 8'h01; d_ctrl = 8'h09; d_pt = PT_COM; end
        M_PROG:     begin d_page = 8'h02; d_ctrl = 8'h0F; d_pt = PT_U32; d_val = {1'b0, prog_pct}; end
        M_SLD_T:    begin d_page = 8'h03; d_ctrl = 8'h12; d_pt = PT_U32; d_val = {1'b0, t_pct}; end
        M_PCT_T:    begin d_page = 8'h03; d_ctrl = 8'h13; d_pt = PT_PCT; d_val = {1'b0, t_pct}; end
        // 播放页 MusicTrack（20）："BGM 1/2"，无曲目时 "BGM -/0"
        M_BGM:      begin d_page = 8'h02; d_ctrl = 8'h14; d_pt = PT_BGM; end
        // M_TOUCH：EE 70 31 = 触摸开、触摸蜂鸣关、坐标不上传、禁连点校准
        default:    begin d_short = 1'b1; d_c1 = 8'h70; d_pt = PT_BYTE; d_val = 8'h31; end
    endcase
end

// 负载长度
wire        img_ok   = display_valid && (image_count != 4'd0);
wire        fn_ok    = img_ok && fn_valid[current_image_index];
reg  [6:0]  d_len;
always @* begin
    case (d_pt)
        PT_BYTE:  d_len = 7'd1;
        PT_U32:   d_len = 7'd4;
        PT_PCT:   d_len = (d_val >= 8'd100) ? 7'd4 : (d_val >= 8'd10) ? 7'd3 : 7'd2;
        PT_SCHED: d_len = sched_en ? 7'd11 : rtc_valid ? 7'd3 : 7'd7;
        PT_GBK:   d_len = (sub_status == SS_SENDING) ? 7'd6 :
                          (sub_status == SS_ASCII)   ? 7'd10 : 7'd8;
        PT_FNAME: d_len = fn_ok ? {3'd0, fn_len[current_image_index]} + 7'd4 : 7'd1;
        PT_INDEX: d_len = 7'd7;
        PT_INTV:  d_len = 7'd2;
        PT_COM:   d_len = com_len;
        PT_BGM:   d_len = 7'd7;
        default:  d_len = 7'd0;
    endcase
end

// 负载字节（m_q_d 是上一拍的偏移，与同步读 RAM 的输出对齐）
function [7:0] gbk_byte;
    input [1:0] st;
    input [3:0] i;
    begin
        gbk_byte = 8'h20;
        case (st)
            SS_SENDING: case (i)   // 发送中
                4'd0: gbk_byte = 8'hB7; 4'd1: gbk_byte = 8'hA2; 4'd2: gbk_byte = 8'hCB;
                4'd3: gbk_byte = 8'hCD; 4'd4: gbk_byte = 8'hD6; 4'd5: gbk_byte = 8'hD0;
                default: ;
            endcase
            SS_OK: case (i)        // 发送成功
                4'd0: gbk_byte = 8'hB7; 4'd1: gbk_byte = 8'hA2; 4'd2: gbk_byte = 8'hCB;
                4'd3: gbk_byte = 8'hCD; 4'd4: gbk_byte = 8'hB3; 4'd5: gbk_byte = 8'hC9;
                4'd6: gbk_byte = 8'hB9; 4'd7: gbk_byte = 8'hA6;
                default: ;
            endcase
            SS_ASCII: case (i)     // 仅支持英文
                4'd0: gbk_byte = 8'hBD; 4'd1: gbk_byte = 8'hF6; 4'd2: gbk_byte = 8'hD6;
                4'd3: gbk_byte = 8'hA7; 4'd4: gbk_byte = 8'hB3; 4'd5: gbk_byte = 8'hD6;
                4'd6: gbk_byte = 8'hD3; 4'd7: gbk_byte = 8'hA2; 4'd8: gbk_byte = 8'hCE;
                4'd9: gbk_byte = 8'hC4;
                default: ;
            endcase
            default: case (i)      // 发送失败
                4'd0: gbk_byte = 8'hB7; 4'd1: gbk_byte = 8'hA2; 4'd2: gbk_byte = 8'hCB;
                4'd3: gbk_byte = 8'hCD; 4'd4: gbk_byte = 8'hCA; 4'd5: gbk_byte = 8'hA7;
                4'd6: gbk_byte = 8'hB0; 4'd7: gbk_byte = 8'hDC;
                default: ;
            endcase
        endcase
    end
endfunction

// 定时文本 "HH:MM-HH:MM" / "OFF" / "RTC ERR"
reg [6:0] sch_v;
always @* begin
    case (m_q)
        7'd0, 7'd1:  sch_v = {2'd0, s_sh};
        7'd3, 7'd4:  sch_v = {1'd0, s_sm};
        7'd6, 7'd7:  sch_v = {2'd0, s_eh};
        default:     sch_v = {1'd0, s_em};
    endcase
end

// 十进制拆分只用一份：S_READ 时按类型选源并锁存到 dig_t / dig_u
wire [6:0] dig_src = (m_pt == PT_SCHED) ? sch_v : m_val[6:0];
wire [3:0] dig_src_t = dec_tens(dig_src);
reg  [3:0] dig_t, dig_u;

reg [7:0] pay_byte;
always @* begin
    pay_byte = 8'h20;
    case (m_pt)
        PT_BYTE:  pay_byte = m_val;
        PT_U32:   pay_byte = (m_q_d == 7'd3) ? m_val : 8'h00;
        PT_PCT: begin
            if (m_len == 7'd4)
                pay_byte = (m_q_d == 7'd0) ? 8'h31 : (m_q_d == 7'd3) ? 8'h25 : 8'h30;
            else if (m_len == 7'd3)
                pay_byte = (m_q_d == 7'd0) ? {4'h3, dig_t} : (m_q_d == 7'd1) ? {4'h3, dig_u} : 8'h25;
            else
                pay_byte = (m_q_d == 7'd0) ? {4'h3, dig_u} : 8'h25;
        end
        PT_SCHED: begin
            if (m_len == 7'd11) begin
                case (m_q_d)
                    7'd2, 7'd8: pay_byte = 8'h3A;           // :
                    7'd5:       pay_byte = 8'h2D;           // -
                    7'd0, 7'd3, 7'd6, 7'd9: pay_byte = {4'h3, dig_t};
                    default:    pay_byte = {4'h3, dig_u};
                endcase
            end else if (m_len == 7'd3) begin
                pay_byte = (m_q_d == 7'd0) ? 8'h4F : 8'h46;   // OFF
            end else begin
                case (m_q_d)                                  // RTC ERR
                    7'd0: pay_byte = 8'h52; 7'd1: pay_byte = 8'h54; 7'd2: pay_byte = 8'h43;
                    7'd3: pay_byte = 8'h20; 7'd4: pay_byte = 8'h45;
                    default: pay_byte = 8'h52;
                endcase
            end
        end
        PT_GBK:   pay_byte = gbk_byte(m_val[1:0], m_q_d[3:0]);
        PT_FNAME: begin
            if (m_len == 7'd1)
                pay_byte = 8'h2D;                              // 无图：-
            else if (m_q_d == {3'd0, m_nlen})
                pay_byte = 8'h2E;                              // .
            else
                pay_byte = fn_q;
        end
        PT_INDEX: begin
            case (m_q_d)                                      // "01 / 06"
                7'd0: pay_byte = 8'h30;
                7'd1: pay_byte = img_ok ? (8'h31 + {5'd0, m_img}) : 8'h30;
                7'd2: pay_byte = 8'h20;
                7'd3: pay_byte = 8'h2F;
                7'd4: pay_byte = 8'h20;
                7'd5: pay_byte = 8'h30;
                default: pay_byte = 8'h30 + {4'd0, image_count};
            endcase
        end
        PT_INTV:  pay_byte = (m_q_d == 7'd0) ? (8'h30 + m_val) : 8'h53;   // "3S"
        PT_COM:   pay_byte = com_q;
        PT_BGM: begin
            case (m_q_d)                                      // "BGM 1/2"
                7'd0: pay_byte = 8'h42;
                7'd1: pay_byte = 8'h47;
                7'd2: pay_byte = 8'h4D;
                7'd3: pay_byte = 8'h20;
                7'd4: pay_byte = (bgm_track_count == 2'd0) ? 8'h2D : (8'h31 + {7'd0, bgm_track_now});
                7'd5: pay_byte = 8'h2F;
                default: pay_byte = 8'h30 + {6'd0, bgm_track_count};
            endcase
        end
        default:  pay_byte = 8'h00;
    endcase
end

// 文件名读地址：主名 q，扩展名 8 + (q - nlen - 1)
wire [6:0] fn_ext_q = m_q - {3'd0, m_nlen} - 7'd1;
wire [3:0] fn_addr  = (m_q < {3'd0, m_nlen}) ? m_q[3:0] : (4'd8 + fn_ext_q[3:0]);

localparam [2:0] S_IDLE = 3'd0, S_ADDR = 3'd1, S_READ = 3'd2, S_BYTE = 3'd3,
                 S_SEND = 3'd4, S_WAIT = 3'd5;

reg [6:0] m_hlen;

always @(posedge clk) begin
    if (s_state == S_READ) begin
        fn_q  <= fn_ram[{m_img, fn_addr}];
        com_q <= com_ram[m_q[5:0]];
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        s_state  <= S_IDLE;
        m_id     <= 6'd0;
        m_short  <= 1'b0;
        m_c1     <= 8'd0;
        m_c2     <= 8'd0;
        m_page   <= 8'd0;
        m_ctrl   <= 8'd0;
        m_pt     <= PT_NONE;
        m_val    <= 8'd0;
        m_len    <= 7'd0;
        m_pos    <= 7'd0;
        m_q      <= 7'd0;
        m_q_d    <= 7'd0;
        m_img    <= 3'd0;
        m_nlen   <= 4'd0;
        m_hlen   <= 7'd7;
        m_region <= 3'd0;
        dig_t    <= 4'd0;
        dig_u    <= 4'd0;
        tx_start <= 1'b0;
        tx_data  <= 8'd0;
        clr_v    <= 1'b0;
    end else begin
        tx_start <= 1'b0;
        clr_v    <= 1'b0;
        case (s_state)
            S_IDLE: begin
                if (pick_any && !(clr_v && (m_id == pick_id))) begin
                    clr_v    <= 1'b1;
                    m_id     <= pick_id;
                    m_short  <= d_short;
                    m_c1     <= d_c1;
                    m_c2     <= d_c2;
                    m_page   <= d_page;
                    m_ctrl   <= d_ctrl;
                    m_pt     <= d_pt;
                    m_val    <= d_val;
                    m_len    <= d_len;
                    m_hlen   <= d_short ? 7'd2 : 7'd7;
                    m_img    <= current_image_index;
                    m_nlen   <= fn_len[current_image_index];
                    m_pos    <= 7'd0;
                    s_state  <= S_ADDR;
                end
            end
            S_ADDR: begin
                // 区段与负载偏移
                if (m_pos < m_hlen) begin
                    m_region <= 3'd0;
                    m_q      <= 7'd0;
                end else if (m_pos < m_hlen + m_len) begin
                    m_region <= 3'd1;
                    m_q      <= m_pos - m_hlen;
                end else if (m_pos < m_hlen + m_len + 7'd4) begin
                    m_region <= 3'd2;
                    m_q      <= m_pos - m_hlen - m_len;
                end else begin
                    m_region <= 3'd3;
                end
                s_state <= S_READ;
            end
            S_READ: begin
                m_q_d   <= m_q;
                dig_t   <= dig_src_t;
                dig_u   <= dec_units(dig_src, dig_src_t);
                s_state <= S_BYTE;
            end
            S_BYTE: begin
                case (m_region)
                    3'd0: begin
                        if (m_short) begin
                            tx_data <= (m_pos == 7'd0) ? 8'hEE : m_c1;
                        end else begin
                            case (m_pos)
                                7'd0: tx_data <= 8'hEE;
                                7'd1: tx_data <= m_c1;
                                7'd2: tx_data <= m_c2;
                                7'd4: tx_data <= m_page;
                                7'd6: tx_data <= m_ctrl;
                                default: tx_data <= 8'h00;
                            endcase
                        end
                    end
                    3'd1: tx_data <= pay_byte;
                    3'd2: tx_data <= (m_q_d == 7'd1) ? 8'hFC : 8'hFF;
                    default: ;
                endcase
                s_state <= (m_region == 3'd3) ? S_IDLE : S_SEND;
            end
            S_SEND: begin
                if (!tx_busy) begin
                    tx_start <= 1'b1;
                    s_state  <= S_WAIT;
                end
            end
            default: begin                       // S_WAIT：等 tx_busy 拉高再回到下一字节
                if (tx_busy) begin
                    m_pos   <= m_pos + 7'd1;
                    s_state <= S_ADDR;
                end
            end
        endcase
    end
end

endmodule
`endif
