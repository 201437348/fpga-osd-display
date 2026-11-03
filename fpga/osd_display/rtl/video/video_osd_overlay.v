// ===========================================================================
// video_osd_overlay -- 顶栏信息行 / 滚动字幕 / 底部状态栏 + 时钟（video_clk，640x480）
//
// 版面：
//   y   0..23   顶栏（半透明），文字 y 4..19：信息行 40 字符，x 16 起
//   y 432..455  滚动字幕带（可关），文字 y 436..451，64 字符 x 8px = 512px 一周期
//   y 456..479  底部状态栏，文字 y 460..475：指示块 x 8..15，状态 x 24 起 10 字符，
//               时钟 HH:MM:SS x 552 起
//
// 文字全部用 osd_font_rom 的 8x16 ASCII（与设置面板同一套 Consolas 字形）。
// 字库 ROM 在顶层例化、双口：A 口给设置面板，B 口给本模块。四处文字的 y 范围
// 互不重叠，所以本模块只要一个读口：按当前行选文字源，按下一个像素 xa = x + 1
// 选字符、出 ROM 地址，ROM 同步读晚一拍后正好对齐当前像素，输出仍是 rgb_in 的
// 纯组合函数，de/vs 不需要重新对齐。（旧版每处文字各带一份 8x8 LUT 字库，
// 单独综合约 1170 LUT；改成共用 BRAM 字库后只剩选字逻辑。）
//
// 唯一的副作用：行首消隐期间 x 停在 0，第 0 个像素取到的是第 1 个像素的字。
// 只有滚动字幕从 x = 0 开始，所以字幕第 0 列直接不画。
// ===========================================================================
module video_osd_overlay #(
    parameter integer CLK_HZ = 25_000_000   // video_clk，时钟秒分频用
) (
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        display_valid,
    input  wire        display_test_pattern,
    input  wire        storage_ready,
    input  wire [2:0]  manager_state,
    input  wire        load_in_progress,
    input  wire [2:0]  target_image_index,
    input  wire [2:0]  current_image_index,
    input  wire [3:0]  image_count,
    // 顶栏信息行（osd_info_text 生成）：40 个 ASCII，按 info_addr 组合读回 info_char
    output wire [5:0]  info_addr,
    input  wire [7:0]  info_char,
    // 时钟校时（串口屏 RTC）：time_set 单拍有效时装入 时/分/秒（二进制，
    // 时 0..23、分秒 0..59，超范围忽略），此后本地每秒走时。没有校时源时从上电 00:00:00
    // 开始计，即显示上电运行时间。
    input  wire        time_set,
    input  wire [4:0]  time_h,
    input  wire [5:0]  time_m,
    input  wire [5:0]  time_s,
    // 串口屏：滚动字幕开关 + 可写字幕。两个电平来自控制域，模块内各打 2FF；
    // 字幕 RAM 写口直接挂在控制域时钟上（64 x 8，读口在 video_clk）。
    // ticker_custom = 0 显示内置默认字幕，= 1 显示 RAM 里的屏幕字幕。
    input  wire        ticker_enable,
    input  wire        ticker_custom,
    input  wire        ticker_wr_clk,
    input  wire        ticker_wr_en,
    input  wire [5:0]  ticker_wr_addr,
    input  wire [7:0]  ticker_wr_data,
    // 字库读口（osd_font_rom 的 B 口，同步读 1 拍）
    output wire [10:0] font_addr,
    input  wire [15:0] font_q,
    output wire [23:0] rgb_out
);


localparam [9:0] TOP_BAR_HEIGHT = 10'd24;
localparam [9:0] BOTTOM_BAR_Y   = 10'd456;
localparam [9:0] TITLE_X        = 10'd16;
localparam [9:0] TITLE_Y        = 10'd4;
localparam [9:0] TITLE_CHARS    = 10'd40;
localparam [9:0] STATUS_X       = 10'd24;
localparam [9:0] STATUS_Y       = 10'd460;
localparam [9:0] STATUS_CHARS   = 10'd10;
localparam [9:0] TICKER_BAR_Y      = 10'd432;
localparam [9:0] TICKER_BAR_HEIGHT = 10'd24;
localparam [9:0] TICKER_TEXT_Y     = 10'd436;

