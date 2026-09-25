// ============================================================================
// osd_info_text
// 生成 OSD 顶栏信息行，例如：
//     "OUT 640X480  IMG 1920X1080  SCALE 0.33"
// 固定 CHARS 个字符（ASCII），不足补空格，打平成 text_flat 给 OSD 逐字取模。
//
// 数据来源：image_storage_adapter 在 source_done_pulse（新图开始显示）时
// 锁存的源宽/源高/缩放比 x100，位于 sd_card_clk 域。
// 跨时钟：控制域在锁存时翻转 info_toggle；这里 3FF 同步后检边沿再采数据。
// 数据在翻转后要等到下一张图加载完成（秒级）才会再变，采样时早已稳定。
//
// 流程：检出新信息 -> 逐个做 14 位 double-dabble（钳到 9999）
//       -> 逐字符组装到 stage_buf -> vs 上升沿整行提交到 text_flat（不撕裂）
// ============================================================================
module osd_info_text #(
    parameter integer OUT_WIDTH  = 640,
    parameter integer OUT_HEIGHT = 480,
    parameter integer CHARS      = 40
) (
    input  wire                 video_clk,
    input  wire                 rst,
    input  wire                 vs,
    input  wire                 info_toggle,     // 控制域翻转
    input  wire [15:0]          info_width,      // 控制域，翻转后保持稳定
    input  wire [15:0]          info_height,
    input  wire [15:0]          info_scale_x100,
    output reg  [CHARS*8-1:0]   text_flat        // 字符 i 在 [i*8 +: 8]
);

// ---------------------------------------------------------------------------
// 1) CDC：toggle 同步 + 边沿采样
// ---------------------------------------------------------------------------
reg [2:0]  tgl_sync;
reg        info_seen;               // 至少收到过一张图的信息
reg [15:0] cap_w, cap_h, cap_s;
reg        new_info;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        tgl_sync  <= 3'b000;
        info_seen <= 1'b0;
        cap_w     <= 16'd0;
        cap_h     <= 16'd0;
        cap_s     <= 16'd0;
        new_info  <= 1'b0;
    end else begin
        tgl_sync <= {tgl_sync[1:0], info_toggle};
        new_info <= 1'b0;
        if (tgl_sync[2] ^ tgl_sync[1]) begin
            cap_w     <= info_width;
            cap_h     <= info_height;
            cap_s     <= info_scale_x100;
            info_seen <= 1'b1;
            new_info  <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// 2) 常量：输出分辨率的十进制各位
// ---------------------------------------------------------------------------
localparam [3:0] OW3 = OUT_WIDTH  / 1000 % 10;
localparam [3:0] OW2 = OUT_WIDTH  / 100  % 10;
localparam [3:0] OW1 = OUT_WIDTH  / 10   % 10;
localparam [3:0] OW0 = OUT_WIDTH         % 10;
localparam [3:0] OH3 = OUT_HEIGHT / 1000 % 10;
localparam [3:0] OH2 = OUT_HEIGHT / 100  % 10;
localparam [3:0] OH1 = OUT_HEIGHT / 10   % 10;
localparam [3:0] OH0 = OUT_HEIGHT        % 10;
localparam [15:0] OUT_W_BCD = {OW3, OW2, OW1, OW0};
localparam [15:0] OUT_H_BCD = {OH3, OH2, OH1, OH0};

// ---------------------------------------------------------------------------
// 3) 顺序 double-dabble：依次转换 cap_w / cap_h / cap_s，每个 14 拍
// ---------------------------------------------------------------------------
localparam [2:0] ST_IDLE  = 3'd0,
                 ST_LOAD  = 3'd1,
                 ST_SHIFT = 3'd2,
                 ST_STORE = 3'd3,
                 ST_BUILD = 3'd4,
                 ST_WAIT  = 3'd5;

reg [2:0]  st;
reg [1:0]  cv_idx;                  // 0=宽 1=高 2=缩放
reg [13:0] bin_sr;
reg [15:0] bcd_sr;
reg [3:0]  sh_cnt;
reg [15:0] img_w_bcd, img_h_bcd, scale_bcd;
reg [5:0]  tok;                     // 组装进度（token 序号）
reg [5:0]  wp;                      // 写指针
reg [7:0]  stage_buf [0:CHARS-1];
reg        stage_ready;
reg        vs_d;
reg        pending;                 // 忙时又来了新图：做完这次再重做
integer    i;

