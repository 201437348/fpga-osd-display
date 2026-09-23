module video_osd_overlay (
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
    input  wire        menu_active,
    input  wire [7:0]  brightness_value,
    input  wire [7:0]  contrast_value,
    input  wire [1:0]  menu_channel,
    input wire [7:0] audio_level,
    input wire [383:0] audio_bands,
    output wire [23:0] rgb_out
);

localparam [9:0] TOP_BAR_HEIGHT = 10'd24;
localparam [9:0] BOTTOM_BAR_Y   = 10'd456;
localparam [9:0] TITLE_X        = 10'd16;
localparam [9:0] TITLE_Y        = 10'd4;
localparam [9:0] STATUS_X       = 10'd24;
localparam [9:0] STATUS_Y       = 10'd460;
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
localparam [23:0] AUDIO_RGB = 24'h55E6A5;
localparam [23:0] SCAN_RGB     = 24'hA7C7FF;

// ---------------------------------------------------------------------------
// 亮度/对比度参数菜单（第13课）
//
// 版面（640x480，取上条与滚动条之间的空白带 y 24..431）：
//   x 448..631, y 24..59 一块深色面板，两行：
//     亮度行 y 26..39   对比度行 y 44..57
//   每行 = 字母标签 + 3 位十进制数值 + 8 段进度条
//     标签 x 452..459（'B' / 'C'）
//     数值 x 464..487（3 位 x 8px，百位为 0 时显示空格）
//     条   x 492 起，段距 16、段宽 14，共 492..617
//   第 i 段点亮的条件是 value > i*32，于是：
//     value=0 -> 全灭    value=32 -> 1 段    value=128 -> 4 段    value=255 -> 8 段
//   （不能写成 value >= (i+1)*32：第 8 段要求 value>=256，永远点不亮。）
//
// **为什么必须同时显示数字**：8 段条每段覆盖 32 级，而步长是 1/4/16/32，
// 所以步长 1、4、16 时**条根本不会动**，看起来就像"按了没反应"。
// 数字读数能反映每一级变化，也能一眼看出"已经到顶 255 / 到底 0"。
//
// 这一层画在亮度/对比度调节之后，所以菜单本身始终是全亮的，不会被调暗。
// ---------------------------------------------------------------------------
localparam [9:0] MENU_PANEL_X0 = 10'd448;
localparam [9:0] MENU_PANEL_X1 = 10'd632;
localparam [9:0] MENU_PANEL_Y0 = 10'd24;
localparam [9:0] MENU_PANEL_Y1 = 10'd60;
localparam [9:0] MENU_LABEL_X  = 10'd452;
localparam [9:0] MENU_DIGIT_X  = 10'd464;
localparam [9:0] MENU_BAR_X    = 10'd492;
localparam [9:0] MENU_BAR_W    = 10'd128;   // 8 段 x 16
localparam [9:0] MENU_SEG_W    = 10'd14;
localparam [9:0] MENU_ROW0_Y   = 10'd26;    // 亮度行
localparam [9:0] MENU_ROW1_Y   = 10'd44;    // 对比度行
localparam [9:0] MENU_GLYPH_H  = 10'd14;    // 7 行 x 2px

localparam [23:0] MENU_PANEL_RGB = 24'h0B1526;
localparam [23:0] MENU_SEG_ON    = 24'h54E3E3;
localparam [23:0] MENU_SEG_ON_DIM= 24'h2E6E6E;   // 非当前通道的已填充段（暗一档）
localparam [23:0] MENU_SEG_OFF   = 24'h10213A;
localparam [23:0] MENU_LABEL_HL  = 24'hFFD166;
localparam [23:0] MENU_LABEL_DIM = 24'hA7C7FF;

reg [9:0] x;
reg [9:0] y;
reg       de_d;
reg       vs_d;
reg [23:0] rgb_out_r;
reg [1:0] ticker_frame_divider;
reg [8:0] ticker_scroll_offset;

