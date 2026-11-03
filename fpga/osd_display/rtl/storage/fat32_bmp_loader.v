`timescale 1ns/1ps

// Loads one FAT32 BMP through logical file sectors. The header pass is kept
// separate from the data pass so SDRAM buffer ownership is known before pixels
// from logical sector zero are emitted.
//
// 支持任意分辨率（供写侧双线性缩放器使用）三处改动：
//   1) 不再要求图片尺寸等于某个固定值。改为「范围 + 最小像素数」校验，
//      并把解析出的原始宽高从 src_width/src_height 输出给缩放器。
//   2) 支持 BMP 行填充（row padding）。每行字节数按 4 字节对齐，
//      行尾 0..3 个填充字节被跳过，不参与像素打包。
//      旧版因为 640*3=1920 恰好 4 字节对齐，完全没有这段逻辑。
//   3) 结束条件由「字节数是 3 的倍数」改为「已输出恰好 W*H 个像素」。
module fat32_bmp_loader #(
    // 允许的源分辨率范围：32x32 .. 1280x960。上限必须与 image_bilinear_scaler 的
    // MAX_SRC_* 一致。下限：小于 32 的图放大到 640x480 只剩色块，没有展示意义；
    // 上限：1080p 文件 6.2 MB，SPI 读一张要十几秒，演示时切图太慢。
    parameter [15:0] MIN_SRC_WIDTH  = 16'd32,
    parameter [15:0] MIN_SRC_HEIGHT = 16'd32,
    parameter [15:0] MAX_SRC_WIDTH  = 16'd1280,
    parameter [15:0] MAX_SRC_HEIGHT = 16'd960,
    // 最小源像素数（宽高下限之外的额外约束）。默认 1 = 不额外限制。
    // 小图（放大）时缩放器输出比源慢，write_fifo_afull 反压本模块：只在扇区之间
    // 的 ST_STREAM_PAUSE 等待，此时没有挂起的扇区读，adapter 的 SD 响应看门狗
    // 不计时；一帧输出固定约 28 ms，远小于 image_load_manager 的加载超时。
    // tests/tb_scaler_sizes.sv 覆盖 1x1、1x480、7x1080 等极端尺寸。
    // 以前取 32000 是按"缩放器必须跟得上 SPI 源流"估的，那个约束并不存在。
    parameter [31:0] MIN_SRC_PIXELS = 32'd1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        abort,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,
    input  wire [31:0] first_fat_lba,
    input  wire [31:0] first_data_lba,
    input  wire [7:0]  sectors_per_cluster,

    // 解析出的源图原始尺寸，供 image_bilinear_scaler 配置使用。
    // 直接由 header_width/header_height 这两个寄存器驱动，无毛刺。
    output wire [15:0] src_width,
    output wire [15:0] src_height,
    // 头校验通过（header_match 为真）后拉高，直到下一次 start 才清零。
    // 缩放器必须以它作为「可以开始配置」的依据 —— 只看 src_width != 0 会把
    // 校验失败时的垃圾头也当成有效配置。
    output reg         header_valid,

    output reg         busy,
    output reg         done,
    output reg         error,
    // 诊断用：当前状态码。只读，不改任何控制流。
    // 0=IDLE 1..4=头解析 5=ST_WRITE_WAIT(等 write_req_ack) 6=STREAM_START
    // 7=STREAM_REQUEST 8=STREAM_WAIT 9=STREAM_PAUSE 10=LOCAL_ERROR 11=ABORT_WAIT
    output wire [3:0]  dbg_state,
    output reg         write_req,
    input  wire        write_req_ack,
    input  wire        write_fifo_afull,
    output reg         bmp_data_wr_en,
    output reg [23:0]  bmp_data,

    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

localparam [3:0] ST_IDLE              = 4'd0;
localparam [3:0] ST_HEADER_START      = 4'd1;
localparam [3:0] ST_HEADER_REQUEST    = 4'd2;
localparam [3:0] ST_HEADER_WAIT       = 4'd3;
localparam [3:0] ST_HEADER_ABORT      = 4'd4;
localparam [3:0] ST_WRITE_WAIT        = 4'd5;
localparam [3:0] ST_STREAM_START      = 4'd6;
localparam [3:0] ST_STREAM_REQUEST    = 4'd7;
localparam [3:0] ST_STREAM_WAIT       = 4'd8;
localparam [3:0] ST_STREAM_PAUSE      = 4'd9;
localparam [3:0] ST_LOCAL_ERROR_ABORT = 4'd10;
localparam [3:0] ST_ABORT_WAIT        = 4'd11;

reg [3:0] state;
reg [31:0] file_first_cluster_latched;
reg [31:0] file_size_latched;
reg [31:0] first_fat_lba_latched;
reg [31:0] first_data_lba_latched;
reg [7:0]  sectors_per_cluster_latched;

reg         reader_start;
reg         reader_abort;
reg         reader_file_sec_read;
reg [31:0]  reader_file_sec_index;
wire        reader_busy;
wire        reader_done;
wire        reader_error;
wire        reader_file_sec_read_ack;
wire [7:0]  reader_file_sec_data;
wire        reader_file_sec_data_valid;
wire        reader_file_sec_read_end;
wire        reader_file_complete;
wire        reader_sd_sec_read;
wire [31:0] reader_sd_sec_read_addr;

reg [9:0]  header_byte_index;
reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] header_file_len;
reg [31:0] pixel_offset;
reg [31:0] dib_size;
reg [15:0] planes;
reg [31:0] header_width;
reg [31:0] header_height;
reg [15:0] bit_count;
reg [31:0] compression;
reg [31:0] stream_byte_count;
reg [31:0] next_stream_sector_index;
reg [1:0]  pixel_byte_index;
reg         abort_pending;

// ---- 行填充与像素计数（新增）----
reg [15:0] src_row_bytes;   // W*3：一行里真正的像素字节数
reg [15:0] src_stride;      // ((W*3)+3) & ~3：一行占用的总字节数（含行尾填充）
reg [15:0] row_byte_pos;    // 当前行内字节偏移，0..src_stride-1
reg [15:0] col_pixel;       // 当前行内已产出的像素数，0..W-1
reg [15:0] row_index;       // 已产出的源行数，0..H-1

wire header_match;
// 时序（100 MHz）：头字节先打一拍再按下标写字段，把状态译码从字段寄存器的
// ce 路径上拿掉；header_match（含 W*H 乘法）也打一拍。头校验在整个扇区
// 读完（read_end）时才看结果，最后一个字段（第 33 字节）早在约 480 拍前
// 就已写好，晚两拍没有影响。
reg        hdr_cap_valid;
reg [9:0]  hdr_cap_index;
reg [7:0]  hdr_cap_data;
reg        header_match_r;
wire stream_pixel_valid;
wire row_pixel_byte;
wire pixels_complete;
wire [31:0] reader_session_file_size;

assign src_width  = header_width[15:0];
assign src_height = header_height[15:0];

assign sd_sec_read      = reader_sd_sec_read;
assign sd_sec_read_addr = reader_sd_sec_read_addr;

// 尺寸校验：拒绝 0、超上限，以及高 16 位非零
// （负高度 = top-down BMP 会让 header_height[31] 为 1，在这里被一并拒绝）
wire src_w_ok = (header_width[31:16]  == 16'd0) &&
                (header_width[15:0]   >= MIN_SRC_WIDTH) &&
                (header_width[15:0]   <= MAX_SRC_WIDTH);
wire src_h_ok = (header_height[31:16] == 16'd0) &&
                (header_height[15:0]  >= MIN_SRC_HEIGHT) &&
                (header_height[15:0]  <= MAX_SRC_HEIGHT);
// 像素总数下限：保证写侧缩放器有足够时钟消费源码流（见文件头注释）
// 注意显式补零到 32 位再做乘法 —— 16bit*16bit 在 Verilog 里会按 16 位截断，
// 而 1920*1080 = 2073600 需要 21 位。
wire [31:0] src_pixels = {16'd0, header_width[15:0]} * {16'd0, header_height[15:0]};
// 乘法 + 比较打一拍（时序）；header_match 本身再打一拍成 header_match_r，
// 都只在 read_end（最后字段写入后约 480 拍）才被采用。
reg src_pixels_ok;
always @(posedge clk)
    src_pixels_ok <= (src_pixels >= MIN_SRC_PIXELS);

// BMP 24bpp 行距：每行字节数向上取整到 4 的倍数
//   src_row_bytes = W*3          （真正的像素字节数，W<=1920 -> <=5760，16 bit 足够）
//   src_stride    = (W*3+3)&~3   （含行尾 0..3 个填充字节）
// 640x480 时 stride==row_bytes==1920，所以旧版没有填充也不会出错。
wire [15:0] hdr_row_bytes = header_width[15:0] + (header_width[15:0] << 1);
wire [15:0] hdr_stride    = (hdr_row_bytes + 16'd3) & 16'hFFFC;

assign header_match = (header_0 == 8'h42) &&
                      (header_1 == 8'h4D) &&
                      src_w_ok &&
                      src_h_ok &&
                      src_pixels_ok &&
                      (dib_size >= 32'd40) &&          // BITMAPINFOHEADER 及以上（排除 OS/2 12 字节头）
                      (planes == 16'd1) &&
                      (bit_count == 16'd24) &&
                      (compression == 32'd0) &&
                      (header_file_len != 32'd0) &&
                      (pixel_offset >= 32'd54) &&      // 像素区不能与 14+40 字节头重叠
                      (pixel_offset < header_file_len) &&
                      (header_file_len <= file_size_latched);

// 字节处于像素数据区（从 pixel_offset 到文件尾）
assign stream_pixel_valid = (stream_byte_count >= pixel_offset) &&
                            (stream_byte_count < header_file_len);

// 该字节属于本行的真实像素部分（不是行尾填充），且还有行要产出
assign row_pixel_byte = stream_pixel_valid &&
                        (row_byte_pos < src_row_bytes) &&
                        (row_index < src_height) &&
                        !pixels_complete;

// 所有源像素都已产出
assign pixels_complete = (row_index >= src_height);
assign dbg_state       = state;

// The header probe must finish after logical sector zero and must not trigger
// a FAT lookup for the file's next cluster before the reader is aborted.
assign reader_session_file_size = (state == ST_HEADER_START) ?
                                ((file_size_latched > 32'd512) ? 32'd512 : file_size_latched) :
                                file_size_latched;

// MAX_FILE_CLUSTERS 默认 4096 对 1920x1080(6.2MB) 这类大文件不够：
// 卡上簇 <= 1KB 时 4096 簇读不完整个文件，会中途报错（表现为该图永远加载不出来）。
// 上限只是 FAT 链的安全网，真正的终点由 file_size 决定，放宽到 0xFFFF 无副作用。
fat32_file_sector_reader #(
    .MAX_FILE_CLUSTERS (16'hFFFF)
) u_file_sector_reader (
    .clk                    (clk),
    .rst                    (rst),
    .start                  (reader_start),
    .abort                  (reader_abort),
    .file_first_cluster     (file_first_cluster_latched),
    .file_size              (reader_session_file_size),
    .first_fat_lba          (first_fat_lba_latched),
    .first_data_lba         (first_data_lba_latched),
    .sectors_per_cluster    (sectors_per_cluster_latched),
    .busy                   (reader_busy),
    .done                   (reader_done),
    .error                  (reader_error),
    .file_sec_read          (reader_file_sec_read),
    .file_sec_index         (reader_file_sec_index),
    .file_sec_read_ack      (reader_file_sec_read_ack),
    .file_sec_data          (reader_file_sec_data),
    .file_sec_data_valid    (reader_file_sec_data_valid),
    .file_sec_read_end      (reader_file_sec_read_end),
    .file_complete          (reader_file_complete),
    .sd_sec_read            (reader_sd_sec_read),
    .sd_sec_read_addr       (reader_sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state                         <= ST_IDLE;
        busy                          <= 1'b0;
        done                          <= 1'b0;
        error                         <= 1'b0;
        write_req                     <= 1'b0;
        bmp_data_wr_en                <= 1'b0;
        bmp_data                      <= 24'd0;
        file_first_cluster_latched    <= 32'd0;
        file_size_latched             <= 32'd0;
        first_fat_lba_latched         <= 32'd0;
        first_data_lba_latched        <= 32'd0;
        sectors_per_cluster_latched   <= 8'd0;
        reader_start                  <= 1'b0;
        reader_abort                  <= 1'b0;
        reader_file_sec_read          <= 1'b0;
        reader_file_sec_index         <= 32'd0;
        header_byte_index             <= 10'd0;
        header_0                      <= 8'd0;
        header_1                      <= 8'd0;
        header_file_len               <= 32'd0;
        pixel_offset                  <= 32'd54;
        dib_size                      <= 32'd0;
        planes                        <= 16'd0;
        header_width                  <= 32'd0;
        header_height                 <= 32'd0;
        bit_count                     <= 16'd0;
        compression                   <= 32'd0;
        stream_byte_count             <= 32'd0;
        next_stream_sector_index      <= 32'd0;
        pixel_byte_index              <= 2'd0;
        abort_pending                 <= 1'b0;
        src_row_bytes                 <= 16'd0;
        src_stride                    <= 16'd0;
        row_byte_pos                  <= 16'd0;
        col_pixel                     <= 16'd0;
        row_index                     <= 16'd0;
        header_valid                  <= 1'b0;
        hdr_cap_valid                 <= 1'b0;
        hdr_cap_index                 <= 10'd0;
        hdr_cap_data                  <= 8'd0;
        header_match_r                <= 1'b0;
    end else begin
        done                 <= 1'b0;
        error                <= 1'b0;
        reader_start         <= 1'b0;
        reader_abort         <= 1'b0;
        reader_file_sec_read <= 1'b0;
        bmp_data_wr_en       <= 1'b0;
        hdr_cap_valid        <= 1'b0;
        header_match_r       <= header_match;

        if (hdr_cap_valid) begin
            case (hdr_cap_index)
                10'd0:  header_0 <= hdr_cap_data;
                10'd1:  header_1 <= hdr_cap_data;
                10'd2:  header_file_len[7:0] <= hdr_cap_data;
                10'd3:  header_file_len[15:8] <= hdr_cap_data;
                10'd4:  header_file_len[23:16] <= hdr_cap_data;
                10'd5:  header_file_len[31:24] <= hdr_cap_data;
                10'd10: pixel_offset[7:0] <= hdr_cap_data;
                10'd11: pixel_offset[15:8] <= hdr_cap_data;
                10'd12: pixel_offset[23:16] <= hdr_cap_data;
                10'd13: pixel_offset[31:24] <= hdr_cap_data;
                10'd14: dib_size[7:0] <= hdr_cap_data;
                10'd15: dib_size[15:8] <= hdr_cap_data;
                10'd16: dib_size[23:16] <= hdr_cap_data;
                10'd17: dib_size[31:24] <= hdr_cap_data;
                10'd18: header_width[7:0] <= hdr_cap_data;
                10'd19: header_width[15:8] <= hdr_cap_data;
                10'd20: header_width[23:16] <= hdr_cap_data;
                10'd21: header_width[31:24] <= hdr_cap_data;
                10'd22: header_height[7:0] <= hdr_cap_data;
                10'd23: header_height[15:8] <= hdr_cap_data;
                10'd24: header_height[23:16] <= hdr_cap_data;
                10'd25: header_height[31:24] <= hdr_cap_data;
                10'd26: planes[7:0] <= hdr_cap_data;
                10'd27: planes[15:8] <= hdr_cap_data;
                10'd28: bit_count[7:0] <= hdr_cap_data;
                10'd29: bit_count[15:8] <= hdr_cap_data;
                10'd30: compression[7:0] <= hdr_cap_data;
                10'd31: compression[15:8] <= hdr_cap_data;
                10'd32: compression[23:16] <= hdr_cap_data;
                10'd33: compression[31:24] <= hdr_cap_data;
                default: ;
            endcase
        end

        if ((abort) && (state != ST_IDLE))
            abort_pending <= 1'b1;

        if ((state != ST_IDLE) && reader_error) begin
            state             <= ST_IDLE;
            busy              <= 1'b0;
            error             <= 1'b1;
            write_req         <= 1'b0;
            abort_pending     <= 1'b0;
        end else if ((state != ST_IDLE) &&
                     (state != ST_ABORT_WAIT) &&
                     (state != ST_LOCAL_ERROR_ABORT) &&
                     (abort_pending || abort)) begin
            write_req <= 1'b0;
            if (!reader_sd_sec_read) begin
                reader_abort <= 1'b1;
                state        <= ST_ABORT_WAIT;
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    busy      <= 1'b0;
                    write_req <= 1'b0;
                    abort_pending <= 1'b0;

                    if (start) begin
                        busy                        <= 1'b1;
                        file_first_cluster_latched <= file_first_cluster;
                        file_size_latched          <= file_size;
                        first_fat_lba_latched      <= first_fat_lba;
                        first_data_lba_latched     <= first_data_lba;
                        sectors_per_cluster_latched <= sectors_per_cluster;
                        header_byte_index          <= 10'd0;
                        header_0                   <= 8'd0;
                        header_1                   <= 8'd0;
                        header_file_len            <= 32'd0;
                        pixel_offset               <= 32'd54;
                        dib_size                   <= 32'd0;
                        planes                     <= 16'd0;
                        header_width               <= 32'd0;
                        header_height              <= 32'd0;
                        bit_count                  <= 16'd0;
                        compression                <= 32'd0;
                        stream_byte_count          <= 32'd0;
                        next_stream_sector_index   <= 32'd0;
                        pixel_byte_index           <= 2'd0;
                        row_byte_pos               <= 16'd0;
                        col_pixel                  <= 16'd0;
                        row_index                  <= 16'd0;
                        header_valid               <= 1'b0;
                        reader_start               <= 1'b1;
                        state                      <= ST_HEADER_START;
                    end
                end

                ST_HEADER_START: begin
                    if (reader_busy)
                        state <= ST_HEADER_REQUEST;
                end

                ST_HEADER_REQUEST: begin
                    reader_file_sec_index <= 32'd0;
                    if (reader_file_sec_read_ack) begin
                        state <= ST_HEADER_WAIT;
                    end else begin
                        reader_file_sec_read <= 1'b1;
                    end
                end

                ST_HEADER_WAIT: begin
                    if (reader_file_sec_data_valid) begin
                        hdr_cap_valid     <= 1'b1;
                        hdr_cap_index     <= header_byte_index;
                        hdr_cap_data      <= reader_file_sec_data;
                        header_byte_index <= header_byte_index + 10'd1;
                    end

                    if (reader_file_sec_read_end) begin
                        reader_abort <= 1'b1;
                        if (header_match_r) begin
                            header_valid <= 1'b1;
                            state <= ST_HEADER_ABORT;
                        end else begin
                            state <= ST_LOCAL_ERROR_ABORT;
                        end
                    end
                end

                ST_HEADER_ABORT: begin
                    if (!reader_busy) begin
                        write_req <= 1'b1;
                        state     <= ST_WRITE_WAIT;
                    end
                end

                ST_WRITE_WAIT: begin
                    if (write_req_ack) begin
                        write_req      <= 1'b0;
                        reader_start   <= 1'b1;
                        stream_byte_count <= 32'd0;
                        next_stream_sector_index <= 32'd0;
                        pixel_byte_index <= 2'd0;
                        // 头已解析完毕，此处锁存行距并复位行/列计数器
                        src_row_bytes <= hdr_row_bytes;
                        src_stride    <= hdr_stride;
                        row_byte_pos  <= 16'd0;
                        col_pixel     <= 16'd0;
                        row_index     <= 16'd0;
                        state          <= ST_STREAM_START;
                    end
                end

                ST_STREAM_START: begin
                    if (reader_busy)
                        state <= ST_STREAM_REQUEST;
                end

                ST_STREAM_REQUEST: begin
                    reader_file_sec_index <= next_stream_sector_index;
                    if (reader_file_sec_read_ack) begin
                        state <= ST_STREAM_WAIT;
                    end else if (!write_fifo_afull) begin
                        reader_file_sec_read <= 1'b1;
                    end
                end

                ST_STREAM_WAIT: begin
                    if (reader_file_sec_data_valid) begin
                        // 只把「本行的真实像素字节」打包成 24bit 像素；
                        // 行尾填充字节被跳过，不参与打包也不推进 pixel_byte_index。
                        // 因为 src_row_bytes = W*3 是 3 的倍数，pixel_byte_index
                        // 在每行开头必然回到 0，行间不会错位。
                        if (row_pixel_byte) begin
                            case (pixel_byte_index)
                                2'd0: bmp_data[7:0]  <= reader_file_sec_data;
                                2'd1: bmp_data[15:8] <= reader_file_sec_data;
                                2'd2: begin
                                    bmp_data[23:16] <= reader_file_sec_data;
                                    bmp_data_wr_en  <= 1'b1;
                                end
                                default: ;
                            endcase
                            pixel_byte_index <= (pixel_byte_index == 2'd2) ?
                                                2'd0 : (pixel_byte_index + 2'd1);
                            // 每凑满一个像素推进列计数；列满则进入下一行
                            if (pixel_byte_index == 2'd2) begin
                                if (col_pixel == (src_width - 16'd1)) begin
                                    col_pixel <= 16'd0;
                                    row_index <= row_index + 16'd1;
                                end else begin
                                    col_pixel <= col_pixel + 16'd1;
                                end
                            end
                        end

                        // 行内字节位置推进：走满 stride 后回绕，从而跳过行尾填充
                        if (stream_pixel_valid) begin
                            if (row_byte_pos == (src_stride - 16'd1))
                                row_byte_pos <= 16'd0;
                            else
                                row_byte_pos <= row_byte_pos + 16'd1;
                        end

                        stream_byte_count <= stream_byte_count + 32'd1;
                    end

                    if (reader_file_sec_read_end) begin
                        if (reader_file_complete) begin
                            busy <= 1'b0;
                            // 结束条件改为「恰好产出了 W*H 个像素」。
                            // 文件截断/尾部多余数据/行距不匹配都会在这里被抓到。
                            if (pixels_complete) begin
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end else begin
                            next_stream_sector_index <= next_stream_sector_index + 32'd1;
                            if (write_fifo_afull)
                                state <= ST_STREAM_PAUSE;
                            else
                                state <= ST_STREAM_REQUEST;
                        end
                    end
                end

                ST_STREAM_PAUSE: begin
                    if (!write_fifo_afull)
                        state <= ST_STREAM_REQUEST;
                end

                ST_LOCAL_ERROR_ABORT: begin
                    if (!reader_busy) begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                ST_ABORT_WAIT: begin
                    if (!reader_busy) begin
                        busy          <= 1'b0;
                        abort_pending <= 1'b0;
                        state         <= ST_IDLE;
                    end
                end

                default: begin
                    state     <= ST_IDLE;
                    busy      <= 1'b0;
                    write_req <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