wire [15:0] cv_src   = (cv_idx == 2'd0) ? cap_w : (cv_idx == 2'd1) ? cap_h : cap_s;
wire [13:0] cv_clamp = (cv_src > 16'd9999) ? 14'd9999 : cv_src[13:0];

// 每个 BCD 位 >=5 时加 3，再整体左移
function [15:0] dabble_adj;
    input [15:0] b;
    integer k;
    begin
        for (k = 0; k < 4; k = k + 1)
            dabble_adj[k*4 +: 4] = (b[k*4 +: 4] >= 4'd5) ? (b[k*4 +: 4] + 4'd3) : b[k*4 +: 4];
    end
endfunction

wire [15:0] bcd_adj = dabble_adj(bcd_sr);

// ---------------------------------------------------------------------------
// 4) token 表：每个 token 对应一个（可能被跳过的）字符
//    数字字段做前导零消隐：4 位数字中，高位全 0 的位跳过，个位永远保留。
//    缩放比格式 "d.dd"：百位（整数部分十位）为 0 时跳过。
// ---------------------------------------------------------------------------
localparam [5:0] TOK_END = 6'd40;

function digit_emit;               // 4 位数中第 pos(3..0) 位是否输出
    input [15:0] bcd;
    input [1:0]  pos;
    begin
        case (pos)
            2'd3: digit_emit = (bcd[15:12] != 4'd0);
            2'd2: digit_emit = (bcd[15:8]  != 8'd0);
            2'd1: digit_emit = (bcd[15:4]  != 12'd0);
            default: digit_emit = 1'b1;
        endcase
    end
endfunction

function [7:0] dch;                // BCD 位 -> ASCII
    input [3:0] d;
    begin
        dch = 8'h30 + {4'd0, d};
    end
endfunction

reg        tok_emit;
reg [7:0]  tok_char;

always @(*) begin
    tok_emit = 1'b1;
    tok_char = 8'h20;
    case (tok)
        // "OUT "
        6'd0:  tok_char = 8'h4F;
        6'd1:  tok_char = 8'h55;
        6'd2:  tok_char = 8'h54;
        6'd3:  tok_char = 8'h20;
        // 输出宽
        6'd4:  begin tok_emit = digit_emit(OUT_W_BCD, 2'd3); tok_char = dch(OUT_W_BCD[15:12]); end
        6'd5:  begin tok_emit = digit_emit(OUT_W_BCD, 2'd2); tok_char = dch(OUT_W_BCD[11:8]);  end
        6'd6:  begin tok_emit = digit_emit(OUT_W_BCD, 2'd1); tok_char = dch(OUT_W_BCD[7:4]);   end
        6'd7:  tok_char = dch(OUT_W_BCD[3:0]);
        6'd8:  tok_char = 8'h58;   // X
        // 输出高
        6'd9:  begin tok_emit = digit_emit(OUT_H_BCD, 2'd3); tok_char = dch(OUT_H_BCD[15:12]); end
        6'd10: begin tok_emit = digit_emit(OUT_H_BCD, 2'd2); tok_char = dch(OUT_H_BCD[11:8]);  end
        6'd11: begin tok_emit = digit_emit(OUT_H_BCD, 2'd1); tok_char = dch(OUT_H_BCD[7:4]);   end
        6'd12: tok_char = dch(OUT_H_BCD[3:0]);
        // 还没有图：只显示输出分辨率
        default: begin
            if (!info_seen) begin
                tok_emit = 1'b0;
            end else begin
                case (tok)
                    // "  IMG "
                    6'd13: tok_char = 8'h20;
                    6'd14: tok_char = 8'h20;
                    6'd15: tok_char = 8'h49;
                    6'd16: tok_char = 8'h4D;
                    6'd17: tok_char = 8'h47;
                    6'd18: tok_char = 8'h20;
                    // 图宽
                    6'd19: begin tok_emit = digit_emit(img_w_bcd, 2'd3); tok_char = dch(img_w_bcd[15:12]); end
                    6'd20: begin tok_emit = digit_emit(img_w_bcd, 2'd2); tok_char = dch(img_w_bcd[11:8]);  end
                    6'd21: begin tok_emit = digit_emit(img_w_bcd, 2'd1); tok_char = dch(img_w_bcd[7:4]);   end
                    6'd22: tok_char = dch(img_w_bcd[3:0]);
                    6'd23: tok_char = 8'h58;   // X
                    // 图高
                    6'd24: begin tok_emit = digit_emit(img_h_bcd, 2'd3); tok_char = dch(img_h_bcd[15:12]); end
                    6'd25: begin tok_emit = digit_emit(img_h_bcd, 2'd2); tok_char = dch(img_h_bcd[11:8]);  end
                    6'd26: begin tok_emit = digit_emit(img_h_bcd, 2'd1); tok_char = dch(img_h_bcd[7:4]);   end
                    6'd27: tok_char = dch(img_h_bcd[3:0]);
                    // "  SCALE "
                    6'd28: tok_char = 8'h20;
                    6'd29: tok_char = 8'h20;
                    6'd30: tok_char = 8'h53;
                    6'd31: tok_char = 8'h43;
                    6'd32: tok_char = 8'h41;
                    6'd33: tok_char = 8'h4C;
                    6'd34: tok_char = 8'h45;
                    6'd35: tok_char = 8'h20;
                    // 缩放比 x100 -> "d.dd"
                    6'd36: begin tok_emit = (scale_bcd[15:12] != 4'd0); tok_char = dch(scale_bcd[15:12]); end
                    6'd37: tok_char = dch(scale_bcd[11:8]);
                    6'd38: tok_char = 8'h2E;   // .
                    6'd39: tok_char = dch(scale_bcd[7:4]);
                    6'd40: tok_char = dch(scale_bcd[3:0]);
                    default: tok_emit = 1'b0;
                endcase
            end
        end
    endcase
