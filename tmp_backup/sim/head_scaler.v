`timescale 1ns/1ps
//
// image_bilinear_scaler -- 写侧双线性缩放器
//
// 位置：插在 fat32_bmp_loader 与 image_storage_adapter 的写通路之间。
//       输出的 640x480x24bit 像素流与旧版 loader 的输出完全一致，
//       因此 SDRAM 帧缓存、读回路、滑动动效、OSD、HDMI 全部不需要改动。
//
// ---------------------------------------------------------------------------
// 算法（详见 tools/bilinear_model.js，已对 W=1..1920 / H=1..1080 穷举验证）
// ---------------------------------------------------------------------------
//   源坐标映射（左上对齐，非居中）：  sx(i) = i * srcW / dstW
//
//   用「定点步进 + Bresenham 余数进位」精确实现，**无累积漂移**：
//       STEP = floor(srcW * 2^F / dstW)
//       REM  = (srcW * 2^F) mod dstW
//       每个输出像素：sum  = rem_acc + REM
//                     fix' = fix + STEP + (sum >= dstW)
//                     rem' = (sum >= dstW) ? sum - dstW : sum
//       => fix[i] 恒等于 floor(i * srcW * 2^F / dstW)
//       sx0 = fix >> F,  fx = fix & (2^F - 1)
//   第二抽头地址钳位（放大时不越界，等价于边缘像素延展）：
//       sx1 = (sx0 >= srcW-1) ? srcW-1 : sx0+1
//
//   插值（可分离，先水平后垂直，与浮点双线性等价）：
//       h   = (p[sx0]*(2^F - fx) + p[sx1]*fx) >> F
//       out = (h0*(2^F - fy) + h1*fy) >> F
//   位宽：p 为 8bit，(2^F-fx) 为 F+1 bit，乘积 F+9 bit，两项和 F+10 bit，
//         右移 F 位后恒 <= 255（已对全部 67.1M 组 p0/p1/fx 穷举确认无溢出）。
//
// ---------------------------------------------------------------------------
// 吞吐
// ---------------------------------------------------------------------------
//   输出回路每个输出像素 7 拍（EM_P0..EM_P6，已由 tools/scaler_cycle_model.js
//   逐拍模型实测：307200 个输出像素用了 2,153,084 拍 = 7.008 拍/像素）。
//   源码流速率由 SPI(25MHz) 决定：每像素 3 字节 ≈ 96 拍@100MHz 才来 1 个。
//   一帧要 640*480 个输出像素，故必须满足
//         640*480*7 <= srcW*srcH*96   ->   srcW*srcH >= 22400
//   fat32_bmp_loader 的 MIN_SRC_PIXELS = 32000 留了约 1.4 倍余量。
//
// ---------------------------------------------------------------------------
// 资源
// ---------------------------------------------------------------------------
//   源行缓存 = 8 个独立的 1024x24 RAM（4 槽 x 2 半行），共 24 个 BRAM9k。
//   必须是 8 个 1024 深的小 RAM，**不能**是 1 个 8192 深的大 RAM —— 原因见
//   第 4 节的长注释（TD 对 8192 深推断 EBR 会失败，实测报 SYN-5042）。
//   9 个 8x11 乘法器（h0/h1 各 3 个，垂直 3 个）
//   1 个共享串行除法器（配置阶段先后跑 X、Y 两次，各 DIVW 拍）
//
module image_bilinear_scaler #(
    parameter [15:0] DST_WIDTH     = 16'd640,
    parameter [15:0] DST_HEIGHT    = 16'd480,
    parameter [15:0] MAX_SRC_WIDTH = 16'd1920,
    parameter [15:0] MAX_SRC_HEIGHT= 16'd1080,
    parameter [3:0]  FRAC_BITS     = 4'd10,
    // 输入 FIFO 深度，必须是 2 的幂（指针按位宽自然回绕）。
    // loader 读一个 512 字节扇区 = 171 个像素，期间**无法被暂停**
    // （fat32_bmp_loader 只在扇区边界检查 write_fifo_afull），故：
    //   1) FIFO 深度 >= 171                    （否则一个扇区都装不下）
    //   2) 反压阈值 <= FDEP - 171               （开始读扇区时必须有 171 个空位）
    //   3) **写入本身只能受"真满"限制**：绝不能写成
    //          fifo_wr = src_valid && !fifo_afull
    //      那会把 FIFO 的实际容量压成"阈值"，扇区剩余像素被静默丢弃。
    //      见第 3 节 fifo_full/fifo_wr 的注释与 tests/tb_scaler_chain.sv。
    // 反压阈值见第 3 节的 FIFO_AFULL_LEAVE，当前 = FDEP - 176。
    parameter [15:0] IN_FIFO_DEPTH = 16'd256
)(
    input  wire        clk,             // sd_card_clk (100 MHz)
    input  wire        rst,
    input  wire        start,           // 与 fat32_bmp_loader 的 start 同步

    // 配置：由 fat32_bmp_loader 解析出的源尺寸
    input  wire [15:0] src_width,
    input  wire [15:0] src_height,
    // 头校验通过（= fat32_bmp_loader 的 header_valid）。
    // 必须以它作为「开始配置」的触发条件：只看 src_width != 0 会把校验失败时
    // 残留在寄存器里的垃圾宽高当成有效配置。
    input  wire        cfg_valid,

    // 源像素流（= fat32_bmp_loader 的 bmp_data / bmp_data_wr_en）
    input  wire [23:0] src_data,
    input  wire        src_valid,
    // 输入缓冲将满。接到 loader 的 write_fifo_afull 上做扇区级反压。
    output wire        src_afull,
    // 因反压来不及而被丢弃的源像素个数（饱和计数）。
    // **正常必须恒为 0**：非 0 说明上游一整段数据没有被暂停的机会，
    // 输出帧必然缺像素 -> 写侧 wr_row 永远到不了 cfg_h -> 一帧写不完。
    output reg  [7:0]  src_overflow_count,

    // 输出反压（来自 write_buf 的 afull；实际几乎不会拉高）
    input  wire        out_stall,

    // 目标像素流：1920x1080 源 -> 恰好 DST_WIDTH*DST_HEIGHT 个像素
    output reg  [23:0] dst_data,
    output reg         dst_valid,
    output reg         dst_done,

    // bit0 = 源尺寸超出 MAX_SRC_WIDTH（非法）
    // bit1 = 输出像素数校验失败（本应恰好 DST_WIDTH*DST_HEIGHT 个）
    output reg  [1:0]  error_code
);

    localparam integer F     = FRAC_BITS;
    localparam integer MUL   = (1 << F);        // 插值分母 2^F
    localparam integer FIXW  = 24;              // 坐标累加器位宽（最大 ~1.97M，21 bit 够）
    localparam integer DIVW  = 27;              // 除法器位宽：max(srcN<<F)=1920<<10=1966080 -> 21 bit
    localparam integer SLOTB = 2;               // 行缓存槽位索引位宽（4 槽，2 的幂 -> 免取模）
    localparam integer FDEP  = IN_FIFO_DEPTH;
    localparam integer FBITS = 8;               // 256 深 -> 8 bit 指针
    // 输出像素总数。显式补零到 32bit 再乘，避免 16bit*16bit 按 16 位截断
    // （640*480 = 307200 需要 19 位）。
    localparam [31:0] DST_PIXELS = {16'd0, DST_WIDTH} * {16'd0, DST_HEIGHT};

    // =======================================================================
    // 1) 配置锁存
    // =======================================================================
    reg [15:0] cfg_w, cfg_h;
    reg        cfg_latched;
    // 一次性标志：配置块只能在 cfg_valid 首次有效时触发一次。
    // 若只靠 !cfg_latched 判断，而在 cfg_latched 拉高之前的每一拍都会重新
    // 进入配置块，把 div_rem/div_quot 清零 -> 串行除法器的余数链被破坏。
    reg        cfg_started;
    wire       cfg_ready   = cfg_valid;
    wire       cfg_w_valid = (src_width != 16'd0) && (src_width <= MAX_SRC_WIDTH);
    wire       cfg_h_valid = (src_height != 16'd0) && (src_height <= MAX_SRC_HEIGHT);

    // =======================================================================
    // 2) 共享串行除法器（恢复余数法，逐位处理被除数最高位）
    //       dividend = srcN << F   (<= 1966080, 21 bit)
    //       divisor  = dstN        (640 / 480)
    //    先算 X，再算 Y，各 DIVW 拍。只在配置阶段跑一次。
    // =======================================================================
    localparam [1:0] DIV_IDLE = 2'd0, DIV_RUN = 2'd1, DIV_DONE = 2'd2;

    reg [1:0]      div_state;
    reg [DIVW-1:0] div_rem, div_quot, div_dividend;
    reg [15:0]     div_divisor;
    reg [5:0]      div_cnt;
    reg            div_is_y;

    reg [FIXW-1:0] step_x, step_y;
    reg [15:0]     rem_x,  rem_y;

    wire [DIVW-1:0] div_cand = {div_rem[DIVW-2:0], div_dividend[div_cnt - 6'd1]};
    wire            div_ge   = (div_cand >= {16'd0, div_divisor});

    // =======================================================================
    // 3) 输入 FIFO（FDEP x 24bit）
    // =======================================================================
    reg [23:0]      fifo_mem [0:FDEP-1];
    reg [FBITS-1:0] fifo_wp, fifo_rp;
    reg [FBITS:0]   fifo_cnt;

    wire fifo_empty = (fifo_cnt == 0);

    // ---- 反压阈值/写门：必须为「一整个扇区」留出空间（2026-09-22 修） ----
    // fat32_bmp_loader 只在**扇区边界**检查 afull（fat32_bmp_loader.v:396 /
    // :455），一个 512 字节扇区一旦开始读，最多会有 171 个像素（512/3 向上取整）
    // 在没有任何反压机会的情况下被推过来。所以：
    //
    //   1) src_afull(给 loader 的水位) <= FDEP - 171，这样开始读扇区时
    //      一定还有 171 个空位；取 FDEP - 176（=80）留 5 个余量。
    //   2) **绝对不能**拿 afull 去 gate 写入本身。原实现是
    //          wire fifo_wr = src_valid && !fifo_afull;
    //      这等于把 FIFO 的实际容量压成「阈值」：阈值多高就最多存多少。
    //      于是 afull 一拉高，本扇区剩下的像素全部被**静默丢弃**
    //      （实测：8x64 的源图在真 loader 下每个扇区丢 40+ 个像素，
    //      丢够 171 个后 wr_row 永远到不了 cfg_h -> 消费者永久停在
    //      EM_ROW_WAIT -> dst_done 不来 -> 一帧永远写不完 -> 板子上黑屏）。
    //      写入只能受"真满"限制：fifo_cnt < FDEP。
    //   3) 只有真满才算丢数据，计数到 src_overflow_count。
    localparam integer SECTOR_MAX_PIXELS = 171;                    // 512 字节 / 3
    localparam integer FIFO_AFULL_LEAVE  = SECTOR_MAX_PIXELS + 5;   // 再留 5 个余量
    // 前提：IN_FIFO_DEPTH 必须 >= SECTOR_MAX_PIXELS + 8，否则阈值会到 0 以下。
    wire fifo_afull = (fifo_cnt >= (FDEP - FIFO_AFULL_LEAVE));   // 扇区级反压
    wire fifo_full  = (fifo_cnt >= FDEP);                        // 真满（指针回绕边界）
    assign src_afull = fifo_afull;

    wire        fifo_wr    = src_valid && !fifo_full;
    // 真满导致的丢弃。正常恒 0；一旦非 0，本帧注定失败，
    // 所以同时把 error_code[1]（像素数校验失败）置起来，便于上板定位。
    wire        fifo_overflow = src_valid && fifo_full;
    wire wr_accept;
    wire        fifo_rd    = !fifo_empty && wr_accept;
    wire [23:0] fifo_rdata = fifo_mem[fifo_rp];   // 组合读 -> 分布式 RAM（只有 256x24，可接受）

    // =======================================================================
    // 4) 源行缓存环（4 个槽，槽号 = 行号[1:0]，免取模）
    //    简单双端口：1 写 + 1 读
    // =======================================================================
    //
    // ---- 为什么是 8 个 1024x24 的小 RAM，而不是 1 个 8192x24 的大 RAM ----
    //
    // 实测（2026-09-18 19:33 那次 syn_1，osd_display_Runs/syn_1/run.log）：
    //     SYN-5042 WARNING: Failed to infer inst
    //         ".../u_image_bilinear_scaler/ramread1_syn_5" as BRAM.
    //     SYN-1023 : Infer 3 Logic DRAMs, 3 Logic BRAMs.
    // 即 TD 尝试把 8192x24 的行缓存推断成 EBR，**失败了**。
    //
    // 失败原因是**深度**，不是宽度。同一份报告里：
    //     u_w24_d1024_fifo    1024 深 x 24 位  ->  成功占用 3 个 BRAM9k
    // 形状和这里需要的完全一样（24 = 9+9+9，浪费 3 位，TD 接受）。
    // 器件原语的深度上限也印证这一点（见 D:\Anlogic\template\verilog\
    // Device-Primitive\EG4\RAM,ROM\eg4_ram_rom.v）：
    //     EG_LOGIC_BRAM  (9Kb)   ADDR_WIDTH_A 最大 10 位  -> 1024 深
    //     EG_PHY_BRAM32K (32Kb)  addra 11 位              -> 2048 深
    // 本工程里所有成功进 EBR 的 RAM 都是 512 或 1024 深。TD 不为推断出的 RAM
    // 做深度级联，8192 = 8 x 1024 它不干。
    //
    // ---- 另一条教训：不要再写 (* ram_style = "bram" *) ----
    // 那个属性的语义是「只准用 BRAM，不许退回分布式 RAM」。推断一旦失败就没有
    // 退路，TD 只能把 196608 个存储位摊成触发器 + 查找表：实测全设计
    // LUT 156968/19600 = 800.86%、REG 204015/19600 = 1040.89%，optimize_gate
    // 从 36 秒涨到 36 分 10 秒。没有属性时至少还能退回分布式 RAM（29563 LUT）。
    // 现在改用 TD 自己生成的 IP 用的注释式 pragma，写在 lbuf_1024x24 模块里
    // （对照 ip/anlogic/afifo_16_32_256.v 第 398 行）。
    //
    // ---- 地址编码（保持不变，这是本方案改动小的关键）----
    //     addr = slot_base(slot) + col = (slot << 11) + col，且 col < 2048
    //   => addr[12:11] = 槽号, addr[10] = 半行号, addr[9:0] = 半行内偏移
    //   8 个数组的编号恰好就是 {槽号, 半行号} = addr[12:10]。
    //   所以 rd_addr_c / wr_addr / slot_base() 的算法**一行都不用改**。
    //
    // 前提：MAX_SRC_WIDTH <= 2048（半行号 1 位 + 偏移 10 位）。当前 1920，满足。
    localparam LBUF_SLOT = 16'd2048;    // 每槽深度，>= MAX_SRC_WIDTH，且 <= 2048

    reg [15:0] wr_row;      // 正在写入的行号（数值上等于已完成的行数）
    reg [15:0] wr_col;      // 行内列号

    // 槽基址 = slot * LBUF_SLOT（2bit x 常量 -> 4 选 1 常量多路，无乘法器）
    function [15:0] slot_base;
        input [SLOTB-1:0] s;
        begin
            case (s)
                2'd0:    slot_base = 16'd0;
                2'd1:    slot_base = LBUF_SLOT;
                2'd2:    slot_base = LBUF_SLOT * 2;
                default: slot_base = LBUF_SLOT * 3;
            endcase
        end
    endfunction

    reg [15:0] y0_cur;      // 消费侧当前需要的最旧源行（用于写侧节流）

    // 写第 wr_row 行会覆盖第 (wr_row - 4) 行；只要它还 < y0_cur 就安全。
    // 放大时该条件会拉低 wr_accept，把写侧节流住而不会覆盖未消费的行。
    // 不会死锁：写侧被挡住时，消费侧所需的两行必然已经就绪，它会推进 y0_cur。
    wire wr_guard_ok = (wr_row < (y0_cur + 16'd4));
    wire wr_row_last = (wr_col == (cfg_w - 16'd1));
    assign wr_accept = !fifo_empty && wr_guard_ok && (wr_row < cfg_h);

    wire [15:0] wr_addr = slot_base(wr_row[SLOTB-1:0]) + wr_col;

    // =======================================================================
    // 5) 坐标累加器
    // =======================================================================
    reg [FIXW-1:0] fix_x, fix_y;
    reg [15:0]     remacc_x, remacc_y;

    // 当前 fix 解码出的采样位置（组合，稳定于整个输出像素期间）
    wire [15:0]  sx0_c = fix_x[FIXW-1:F];
    wire [F-1:0] fx_c  = fix_x[F-1:0];
    wire [15:0]  sx1_c = (sx0_c >= (cfg_w - 16'd1)) ? (cfg_w - 16'd1) : (sx0_c + 16'd1);

    wire [15:0]  sy0_c = fix_y[FIXW-1:F];
    wire [F-1:0] fy_c  = fix_y[F-1:0];
    wire [15:0]  sy1_c = (sy0_c >= (cfg_h - 16'd1)) ? (cfg_h - 16'd1) : (sy0_c + 16'd1);

    // ---- 水平累加器下一状态 ----
    wire [16:0]     remacc_x_sum = {1'b0, remacc_x} + {1'b0, rem_x};
    wire            carry_x      = (remacc_x_sum >= {1'b0, DST_WIDTH});
    wire [15:0]     remacc_x_new = carry_x ? (remacc_x_sum[15:0] - DST_WIDTH) : remacc_x_sum[15:0];
    wire [FIXW-1:0] fix_x_new    = fix_x + step_x + {{(FIXW-1){1'b0}}, carry_x};

    // ---- 垂直累加器下一状态 ----
    wire [16:0]     remacc_y_sum = {1'b0, remacc_y} + {1'b0, rem_y};
    wire            carry_y      = (remacc_y_sum >= {1'b0, DST_HEIGHT});
    wire [15:0]     remacc_y_new = carry_y ? (remacc_y_sum[15:0] - DST_HEIGHT) : remacc_y_sum[15:0];
    wire [FIXW-1:0] fix_y_new    = fix_y + step_y + {{(FIXW-1){1'b0}}, carry_y};

    // =======================================================================
    // 6) 输出侧状态机（每输出像素 7 拍：EM_P0..EM_P6）
    // =======================================================================
    localparam [3:0] EM_ROW_INIT = 4'd0,   // 锁存本输出行的垂直采样位置
                     EM_ROW_WAIT = 4'd1,   // 等 sy1 行写完
                     EM_P0       = 4'd2,   // 发 (sy0, sx0) 读地址
                     EM_P1       = 4'd3,   // 取 p00；发 (sy0, sx1)
                     EM_P2       = 4'd4,   // 取 p01；发 (sy1, sx0)
                     EM_P3       = 4'd5,   // 取 p10；发 (sy1, sx1)
                     EM_P4       = 4'd6,   // 取 p11
                     EM_P5       = 4'd7,   // 算 h0/h1
                     EM_P6       = 4'd8,   // 算 v、输出、推进累加器
                     EM_FINISH   = 4'd9;

    reg [3:0]  em_state;
    reg [15:0] out_y, out_x;

    reg [15:0] sy0, sy1;        // 本输出行锁存的源行对
    reg [F-1:0] fy;

    reg [23:0] p00, p01, p10, p11, h0, h1;

    reg [31:0] px_count;        // 已输出像素数，用于最终校验

    // 行缓存读地址：由当前状态 **组合** 译码。
    // 地址在 EM_P0 发出，RAM 的输出寄存器在 EM_P0 末采样 -> EM_P1 数据有效，
    // 于是 EM_P0 发地址、EM_P1 取数据，每输出像素正好 7 拍闭环。
    // 若把 rd_addr 也打一拍（reg），读延迟变 2 拍，四个抽头会整体错位一拍，
    // 取到的就不是 p00/p01/p10/p11，图像会串行错位。
    // 地址位段含义见第 4 节：addr[12:11]=槽号, addr[10]=半行号, addr[9:0]=偏移。
    // rd_data（8 选 1 的结果）在存储器实例之后定义。
    reg  [15:0] rd_addr_c;

    wire em_x_last = (out_x == (DST_WIDTH  - 16'd1));
    wire em_y_last = (out_y == (DST_HEIGHT - 16'd1));
    // sy1 行写完的条件：已完成的行数 wr_row 必须 > sy1
    wire row_pair_ready = (wr_row > sy1);

    // ---- 逐通道线性插值 ----
    //
    // 原式（双乘法器）：  out = (a*(MUL-t) + b*t) >> F
    // 本实现（单乘法器）： out = a + floor((b-a)*t / MUL)
    //
    // 两者 **完全等价**，连取整行为都一致：
    //     a*(MUL-t) + b*t = a*MUL + (b-a)*t
    //     >>F 就是 floor(/MUL)，而 a 是整数，floor(a + x) = a + floor(x)
    //
    // 为什么非要改：EG4S20 只有 29 个 DSP。原来的写法每次 lerp 要 2 个乘法器，
    // 本模块 9 次调用 = 18 个 DSP，实测综合后 #dsp = 29/29 = 100%，一点余量
    // 都不剩。单乘法器写法把它砍到 9 个。
    //
    // 取值范围：|b-a|*t/MUL 恒在 [0, |b-a|] 内（t <= 1023 < MUL），所以结果
    // 恒在 [min(a,b), max(a,b)] 内，必然落在 [0,255]，无需钳位。
    //
    // 实现上刻意**完全不用有符号数**：用 |b-a| 加上「按 b>=a 分支」把 floor
    // 的取整方向处理掉。若改用 signed/$signed + >>> 算术右移，一旦综合器的
    // 符号处理有出入，结果是**算出错的像素值**而不是报错，比资源问题难查得多。
    //
    //   b >= a:  a + floor((b-a)t/MUL)  = a + (m >> F)
    //   b <  a:  a - ceil((a-b)t/MUL)   = a - ((m + MUL-1) >> F)
    // 合起来正好等于 floor((a*MUL + (b-a)*t) / MUL)。
    function [7:0] lerp8;
        input [7:0]   a;
        input [7:0]   b;
        input [F-1:0] t;
        reg [7:0]     dpos;     // |b - a|
        reg [F+9:0]   m;        // dpos * t，最大 255*1023 = 260865
        reg [F+9:0]   lo;       // floor(m / MUL)
        reg [F+9:0]   hi;       // ceil (m / MUL)
        begin
            dpos  = (b >= a) ? (b - a) : (a - b);
            m     = dpos * t;                       // 唯一一个乘法器
            lo    = m >> F;
            hi    = (m + (MUL - 1)) >> F;
            lerp8 = (b >= a) ? (a + lo) : (a - hi);
        end
    endfunction

    wire [23:0] h0_c = {lerp8(p00[23:16], p01[23:16], fx_c),
                        lerp8(p00[15:8],  p01[15:8],  fx_c),
                        lerp8(p00[7:0],   p01[7:0],   fx_c)};
    wire [23:0] h1_c = {lerp8(p10[23:16], p11[23:16], fx_c),
                        lerp8(p10[15:8],  p11[15:8],  fx_c),
                        lerp8(p10[7:0],   p11[7:0],   fx_c)};
    wire [23:0] dst_c = {lerp8(h0[23:16], h1[23:16], fy),
                         lerp8(h0[15:8],  h1[15:8],  fy),
                         lerp8(h0[7:0],   h1[7:0],   fy)};

    // =======================================================================
    // 行缓存读地址译码（组合）
    //   EM_P0 发 A0=(sy0,sx0) -> 下一拍 RAM 输出有效 -> EM_P1 取 p00
    //   EM_P1 发 A1=(sy0,sx1) -> EM_P2 取 p01
    //   EM_P2 发 A2=(sy1,sx0) -> EM_P3 取 p10
    //   EM_P3 发 A3=(sy1,sx1) -> EM_P4 取 p11
    // =======================================================================
    always @(*) begin
        case (em_state)
            EM_P0:   rd_addr_c = slot_base(sy0[SLOTB-1:0]) + sx0_c;
            EM_P1:   rd_addr_c = slot_base(sy0[SLOTB-1:0]) + sx1_c;
            EM_P2:   rd_addr_c = slot_base(sy1[SLOTB-1:0]) + sx0_c;
            EM_P3:   rd_addr_c = slot_base(sy1[SLOTB-1:0]) + sx1_c;
            default: rd_addr_c = 16'd0;
        endcase
    end

    // =======================================================================
    // 存储器实例
    //
    // 输入 FIFO：256x24，组合读，退化成分布式 RAM 是对的（只有 6144 bit，
    // 约 500 个 LUT）。它太小，进 EBR 反而浪费块。**刻意不加任何 ram_style 属性。**
    // =======================================================================
    always @(posedge clk) begin
        if (fifo_wr) fifo_mem[fifo_wp] <= src_data;
    end

    // =======================================================================
    // 行缓存：8 个独立的 1024x24 RAM
    //
    // 数组编号 = {槽号, 半行号} = addr[12:10]，数组内地址 = addr[9:0]。
    // 写口全程只有一个（fifo_rd），读口全程也只有一个（rd_addr_c），
    // 所以每个 RAM 仍是 1 写 + 1 读，正好一个简单双口 EBR。
    // =======================================================================
    wire [2:0] wr_sel = wr_addr[12:10];
    wire [9:0] wr_off = wr_addr[9:0];

    // 读数据的 8 选 1 必须用**延一拍**的选择信号：
    // RAM 的输出寄存器在 EM_P0 末采样、EM_P1 有效，所以选择信号也要在 EM_P1
    // 有效。这样 lb_o[] 与 rd_sel_d 同拍有效，与原 rd_q 的时序逐拍完全一致，
    // 每输出像素仍然是 7 拍。
    reg [2:0] rd_sel_d;

    always @(posedge clk) begin
        rd_sel_d <= rd_addr_c[12:10];
    end

    wire [23:0] lb_o [0:7];

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_lbuf
            lbuf_1024x24 u_lbuf (
                .clk   (clk),
                .we    (fifo_rd && (wr_sel == gi)),
                .waddr (wr_off),
                .wdata (fifo_rdata),
                .raddr (rd_addr_c[9:0]),
                .rdata (lb_o[gi])
            );
        end
    endgenerate

    // 8 选 1（约 100 个 LUT）。EM_P1..EM_P4 的 p00/p01/p10/p11 <= rd_data 不变。
    wire [23:0] rd_data = lb_o[rd_sel_d];

    // =======================================================================
    // 主时序块
    // =======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_state <= DIV_IDLE; div_rem <= 0; div_quot <= 0;
            div_dividend <= 0; div_divisor <= 0; div_cnt <= 0; div_is_y <= 1'b0;
            step_x <= 0; step_y <= 0; rem_x <= 0; rem_y <= 0;

            cfg_w <= 0; cfg_h <= 0; cfg_latched <= 1'b0; cfg_started <= 1'b0;

            fifo_wp <= 0; fifo_rp <= 0; fifo_cnt <= 0;
            src_overflow_count <= 8'd0;

            wr_row <= 0; wr_col <= 0; y0_cur <= 0;

            em_state <= EM_ROW_INIT; out_y <= 0; out_x <= 0;
            fix_x <= 0; fix_y <= 0; remacc_x <= 0; remacc_y <= 0;
            sy0 <= 0; sy1 <= 0; fy <= 0;
            p00 <= 0; p01 <= 0; p10 <= 0; p11 <= 0; h0 <= 0; h1 <= 0;
            px_count <= 0;

            dst_data <= 0; dst_valid <= 1'b0; dst_done <= 1'b0;
            error_code <= 2'd0;
        end else begin
            dst_valid <= 1'b0;

            // ---------------------------------------------------------------
            // 输入 FIFO
            // ---------------------------------------------------------------
            if (fifo_wr) fifo_wp <= fifo_wp + 1'b1;
            if (fifo_rd) fifo_rp <= fifo_rp + 1'b1;
            case ({fifo_wr, fifo_rd})
                2'b10:   fifo_cnt <= fifo_cnt + 1'b1;
                2'b01:   fifo_cnt <= fifo_cnt - 1'b1;
                default: ;
            endcase

            // 溢出计数（饱和）。正常路径下 fifo_overflow 恒为 0；
            // 一旦发生就是不可恢复的本帧失败，同时点亮 error_code[1]。
            if (fifo_overflow) begin
                if (src_overflow_count != 8'hFF)
                    src_overflow_count <= src_overflow_count + 8'd1;
                error_code[1] <= 1'b1;
            end

            // ---------------------------------------------------------------
            // 源行写指针推进
            // 注意：行缓存的数据写入不在这里，在 8 个 lbuf_1024x24 实例里
            // （见第 4 节「存储器实例」）。
            // ---------------------------------------------------------------
            if (fifo_rd) begin
                if (wr_row_last) begin
                    wr_col <= 16'd0;
                    wr_row <= wr_row + 16'd1;
                end else begin
                    wr_col <= wr_col + 16'd1;
                end
            end

            // ---------------------------------------------------------------
            // start / 配置
            // ---------------------------------------------------------------
            if (start) begin
                cfg_latched <= 1'b0;
                cfg_started <= 1'b0;
                step_x <= 0; step_y <= 0; rem_x <= 0; rem_y <= 0;
                wr_row <= 0; wr_col <= 0; y0_cur <= 0;
                fifo_wp <= 0; fifo_rp <= 0; fifo_cnt <= 0;
                src_overflow_count <= 8'd0;
                em_state <= EM_ROW_INIT; out_y <= 0; out_x <= 0;
                fix_x <= 0; fix_y <= 0; remacc_x <= 0; remacc_y <= 0;
                sy0 <= 0; sy1 <= 0; fy <= 0;
                px_count <= 0; dst_done <= 1'b0; error_code <= 2'd0;
                div_state <= DIV_IDLE;
            end else if (!cfg_latched && !cfg_started && cfg_ready) begin
                cfg_started  <= 1'b1;
                cfg_w <= src_width;
                cfg_h <= src_height;
                if (!cfg_w_valid || !cfg_h_valid) error_code[0] <= 1'b1;
                // 启动 X 轴除法
                div_is_y     <= 1'b0;
                div_dividend <= ({16'd0, src_width} << F);
                div_divisor  <= DST_WIDTH;
                div_rem      <= 0;
                div_quot     <= 0;
                div_cnt      <= DIVW[5:0];
                div_state    <= DIV_RUN;
            end

            // start 期间冻结除法器与输出状态机：
            // 保证 start 一定能中止上一次尚未完成的转换，且不会在 start 那一拍
            // 多吐一个陈旧像素进 write_buf（cfg_latched 是寄存器，start 当拍仍为 1）。
            if (!start) begin

            // ---------------------------------------------------------------
            // 串行除法器
            // ---------------------------------------------------------------
            case (div_state)
                DIV_RUN: begin
                    if (div_ge) begin
                        div_rem  <= div_cand - {16'd0, div_divisor};
                        div_quot[div_cnt - 6'd1] <= 1'b1;
                    end else begin
                        div_rem  <= div_cand;
                        div_quot[div_cnt - 6'd1] <= 1'b0;
                    end
                    div_cnt <= div_cnt - 6'd1;
                    if (div_cnt == 6'd1) div_state <= DIV_DONE;
                end
                DIV_DONE: begin
                    if (!div_is_y) begin
                        step_x <= div_quot[FIXW-1:0];
                        rem_x  <= div_rem[15:0];
                        // 接着算 Y 轴
                        div_is_y     <= 1'b1;
                        div_dividend <= ({16'd0, cfg_h} << F);
                        div_divisor  <= DST_HEIGHT;
                        div_rem      <= 0;
                        div_quot     <= 0;
                        div_cnt      <= DIVW[5:0];
                        div_state    <= DIV_RUN;
                    end else begin
                        step_y <= div_quot[FIXW-1:0];
                        rem_y  <= div_rem[15:0];
                        cfg_latched <= 1'b1;
                        em_state <= EM_ROW_INIT;
                        div_state <= DIV_IDLE;
                    end
                end
                default: ;
            endcase

            // ---------------------------------------------------------------
            // 输出状态机
            // ---------------------------------------------------------------
            if (cfg_latched) begin
                case (em_state)
                    // 锁存本输出行的垂直采样位置（fix_y 指向当前输出行）
                    EM_ROW_INIT: begin
                        sy0 <= sy0_c;
                        sy1 <= sy1_c;
                        fy  <= fy_c;
                        em_state <= EM_ROW_WAIT;
                    end

                    // 等 sy1 行写完，然后开始本行第一个像素
                    // 注意：这里不改 y0_cur —— 它在上一行结束时已被设为「下一个
                    // 输出行的起始源行」，见 EM_P6。若在这里改成当前行的 sy0，
                    // 降采样步长接近 3 时（1080/480 = 2.25）会死锁。
                    EM_ROW_WAIT: begin
                        if (row_pair_ready) begin
                            out_x    <= 16'd0;
                            em_state <= EM_P0;
                        end
                    end

                    EM_P0: begin
                        em_state <= EM_P1;         // rd_addr_c 已指向 (sy0, sx0)
                    end
                    EM_P1: begin
                        p00      <= rd_data;                       // = lbuf[sy0][sx0]
                        em_state <= EM_P2;
                    end
                    EM_P2: begin
                        p01      <= rd_data;                       // = lbuf[sy0][sx1]
                        em_state <= EM_P3;
                    end
                    EM_P3: begin
                        p10      <= rd_data;                       // = lbuf[sy1][sx0]
                        em_state <= EM_P4;
                    end
                    EM_P4: begin
                        p11      <= rd_data;                       // = lbuf[sy1][sx1]
                        em_state <= EM_P5;
                    end
                    EM_P5: begin
                        h0 <= h0_c;
                        h1 <= h1_c;
                        em_state <= EM_P6;
                    end
                    EM_P6: begin
                        // 输出缓冲满则原地等待（h0/h1 已稳定，不会丢数据）
                        if (!out_stall) begin
                            dst_data  <= dst_c;
                            dst_valid <= 1'b1;
                            px_count  <= px_count + 32'd1;
                            if (em_x_last) begin
                                // 本行结束：推进垂直累加器，水平累加器清零
                                fix_y    <= fix_y_new;
                                remacc_y <= remacc_y_new;
                                fix_x    <= 0;
                                remacc_x <= 0;
                                out_x    <= 16'd0;
                                out_y    <= out_y + 16'd1;
                                if (em_y_last) begin
                                    // 最后一个输出行：不再需要任何源行，放开写侧
                                    y0_cur   <= cfg_h;
                                    em_state <= EM_FINISH;
                                end else begin
                                    // 关键：y0_cur 取「**下一个**输出行」的起始源行
                                    // fix_y_new>>F，而不是当前行的 sy0。
                                    // 否则降采样步长为 2.25 时下一行一次跳过 3 行，
                                    // 写侧被 wr_guard_ok 挡住 -> 死锁（已由
                                    // tools/scaler_rtl_model.js 复现并验证修复）。
                                    y0_cur   <= fix_y_new[FIXW-1:F];
                                    em_state <= EM_ROW_INIT;
                                end
                            end else begin
                                fix_x    <= fix_x_new;
                                remacc_x <= remacc_x_new;
                                out_x    <= out_x + 16'd1;
                                em_state <= EM_P0;
                            end
                        end
                    end
                    EM_FINISH: begin
                        dst_done <= 1'b1;
                        if (px_count != DST_PIXELS) error_code[1] <= 1'b1;
                    end
                    default: em_state <= EM_ROW_INIT;
                endcase
            end

            end  // if (!start)

        end
    end

endmodule


// ===========================================================================
// lbuf_1024x24 —— 行缓存的一个「半行」，1024 深 x 24 位，单写单读。
//
// 形状刻意做得与 TD 已经成功推断成 EBR 的 u_w24_d1024_fifo 一致
// （1024 深 x 24 位 -> 3 个 BRAM9k）。每个实例独立推断，不涉及深度级联，
// 所以不会踩到 8192 深推断失败（SYN-5042）那个坑。
//
// pragma 用 TD 自己生成的 IP 的**注释式**写法（对照
// ip/anlogic/afifo_16_32_256.v 第 398 行），而不是 (* ram_style = "bram" *)：
// 后者会禁止分布式 RAM 回退，一旦推断失败就会退化成触发器 + 查找表，
// 后果比推断失败本身严重得多（实测 LUT 800.86%、REG 1040.89%）。
//
// rdata 不加复位：EBR 的内部输出寄存器没有异步复位，带上它 TD 就用不了 EBR。
// 数据只在 cfg_latched 之后被消费，那时早过了复位，不复位是安全的。
// ===========================================================================
module lbuf_1024x24 (
    input  wire        clk,
    input  wire        we,
    input  wire [9:0]  waddr,
    input  wire [23:0] wdata,
    input  wire [9:0]  raddr,
    output reg  [23:0] rdata
);
    reg [23:0] mem [0:1023];    /* fehdl force_ram=1, ram_style="bram" */

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= mem[raddr];
    end
endmodule
