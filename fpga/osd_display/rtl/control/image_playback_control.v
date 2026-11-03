// ===========================================================================
// image_playback_control -- KEY1/KEY2 播放控制（sd_card_clk 域）
//
// KEY1（低有效）：
//   短按（松手时未到长按阈值）   -> 下一张（next_request）
//   长按（按住达到 LONG_PRESS_MS）-> 上一张（prev_request，按住期间立即触发，
//                                  松手不再补发下一张）
// KEY2（低有效）：
//   短按 -> 开/关自动播放
//   长按 -> 自动播放间隔在 1/2/3/5 秒之间循环（auto_period_sec），不改开关状态
//
// 串口屏命令（同域单拍）：cmd_next / cmd_prev / cmd_auto_toggle 与按键动作等效；
// cmd_period_valid 把间隔直接设为 cmd_period（只接受 1/2/3/5）；
// hold = 1（定时息屏）时暂停自动播放计时，开关状态保留，hold 撤销后继续。
//
// 自动播放计时：1 秒节拍计数 + 秒计数，不用 32 位大比较器（时序）。
// 任何按键动作都让计时从头开始，且同一拍不会再发自动请求。
// ===========================================================================
module image_playback_control #(
    parameter integer CLK_FREQ_HZ           = 100_000_000,
    parameter integer AUTO_INTERVAL_SECONDS = 1,      // 上电默认间隔（1/2/3/5）
    parameter integer DEBOUNCE_MS           = 50,
    parameter integer LONG_PRESS_MS         = 800
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       key_next,
    input  wire       key_auto,
    input  wire       display_valid,
    input  wire [3:0] image_count,
    input  wire       manager_idle,
    input  wire       cmd_next,
    input  wire       cmd_prev,
    input  wire       cmd_auto_toggle,
    input  wire       cmd_period_valid,
    input  wire [2:0] cmd_period,
    input  wire       hold,
    output reg        next_request,
    output reg        prev_request,
    output reg        auto_request,
    output reg        auto_play_enabled,
    output reg [2:0]  auto_period_sec,
    output wire       key_down          // KEY1/KEY2 任一已消抖按下（给按键提示音）
);

localparam integer MS_CYCLES        = CLK_FREQ_HZ / 1000;
localparam integer LONG_CYCLES      = MS_CYCLES * LONG_PRESS_MS;
localparam integer SEC_CYCLES       = CLK_FREQ_HZ;
localparam integer HOLD_W           = $clog2(LONG_CYCLES + 1);
localparam integer SEC_W            = $clog2(SEC_CYCLES + 1);

wire next_down, next_press, next_release;
wire auto_down, auto_press, auto_release;

assign key_down = next_down || auto_down;

key_debounce_level #(.DEBOUNCE_CYCLES(MS_CYCLES * DEBOUNCE_MS)) u_key_next (
    .clk(clk), .rst(rst), .key_n(key_next),
    .down(next_down), .press(next_press), .release_pulse(next_release)
);

key_debounce_level #(.DEBOUNCE_CYCLES(MS_CYCLES * DEBOUNCE_MS)) u_key_auto (
    .clk(clk), .rst(rst), .key_n(key_auto),
    .down(auto_down), .press(auto_press), .release_pulse(auto_release)
);

