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
//             10 = 亮度+对比度一起调   11 = 恢复默认
//   sw[3:2] : 00 = 步长 1   01 = 步长 4     10 = 步长 16   11 = 步长 32
//
// 注意：四个通道档位全部有实际作用，**不设"保留"档**。早期版本把 11 做成
// "保留/按键忽略"，结果"四个开关全拨上"这个最自然的位置按什么都没反应，
// 上板时被误判成功能坏了。
//
// 按键（KEY3）：
//   短按（松手时未达长按阈值）              -> 当前通道 += 步长
//   长按（按住 >= LONG_PRESS_MS，松手时判定）-> 当前通道 -= 步长
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
    parameter [7:0]   CONTRAST_DEFAULT   = 8'd128
)(
    input  wire       clk,
    input  wire       rst,           // 高有效异步
    input  wire       key,           // KEY3，低有效
    input  wire [3:0] sw,            // 逻辑值，1 = 合上
    output wire [7:0] brightness,
    output wire [7:0] contrast,
    output wire [1:0] menu_channel,  // 当前调节通道，供 OSD 高亮
    output wire       menu_active,   // 最近一次操作后保持 MENU_HOLD_MS
    output wire       cfg_toggle     // 每次配置变化翻转一次（跨时钟域握手）
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

    // 一次"操作"：拨码变化，或保留档以外的按键松手
    wire menu_event = sw_changed || (key_release && (sel_ch != 2'b11));

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

    wire [7:0] b_plus  = (cur_b > (8'd255 - step)) ? 8'd255 : (cur_b + step);
    wire [7:0] b_minus = (cur_b > step)            ? (cur_b - step) : 8'd0;
    wire [7:0] c_plus  = (cur_c > (8'd255 - step)) ? 8'd255 : (cur_c + step);
    wire [7:0] c_minus = (cur_c > step)            ? (cur_c - step) : 8'd0;

    reg [7:0] next_b;
    reg [7:0] next_c;
    reg [1:0] next_ch;
    reg       next_active;

    always @* begin
        next_b  = cur_b;
        next_c  = cur_c;
        next_ch = cur_ch;

        // 关键：本拍有操作事件就立刻点亮菜单，与数值变化同一拍提交，
        // 保证"一次操作 = cfg 变化一次 = cfg_toggle 翻转一次"
        next_active = menu_event ? 1'b1 : menu_active_now;

        if (sel_ch == 2'b11) begin
            // 恢复默认：持续强制默认值，拨回别的档位即从默认值继续
            next_b  = BRIGHTNESS_DEFAULT;
            next_c  = CONTRAST_DEFAULT;
            next_ch = 2'b11;
        end else begin
            next_ch = sel_ch;
            if (key_release) begin
                // 00 = 只调亮度，01 = 只调对比度，10 = 两个一起调
                if (sel_ch != 2'b01)
                    next_b = long_fired ? b_minus : b_plus;
                if (sel_ch != 2'b00)
                    next_c = long_fired ? c_minus : c_plus;
            end
        end
    end

    wire [18:0] next_cfg   = {next_ch, next_active, next_c, next_b};
    wire        cfg_change = (next_cfg != cfg);
    wire        spacing_ok = (spacing == 5'd0);

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
`endif