wire [9:0] title_x_offset;
wire [9:0] title_y_offset;
wire [9:0] status_x_offset;
wire [9:0] status_y_offset;
wire [3:0] title_char_index;
wire [3:0] status_char_index;
wire [2:0] title_row;
wire [2:0] status_row;
wire [7:0] title_glyph;
wire [7:0] status_glyph;
wire       title_pixel;
wire       status_pixel;
wire       title_active;
wire       status_active;
wire       indicator_active;
wire [23:0] status_rgb;
wire        ticker_active;
wire        ticker_text_active;
wire [10:0] ticker_x_sum;
wire [9:0] ticker_period_x;
wire [9:0] ticker_y_offset;
wire [5:0] ticker_char_index;
wire [2:0] ticker_column;
wire [2:0] ticker_row;
wire [7:0] ticker_glyph;
wire       ticker_pixel;

wire        menu_panel_active;
wire        menu_row0_active;
wire        menu_row1_active;
wire [9:0]  menu_row0_yoff;
wire [9:0]  menu_row1_yoff;
wire [9:0]  menu_label_xoff;
wire        menu_label_col;
wire [7:0]  menu_label_b_glyph;
wire [7:0]  menu_label_c_glyph;
wire        menu_label_b_pixel;
wire        menu_label_c_pixel;
wire [9:0]  menu_digit_xoff;
wire        menu_digit_col;
wire [1:0]  menu_digit_sel;
wire [2:0]  menu_digit_bit;
wire [7:0]  menu_b_rem;
wire [7:0]  menu_c_rem;
wire [7:0]  menu_digit_b0;
wire [7:0]  menu_digit_b1;
wire [7:0]  menu_digit_b2;
wire [7:0]  menu_digit_c0;
wire [7:0]  menu_digit_c1;
wire [7:0]  menu_digit_c2;
wire [7:0]  menu_digit_b_glyph;
wire [7:0]  menu_digit_c_glyph;
wire        menu_digit_b_pixel;
wire        menu_digit_c_pixel;
wire [9:0]  menu_seg_x;
wire        menu_seg_col;
wire [2:0]  menu_seg_index;
wire [7:0]  menu_seg_thresh;
wire        menu_seg_b_area;
wire        menu_seg_c_area;
wire        menu_seg_b_on;
wire        menu_seg_c_on;
wire        menu_hl_b;
wire        menu_hl_c;

wire       audio_meter_active;
wire       audio_meter_fill;
wire [23:0] bars_rgb;
wire bars_active, line_active;
audio_bars_overlay u_audio_bars_overlay (
    .x(x), .y(y), .de(de), .bands_display(audio_bands),
    .bars_rgb(bars_rgb), .bars_active(bars_active), .line_active(line_active)
);
wire [9:0] audio_meter_offset;

assign title_x_offset = x - TITLE_X;
assign title_y_offset = y - TITLE_Y;
assign status_x_offset = x - STATUS_X;
assign status_y_offset = y - STATUS_Y;
assign title_char_index = title_x_offset[6:3];
assign status_char_index = status_x_offset[6:3];
assign title_row = title_y_offset[3:1];
assign status_row = status_y_offset[3:1];

