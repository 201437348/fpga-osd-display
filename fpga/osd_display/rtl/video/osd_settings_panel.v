`timescale 1ns/1ps

// ===========================================================================
// osd_settings_panel -- 居中"设置"面板（video_clk 25 MHz，640x480 有效区）
//
// 版面（x 176..463，y 132..335，288 x 204）：纵向按 28px 一行切成 7 行，
//   第 r 行占 y 132+28r .. +27，行内偏移 ry：
//   r = 0     标题条：左"设置"（16x16 汉字），右"SETTINGS"（暗色）
//   r = 1..5  内容行；ry 2..25 为高亮带（x 184..455），ry 0 那条是 r=1 上方的分隔线
//     亮度 / 对比度 / 音量 ：中文标签 + 100px 进度条 + 右对齐百分比
//     背景音乐            ："1/2"，卡上无音乐 "NONE"
//     轮播                ："AUTO 3S" / "MANU"
//   r = 6     操作提示（暗色 ASCII）
//   每行文字都在 ry 6..21。
//   行号 r / ry 用行计数器在每行开始前更新一次，不对 y 做逐像素区间比较（省 LUT）。
//
// 交互：
//   - 任一参数变化（板上按键/拨码、串口屏）都会弹出面板 SHOW_FRAMES 帧，
//     高亮"刚变化的那几行"；拨码切通道时按通道高亮（10 = 亮度+对比度两行）。
//   - 上电后 BOOT_FRAMES 帧内只记录不弹出（SD 扫描、默认值同步期间不打扰）。
//   - 显示/隐藏各经过一级半透明（每级 FADE_FRAMES 帧）。
//
// 文字：字库在顶层的 osd_font_rom（A 口），地址 = {gid, row}。ROM 同步读晚一拍，
// 所以取字地址按下一个像素 x+1 计算，读出数据正好和当前像素对齐，
// 输出仍是 rgb_in 的纯组合函数，de/vs 不需要重新对齐。
//
// 输入：
//   brightness / contrast / channel：视频域、帧边界提交的稳定值（brightness_contrast_adjust）
//   status_sd：sd 域状态包 {volume[3:0], mute, bgm_now, bgm_count[1:0], auto_on, period[2:0]}，
//              本模块内做"连续两拍一致才采纳"的同步，再在 vs 处锁存。
// 不用 DSP（已用满）：百分比 p = (v*401 + 512) >> 10 全部移位加法，
// 且三项数值在帧消隐期间分时共用一套换算电路。
// ===========================================================================
module osd_settings_panel #(
    parameter integer SHOW_FRAMES = 300,   // 5 s @ 60 Hz
    parameter integer BOOT_FRAMES = 240,   // 4 s
    parameter integer FADE_FRAMES = 3      // 每级淡入/淡出帧数
)(
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [1:0]  channel,
    input  wire [11:0] status_sd,
    // 字库读口（osd_font_rom 的 A 口，同步读 1 拍）
    output wire [10:0] font_addr,
    input  wire [15:0] font_q,
    output reg  [23:0] rgb_out
);

// ---------------------------------------------------------------------------
// 版面常量
// ---------------------------------------------------------------------------
localparam [9:0] PX0 = 10'd176, PX1 = 10'd464;      // 面板 [PX0, PX1)
localparam [9:0] PY0 = 10'd132, PY1 = 10'd336;
localparam [4:0] ROW_PITCH = 5'd28;                 // 行计数从 PY0 开始，共 7 行
localparam [2:0] ROW_LAST  = 3'd6;
localparam [4:0] TEXT_RY   = 5'd6;                  // 行内文字 ry 6..21
localparam [4:0] BAND_RY0  = 5'd2, BAND_RY1 = 5'd26;
localparam [4:0] BAR_RY0   = 5'd12, BAR_RY1 = 5'd16;
localparam [9:0] BAND_X0   = 10'd184, BAND_X1 = 10'd456;
localparam [9:0] ACCENT_W  = 10'd3;
localparam [9:0] LABEL_X   = 10'd196;               // 汉字标签，最多 4 字
localparam [9:0] BAR_X     = 10'd284, BAR_W = 10'd100;
localparam [9:0] VALUE_X   = 10'd396;               // 7 个 ASCII，右对齐，到 451
localparam [9:0] TCJK_X    = 10'd192;               // "设置"
localparam [9:0] TASC_X    = 10'd384;               // "SETTINGS"
localparam [9:0] HINT_X    = 10'd196;
localparam integer HINT_LEN = 19;                   // "SW:SELECT  KEY3:+/-"

// 汉字编号：与 tools/gen_osd_font.py 的 CJK 字符串顺序一致
localparam [6:0] CJK_SHE = 7'd0,  CJK_ZHI = 7'd1,  CJK_LIANG = 7'd2, CJK_DU   = 7'd3,
                 CJK_DUI = 7'd4,  CJK_BI  = 7'd5,  CJK_YIN   = 7'd6, CJK_LIANG2 = 7'd7,
                 CJK_BEI = 7'd8,  CJK_JING = 7'd9, CJK_YUE   = 7'd10,
                 CJK_LUN = 7'd11, CJK_BO  = 7'd12;
localparam [6:0] SP = 7'h20;   // 空格 = 空白字形

localparam [23:0] C_PANEL    = 24'h0C1628;   // 面板底（与图片 3:1 混合）
localparam [23:0] C_TITLE    = 24'h1A2C48;   // 标题条底（同上）
localparam [23:0] C_BORDER   = 24'h6A8CAE;
localparam [23:0] C_DIVIDER  = 24'h34506E;
localparam [23:0] C_WHITE    = 24'hFFFFFF;
localparam [23:0] C_LABEL    = 24'hD0DCEA;
localparam [23:0] C_VALUE    = 24'h9FC3E6;
localparam [23:0] C_DIM      = 24'h7F96B0;
localparam [23:0] C_ACCENT   = 24'h54E3E3;
localparam [23:0] C_TRACK    = 24'h263A52;
localparam [23:0] C_TRACK_HL = 24'h0E3C7A;
localparam [23:0] C_FILL     = 24'h54E3E3;

// ---------------------------------------------------------------------------
// 像素计数（与 video_osd_overlay 相同写法）+ 面板行计数
// ---------------------------------------------------------------------------
reg [9:0] x, y;
reg       de_d, vs_d;
wire      frame_tick = vs && !vs_d;
wire      line_adv   = de_d && !de;            // 本拍结束后 y 加 1

reg [2:0] r;          // 面板行 0..6
reg [4:0] ry;         // 行内偏移 0..27
reg       r_ok;       // 当前行在面板行范围内（y 132..327）

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x <= 10'd0; y <= 10'd0; de_d <= 1'b0; vs_d <= 1'b0;
        r <= 3'd0; ry <= 5'd0; r_ok <= 1'b0;
    end else begin
        de_d <= de;
        vs_d <= vs;
        if (frame_tick) begin
            x <= 10'd0; y <= 10'd0;
            r_ok <= 1'b0;
        end else if (de) begin
            x <= x + 10'd1;
        end else if (de_d) begin
            x <= 10'd0; y <= y + 10'd1;
        end

        if (line_adv && !frame_tick) begin
            if (y == PY0 - 10'd1) begin
                r <= 3'd0; ry <= 5'd0; r_ok <= 1'b1;
            end else if (r_ok) begin
                if (ry == ROW_PITCH - 5'd1) begin
                    ry <= 5'd0;
                    if (r == ROW_LAST) r_ok <= 1'b0;
                    else               r  <= r + 3'd1;
                end else begin
                    ry <= ry + 5'd1;
                end
            end
        end
    end
end

// 行内各区段（整行不变）
wire       text_line = r_ok && (ry >= TEXT_RY) && (ry < TEXT_RY + 5'd16);
wire [4:0] ty        = ry - TEXT_RY;
wire       content   = r_ok && (r != 3'd0) && (r != ROW_LAST);
wire [2:0] line      = r - 3'd1;                // 内容行号 0..4
wire       band_line = content && (ry >= BAND_RY0) && (ry < BAND_RY1);
wire       bar_line  = content && (line < 3'd3) && (ry >= BAR_RY0) && (ry < BAR_RY1);
wire       div_line  = r_ok && (r == 3'd1) && (ry == 5'd0);
wire       title_bar = r_ok && (r == 3'd0);

// ---------------------------------------------------------------------------
// sd 域状态包同步：连续两拍一致才采纳（多位同时变化时不会采到混合值）
// ---------------------------------------------------------------------------
reg [11:0] st_meta, st_prev, st_sync;
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        st_meta <= 12'd0; st_prev <= 12'd0; st_sync <= 12'd0;
    end else begin
        st_meta <= status_sd;
        st_prev <= st_meta;
        if (st_prev == st_meta)
            st_sync <= st_prev;
    end
end

// ---------------------------------------------------------------------------
// 帧边界：锁存显示值、检测变化、弹出计时、淡入淡出
// ---------------------------------------------------------------------------
reg [7:0]  b_l, c_l;
reg [1:0]  ch_l;
reg [11:0] st_l;
wire [3:0] vol_l   = st_l[11:8];
wire       mute_l  = st_l[7];
wire       bgm_now = st_l[6];
wire [1:0] bgm_cnt = st_l[5:4];
wire       auto_l  = st_l[3];
wire [2:0] per_l   = st_l[2:0];

reg [8:0]  show_cnt;
reg [7:0]  boot_cnt;
reg [4:0]  hl;               // 高亮行掩码
reg [1:0]  lvl;              // 0 隐藏，1 半透明，2 完全显示
reg [1:0]  fade_div;
reg        armed;            // 过了上电静默期

wire chg_b   = (brightness != b_l);
wire chg_c   = (contrast   != c_l);
wire chg_ch  = (channel    != ch_l);
wire chg_vol = (st_sync[11:7] != st_l[11:7]);
wire chg_bgm = (st_sync[6]    != st_l[6]);       // 曲目数只在扫描时变，不弹出
wire chg_ply = (st_sync[3:0]  != st_l[3:0]);

reg [4:0] ch_mask;
always @* begin
    case (channel)
        2'b00:   ch_mask = 5'b00001;
        2'b01:   ch_mask = 5'b00010;
        2'b10:   ch_mask = 5'b00011;
        default: ch_mask = 5'b00100;
    endcase
end
wire [4:0] chg_mask = (chg_ch ? ch_mask : 5'd0) |
                      {chg_ply, chg_bgm, chg_vol, chg_c, chg_b};

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        b_l <= 8'd0; c_l <= 8'd0; ch_l <= 2'd0; st_l <= 12'd0;
        show_cnt <= 9'd0; boot_cnt <= 8'd0; armed <= 1'b0;
        hl <= 5'b00001; lvl <= 2'd0; fade_div <= 2'd0;
    end else if (frame_tick) begin
        b_l  <= brightness;
        c_l  <= contrast;
        ch_l <= channel;
        st_l <= st_sync;

        if (!armed) begin
            boot_cnt <= boot_cnt + 8'd1;
            if (boot_cnt == BOOT_FRAMES - 1)
                armed <= 1'b1;
        end

        if (armed && (chg_mask != 5'd0)) begin
            show_cnt <= SHOW_FRAMES;
            hl       <= chg_mask;
        end else if (show_cnt != 9'd0) begin
            show_cnt <= show_cnt - 9'd1;
        end

        if (fade_div == FADE_FRAMES - 1) begin
            fade_div <= 2'd0;
            if ((show_cnt != 9'd0) && (lvl != 2'd2))
                lvl <= lvl + 2'd1;
            else if ((show_cnt == 9'd0) && (lvl != 2'd0))
                lvl <= lvl - 2'd1;
        end else begin
            fade_div <= fade_div + 2'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// 数值：百分比与十进制拆分。frame_tick 后用 4 拍依次算亮度/对比度/音量，
// 共用一份 pct8 和一份 dec3（都在帧消隐期内完成，整帧不变）
// ---------------------------------------------------------------------------
function [6:0] pct8;               // 0..255 -> 0..100
    input [7:0] v;
    reg [17:0] s;
    begin
        s = {v, 8'd0} + {1'b0, v, 7'd0} + {v, 4'd0} + v + 18'd512;
        pct8 = s[16:10];
    end
endfunction

function [6:0] vol_pct;            // 音量档 0..8 -> 屏显百分比（与串口屏一致）
    input [3:0] l;
    begin
        case (l)
            4'd0: vol_pct = 7'd0;   4'd1: vol_pct = 7'd13;  4'd2: vol_pct = 7'd25;
            4'd3: vol_pct = 7'd38;  4'd4: vol_pct = 7'd50;  4'd5: vol_pct = 7'd63;
            4'd6: vol_pct = 7'd75;  4'd7: vol_pct = 7'd88;  default: vol_pct = 7'd100;
        endcase
    end
endfunction

function [3:0] tens;               // 0..100 的十位（100 -> 0，百位另判）
    input [6:0] p;
    begin
        tens = (p >= 7'd100) ? 4'd0 : (p >= 7'd90) ? 4'd9 : (p >= 7'd80) ? 4'd8 :
               (p >= 7'd70)  ? 4'd7 : (p >= 7'd60) ? 4'd6 : (p >= 7'd50) ? 4'd5 :
               (p >= 7'd40)  ? 4'd4 : (p >= 7'd30) ? 4'd3 : (p >= 7'd20) ? 4'd2 :
               (p >= 7'd10)  ? 4'd1 : 4'd0;
    end
endfunction

// 十进制拆分：{百位, 十位, 个位}，0..100
function [8:0] dec3;
    input [6:0] p;
    reg [3:0] t;
    reg       h;
    begin
        h    = (p >= 7'd100);
        t    = tens(p);
        // 个位 = p - 10t - 100h，只取低 4 位：10t ≡ 8t + 2t，100 ≡ 4 (mod 16)
        dec3 = {h, t, p[3:0] - {t[0], 3'd0} - {t[2:0], 1'b0} - (h ? 4'd4 : 4'd0)};
    end
endfunction

// 亮度 / 对比度 / 音量各自独立寄存器（不写成数组，免得被推断成 RAM）
reg [6:0] pct_b, pct_c, pct_v;
reg [8:0] dg_b, dg_c, dg_v;
reg [2:0] cv_step;                 // 0 空闲，1..4 依次换算
wire [6:0] pct_in = (cv_step == 3'd1) ? pct8(b_l) : pct8(c_l);
wire [6:0] dec_in = (cv_step == 3'd2) ? pct_b : (cv_step == 3'd3) ? pct_c : pct_v;
wire [8:0] dec_out = dec3(dec_in);
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        cv_step <= 3'd0;
        pct_b <= 7'd0; pct_c <= 7'd0; pct_v <= 7'd0;
        dg_b  <= 9'd0; dg_c  <= 9'd0; dg_v  <= 9'd0;
    end else begin
        if (frame_tick)                  // b_l/c_l/st_l 在同一拍锁存，下一拍起换算
            cv_step <= 3'd1;
        else if (cv_step != 3'd0)
            cv_step <= (cv_step == 3'd4) ? 3'd0 : cv_step + 3'd1;
        case (cv_step)
            3'd1: pct_b <= pct_in;
            3'd2: begin pct_c <= pct_in; pct_v <= vol_pct(vol_l); dg_b <= dec_out; end
            3'd3: dg_c <= dec_out;
            3'd4: dg_v <= dec_out;
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// 文字：按 xa = x + 1 选字、算 ROM 地址
// ---------------------------------------------------------------------------
wire [9:0] xa = x + 10'd1;

// 各字段内偏移
wire [9:0] dx_label = xa - LABEL_X;
wire [9:0] dx_value = xa - VALUE_X;
wire [9:0] dx_tcjk  = xa - TCJK_X;
wire [9:0] dx_tasc  = xa - TASC_X;
wire [9:0] dx_hint  = xa - HINT_X;
wire [2:0] xa_slot8 = dx_value[5:3];

// 各行汉字标签
function [6:0] label_gid;
    input [2:0] ln;
    input [1:0] slot;
    begin
        label_gid = SP;
        case (ln)
            3'd0: case (slot) 2'd0: label_gid = CJK_LIANG; 2'd1: label_gid = CJK_DU; default: ; endcase
            3'd1: case (slot) 2'd0: label_gid = CJK_DUI; 2'd1: label_gid = CJK_BI;
                              2'd2: label_gid = CJK_DU; default: ; endcase
            3'd2: case (slot) 2'd0: label_gid = CJK_YIN; 2'd1: label_gid = CJK_LIANG2; default: ; endcase
            3'd3: case (slot) 2'd0: label_gid = CJK_BEI; 2'd1: label_gid = CJK_JING;
                              2'd2: label_gid = CJK_YIN; default: label_gid = CJK_YUE; endcase
            3'd4: case (slot) 2'd0: label_gid = CJK_LUN; 2'd1: label_gid = CJK_BO; default: ; endcase
            default: ;
        endcase
    end
endfunction

// 百分比 7 格："    75%" / "   100%"
function [6:0] pct_char;
    input [2:0] slot;
    input       h;
    input [3:0] t;
    input [3:0] u;
    begin
        case (slot)
            3'd3:    pct_char = h ? 7'h31 : SP;
            3'd4:    pct_char = (h || (t != 4'd0)) ? (7'h30 + {3'd0, t}) : SP;
            3'd5:    pct_char = 7'h30 + {3'd0, u};
            3'd6:    pct_char = 7'h25;                    // %
            default: pct_char = SP;
        endcase
    end
endfunction

function [6:0] str_mute;           // "   MUTE"
    input [2:0] slot;
    begin
        case (slot)
            3'd3: str_mute = 7'h4D; 3'd4: str_mute = 7'h55;
            3'd5: str_mute = 7'h54; 3'd6: str_mute = 7'h45;
            default: str_mute = SP;
        endcase
    end
endfunction

// 亮度/对比度/音量三行共用一个 pct_char：先选数据再查
wire [8:0] dg_sel = (line == 3'd0) ? dg_b : (line == 3'd1) ? dg_c : dg_v;

reg [6:0] value_gid;
always @* begin
    value_gid = SP;
    case (line)
        3'd0, 3'd1, 3'd2:
            value_gid = ((line == 3'd2) && mute_l) ? str_mute(xa_slot8)
                                                   : pct_char(xa_slot8, dg_sel[8], dg_sel[7:4], dg_sel[3:0]);
        3'd3: begin
            if (bgm_cnt == 2'd0) begin
                case (xa_slot8)                            // "   NONE"
                    3'd3: value_gid = 7'h4E; 3'd4: value_gid = 7'h4F;
                    3'd5: value_gid = 7'h4E; 3'd6: value_gid = 7'h45;
                    default: ;
                endcase
            end else begin
                case (xa_slot8)                            // "    1/2"
                    3'd4: value_gid = 7'h31 + {6'd0, bgm_now};
                    3'd5: value_gid = 7'h2F;
                    3'd6: value_gid = 7'h30 + {5'd0, bgm_cnt};
                    default: ;
                endcase
            end
        end
        3'd4: begin
            if (auto_l) begin
                case (xa_slot8)                            // "AUTO 3S"
                    3'd0: value_gid = 7'h41; 3'd1: value_gid = 7'h55;
                    3'd2: value_gid = 7'h54; 3'd3: value_gid = 7'h4F;
                    3'd5: value_gid = 7'h30 + {4'd0, per_l};
                    3'd6: value_gid = 7'h53;
                    default: ;
                endcase
            end else begin
                case (xa_slot8)                            // "   MANU"
                    3'd3: value_gid = 7'h4D; 3'd4: value_gid = 7'h41;
                    3'd5: value_gid = 7'h4E; 3'd6: value_gid = 7'h55;
                    default: ;
                endcase
            end
        end
        default: ;
    endcase
end

function [6:0] settings_char;      // "SETTINGS"
    input [2:0] slot;
    begin
        case (slot)
            3'd0: settings_char = 7'h53; 3'd1: settings_char = 7'h45;
            3'd2: settings_char = 7'h54; 3'd3: settings_char = 7'h54;
            3'd4: settings_char = 7'h49; 3'd5: settings_char = 7'h4E;
            3'd6: settings_char = 7'h47; default: settings_char = 7'h53;
        endcase
    end
endfunction

function [6:0] hint_char;          // "SW:SELECT  KEY3:+/-"
    input [4:0] slot;
    begin
        case (slot)
            5'd0:  hint_char = 7'h53; 5'd1:  hint_char = 7'h57; 5'd2:  hint_char = 7'h3A;
            5'd3:  hint_char = 7'h53; 5'd4:  hint_char = 7'h45; 5'd5:  hint_char = 7'h4C;
            5'd6:  hint_char = 7'h45; 5'd7:  hint_char = 7'h43; 5'd8:  hint_char = 7'h54;
            5'd11: hint_char = 7'h4B; 5'd12: hint_char = 7'h45; 5'd13: hint_char = 7'h59;
            5'd14: hint_char = 7'h33; 5'd15: hint_char = 7'h3A; 5'd16: hint_char = 7'h2B;
            5'd17: hint_char = 7'h2F; 5'd18: hint_char = 7'h2D;
            default: hint_char = SP;
        endcase
    end
endfunction

// 文字类别：0 无，1 标题白，2 暗色，3 标签，4 数值
localparam [2:0] TC_NONE = 3'd0, TC_TITLE = 3'd1, TC_DIM = 3'd2, TC_LABEL = 3'd3, TC_VALUE = 3'd4;

reg  [6:0] gid;
reg  [3:0] col;                    // 字内列（汉字 0..15，ASCII 0..7）
reg  [2:0] tcls;
always @* begin
    gid  = SP;
    col  = 4'd0;
    tcls = TC_NONE;
    if (text_line) begin
        if (r == 3'd0) begin
            if ((xa >= TCJK_X) && (xa < TCJK_X + 10'd32)) begin
                gid = dx_tcjk[4] ? CJK_ZHI : CJK_SHE; col = dx_tcjk[3:0]; tcls = TC_TITLE;
            end else if ((xa >= TASC_X) && (xa < TASC_X + 10'd64)) begin
                gid = settings_char(dx_tasc[5:3]); col = {1'b0, dx_tasc[2:0]}; tcls = TC_DIM;
            end
        end else if (r == ROW_LAST) begin
            if ((xa >= HINT_X) && (xa < HINT_X + HINT_LEN * 8)) begin
                gid = hint_char(dx_hint[7:3]); col = {1'b0, dx_hint[2:0]}; tcls = TC_DIM;
            end
        end else begin
            if ((xa >= LABEL_X) && (xa < LABEL_X + 10'd64)) begin
                gid = label_gid(line, dx_label[5:4]); col = dx_label[3:0]; tcls = TC_LABEL;
            end else if ((xa >= VALUE_X) && (xa < VALUE_X + 10'd56)) begin
                gid = value_gid; col = {1'b0, dx_value[2:0]}; tcls = TC_VALUE;
            end
        end
    end
end

assign font_addr = {gid, ty[3:0]};

// 与 ROM 读同拍寄存：到下一拍正好对应当前像素
reg [3:0] col_q;
reg [2:0] tcls_q;
always @(posedge video_clk) begin
    col_q  <= col;
    tcls_q <= tcls;
end
wire text_px = (tcls_q != TC_NONE) && font_q[4'd15 - col_q];

// ---------------------------------------------------------------------------
// 当前像素的底层图形
// ---------------------------------------------------------------------------
function [23:0] blend34;           // out = c*3/4 + img/4（同 video_osd_overlay.bar_blend）
    input [23:0] c;
    input [23:0] img;
    begin
        blend34[23:16] = {2'b00, c[23:18]} + {1'b0, c[23:17]} + {2'b00, img[23:18]};
        blend34[15:8]  = {2'b00, c[15:10]} + {1'b0, c[15:9]}  + {2'b00, img[15:10]};
        blend34[7:0]   = {2'b00, c[7:2]}   + {1'b0, c[7:1]}   + {2'b00, img[7:2]};
    end
endfunction

function [23:0] avg2;
    input [23:0] a;
    input [23:0] b;
    reg [8:0] rr, gg, bb;
    begin
        rr = {1'b0, a[23:16]} + {1'b0, b[23:16]};
        gg = {1'b0, a[15:8]}  + {1'b0, b[15:8]};
        bb = {1'b0, a[7:0]}   + {1'b0, b[7:0]};
        avg2 = {rr[8:1], gg[8:1], bb[8:1]};
    end
endfunction

wire in_panel  = (lvl != 2'd0) && (x >= PX0) && (x < PX1) && (y >= PY0) && (y < PY1);
wire border    = (x == PX0) || (x == PX1 - 10'd1) || (y == PY0) || (y == PY1 - 10'd1);
wire in_band_x = (x >= BAND_X0) && (x < BAND_X1);

wire       row_hl   = band_line && hl[line];
wire [9:0] dx_band  = x - BAND_X0;
wire [9:0] dx_bar   = x - BAR_X;
wire       in_bar   = bar_line && (x >= BAR_X) && (x < BAR_X + BAR_W);
wire [6:0] bar_pct  = (line == 3'd0) ? pct_b : (line == 3'd1) ? pct_c :
                      (mute_l ? 7'd0 : pct_v);
wire       bar_fill = (dx_bar[6:0] < bar_pct);

// 高亮带：蓝色向右渐亮（只用加法）
wire [23:0] band_rgb = {8'h18 + {3'd0, dx_band[8:4]},
                        8'h5A + {2'd0, dx_band[8:3]},
                        8'hB4 + {3'd0, dx_band[8:4]}};

// 文字行高亮：文字在 ry 6..21，整段都在高亮带 ry 2..25 之内，直接用同一行的 hl
wire text_hl = content && hl[line];

reg [23:0] panel_rgb;
always @* begin
    panel_rgb = blend34(title_bar ? C_TITLE : C_PANEL, rgb_in);
    if (border)
        panel_rgb = C_BORDER;
    else if (div_line && in_band_x)
        panel_rgb = C_DIVIDER;
    else if (row_hl && in_band_x)
        panel_rgb = band_rgb;

    if (in_bar)
        panel_rgb = bar_fill ? (row_hl ? C_WHITE : C_FILL) : (row_hl ? C_TRACK_HL : C_TRACK);
    if (row_hl && (x >= BAND_X0) && (x < BAND_X0 + ACCENT_W))
        panel_rgb = C_ACCENT;

    if (text_px) begin
        case (tcls_q)
            TC_TITLE: panel_rgb = C_WHITE;
            TC_DIM:   panel_rgb = C_DIM;
            TC_LABEL: panel_rgb = text_hl ? C_WHITE : C_LABEL;
            default:  panel_rgb = text_hl ? C_WHITE : C_VALUE;
        endcase
    end
end

// 淡入淡出：lvl 2 = 面板，1 = 面板与画面各半
always @* begin
    rgb_out = rgb_in;
    if (de && in_panel)
        rgb_out = (lvl == 2'd2) ? panel_rgb : avg2(panel_rgb, rgb_in);
end

endmodule
