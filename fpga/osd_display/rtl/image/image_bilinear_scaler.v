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
//   输出回路每个输出像素 9 拍（EM_P0..EM_P6 + 插值流水 EM_P5B/EM_P6A；
//   改流水前 tools/scaler_cycle_model.js 实测为 7.008 拍/像素）。
//   源码流速率由 SPI(25MHz) 决定：每像素 3 字节 ≈ 96 拍@100MHz 才来 1 个。
//   小图（放大）时输出比源慢，输入 FIFO 反压 loader：loader 只在扇区之间
//   （ST_STREAM_PAUSE，此时没有挂起的扇区读，SD 看门狗不计时）停下来等，
//   每次最多等几行输出（< 1 ms）。所以源图再小也不会丢数据或超时，
//   只是一帧固定要 640*480*9 拍 ≈ 28 ms 输出时间。loader 的 MIN_SRC_PIXELS
//   因此已放宽到 1（tests/tb_scaler_sizes.sv 覆盖 1x1 .. 1920x1080）。
//
// ---------------------------------------------------------------------------
// 抗锯齿（降采样比 >= 1.5 时自动启用，AA_ENABLE=0 可关）
// ---------------------------------------------------------------------------
//   纯双线性在 1920->640 这类 3 倍缩小时每 3 个源像素只取 2 个，细线/文字会
//   断续闪烁（混叠）。启用后每个图像像素读 4x4 源窗口
//       行 sy0-1, sy0, sy0+1, sy0+2  x  列 sx0-1, sx0, sx0+1, sx0+2（边缘钳位）
//   先做 [1 2 1]x[1 2 1]/16 的帐篷预滤波得到 4 个抽头 q00/q01/q10/q11，
//   再走原来的双线性。预滤波全是移位加法，不占 DSP（DSP 已 29/29），不加 BRAM。
//   代价：图像像素 9 -> 25 拍；降采样时源流速 >= 96 拍/像素，输出永远更快，
//   加载时间不变。行缓存仍是 4 槽：读窗口正好 4 行，写侧节流改为
//   wr_row < y0_cur + 3（y0_cur 仍是当前 sy0，窗口最低行为 sy0-1）。
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
    parameter [15:0] MAX_SRC_WIDTH = 16'd1280,
    parameter [15:0] MAX_SRC_HEIGHT= 16'd960,
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
    parameter [15:0] IN_FIFO_DEPTH = 16'd256,
    // 黑边像素输出间隔（拍/像素）。黑边不依赖源数据，若 1 拍 1 个满速吐，
    // 写 FIFO 会连续突发把 SDRAM 带宽占满，读侧（显示/滑动转场）断流
    // -> read_fault 锁死（1920x1080 上下各 60 行黑边实测复现）。
    // 取 8：与图像像素 EM_P0..P6 的 7 拍/像素同量级。
    parameter [3:0]  BLACK_INTERVAL = 4'd8,
    // 降采样抗锯齿（见文件头）。1 = 缩小比 >= 1.5 时启用，0 = 始终纯双线性
    parameter        AA_ENABLE      = 1'b1
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
    output reg  [1:0]  error_code,

    // 等比例缩放结果（info_valid 拉高后有效，直到下一次 start）
    //   img_width/img_height : 缩放后图像在输出帧里占的尺寸
    //   scale_x100           : 缩放比 x100（例：640/600 -> 106，1920->640 -> 33）
    output reg  [15:0] img_width,
    output reg  [15:0] img_height,
    output reg  [15:0] scale_x100,
    output wire        info_valid
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
    // cfg_valid 晚一拍使用：fit_w_c 打了一拍（见下），保证配置时采到的是
    // 当前 src_width/src_height 算出的结果（header_valid 是电平，晚一拍无影响）。
    reg        cfg_valid_q;
    wire       cfg_ready   = cfg_valid && cfg_valid_q;
    wire       cfg_w_valid = (src_width != 16'd0) && (src_width <= MAX_SRC_WIDTH);
    wire       cfg_h_valid = (src_height != 16'd0) && (src_height <= MAX_SRC_HEIGHT);

    // =======================================================================
    // 1b) 等比例缩放（letterbox）
    //
    //   统一缩放比 = min(DST_W/srcW, DST_H/srcH)，X/Y 用同一个步长，图像居中，
    //   其余区域填黑。判断哪条边先贴边只需比较交叉乘积（无除法）：
    //       fit_w = (srcW * DST_H >= srcH * DST_W)   -> 宽先贴边
    //   记 N = 受限边的源尺寸，D = 对应的输出尺寸（fit_w ? (srcW,DST_W) : (srcH,DST_H)），
    //   则缩放比 = D/N：
    //       步长        STEP = (N << F) / D，余数 REM = (N << F) mod D
    //       另一条边尺寸      = floor(另一边源尺寸 * D / N)
    //       缩放比 x100       = floor(D * 100 / N)
    //   例（DST 640x480）：640x400 -> 1.00, 640x400 居中；
    //                      600x400 -> 1.06, 640x426；1920x1080 -> 0.33, 640x360。
    //
    //   采样仍是左上对齐的 sx(i) = floor(i * N / D)，Bresenham 的分母由常量
    //   DST_WIDTH/DST_HEIGHT 换成了寄存器 scale_den（= D），两轴共用。
    //   不越界：宽贴边时 i <= DST_W-1 -> sx <= srcW-1；
    //           另一边 j <= floor(srcH*D/N)-1 -> j*N/D < srcH -> sy <= srcH-1。
    // =======================================================================
    wire [31:0] cross_w = {16'd0, src_width}  * {16'd0, DST_HEIGHT};
    wire [31:0] cross_h = {16'd0, src_height} * {16'd0, DST_WIDTH};
    // 乘法 + 比较打一拍再用（时序：src_width -> MULT -> 比较 -> div_dividend 原本一拍做完）
    reg         fit_w_c;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fit_w_c     <= 1'b1;
            cfg_valid_q <= 1'b0;
        end else begin
            fit_w_c     <= (cross_w >= cross_h);
            cfg_valid_q <= cfg_valid;
        end
    end

    reg         fit_w;          // 1 = 宽贴边，0 = 高贴边
    reg  [15:0] scale_num;      // N
    reg  [15:0] scale_den;      // D
    reg  [15:0] img_x0, img_x1; // 图像列区间 [img_x0, img_x1)
    reg  [15:0] img_y0, img_y1; // 图像行区间 [img_y0, img_y1)

    // =======================================================================
    // 2) 共享串行除法器（恢复余数法，逐位处理被除数最高位）
    //    配置阶段依次跑 3 次，各 DIVW 拍：
    //       DIV_STEP  : (N << F) / D          -> 步长 + 余数   (<= 1966080, 21 bit)
    //       DIV_OTHER : 另一边源尺寸 * D / N  -> 另一边输出尺寸 (<= 1080*640, 20 bit)
    //       DIV_SCALE : D * 100 / N           -> 缩放比 x100
    // =======================================================================
    localparam [1:0] DIV_IDLE = 2'd0, DIV_RUN = 2'd1, DIV_DONE = 2'd2;
    // DIV_POST：另一边尺寸的钳位/居中偏移分 3 拍算完（时序，100 MHz）
    localparam [1:0] DIV_POST = 2'd3;
    localparam [1:0] DIV_STEP = 2'd0, DIV_OTHER = 2'd1, DIV_SCALE = 2'd2;

    reg [1:0]      div_state;
    reg [DIVW-1:0] div_rem, div_quot, div_dividend;
    reg [15:0]     div_divisor;
    reg [5:0]      div_cnt;
    reg [1:0]      div_phase;
    reg [1:0]      div_post;
    reg [15:0]     oth_raw_r, oth_size_r, oth_off_r;

    // 两轴共用同一缩放比，所以 step_x == step_y、rem_x == rem_y。
    // 保留两套名字只是为了让下面的累加器代码保持 X/Y 对称、易读。
    reg [FIXW-1:0] step_x, step_y;
    reg [15:0]     rem_x,  rem_y;

    assign info_valid = cfg_latched;

    // 另一条边的输出尺寸：钳到 [1, DST]（源尺寸合法时本就在范围内，钳位只防呆）
    wire [15:0] other_dst_lim = fit_w ? DST_HEIGHT : DST_WIDTH;
    wire [15:0] other_raw     = (div_quot[DIVW-1:16] != 0) ? 16'hFFFF : div_quot[15:0];
    wire [31:0] other_dividend = fit_w ? ({16'd0, cfg_h} * {16'd0, DST_WIDTH})
                                       : ({16'd0, cfg_w} * {16'd0, DST_HEIGHT});
    wire [31:0] scale_dividend = {16'd0, scale_den} * 32'd100;
    wire [15:0] other_size    = (oth_raw_r == 16'd0) ? 16'd1 :
                                (oth_raw_r > other_dst_lim) ? other_dst_lim : oth_raw_r;
    wire [15:0] other_off      = (other_dst_lim - oth_size_r) >> 1;

    // 被除数每步左移一位、商从最低位移入：与按 div_cnt 下标取位/置位完全等价，
    // 但去掉了 32 选 1 的可变下标（时序）。
    wire [DIVW-1:0] div_cand = {div_rem[DIVW-2:0], div_dividend[DIVW-1]};
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
    reg [15:0] wr_row_done; // wr_row 晚一拍：行缓存写入打了一拍，读侧用它判断行已写完
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
    // 抗锯齿时读窗口从 sy0-1 开始，只能领先 3 行。限值寄存一拍（时序）：
    // y0_cur 只增不减（start 时虽清零，但那一拍 FIFO 同时清空，不会误写），
    // 晚一拍只会让节流更保守。
    reg        aa_en;
    reg [15:0] wr_row_lim;
    always @(posedge clk or posedge rst) begin
        if (rst) wr_row_lim <= 16'd0;
        else     wr_row_lim <= y0_cur + (aa_en ? 16'd3 : 16'd4);
    end
    wire wr_guard_ok = (wr_row < wr_row_lim);
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
    reg  [F-1:0] fx_r;   // 本像素的水平小数（fix_x 在 EM_P4 已推进到下一像素）
    wire [15:0]  sx1_c = (sx0_c >= (cfg_w - 16'd1)) ? (cfg_w - 16'd1) : (sx0_c + 16'd1);

    wire [15:0]  sy0_c = fix_y[FIXW-1:F];
    wire [F-1:0] fy_c  = fix_y[F-1:0];
    wire [15:0]  sy1_c = (sy0_c >= (cfg_h - 16'd1)) ? (cfg_h - 16'd1) : (sy0_c + 16'd1);

    // ---- 水平累加器下一状态 ----
    wire [16:0]     remacc_x_sum = {1'b0, remacc_x} + {1'b0, rem_x};
    wire            carry_x      = (remacc_x_sum >= {1'b0, scale_den});
    wire [15:0]     remacc_x_new = carry_x ? (remacc_x_sum[15:0] - scale_den) : remacc_x_sum[15:0];
    wire [FIXW-1:0] fix_x_new    = fix_x + step_x + {{(FIXW-1){1'b0}}, carry_x};

    // ---- 垂直累加器下一状态 ----
    wire [16:0]     remacc_y_sum = {1'b0, remacc_y} + {1'b0, rem_y};
    wire            carry_y      = (remacc_y_sum >= {1'b0, scale_den});
    wire [15:0]     remacc_y_new = carry_y ? (remacc_y_sum[15:0] - scale_den) : remacc_y_sum[15:0];
    wire [FIXW-1:0] fix_y_new    = fix_y + step_y + {{(FIXW-1){1'b0}}, carry_y};

    // =======================================================================
    // 6) 输出侧状态机（每输出像素 9 拍：EM_P0..EM_P6，含 EM_P5B/EM_P6A）
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
                     EM_FINISH   = 4'd9,
                     EM_BLACK    = 4'd10,  // 黑边像素：BLACK_INTERVAL 拍 1 个，不读行缓存
                     EM_P5B      = 4'd11,  // 水平插值第 2 级：移位/加减 -> h0/h1
                     EM_P6A      = 4'd12,  // 垂直插值第 1 级：乘法 -> vm*
                     EM_AS       = 4'd13,  // 抗锯齿：锁存 4 列、发第 1 个地址、清累加器
                     EM_AR       = 4'd14,  // 抗锯齿：连发 16 个地址 + 3 级滤波流水（19 拍）
                     EM_AQ       = 4'd15;  // 抗锯齿：累加结果 -> p00..p11，推进 fix_x

    reg [3:0]  em_state;
    reg [15:0] out_y, out_x;

    reg [15:0] sy0, sy1;        // 本输出行锁存的源行对
    reg [15:0] sym, sy3;        // 抗锯齿窗口的上/下行：clamp(sy0-1), clamp(sy0+2)
    reg [F-1:0] fy;

    reg [23:0] p00, p01, p10, p11, h0, h1;

    // 插值两级流水寄存器（第 1 级乘法 / 第 2 级移位加减）
    // 时序：原先 p11->h1、h0/h1->dst_data 都是「乘法+加减」一拍完成，
    // 100MHz 下 -2.9ns；拆成两级后每级只有乘法或加减。
    reg [F+9:0] hm0r, hm0g, hm0b, hm1r, hm1g, hm1b;   // 水平乘积
    reg [2:0]   hge0, hge1;                           // b >= a
    reg [23:0]  ha0, ha1;                             // 被插值的 a
    reg [F+9:0] vmr, vmg, vmb;                        // 垂直乘积
    reg [2:0]   vge;

    reg [31:0] px_count;        // 已输出像素数，用于最终校验
    reg [3:0]  black_div;       // 黑边限速计数

    // 行缓存读地址：由当前状态 **组合** 译码。
    // 地址在 EM_P0 发出，RAM 的输出寄存器在 EM_P0 末采样 -> EM_P1 数据有效，
    // 于是 EM_P0 发地址、EM_P1 取数据，每输出像素正好 7 拍闭环。
    // 若把 rd_addr 也打一拍（reg），读延迟变 2 拍，四个抽头会整体错位一拍，
    // 取到的就不是 p00/p01/p10/p11，图像会串行错位。
    // 地址位段含义见第 4 节：addr[12:11]=槽号, addr[10]=半行号, addr[9:0]=偏移。
    // rd_data（8 选 1 的结果）在存储器实例之后定义。
    reg  [15:0] rd_addr_c;

    // ---- 抗锯齿 4x4 窗口 ----
    // 行缓存地址 = slot*2048 + col = {slot[1:0], col[10:0]}（col < 2048），拼接即可。
    reg  [10:0] aa_cx0, aa_cx1, aa_cx2, aa_cx3;   // 4 列（已钳位）
    reg  [4:0]  aa_cnt;                           // EM_AR 内 0..18
    reg  [15:0] aa_addr_r;                        // 本拍送 RAM 的地址（提前一拍算好）
    wire [4:0]  aa_kn = aa_cnt + 5'd1;            // 下一拍要发的窗口序号（行=kn[3:2]，列=kn[1:0]）
    wire [15:0] sx0p2 = sx0_c + 16'd2;
    wire [15:0] aa_cx0_c = (sx0_c == 16'd0) ? 16'd0 : (sx0_c - 16'd1);
    wire [15:0] aa_cx3_c = (sx0p2 >= cfg_w) ? (cfg_w - 16'd1) : sx0p2;
    wire [15:0] sy0p2 = sy0_c + 16'd2;
    reg  [1:0]  aa_row_slot;
    reg  [10:0] aa_col;
    always @(*) begin
        case (aa_kn[3:2])
            2'd0:    aa_row_slot = sym[1:0];
            2'd1:    aa_row_slot = sy0[1:0];
            2'd2:    aa_row_slot = sy1[1:0];
            default: aa_row_slot = sy3[1:0];
        endcase
        case (aa_kn[1:0])
            2'd0:    aa_col = aa_cx0;
            2'd1:    aa_col = aa_cx1;
            2'd2:    aa_col = aa_cx2;
            default: aa_col = aa_cx3;
        endcase
    end

    // 时序（100 MHz）：四个抽头地址预先打一拍。原来 cfg_w-1 比较 -> sx1 选择 ->
    // 加槽基址 -> RAM 地址脚是一条组合长路径。fix_x 在 EM_P4 推进、sy0/sy1 在
    // EM_ROW_INIT 更新，距离下一次 EM_P0 至少隔 1 拍，所以寄存器版本在 EM_P0..P3
    // 期间总是与组合版本相同。
    reg  [15:0] rd_a00_r, rd_a01_r, rd_a10_r, rd_a11_r;
    always @(posedge clk) begin
        rd_a00_r <= slot_base(sy0[SLOTB-1:0]) + sx0_c;
        rd_a01_r <= slot_base(sy0[SLOTB-1:0]) + sx1_c;
        rd_a10_r <= slot_base(sy1[SLOTB-1:0]) + sx0_c;
        rd_a11_r <= slot_base(sy1[SLOTB-1:0]) + sx1_c;
    end

    wire em_x_last = (out_x == (DST_WIDTH  - 16'd1));
    wire em_y_last = (out_y == (DST_HEIGHT - 16'd1));
    // sy1 行写完的条件：已完成的行数 wr_row 必须 > sy1（抗锯齿时要到 sy3）
    wire row_pair_ready = (wr_row_done > (aa_en ? sy3 : sy1));
    // 图像像素的入口状态
    wire [3:0] em_img_px = aa_en ? EM_AS : EM_P0;

    // ---- letterbox 区域判断 ----
    // 当前行是否图像行；下一个像素（同一行 out_x+1）是否图像像素；
    // 下一行（out_y+1）是否图像行；当前行是否最后一个图像行。
    wire [15:0] out_x_nx      = out_x + 16'd1;
    wire [15:0] out_y_nx      = out_y + 16'd1;
    wire        row_is_img    = (out_y    >= img_y0) && (out_y    < img_y1);
    wire        nx_is_img     = row_is_img && (out_x_nx >= img_x0) && (out_x_nx < img_x1);
    wire        ny_is_img     = (out_y_nx >= img_y0) && (out_y_nx < img_y1);
    wire        row_img_last  = (out_y_nx == img_y1);
    // 一个像素输出后的下一状态（黑边与图像像素共用）
    wire [3:0]  em_next_px    = em_x_last ? (em_y_last ? EM_FINISH :
                                              (ny_is_img ? EM_ROW_INIT : EM_BLACK))
                                          : (nx_is_img ? em_img_px : EM_BLACK);

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
    // 第 1 级：|b-a| * t（唯一一个乘法器）
    function [F+9:0] lerp_m;
        input [7:0]   a;
        input [7:0]   b;
        input [F-1:0] t;
        reg [7:0]     dpos;     // |b - a|
        begin
            dpos   = (b >= a) ? (b - a) : (a - b);
            lerp_m = dpos * t;                      // 最大 255*1023 = 260865
        end
    endfunction

    // 第 2 级：a + floor(m/MUL) 或 a - ceil(m/MUL)
    function [7:0] lerp_fin;
        input [7:0]   a;
        input         ge;       // b >= a
        input [F+9:0] m;
        reg [F+9:0]   lo;       // floor(m / MUL)
        reg [F+9:0]   hi;       // ceil (m / MUL)
        begin
            lo       = m >> F;
            hi       = (m + (MUL - 1)) >> F;
            lerp_fin = ge ? (a + lo) : (a - hi);
        end
    endfunction

    wire [23:0] h0_c = {lerp_fin(ha0[23:16], hge0[2], hm0r),
                        lerp_fin(ha0[15:8],  hge0[1], hm0g),
                        lerp_fin(ha0[7:0],   hge0[0], hm0b)};
    wire [23:0] h1_c = {lerp_fin(ha1[23:16], hge1[2], hm1r),
                        lerp_fin(ha1[15:8],  hge1[1], hm1g),
                        lerp_fin(ha1[7:0],   hge1[0], hm1b)};
    wire [23:0] dst_c = {lerp_fin(h0[23:16], vge[2], vmr),
                         lerp_fin(h0[15:8],  vge[1], vmg),
                         lerp_fin(h0[7:0],   vge[0], vmb)};

    // =======================================================================
    // 行缓存读地址译码（组合）
    //   EM_P0 发 A0=(sy0,sx0) -> 下一拍 RAM 输出有效 -> EM_P1 取 p00
    //   EM_P1 发 A1=(sy0,sx1) -> EM_P2 取 p01
    //   EM_P2 发 A2=(sy1,sx0) -> EM_P3 取 p10
    //   EM_P3 发 A3=(sy1,sx1) -> EM_P4 取 p11
    // =======================================================================
    always @(*) begin
        case (em_state)
            EM_P0:   rd_addr_c = rd_a00_r;
            EM_P1:   rd_addr_c = rd_a01_r;
            EM_P2:   rd_addr_c = rd_a10_r;
            EM_P3:   rd_addr_c = rd_a11_r;
            EM_AR:   rd_addr_c = aa_addr_r;
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

    // 时序（100 MHz）：fifo_mem 是 256 深的分布式 RAM，组合读出后再扇出到 8 块
    // BRAM 的 dia，路径过长。写端口整体打一拍（we/地址/数据同拍），
    // 读侧的行就绪判断相应改用晚一拍的 wr_row_done。
    reg        lb_we_q;
    reg [2:0]  lb_sel_q;
    reg [9:0]  lb_off_q;
    reg [23:0] lb_wdata_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lb_we_q    <= 1'b0;
            lb_sel_q   <= 3'd0;
            lb_off_q   <= 10'd0;
            lb_wdata_q <= 24'd0;
        end else begin
            lb_we_q    <= fifo_rd;
            lb_sel_q   <= wr_sel;
            lb_off_q   <= wr_off;
            lb_wdata_q <= fifo_rdata;
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_lbuf
            lbuf_1024x24 u_lbuf (
                .clk   (clk),
                .we    (lb_we_q && (lb_sel_q == gi)),
                .waddr (lb_off_q),
                .wdata (lb_wdata_q),
                .raddr (rd_addr_c[9:0]),
                .rdata (lb_o[gi])
            );
        end
    endgenerate

    // 8 选 1（约 100 个 LUT）。EM_P1..EM_P4 的 p00/p01/p10/p11 <= rd_data 不变。
    wire [23:0] rd_data = lb_o[rd_sel_d];

    // =======================================================================
    // 抗锯齿滤波流水（只在 EM_AR 里有数据流过）
    //   EM_AR 第 c 拍发窗口第 c 个地址（c = 0..15），第 c+1 拍 rd_data 有效：
    //   级 1：按列存 aa_px0..3，一行 4 列到齐 -> s1_v
    //   级 2：水平 [1 2 1]：ha = c0+2c1+c2（给 sx0），hb = c1+2c2+c3（给 sx1）
    //   级 3：垂直 [1 2 1] 累加：窗口行 0..3 对上抽头行（sy0）权重 1,2,1,0，
    //         对下抽头行（sy1）权重 0,1,2,1
    //   最后一行第 3 列在 c=16 到，c=17 过级 2，c=18 过级 3，EM_AQ 取结果。
    // =======================================================================
    wire       aa_cap_v   = (em_state == EM_AR) && (aa_cnt != 5'd0) && (aa_cnt <= 5'd16);
    wire [3:0] aa_cap_idx = aa_cnt[3:0] - 4'd1;      // cnt=16 -> 15

    reg [23:0] aa_px0, aa_px1, aa_px2, aa_px3;
    reg        aa_s1_v, aa_s2_v;
    reg [1:0]  aa_s1_row, aa_s2_row;
    reg [29:0] aa_ha, aa_hb;                          // 3 通道 x 10 bit
    reg [35:0] aa_a0a, aa_a0b, aa_a1a, aa_a1b;        // 3 通道 x 12 bit

    function [9:0] aa_tap3;                           // a + 2b + c
        input [7:0] a, b, c;
        aa_tap3 = {2'd0, a} + {1'b0, b, 1'b0} + {2'd0, c};
    endfunction

    function [29:0] aa_h3;
        input [23:0] a, b, c;
        aa_h3 = {aa_tap3(a[23:16], b[23:16], c[23:16]),
                 aa_tap3(a[15:8],  b[15:8],  c[15:8]),
                 aa_tap3(a[7:0],   b[7:0],   c[7:0])};
    endfunction

    // acc += h * w，w = 0/1/2
    function [35:0] aa_acc;
        input [35:0] acc;
        input [29:0] h;
        input [1:0]  w;
        reg   [11:0] t2, t1, t0;
        begin
            t2 = (w == 2'd2) ? {1'b0, h[29:20], 1'b0} : (w == 2'd1) ? {2'd0, h[29:20]} : 12'd0;
            t1 = (w == 2'd2) ? {1'b0, h[19:10], 1'b0} : (w == 2'd1) ? {2'd0, h[19:10]} : 12'd0;
            t0 = (w == 2'd2) ? {1'b0, h[9:0],   1'b0} : (w == 2'd1) ? {2'd0, h[9:0]}   : 12'd0;
            aa_acc = {acc[35:24] + t2, acc[23:12] + t1, acc[11:0] + t0};
        end
    endfunction

    // 12 bit 累加值 /16 四舍五入：最大 (4080+8)>>4 = 255
    function [23:0] aa_q;
        input [35:0] a;
        reg   [12:0] r, g, b;
        begin
            r = {1'b0, a[35:24]} + 13'd8;
            g = {1'b0, a[23:12]} + 13'd8;
            b = {1'b0, a[11:0]}  + 13'd8;
            aa_q = {r[11:4], g[11:4], b[11:4]};
        end
    endfunction

    wire [1:0] aa_w_top = (aa_s2_row == 2'd1) ? 2'd2 : (aa_s2_row == 2'd3) ? 2'd0 : 2'd1;
    wire [1:0] aa_w_bot = (aa_s2_row == 2'd2) ? 2'd2 : (aa_s2_row == 2'd0) ? 2'd0 : 2'd1;

    always @(posedge clk) begin
        if (aa_cap_v) begin
            case (aa_cap_idx[1:0])
                2'd0:    aa_px0 <= rd_data;
                2'd1:    aa_px1 <= rd_data;
                2'd2:    aa_px2 <= rd_data;
                default: aa_px3 <= rd_data;
            endcase
        end
        aa_s1_v   <= aa_cap_v && (aa_cap_idx[1:0] == 2'd3);
        aa_s1_row <= aa_cap_idx[3:2];
        aa_s2_v   <= aa_s1_v;
        aa_s2_row <= aa_s1_row;
        if (aa_s1_v) begin
            aa_ha <= aa_h3(aa_px0, aa_px1, aa_px2);
            aa_hb <= aa_h3(aa_px1, aa_px2, aa_px3);
        end
        if (em_state == EM_AS) begin
            aa_a0a <= 36'd0; aa_a0b <= 36'd0; aa_a1a <= 36'd0; aa_a1b <= 36'd0;
        end else if (aa_s2_v) begin
            aa_a0a <= aa_acc(aa_a0a, aa_ha, aa_w_top);
            aa_a0b <= aa_acc(aa_a0b, aa_hb, aa_w_top);
            aa_a1a <= aa_acc(aa_a1a, aa_ha, aa_w_bot);
            aa_a1b <= aa_acc(aa_a1b, aa_hb, aa_w_bot);
        end
    end

    // =======================================================================
    // 主时序块
    // =======================================================================
    // 本拍是否输出了一个像素（组合临时量，只在本 always 块内用阻塞赋值）
    reg em_advance_px;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_state <= DIV_IDLE; div_rem <= 0; div_quot <= 0;
            div_dividend <= 0; div_divisor <= 0; div_cnt <= 0; div_phase <= DIV_STEP;
            div_post <= 0; oth_raw_r <= 0; oth_size_r <= 0; oth_off_r <= 0;
            step_x <= 0; step_y <= 0; rem_x <= 0; rem_y <= 0;
            fit_w <= 1'b1; scale_num <= 0; scale_den <= DST_WIDTH; aa_en <= 1'b0;
            img_x0 <= 0; img_x1 <= DST_WIDTH; img_y0 <= 0; img_y1 <= DST_HEIGHT;
            img_width <= 0; img_height <= 0; scale_x100 <= 0;

            cfg_w <= 0; cfg_h <= 0; cfg_latched <= 1'b0; cfg_started <= 1'b0;

            fifo_wp <= 0; fifo_rp <= 0; fifo_cnt <= 0;
            src_overflow_count <= 8'd0;

            wr_row <= 0; wr_row_done <= 0; wr_col <= 0; y0_cur <= 0;

            em_state <= EM_ROW_INIT; out_y <= 0; out_x <= 0;
            fix_x <= 0; fix_y <= 0; remacc_x <= 0; remacc_y <= 0;
            sy0 <= 0; sy1 <= 0; fy <= 0; sym <= 0; sy3 <= 0;
            aa_cnt <= 0; aa_addr_r <= 0;
            aa_cx0 <= 0; aa_cx1 <= 0; aa_cx2 <= 0; aa_cx3 <= 0;
            p00 <= 0; p01 <= 0; p10 <= 0; p11 <= 0; h0 <= 0; h1 <= 0;
            hm0r <= 0; hm0g <= 0; hm0b <= 0; hm1r <= 0; hm1g <= 0; hm1b <= 0;
            hge0 <= 0; hge1 <= 0; ha0 <= 0; ha1 <= 0;
            vmr <= 0; vmg <= 0; vmb <= 0; vge <= 0;
            px_count <= 0;
            black_div <= 4'd0;

            dst_data <= 0; dst_valid <= 1'b0; dst_done <= 1'b0;
            error_code <= 2'd0;
        end else begin
            dst_valid <= 1'b0;
            em_advance_px = 1'b0;

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
            wr_row_done <= wr_row;
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
                aa_en <= 1'b0;
                wr_row <= 0; wr_row_done <= 0; wr_col <= 0; y0_cur <= 0;
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
                // 决定哪条边贴边，然后启动步长除法 (N << F) / D
                fit_w        <= fit_w_c;
                scale_num    <= fit_w_c ? src_width : src_height;
                scale_den    <= fit_w_c ? DST_WIDTH : DST_HEIGHT;
                div_phase    <= DIV_STEP;
                div_dividend <= ({11'd0, (fit_w_c ? src_width : src_height)} << F);
                div_divisor  <= fit_w_c ? DST_WIDTH : DST_HEIGHT;
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
                    if (div_ge)
                        div_rem  <= div_cand - {16'd0, div_divisor};
                    else
                        div_rem  <= div_cand;
                    div_quot     <= {div_quot[DIVW-2:0], div_ge};
                    div_dividend <= {div_dividend[DIVW-2:0], 1'b0};
                    div_cnt <= div_cnt - 6'd1;
                    if (div_cnt == 6'd1) div_state <= DIV_DONE;
                end
                DIV_DONE: begin
                    div_rem   <= 0;
                    div_quot  <= 0;
                    div_cnt   <= DIVW[5:0];
                    case (div_phase)
                        DIV_STEP: begin
                            // 两轴同一个步长 -> 等比例
                            step_x <= div_quot[FIXW-1:0];
                            step_y <= div_quot[FIXW-1:0];
                            rem_x  <= div_rem[15:0];
                            rem_y  <= div_rem[15:0];
                            // 缩小比 N/D >= 1.5  <=>  2N >= 3D
                            aa_en  <= AA_ENABLE &&
                                      ({1'b0, scale_num, 1'b0} >= ({2'd0, scale_den} + {1'b0, scale_den, 1'b0}));
                            // 接着算另一条边的输出尺寸
                            div_phase    <= DIV_OTHER;
                            div_dividend <= other_dividend[DIVW-1:0];
                            div_divisor  <= scale_num;
                            div_state    <= DIV_RUN;
                        end
                        DIV_OTHER: begin
                            oth_raw_r <= other_raw;
                            div_post  <= 2'd0;
                            div_state <= DIV_POST;
                        end
                        default: begin
                            scale_x100  <= (div_quot[DIVW-1:16] != 0) ? 16'hFFFF : div_quot[15:0];
                            cfg_latched <= 1'b1;
                            // 第 0 行在上黑边里就先吐黑像素，否则直接进图像行
                            em_state    <= (img_y0 == 16'd0) ? EM_ROW_INIT : EM_BLACK;
                            div_state   <= DIV_IDLE;
                        end
                    endcase
                end
                DIV_POST: begin
                    div_post <= div_post + 2'd1;
                    case (div_post)
                        2'd0: oth_size_r <= other_size;
                        2'd1: oth_off_r  <= other_off;
                        default: begin
                            if (fit_w) begin
                                img_width  <= DST_WIDTH;
                                img_height <= oth_size_r;
                                img_x0 <= 16'd0;
                                img_x1 <= DST_WIDTH;
                                img_y0 <= oth_off_r;
                                img_y1 <= oth_off_r + oth_size_r;
                            end else begin
                                img_width  <= oth_size_r;
                                img_height <= DST_HEIGHT;
                                img_x0 <= oth_off_r;
                                img_x1 <= oth_off_r + oth_size_r;
                                img_y0 <= 16'd0;
                                img_y1 <= DST_HEIGHT;
                            end
                            // 最后算缩放比 x100（只给 OSD 显示用）
                            div_phase    <= DIV_SCALE;
                            div_dividend <= scale_dividend[DIVW-1:0];
                            div_divisor  <= scale_num;
                            div_state    <= DIV_RUN;
                        end
                    endcase
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
                        sym <= (sy0_c == 16'd0) ? 16'd0 : (sy0_c - 16'd1);
                        sy3 <= (sy0p2 >= cfg_h) ? (cfg_h - 16'd1) : sy0p2;
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
                            // 左黑边从第 0 列开始；宽贴边时 img_x0 = 0 直接进图像
                            em_state <= (img_x0 == 16'd0) ? em_img_px : EM_BLACK;
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
                        // 四个抽头地址都已发出，水平累加器可提前推进到下一像素
                        // （行尾在 EM_P6 被清零覆盖）；本像素的小数先锁存。
                        fx_r     <= fx_c;
                        fix_x    <= fix_x_new;
                        remacc_x <= remacc_x_new;
                        em_state <= EM_P5;
                    end
                    // ---- 抗锯齿路径：EM_AS -> EM_AR(19 拍) -> EM_AQ -> EM_P5 ----
                    EM_AS: begin
                        aa_cx0    <= aa_cx0_c[10:0];
                        aa_cx1    <= sx0_c[10:0];
                        aa_cx2    <= sx1_c[10:0];
                        aa_cx3    <= aa_cx3_c[10:0];
                        aa_addr_r <= {3'd0, sym[1:0], aa_cx0_c[10:0]};
                        aa_cnt    <= 5'd0;
                        em_state  <= EM_AR;
                    end
                    EM_AR: begin
                        aa_addr_r <= {3'd0, aa_row_slot, aa_col};
                        aa_cnt    <= aa_kn;
                        if (aa_cnt == 5'd18) em_state <= EM_AQ;
                    end
                    EM_AQ: begin
                        p00      <= aa_q(aa_a0a);
                        p01      <= aa_q(aa_a0b);
                        p10      <= aa_q(aa_a1a);
                        p11      <= aa_q(aa_a1b);
                        fx_r     <= fx_c;
                        fix_x    <= fix_x_new;
                        remacc_x <= remacc_x_new;
                        em_state <= EM_P5;
                    end
                    EM_P5: begin
                        hm0r <= lerp_m(p00[23:16], p01[23:16], fx_r);
                        hm0g <= lerp_m(p00[15:8],  p01[15:8],  fx_r);
                        hm0b <= lerp_m(p00[7:0],   p01[7:0],   fx_r);
                        hm1r <= lerp_m(p10[23:16], p11[23:16], fx_r);
                        hm1g <= lerp_m(p10[15:8],  p11[15:8],  fx_r);
                        hm1b <= lerp_m(p10[7:0],   p11[7:0],   fx_r);
                        hge0 <= {p01[23:16] >= p00[23:16], p01[15:8] >= p00[15:8], p01[7:0] >= p00[7:0]};
                        hge1 <= {p11[23:16] >= p10[23:16], p11[15:8] >= p10[15:8], p11[7:0] >= p10[7:0]};
                        ha0  <= p00;
                        ha1  <= p10;
                        em_state <= EM_P5B;
                    end
                    EM_P5B: begin
                        h0 <= h0_c;
                        h1 <= h1_c;
                        em_state <= EM_P6A;
                    end
                    EM_P6A: begin
                        vmr <= lerp_m(h0[23:16], h1[23:16], fy);
                        vmg <= lerp_m(h0[15:8],  h1[15:8],  fy);
                        vmb <= lerp_m(h0[7:0],   h1[7:0],   fy);
                        vge <= {h1[23:16] >= h0[23:16], h1[15:8] >= h0[15:8], h1[7:0] >= h0[7:0]};
                        em_state <= EM_P6;
                    end
                    EM_P6: begin
                        // 输出缓冲满则原地等待（h0/h1 已稳定，不会丢数据）
                        if (!out_stall) begin
                            dst_data  <= dst_c;
                            dst_valid <= 1'b1;
                            px_count  <= px_count + 32'd1;
                            em_advance_px = 1'b1;
                        end
                    end
                    // 黑边像素：不读行缓存、不推进 fix_x，BLACK_INTERVAL 拍 1 个
                    EM_BLACK: begin
                        if (black_div != 4'd0) begin
                            black_div <= black_div - 4'd1;
                        end else if (!out_stall) begin
                            black_div <= BLACK_INTERVAL - 4'd1;
                            dst_data  <= 24'h000000;
                            dst_valid <= 1'b1;
                            px_count  <= px_count + 32'd1;
                            em_advance_px = 1'b1;
                        end
                    end
                    EM_FINISH: begin
                        dst_done <= 1'b1;
                        if (px_count != DST_PIXELS) error_code[1] <= 1'b1;
                    end
                    default: em_state <= EM_ROW_INIT;
                endcase

                // -----------------------------------------------------------
                // 一个像素（图像或黑边）已输出：推进 out_x/out_y 与下一状态
                // （写在 case 之后，覆盖 case 内对 fix_x 的推进 -> 行尾清零优先）
                // -----------------------------------------------------------
                if (em_advance_px) begin
                    em_state <= em_next_px;
                    if (em_x_last) begin
                        // 本行结束：水平累加器清零
                        fix_x    <= 0;
                        remacc_x <= 0;
                        out_x    <= 16'd0;
                        out_y    <= out_y_nx;
                        if (row_is_img) begin
                            // 图像行结束才推进垂直累加器（黑边行不消耗源行）
                            fix_y    <= fix_y_new;
                            remacc_y <= remacc_y_new;
                            // 关键：y0_cur 取「**下一个**输出行」的起始源行
                            // fix_y_new>>F，而不是当前行的 sy0。
                            // 否则降采样步长为 2.25 时下一行一次跳过 3 行，
                            // 写侧被 wr_guard_ok 挡住 -> 死锁（已由
                            // tools/scaler_rtl_model.js 复现并验证修复）。
                            // 最后一个图像行之后不再需要任何源行，放开写侧。
                            y0_cur   <= row_img_last ? cfg_h : fix_y_new[FIXW-1:F];
                        end
                        if (em_y_last)
                            y0_cur <= cfg_h;
                    end else begin
                        out_x <= out_x_nx;
                    end
                end
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