end

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        st          <= ST_BUILD;   // 上电先组装一次（仅输出分辨率）
        cv_idx      <= 2'd0;
        bin_sr      <= 14'd0;
        bcd_sr      <= 16'd0;
        sh_cnt      <= 4'd0;
        img_w_bcd   <= 16'd0;
        img_h_bcd   <= 16'd0;
        scale_bcd   <= 16'd0;
        tok         <= 6'd0;
        wp          <= 6'd0;
        stage_ready <= 1'b0;
        vs_d        <= 1'b0;
        pending     <= 1'b0;
        text_flat   <= {CHARS{8'h20}};
        for (i = 0; i < CHARS; i = i + 1)
            stage_buf[i] <= 8'h20;
    end else begin
        vs_d <= vs;
        if (new_info)
            pending <= 1'b1;

        // 帧边界整行提交
        if (vs && !vs_d && stage_ready) begin
            stage_ready <= 1'b0;
            for (i = 0; i < CHARS; i = i + 1)
                text_flat[i*8 +: 8] <= stage_buf[i];
        end

        case (st)
            ST_IDLE: begin
                if (pending) begin
                    pending <= 1'b0;
                    cv_idx  <= 2'd0;
                    st     <= ST_LOAD;
                end
            end
            ST_LOAD: begin
                bin_sr <= cv_clamp;
                bcd_sr <= 16'd0;
                sh_cnt <= 4'd0;
                st     <= ST_SHIFT;
            end
            ST_SHIFT: begin
                {bcd_sr, bin_sr} <= {bcd_adj, bin_sr} << 1;
                sh_cnt <= sh_cnt + 4'd1;
                if (sh_cnt == 4'd13)
                    st <= ST_STORE;
            end
            ST_STORE: begin
                case (cv_idx)
                    2'd0: img_w_bcd <= bcd_sr;
                    2'd1: img_h_bcd <= bcd_sr;
                    default: scale_bcd <= bcd_sr;
                endcase
                if (cv_idx == 2'd2) begin
                    tok <= 6'd0;
                    wp  <= 6'd0;
                    st  <= ST_BUILD;
                end else begin
                    cv_idx <= cv_idx + 2'd1;
                    st     <= ST_LOAD;
                end
            end
            ST_BUILD: begin
                // 每拍处理一个 token；token 用完后剩余位置补空格
                if (tok <= TOK_END) begin
                    if (tok_emit) begin
                        if (wp < CHARS)
                            stage_buf[wp] <= tok_char;
                        wp <= wp + 6'd1;
                    end
                    tok <= tok + 6'd1;
                end else if (wp < CHARS) begin
                    stage_buf[wp] <= 8'h20;
                    wp <= wp + 6'd1;
                end else begin
                    stage_ready <= 1'b1;
                    st          <= ST_WAIT;
                end
            end
            default: begin // ST_WAIT：等提交后回到 IDLE
                if (!stage_ready)
                    st <= ST_IDLE;
            end
        endcase
    end
end

endmodule