assign title_active = (y >= TITLE_Y) && (y < (TITLE_Y + 10'd16)) &&
                      (x >= TITLE_X) && (x < (TITLE_X + 10'd88));
assign status_active = (y >= STATUS_Y) && (y < (STATUS_Y + 10'd16)) &&
                       (x >= STATUS_X) && (x < (STATUS_X + 10'd80));
assign indicator_active = (y >= (STATUS_Y + 10'd4)) &&
                          (y < (STATUS_Y + 10'd12)) &&
                          (x >= 10'd8) && (x < 10'd16);
assign ticker_active = (y >= TICKER_BAR_Y) &&
                       (y < (TICKER_BAR_Y + TICKER_BAR_HEIGHT));
assign ticker_text_active = (y >= TICKER_TEXT_Y) &&
                            (y < (TICKER_TEXT_Y + 10'd16));
assign ticker_x_sum = {1'b0, x} + {2'b00, ticker_scroll_offset};
assign ticker_period_x = (ticker_x_sum >= 11'd880) ? ticker_x_sum - 11'd880 :
                         (ticker_x_sum >= 11'd440) ? ticker_x_sum - 11'd440 :
                                                       ticker_x_sum[9:0];
assign ticker_y_offset = y - TICKER_TEXT_Y;
assign ticker_char_index = ticker_period_x[8:3];
assign ticker_column = ticker_period_x[2:0];
assign ticker_row = ticker_y_offset[3:1];

// ---- 参数菜单解码 ----
assign menu_panel_active = menu_active &&
                           (y >= MENU_PANEL_Y0) && (y < MENU_PANEL_Y1) &&
                           (x >= MENU_PANEL_X0) && (x < MENU_PANEL_X1);

assign menu_row0_yoff = y - MENU_ROW0_Y;
assign menu_row1_yoff = y - MENU_ROW1_Y;
assign menu_row0_active = menu_panel_active && (y >= MENU_ROW0_Y) &&
                          (y < (MENU_ROW0_Y + MENU_GLYPH_H));
assign menu_row1_active = menu_panel_active && (y >= MENU_ROW1_Y) &&
                          (y < (MENU_ROW1_Y + MENU_GLYPH_H));

assign menu_label_xoff = x - MENU_LABEL_X;
assign menu_label_col  = (x >= MENU_LABEL_X) && (x < (MENU_LABEL_X + 10'd8));
assign menu_label_b_glyph = glyph_row(8'h42, menu_row0_yoff[3:1]); // B
assign menu_label_c_glyph = glyph_row(8'h43, menu_row1_yoff[3:1]); // C
assign menu_label_b_pixel = menu_row0_active && menu_label_col &&
                            menu_label_b_glyph[7 - menu_label_xoff[2:0]];
assign menu_label_c_pixel = menu_row1_active && menu_label_col &&
                            menu_label_c_glyph[7 - menu_label_xoff[2:0]];

// ---- 3 位十进制读数 ----
assign menu_b_rem    = digit_rem(brightness_value);
assign menu_c_rem    = digit_rem(contrast_value);
assign menu_digit_b0 = digit_hundreds(brightness_value);
assign menu_digit_b1 = digit_tens(menu_b_rem);
assign menu_digit_b2 = digit_units(menu_b_rem);
assign menu_digit_c0 = digit_hundreds(contrast_value);
assign menu_digit_c1 = digit_tens(menu_c_rem);
assign menu_digit_c2 = digit_units(menu_c_rem);

assign menu_digit_xoff = x - MENU_DIGIT_X;
assign menu_digit_col  = (x >= MENU_DIGIT_X) && (menu_digit_xoff < 10'd24);
assign menu_digit_sel  = menu_digit_xoff[4:3];   // /8 -> 0/1/2
assign menu_digit_bit  = menu_digit_xoff[2:0];
assign menu_digit_b_glyph = glyph_row(
    pick_digit(menu_digit_sel, menu_digit_b0, menu_digit_b1, menu_digit_b2),
    menu_row0_yoff[3:1]);
assign menu_digit_c_glyph = glyph_row(
    pick_digit(menu_digit_sel, menu_digit_c0, menu_digit_c1, menu_digit_c2),
    menu_row1_yoff[3:1]);
assign menu_digit_b_pixel = menu_row0_active && menu_digit_col &&
                            menu_digit_b_glyph[7 - menu_digit_bit];
assign menu_digit_c_pixel = menu_row1_active && menu_digit_col &&
                            menu_digit_c_glyph[7 - menu_digit_bit];

assign menu_seg_x      = x - MENU_BAR_X;
assign menu_seg_col    = (x >= MENU_BAR_X) && (menu_seg_x < MENU_BAR_W);
assign menu_seg_index  = menu_seg_x[6:4];                  // /16 -> 段号 0..7
assign menu_seg_thresh = {menu_seg_index, 5'b00000};       // 段号 x 32
assign menu_seg_b_area = menu_row0_active && menu_seg_col &&
                         (menu_seg_x[3:0] < MENU_SEG_W);
assign menu_seg_c_area = menu_row1_active && menu_seg_col &&
                         (menu_seg_x[3:0] < MENU_SEG_W);
assign menu_seg_b_on   = menu_seg_b_area && (brightness_value > menu_seg_thresh);
assign menu_seg_c_on   = menu_seg_c_area && (contrast_value   > menu_seg_thresh);

// 高亮当前正在调的通道（10 = 两个一起，两行都高亮）
assign menu_hl_b = (menu_channel != 2'b01);
assign menu_hl_c = (menu_channel != 2'b00);

assign title_glyph = glyph_row(title_char(title_char_index), title_row);
assign status_glyph = glyph_row(status_char(status_char_index,
                                             display_valid,
                                             display_test_pattern,
                                             storage_ready,
                                             manager_state,
                                             load_in_progress,
                                             target_image_index,
                                             current_image_index,
                                             image_count), status_row);
assign ticker_glyph = glyph_row(ticker_char(ticker_char_index), ticker_row);
assign title_pixel = title_active && title_glyph[7 - title_x_offset[2:0]];
assign status_pixel = status_active && status_glyph[7 - status_x_offset[2:0]];
assign ticker_pixel = ticker_text_active && ticker_glyph[7 - ticker_column];
assign audio_meter_offset = x - 10'd512;
assign audio_meter_active = (y >= 10'd8) && (y < 10'd16) &&
                            (x >= 10'd512) && (x < 10'd632);
assign audio_meter_fill = audio_meter_active &&
                          (audio_meter_offset < ({2'd0, audio_level} * 10'd120 >> 8));
assign status_rgb = display_test_pattern ? FALLBACK_RGB :
                    !storage_ready ? WAIT_RGB :
                    load_in_progress ? LOAD_RGB :
                    ((manager_state == 3'd1) || (manager_state == 3'd6) ||
                     !display_valid) ? SCAN_RGB : READY_RGB;
assign rgb_out = rgb_out_r;

function [7:0] title_char;
    input [3:0] char_index;
    begin
        case (char_index)
            4'd0: title_char = 8'h4F; // O
            4'd1: title_char = 8'h53; // S
            4'd2: title_char = 8'h44; // D
            4'd3: title_char = 8'h20; // space
            4'd4: title_char = 8'h44; // D
            4'd5: title_char = 8'h49; // I
            4'd6: title_char = 8'h53; // S
            4'd7: title_char = 8'h50; // P
            4'd8: title_char = 8'h4C; // L
            4'd9: title_char = 8'h41; // A
            4'd10: title_char = 8'h59; // Y
            default: title_char = 8'h20;
        endcase
    end
endfunction

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

// ---------------------------------------------------------------------------
// 0..255 -> 三位十进制字符码
//   纯比较/减法实现，刻意不用除法也不用乘法（DSP 已经 25/29，很紧）。
//   百位为 0 时输出空格，读起来是 " 64" 而不是 "064"。
// ---------------------------------------------------------------------------
function [7:0] digit_rem;          // 去掉百位后的余数，0..99
    input [7:0] v;
    begin
        digit_rem = (v >= 8'd200) ? (v - 8'd200) :
                    (v >= 8'd100) ? (v - 8'd100) : v;
    end
endfunction

function [7:0] digit_hundreds;
    input [7:0] v;
    begin
        digit_hundreds = (v >= 8'd200) ? 8'h32 :          // '2'
                         (v >= 8'd100) ? 8'h31 : 8'h20;   // '1' / 空格
    end
endfunction

function [7:0] digit_tens;
    input [7:0] v;                 // 0..99
    begin
        digit_tens = (v >= 8'd90) ? 8'h39 :
                     (v >= 8'd80) ? 8'h38 :
                     (v >= 8'd70) ? 8'h37 :
                     (v >= 8'd60) ? 8'h36 :
                     (v >= 8'd50) ? 8'h35 :
                     (v >= 8'd40) ? 8'h34 :
                     (v >= 8'd30) ? 8'h33 :
                     (v >= 8'd20) ? 8'h32 :
                     (v >= 8'd10) ? 8'h31 : 8'h30;
    end
endfunction

function [7:0] digit_units;
    input [7:0] v;                 // 0..99
    begin
        digit_units = (v >= 8'd90) ? (8'h30 + (v - 8'd90)) :
                      (v >= 8'd80) ? (8'h30 + (v - 8'd80)) :
                      (v >= 8'd70) ? (8'h30 + (v - 8'd70)) :
                      (v >= 8'd60) ? (8'h30 + (v - 8'd60)) :
                      (v >= 8'd50) ? (8'h30 + (v - 8'd50)) :
                      (v >= 8'd40) ? (8'h30 + (v - 8'd40)) :
                      (v >= 8'd30) ? (8'h30 + (v - 8'd30)) :
                      (v >= 8'd20) ? (8'h30 + (v - 8'd20)) :
                      (v >= 8'd10) ? (8'h30 + (v - 8'd10)) :
                                     (8'h30 + v);
    end
endfunction

function [7:0] pick_digit;
    input [1:0] sel;
    input [7:0] d0;
    input [7:0] d1;
    input [7:0] d2;
    begin
        pick_digit = (sel == 2'd0) ? d0 : (sel == 2'd1) ? d1 : d2;
    end
endfunction

function [7:0] glyph_row;
    input [7:0] char_code;
    input [2:0] row;
    begin
        glyph_row = 8'h00;
        case (char_code)
            8'h30: case (row) // 0
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000110;
                3'd3: glyph_row = 8'b01001010;
                3'd4: glyph_row = 8'b01010010;
                3'd5: glyph_row = 8'b01100010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h31: case (row) // 1
                3'd0: glyph_row = 8'b00010000;
                3'd1: glyph_row = 8'b00110000;
                3'd2: glyph_row = 8'b00010000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00111000;
            endcase
            8'h32: case (row) // 2
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b00000010;
                3'd3: glyph_row = 8'b00001100;
                3'd4: glyph_row = 8'b00110000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01111110;
            endcase
            8'h33: case (row) // 3
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b00000010;
                3'd3: glyph_row = 8'b00011100;
                3'd4: glyph_row = 8'b00000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h34: case (row) // 4
                3'd0: glyph_row = 8'b00000100;
                3'd1: glyph_row = 8'b00001100;
                3'd2: glyph_row = 8'b00010100;
                3'd3: glyph_row = 8'b00100100;
                3'd4: glyph_row = 8'b01111110;
                3'd5: glyph_row = 8'b00000100;
                3'd6: glyph_row = 8'b00000100;
            endcase
            8'h35: case (row) // 5
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b00000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h36: case (row) // 6
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h37: case (row) // 7
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b00000010;
                3'd2: glyph_row = 8'b00000100;
                3'd3: glyph_row = 8'b00001000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00010000;
            endcase
            8'h38: case (row) // 8
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b00111100;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h39: case (row) // 9
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b00111110;
                3'd4: glyph_row = 8'b00000010;
                3'd5: glyph_row = 8'b00000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h41: case (row) // A
                3'd0: glyph_row = 8'b00011000;
                3'd1: glyph_row = 8'b00100100;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01111110;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h42: case (row) // B
                3'd0: glyph_row = 8'b01111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01111100;
            endcase
            8'h43: case (row) // C
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01000000;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h44: case (row) // D
                3'd0: glyph_row = 8'b01111000;
                3'd1: glyph_row = 8'b01000100;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000100;
                3'd6: glyph_row = 8'b01111000;
            endcase
            8'h45: case (row) // E
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01111110;
            endcase
            8'h46: case (row) // F
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01000000;
            endcase
            8'h47: case (row) // G
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01001110;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h48: case (row) // H
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111110;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h49: case (row) // I
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b00010000;
                3'd2: glyph_row = 8'b00010000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h4B: case (row) // K
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01000100;
                3'd2: glyph_row = 8'b01001000;
                3'd3: glyph_row = 8'b01110000;
                3'd4: glyph_row = 8'b01001000;
                3'd5: glyph_row = 8'b01000100;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h4C: case (row) // L
                3'd0: glyph_row = 8'b01000000;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01000000;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01111110;
            endcase
            8'h4D: case (row) // M
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01100110;
                3'd2: glyph_row = 8'b01011010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h4E: case (row) // N
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01100010;
                3'd2: glyph_row = 8'b01010010;
                3'd3: glyph_row = 8'b01001010;
                3'd4: glyph_row = 8'b01000110;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h4F: case (row) // O
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h50: case (row) // P
                3'd0: glyph_row = 8'b01111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01000000;
            endcase
            8'h52: case (row) // R
                3'd0: glyph_row = 8'b01111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01001000;
                3'd5: glyph_row = 8'b01000100;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h53: case (row) // S
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b00111100;
                3'd4: glyph_row = 8'b00000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h54: case (row) // T
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b00010000;
                3'd2: glyph_row = 8'b00010000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00010000;
            endcase
            8'h55: case (row) // U
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h57: case (row) // W
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01011010;
                3'd4: glyph_row = 8'b01011010;
                3'd5: glyph_row = 8'b01100110;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h59: case (row) // Y
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b00100100;
                3'd2: glyph_row = 8'b00011000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00010000;
            endcase
            8'h2F: case (row) // /
                3'd0: glyph_row = 8'b00000010;
                3'd1: glyph_row = 8'b00000100;
                3'd2: glyph_row = 8'b00001000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00100000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b00000000;
            endcase
            default: glyph_row = 8'h00;
        endcase
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
                if (ticker_scroll_offset == 9'd439)
                    ticker_scroll_offset <= 9'd0;
                else
                    ticker_scroll_offset <= ticker_scroll_offset + 9'd1;
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
            rgb_out_r = BAR_RGB;
            if (title_pixel)
                rgb_out_r = TITLE_RGB;
            if (audio_meter_active)
                rgb_out_r = audio_meter_fill ? AUDIO_RGB : 24'h244056;
        end else if (ticker_active) begin
            rgb_out_r = BAR_RGB;
            if (ticker_pixel)
                rgb_out_r = TICKER_RGB;
        end else if (y >= BOTTOM_BAR_Y) begin
            rgb_out_r = BAR_RGB;
            if (indicator_active || status_pixel)
                rgb_out_r = status_rgb;
        end

        // 参数菜单画在最上层。它落在 y 24..431 的空白带里，
        // 与上条/滚动条/状态栏都不重叠，不会互相遮挡。
        if (bars_active || line_active)
            rgb_out_r = bars_rgb;

        if (menu_panel_active) begin
            if (menu_seg_b_area)
                rgb_out_r = menu_seg_b_on ? (menu_hl_b ? MENU_SEG_ON : MENU_SEG_ON_DIM)
                                          : MENU_SEG_OFF;
            else if (menu_seg_c_area)
                rgb_out_r = menu_seg_c_on ? (menu_hl_c ? MENU_SEG_ON : MENU_SEG_ON_DIM)
                                          : MENU_SEG_OFF;
            else if (menu_label_b_pixel || menu_digit_b_pixel)
                rgb_out_r = menu_hl_b ? MENU_LABEL_HL : MENU_LABEL_DIM;
            else if (menu_label_c_pixel || menu_digit_c_pixel)
                rgb_out_r = menu_hl_c ? MENU_LABEL_HL : MENU_LABEL_DIM;
            else
                rgb_out_r = MENU_PANEL_RGB;
        end
    end
end

endmodule