// ---- 长按计时：到阈值那一拍给出 long_hit，之后打 long_fired 直到松手 ----
reg [HOLD_W-1:0] next_hold;
reg [HOLD_W-1:0] auto_hold;
reg              next_long_fired;
reg              auto_long_fired;
wire next_long_hit = next_down && !next_long_fired && (next_hold == LONG_CYCLES - 1);
wire auto_long_hit = auto_down && !auto_long_fired && (auto_hold == LONG_CYCLES - 1);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_hold       <= {HOLD_W{1'b0}};
        auto_hold       <= {HOLD_W{1'b0}};
        next_long_fired <= 1'b0;
        auto_long_fired <= 1'b0;
    end else begin
        if (!next_down) begin
            next_hold       <= {HOLD_W{1'b0}};
            next_long_fired <= 1'b0;
        end else if (!next_long_fired) begin
            next_hold <= next_hold + 1'b1;
            if (next_long_hit)
                next_long_fired <= 1'b1;
        end

        if (!auto_down) begin
            auto_hold       <= {HOLD_W{1'b0}};
            auto_long_fired <= 1'b0;
        end else if (!auto_long_fired) begin
            auto_hold <= auto_hold + 1'b1;
            if (auto_long_hit)
                auto_long_fired <= 1'b1;
        end
    end
end

wire next_short = next_release && !next_long_fired;
wire auto_short = auto_release && !auto_long_fired;
wire go_next    = next_short || cmd_next;
wire go_prev    = next_long_hit || cmd_prev;
wire go_toggle  = auto_short || cmd_auto_toggle;
wire period_ok  = (cmd_period == 3'd1) || (cmd_period == 3'd2) ||
                  (cmd_period == 3'd3) || (cmd_period == 3'd5);
wire key_action = next_press || next_release || auto_press || auto_release ||
                  next_long_hit || auto_long_hit ||
                  cmd_next || cmd_prev || cmd_auto_toggle || cmd_period_valid;

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

// ---- 自动播放计时 ----
reg [SEC_W-1:0] sec_counter;
reg [2:0]       sec_elapsed;
wire sec_tick = (sec_counter == SEC_CYCLES - 1);
wire auto_run = auto_play_enabled && display_valid && manager_idle && !hold &&
                (image_count > 4'd1);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_request      <= 1'b0;
        prev_request      <= 1'b0;
        auto_request      <= 1'b0;
        auto_play_enabled <= 1'b0;
        auto_period_sec   <= AUTO_INTERVAL_SECONDS[2:0];
        sec_counter       <= {SEC_W{1'b0}};
        sec_elapsed       <= 3'd0;
    end else begin
        next_request <= 1'b0;
        prev_request <= 1'b0;
        auto_request <= 1'b0;

        if (go_next && manager_idle && (image_count != 4'd0))
            next_request <= 1'b1;
        else if (go_prev && manager_idle && (image_count > 4'd1))
            prev_request <= 1'b1;

        if (go_toggle && (image_count > 4'd1))
            auto_play_enabled <= ~auto_play_enabled;
        if (cmd_period_valid && period_ok)
            auto_period_sec <= cmd_period;
        else if (auto_long_hit)
            auto_period_sec <= next_period(auto_period_sec);

        if (key_action || !auto_run) begin
            sec_counter <= {SEC_W{1'b0}};
            sec_elapsed <= 3'd0;
        end else if (sec_tick) begin
            sec_counter <= {SEC_W{1'b0}};
            if (sec_elapsed + 3'd1 >= auto_period_sec) begin
                auto_request <= 1'b1;
                sec_elapsed  <= 3'd0;
            end else begin
                sec_elapsed <= sec_elapsed + 3'd1;
            end
        end else begin
            sec_counter <= sec_counter + 1'b1;
        end
    end
end

endmodule

// ---------------------------------------------------------------------------
// key_debounce_level -- 低有效按键：2FF 同步 + 消抖，输出稳定电平与按下/松开沿
// ---------------------------------------------------------------------------
module key_debounce_level #(
    parameter integer DEBOUNCE_CYCLES = 5_000_000
)(
    input  wire clk,
    input  wire rst,
    input  wire key_n,
    output wire down,
    output reg  press,
    output reg  release_pulse
);

localparam integer CW = $clog2(DEBOUNCE_CYCLES + 1);

reg          s0, s1, stable_n;
reg [CW-1:0] counter;

assign down = !stable_n;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        s0            <= 1'b1;
        s1            <= 1'b1;
        stable_n      <= 1'b1;
        counter       <= {CW{1'b0}};
        press         <= 1'b0;
        release_pulse <= 1'b0;
    end else begin
        s0            <= key_n;
        s1            <= s0;
        press         <= 1'b0;
        release_pulse <= 1'b0;

        if (s1 == stable_n) begin
            counter <= {CW{1'b0}};
        end else if (counter == DEBOUNCE_CYCLES - 1) begin
            stable_n      <= s1;
            counter       <= {CW{1'b0}};
            press         <= stable_n && !s1;
            release_pulse <= !stable_n && s1;
        end else begin
            counter <= counter + 1'b1;
        end
    end
end

endmodule