localparam [23:0] BAR_RGB      = 24'h10213A;
localparam [23:0] TITLE_RGB    = 24'hF4F7FB;
localparam [23:0] TICKER_RGB   = 24'hFFD166;
localparam [23:0] READY_RGB    = 24'h54E3E3;
localparam [23:0] FALLBACK_RGB = 24'hFFD166;
localparam [23:0] WAIT_RGB     = 24'hFF6B6B;
localparam [23:0] LOAD_RGB     = 24'h7EE787;
localparam [23:0] SCAN_RGB     = 24'hA7C7FF;
localparam [23:0] CLOCK_RGB    = 24'hF4F7FB;

// 状态栏右侧时钟 HH:MM:SS（8 字符 x 8px），与左侧状态文字同一行
localparam [9:0] CLOCK_X = 10'd552;

// 三条信息栏背景半透明：out = bar*3/4 + img*1/4（仅移位加法），文字仍不透明
function [23:0] bar_blend;
    input [23:0] img;
    begin
        bar_blend[23:16] = {2'b00, BAR_RGB[23:18]} + {1'b0, BAR_RGB[23:17]} + {2'b00, img[23:18]};
        bar_blend[15:8]  = {2'b00, BAR_RGB[15:10]} + {1'b0, BAR_RGB[15:9]}  + {2'b00, img[15:10]};
        bar_blend[7:0]   = {2'b00, BAR_RGB[7:2]}   + {1'b0, BAR_RGB[7:1]}   + {2'b00, img[7:2]};
    end
endfunction

reg [9:0] x;
reg [9:0] y;
reg       de_d;
reg       vs_d;
reg [23:0] rgb_out_r;
reg [1:0] ticker_frame_divider;
reg [8:0] ticker_scroll_offset;

// ---- 串口屏字幕：开关同步 + 64 字节字幕 RAM ----
reg  [1:0] ticker_en_sync;
reg  [1:0] ticker_custom_sync;
reg  [7:0] ticker_ram [0:63];

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        ticker_en_sync     <= 2'b11;
        ticker_custom_sync <= 2'b00;
    end else begin
        ticker_en_sync     <= {ticker_en_sync[0], ticker_enable};
        ticker_custom_sync <= {ticker_custom_sync[0], ticker_custom};
    end
end

always @(posedge ticker_wr_clk) begin
    if (ticker_wr_en)
        ticker_ram[ticker_wr_addr] <= ticker_wr_data;
end

// ---- 时钟：秒分频 + 时分秒计数 ----
reg [24:0] sec_div;
reg [4:0]  clk_h;
reg [5:0]  clk_m;
reg [5:0]  clk_s;
wire       sec_tick = (sec_div == CLK_HZ - 1);

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        sec_div <= 25'd0;
        clk_h   <= 5'd0;
        clk_m   <= 6'd0;
        clk_s   <= 6'd0;
    end else if (time_set && (time_h < 5'd24) && (time_m < 6'd60) && (time_s < 6'd60)) begin
        sec_div <= 25'd0;
        clk_h   <= time_h;
        clk_m   <= time_m;
        clk_s   <= time_s;
    end else begin
        sec_div <= sec_tick ? 25'd0 : sec_div + 25'd1;
        if (sec_tick) begin
            if (clk_s != 6'd59) begin
                clk_s <= clk_s + 6'd1;
            end else begin
                clk_s <= 6'd0;
                if (clk_m != 6'd59) begin
                    clk_m <= clk_m + 6'd1;
                end else begin
                    clk_m <= 6'd0;
                    clk_h <= (clk_h == 5'd23) ? 5'd0 : clk_h + 5'd1;
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// 当前行的文字源（y 在整行内不变）
// ---------------------------------------------------------------------------
wire ticker_active = ticker_en_sync[1] && (y >= TICKER_BAR_Y) &&
                     (y < (TICKER_BAR_Y + TICKER_BAR_HEIGHT));
wire title_line    = (y >= TITLE_Y) && (y < (TITLE_Y + 10'd16));
wire ticker_line   = ticker_en_sync[1] && (y >= TICKER_TEXT_Y) && (y < (TICKER_TEXT_Y + 10'd16));
wire status_line   = (y >= STATUS_Y) && (y < (STATUS_Y + 10'd16));
// TITLE_Y = 4 与 TICKER_TEXT_Y = 436 模 16 同余，两行共用一个减法
wire [9:0] row_tt  = y - TITLE_Y;
wire [9:0] row_st  = y - STATUS_Y;
wire [3:0] font_row = status_line ? row_st[3:0] : row_tt[3:0];

// ---------------------------------------------------------------------------
// 按下一个像素 xa 选字符
// ---------------------------------------------------------------------------
wire [9:0] xa = x + 10'd1;

wire [9:0] title_dx  = xa - TITLE_X;
wire [9:0] status_dx = xa - STATUS_X;
wire [9:0] clock_dx  = xa - CLOCK_X;
wire       title_col_ok  = (xa >= TITLE_X)  && (title_dx  < TITLE_CHARS * 10'd8);
wire       status_col_ok = (xa >= STATUS_X) && (status_dx < STATUS_CHARS * 10'd8);
wire       clock_col_ok  = (xa >= CLOCK_X)  && (clock_dx  < 10'd64);

// 字幕：64 字符 x 8px = 512px 一个周期，回绕只需截位
wire [10:0] ticker_x_sum = {1'b0, xa} + {2'b00, ticker_scroll_offset};
wire [5:0]  ticker_idx   = ticker_x_sum[8:3];
wire [7:0]  ticker_code  = ticker_custom_sync[1] ? ticker_ram[ticker_idx] : ticker_char(ticker_idx);

assign info_addr = title_dx[8:3];

wire [7:0] status_code = status_char(status_dx[6:3], display_valid, display_test_pattern,
                                     storage_ready, manager_state, load_in_progress,
                                     target_image_index, current_image_index, image_count);
wire [7:0] clock_code  = clock_digit(clock_dx[5:3], clk_h, clk_m, clk_s);

localparam [2:0] SRC_NONE = 3'd0, SRC_TITLE = 3'd1, SRC_TICKER = 3'd2,
                 SRC_STATUS = 3'd3, SRC_CLOCK = 3'd4;

reg  [7:0] code;
reg  [2:0] col;
reg  [2:0] src;
always @* begin
    code = 8'h20;
    col  = 3'd0;
    src  = SRC_NONE;
    if (title_line) begin
        if (title_col_ok) begin
            code = info_char; col = title_dx[2:0]; src = SRC_TITLE;
        end
    end else if (ticker_line) begin
        code = ticker_code; col = ticker_x_sum[2:0]; src = SRC_TICKER;
    end else if (status_line) begin
        if (status_col_ok) begin
            code = status_code; col = status_dx[2:0]; src = SRC_STATUS;
        end else if (clock_col_ok) begin
            code = clock_code; col = clock_dx[2:0]; src = SRC_CLOCK;
        end
    end
end

// 字库只有 0x20..0x7F 的 ASCII（gid 0..31 是汉字），其余码一律按空格画
wire [6:0] gid = ((code < 8'h20) || code[7]) ? 7'h20 : code[6:0];
assign font_addr = {gid, font_row};

reg [2:0] col_q;
reg [2:0] src_q;
always @(posedge video_clk) begin
    col_q <= col;
    src_q <= src;
end
wire       glyph_on    = font_q[4'd15 - {1'b0, col_q}];
wire       title_pixel  = (src_q == SRC_TITLE)  && glyph_on;
wire       ticker_pixel = (src_q == SRC_TICKER) && glyph_on && (x != 10'd0);
wire       status_pixel = (src_q == SRC_STATUS) && glyph_on;
wire       clock_pixel  = (src_q == SRC_CLOCK)  && glyph_on;

wire indicator_active = (y >= (STATUS_Y + 10'd4)) && (y < (STATUS_Y + 10'd12)) &&
                        (x >= 10'd8) && (x < 10'd16);
wire [23:0] status_rgb = display_test_pattern ? FALLBACK_RGB :
                         !storage_ready ? WAIT_RGB :
                         load_in_progress ? LOAD_RGB :
                         ((manager_state == 3'd1) || (manager_state == 3'd6) ||
                          !display_valid) ? SCAN_RGB : READY_RGB;
assign rgb_out = rgb_out_r;

function [7:0] ticker_char;
    input [5:0] char_index;
    begin
        case (char_index)
            6'd0:  ticker_char = 8'h20; // space
            6'd1:  ticker_char = 8'h46; // F
            6'd2:  ticker_char = 8'h50; // P
            6'd3:  ticker_char = 8'h47; // G
            6'd4:  ticker_char = 8'h41; // A
            6'd5:  ticker_char = 8'h20; // space
            6'd6:  ticker_char = 8'h48; // H
            6'd7:  ticker_char = 8'h44; // D
            6'd8:  ticker_char = 8'h4D; // M
            6'd9:  ticker_char = 8'h49; // I
            6'd10: ticker_char = 8'h20; // space
            6'd11: ticker_char = 8'h4D; // M
            6'd12: ticker_char = 8'h55; // U
            6'd13: ticker_char = 8'h4C; // L
            6'd14: ticker_char = 8'h54; // T
            6'd15: ticker_char = 8'h49; // I
            6'd16: ticker_char = 8'h4D; // M
            6'd17: ticker_char = 8'h45; // E
            6'd18: ticker_char = 8'h44; // D
            6'd19: ticker_char = 8'h49; // I
            6'd20: ticker_char = 8'h41; // A
            6'd21: ticker_char = 8'h20; // space
            6'd22: ticker_char = 8'h44; // D
            6'd23: ticker_char = 8'h49; // I
            6'd24: ticker_char = 8'h53; // S
            6'd25: ticker_char = 8'h50; // P
            6'd26: ticker_char = 8'h4C; // L
            6'd27: ticker_char = 8'h41; // A
            6'd28: ticker_char = 8'h59; // Y
            6'd29: ticker_char = 8'h20; // space
            6'd30: ticker_char = 8'h2F; // /
            6'd31: ticker_char = 8'h20; // space
            6'd32: ticker_char = 8'h54; // T
            6'd33: ticker_char = 8'h46; // F
            6'd34: ticker_char = 8'h20; // space
            6'd35: ticker_char = 8'h49; // I
            6'd36: ticker_char = 8'h4D; // M
            6'd37: ticker_char = 8'h41; // A
            6'd38: ticker_char = 8'h47; // G
            6'd39: ticker_char = 8'h45; // E
            6'd40: ticker_char = 8'h20; // space
            6'd41: ticker_char = 8'h2F; // /
            6'd42: ticker_char = 8'h20; // space
            6'd43: ticker_char = 8'h34; // 4
            6'd44: ticker_char = 8'h38; // 8
            6'd45: ticker_char = 8'h4B; // K
            6'd46: ticker_char = 8'h20; // space
            6'd47: ticker_char = 8'h41; // A
            6'd48: ticker_char = 8'h55; // U
            6'd49: ticker_char = 8'h44; // D
            6'd50: ticker_char = 8'h49; // I
            6'd51: ticker_char = 8'h4F; // O
            6'd52: ticker_char = 8'h20; // space
            6'd53: ticker_char = 8'h2F; // /
            6'd54: ticker_char = 8'h20; // space
            default: ticker_char = 8'h20;
        endcase
    end
endfunction

// 0..59 -> 十位 / 个位字符码（值域小，直接比较，不用除法器）
function [7:0] tens_char;
    input [5:0] v;
    begin
        tens_char = (v >= 6'd50) ? 8'h35 : (v >= 6'd40) ? 8'h34 :
                    (v >= 6'd30) ? 8'h33 : (v >= 6'd20) ? 8'h32 :
                    (v >= 6'd10) ? 8'h31 : 8'h30;
    end
endfunction

function [7:0] units_char;
    input [5:0] v;
    begin
        units_char = 8'h30 + ((v >= 6'd50) ? v - 6'd50 : (v >= 6'd40) ? v - 6'd40 :
                              (v >= 6'd30) ? v - 6'd30 : (v >= 6'd20) ? v - 6'd20 :
                              (v >= 6'd10) ? v - 6'd10 : v);
    end
endfunction

function [7:0] clock_digit;       // 位置 0..7 -> "HH:MM:SS"
    input [2:0] pos;
    input [4:0] h;
    input [5:0] m;
    input [5:0] sec;
    begin
        case (pos)
            3'd0:    clock_digit = tens_char({1'b0, h});
            3'd1:    clock_digit = units_char({1'b0, h});
            3'd3:    clock_digit = tens_char(m);
            3'd4:    clock_digit = units_char(m);
            3'd6:    clock_digit = tens_char(sec);
            3'd7:    clock_digit = units_char(sec);
            default: clock_digit = 8'h3A;   // ':'
        endcase
    end
endfunction

function [7:0] status_char;
    input [3:0] char_index;
    input       valid;
    input       fallback;
    input       ready;
    input [2:0] state;
    input       loading;
    input [2:0] target_index;
    input [2:0] current_index;
    input [3:0] count;
    begin
        status_char = 8'h20;
        if (fallback) begin
            case (char_index)
                4'd0: status_char = 8'h46; // F
                4'd1: status_char = 8'h41; // A
                4'd2: status_char = 8'h4C; // L
                4'd3: status_char = 8'h4C; // L
                4'd4: status_char = 8'h42; // B
                4'd5: status_char = 8'h41; // A
                4'd6: status_char = 8'h43; // C
                4'd7: status_char = 8'h4B; // K
            endcase
        end else if (!ready) begin
            case (char_index)
                4'd0: status_char = 8'h57; // W
                4'd1: status_char = 8'h41; // A
                4'd2: status_char = 8'h49; // I
                4'd3: status_char = 8'h54; // T
                4'd4: status_char = 8'h20; // space
                4'd5: status_char = 8'h54; // T
                4'd6: status_char = 8'h46; // F
            endcase
        end else if (loading) begin
            case (char_index)
                4'd0: status_char = 8'h4C; // L
                4'd1: status_char = 8'h4F; // O
                4'd2: status_char = 8'h41; // A
                4'd3: status_char = 8'h44; // D
                4'd4: status_char = 8'h20; // space
                4'd5: status_char = 8'h30 + target_index + 2'd1;
                4'd6: status_char = 8'h2F; // /
                4'd7: status_char = 8'h30 + count;
            endcase
        end else if ((state == 3'd1) || (state == 3'd6) || !valid) begin
            case (char_index)
                4'd0: status_char = 8'h53; // S
                4'd1: status_char = 8'h43; // C
                4'd2: status_char = 8'h41; // A
                4'd3: status_char = 8'h4E; // N
            endcase
        end else begin
            case (char_index)
                4'd0: status_char = 8'h49; // I
                4'd1: status_char = 8'h4D; // M
                4'd2: status_char = 8'h41; // A
                4'd3: status_char = 8'h47; // G
                4'd4: status_char = 8'h45; // E
                4'd5: status_char = 8'h20; // space
                4'd6: status_char = 8'h30 + current_index + 2'd1;
                4'd7: status_char = 8'h2F; // /
                4'd8: status_char = 8'h30 + count;
            endcase
        end
    end
endfunction

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x                    <= 10'd0;
        y                    <= 10'd0;
        de_d                 <= 1'b0;
        vs_d                 <= 1'b0;
        ticker_frame_divider <= 2'd0;
        ticker_scroll_offset <= 9'd0;
    end else begin
        de_d <= de;
        vs_d <= vs;

        if (vs && !vs_d) begin
            if (ticker_frame_divider == 2'd2) begin
                ticker_frame_divider <= 2'd0;
                ticker_scroll_offset <= ticker_scroll_offset + 9'd1;   // 512 回绕
            end else begin
                ticker_frame_divider <= ticker_frame_divider + 2'd1;
            end

            x <= 10'd0;
            y <= 10'd0;
        end else if (de) begin
            x <= x + 10'd1;
        end else if (de_d) begin
            x <= 10'd0;
            y <= y + 10'd1;
        end
    end
end

always @* begin
    rgb_out_r = rgb_in;

    if (de) begin
        if (y < TOP_BAR_HEIGHT) begin
            rgb_out_r = bar_blend(rgb_in);
            if (title_pixel)
                rgb_out_r = TITLE_RGB;
        end else if (ticker_active) begin
            rgb_out_r = bar_blend(rgb_in);
            if (ticker_pixel)
                rgb_out_r = TICKER_RGB;
        end else if (y >= BOTTOM_BAR_Y) begin
            rgb_out_r = bar_blend(rgb_in);
            if (indicator_active || status_pixel)
                rgb_out_r = status_rgb;
            else if (clock_pixel)
                rgb_out_r = CLOCK_RGB;
        end
    end
end

endmodule
