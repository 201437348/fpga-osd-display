`timescale 1ns/1ps

// image_bilinear_scaler 多尺寸回归（放宽 MIN_SRC_PIXELS 与抗锯齿用）
//   +W=<宽> +H=<高> 选源尺寸；-Ptb_scaler_sizes.AA=0 编 AA_ENABLE=0 版本
//   源像素按扇区（171 个）突发送入，只在扇区边界看 src_afull（与 loader 一致），
//   输出侧随机 out_stall。逐像素与参考模型比对：
//     letterbox 区间取 DUT 的 img_x0/x1/y0/y1（本 tb 不重复验证居中算法），
//     坐标 fix = i*N*2^10/D，双线性 floor((a*1024 + (b-a)*t) / 1024)；
//     缩小比 N/D >= 1.5 时，4 个抽头先做 [1 2 1]x[1 2 1]/16 预滤波（与 RTL 窗口一致：
//     上抽头行 sy0-1/sy0/sy1，下抽头行 sy0/sy1/sy0+2，列同理，均钳位）。
module tb_scaler_sizes;

localparam integer DW = 640, DH = 480, SECTOR = 171;

reg clk = 1'b0;
reg rst = 1'b1;
reg start = 1'b0;
reg [15:0] src_w = 16'd0, src_h = 16'd0;
reg cfg_valid = 1'b0;
reg [23:0] src_data = 24'd0;
reg src_valid = 1'b0;
reg out_stall = 1'b0;
wire src_afull;
wire [7:0] ovf;
wire [23:0] dst;
wire dv, done;
wire [1:0] err;
wire [15:0] iw, ih, sc;
wire inf;

always #5 clk = ~clk;

// iverilog -Ptb_scaler_sizes.AA=0 编出纯双线性版本
parameter AA = 1;
parameter FD = 16'd256;
image_bilinear_scaler #(.AA_ENABLE(AA), .IN_FIFO_DEPTH(FD)) u_dut (
    .clk(clk), .rst(rst), .start(start),
    .src_width(src_w), .src_height(src_h), .cfg_valid(cfg_valid),
    .src_data(src_data), .src_valid(src_valid), .src_afull(src_afull),
    .src_overflow_count(ovf), .out_stall(out_stall),
    .dst_data(dst), .dst_valid(dv), .dst_done(done), .error_code(err),
    .img_width(iw), .img_height(ih), .scale_x100(sc), .info_valid(inf)
);

wire        aa_on = u_dut.aa_en;
wire [15:0] x0 = u_dut.img_x0, x1 = u_dut.img_x1;
wire [15:0] y0 = u_dut.img_y0, y1 = u_dut.img_y1;
wire [15:0] sn = u_dut.scale_num, sd = u_dut.scale_den;

integer W, H;
reg [23:0] img [0:1920*1080-1];

function [23:0] src_px(input integer x, input integer y);
    reg [7:0] r, g, b;
    begin
        // 细线 + 棋盘 + 渐变 + 伪随机，覆盖大跳变（抗锯齿/钳位）与缓变
        r = ((x % 3) == 0) ? 8'd255 : 8'd0;
        g = (((x >> 2) ^ (y >> 2)) & 1) ? 8'd240 : 8'd16;
        b = (x * 7 + y * 13 + ((x * y) >> 3)) & 8'hFF;
        if (y % 5 == 1) r = ~r;
        src_px = {r, g, b};
    end
endfunction

function integer clampi(input integer v, input integer lo, input integer hi);
    clampi = (v < lo) ? lo : (v > hi) ? hi : v;
endfunction

function integer ch(input [23:0] p, input integer c);
    ch = (p >> (8 * c)) & 8'hFF;
endfunction

// floor((a*1024 + (b-a)*t) / 1024)，被除数可为负
function integer lerp(input integer a, input integer b, input integer t);
    integer n;
    begin
        n = a * 1024 + (b - a) * t;
        lerp = (n >= 0) ? (n / 1024) : -((-n + 1023) / 1024);
    end
endfunction

// 抽头：AA 时为 3x3 [1 2 1] 帐篷，行/列三元组由调用方给出
function integer tap(input integer r0, input integer r1, input integer r2,
                     input integer c0, input integer c1, input integer c2,
                     input integer c, input integer aa);
    integer s;
    begin
        if (!aa) tap = ch(img[r1 * W + c1], c);
        else begin
            s =     ch(img[r0*W+c0],c) + 2*ch(img[r0*W+c1],c) +   ch(img[r0*W+c2],c)
              + 2*( ch(img[r1*W+c0],c) + 2*ch(img[r1*W+c1],c) +   ch(img[r1*W+c2],c) )
              +     ch(img[r2*W+c0],c) + 2*ch(img[r2*W+c1],c) +   ch(img[r2*W+c2],c);
            tap = (s + 8) >> 4;
        end
    end
endfunction

function [23:0] ref_px(input integer ox, input integer oy, input integer aa);
    longint fxx, fyy;
    integer sx0, sx1, sy0, sy1, fx, fy, sxm, sx3, sym, sy3, c, q00, q01, q10, q11, h0, h1;
    begin
        if (ox < x0 || ox >= x1 || oy < y0 || oy >= y1) ref_px = 24'd0;
        else begin
            fxx = (longint'(ox - x0) * sn * 1024) / sd;
            fyy = (longint'(oy - y0) * sn * 1024) / sd;
            sx0 = fxx >> 10; fx = fxx & 1023;
            sy0 = fyy >> 10; fy = fyy & 1023;
            sx1 = (sx0 >= W - 1) ? W - 1 : sx0 + 1;
            sy1 = (sy0 >= H - 1) ? H - 1 : sy0 + 1;
            sxm = clampi(sx0 - 1, 0, W - 1); sx3 = clampi(sx0 + 2, 0, W - 1);
            sym = clampi(sy0 - 1, 0, H - 1); sy3 = clampi(sy0 + 2, 0, H - 1);
            ref_px = 24'd0;
            for (c = 0; c < 3; c = c + 1) begin
                q00 = tap(sym, sy0, sy1, sxm, sx0, sx1, c, aa);
                q01 = tap(sym, sy0, sy1, sx0, sx1, sx3, c, aa);
                q10 = tap(sy0, sy1, sy3, sxm, sx0, sx1, c, aa);
                q11 = tap(sy0, sy1, sy3, sx0, sx1, sx3, c, aa);
                if (!aa) begin
                    q01 = ch(img[sy0*W+sx1], c);
                    q10 = ch(img[sy1*W+sx0], c);
                    q11 = ch(img[sy1*W+sx1], c);
                end
                h0 = lerp(q00, q01, fx);
                h1 = lerp(q10, q11, fx);
                ref_px = ref_px | (lerp(h0, h1, fy) << (8 * c));
            end
        end
    end
endfunction

// 输出侧：随机反压 + 逐像素比对
integer seed = 1;
always @(posedge clk) out_stall <= (($random(seed) & 7) == 0);

integer out_n = 0, bad = 0, aa_exp;
reg [23:0] e;
always @(posedge clk) begin
    if (dv) begin
        e = ref_px(out_n % DW, out_n / DW, aa_exp);
        if (dst !== e) begin
            bad = bad + 1;
            if (bad <= 8)
                $display("MISMATCH px %0d (%0d,%0d): got %06h exp %06h",
                         out_n, out_n % DW, out_n / DW, dst, e);
        end
        out_n = out_n + 1;
    end
end

integer i, k, n, gap;
longint t0;
initial begin
    if (!$value$plusargs("W=%d", W)) W = 16;
    if (!$value$plusargs("H=%d", H)) H = 16;
    if (!$value$plusargs("GAP=%d", gap)) gap = 3;
    for (i = 0; i < W * H; i = i + 1) img[i] = src_px(i % W, i / W);
    aa_exp = (AA != 0) && (2 * ((W * DH >= H * DW) ? W : H) >= 3 * ((W * DH >= H * DW) ? DW : DH));

    repeat (4) @(posedge clk);
    rst = 1'b0;
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;
    src_w = W; src_h = H; cfg_valid = 1'b1;
    t0 = $time;

    // 源：扇区边界查 src_afull，扇区内不停（每 gap 拍一个像素）
    n = 0;
    while (n < W * H) begin
        @(negedge clk);
        if (!src_afull) begin
            for (k = 0; k < SECTOR && n < W * H; k = k + 1) begin
                src_data = img[n]; src_valid = 1'b1;
                @(negedge clk); src_valid = 1'b0;
                n = n + 1;
                repeat (gap - 1) @(negedge clk);
            end
        end
    end

    while (!done) @(posedge clk);
    repeat (4) @(posedge clk);
    if (aa_on !== aa_exp[0]) $fatal(1, "FAIL %0dx%0d aa_en=%0d expected %0d", W, H, aa_on, aa_exp);
    if (out_n != DW * DH) $fatal(1, "FAIL %0dx%0d output count %0d", W, H, out_n);
    if (err != 2'd0) $fatal(1, "FAIL %0dx%0d error_code %0d", W, H, err);
    if (ovf != 8'd0) $fatal(1, "FAIL %0dx%0d overflow %0d", W, H, ovf);
    if (bad != 0) $fatal(1, "FAIL %0dx%0d %0d mismatches", W, H, bad);
    $display("PASS tb_scaler_sizes %0dx%0d aa=%0d img [%0d,%0d)x[%0d,%0d) %0d us",
             W, H, aa_exp, x0, x1, y0, y1, ($time - t0) / 1000);
    $finish;
end

initial begin
    #2_000_000_000;
    $fatal(1, "FAIL tb_scaler_sizes timeout");
end

endmodule
