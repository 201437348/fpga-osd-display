module image_storage_adapter #(
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR   = 32'd131071,
    parameter [3:0]  SCAN_TARGET_COUNT = 4'd8,
    parameter integer SD_CLK_FREQ_HZ = 100_000_000,
    parameter integer SD_RESPONSE_TIMEOUT_MS = 250,
    // 最小源像素数，透传给 fat32_bmp_loader。见该模块的注释：源码流速率受
    // SPI 限制（每像素约 96 拍），写侧缩放器每输出像素要 7 拍，所以
    // 源图必须有 W*H*96 >= 640*480*7，即 W*H >= 22400。这里默认 32000
    // （约 1.4 倍余量）。做成参数是为了让集成测试能用小图。
    parameter [31:0] MIN_SRC_PIXELS = 32'd32000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        scan_start,
    input  wire        load_start,
    input  wire        load_abort,
    input  wire        storage_reinit,
    input  wire [2:0]  target_image_index,

    output wire        storage_ready,
    output reg         scan_done,
    output reg [3:0]   scan_found_count,
    output reg         source_done_pulse,
    output reg         source_error_pulse,
    output reg         storage_fault_pulse,
    output reg [3:0]   state_code,
    // 缩放器输入 FIFO 因反压来不及而丢弃的源像素数（饱和计数，正常恒 0）。
    // 直接来自 u_image_bilinear_scaler.src_overflow_count，上板把它接到
    // 数码管/LED 就能一眼判断"是不是被反压丢了像素"。
    output wire [7:0]  scaler_overflow_count,

    // ---- 上板诊断（全部只读，不参与任何控制流）----
    // load_diag_state  : fat32_bmp_loader 状态码
    //                    0=IDLE 1..4=头解析 5=ST_WRITE_WAIT(在等 write_req_ack)
    //                    6=STREAM_START 7=STREAM_REQUEST 8=STREAM_WAIT
    //                    9=STREAM_PAUSE 10=LOCAL_ERROR 11=ABORT_WAIT
    // load_diag_sector : 图像通道已读完的扇区数低 4 位（看它在不在跳）
    // load_diag_flags  : {write_req_ack, 保留, 缩放器 out_stall(= write_buf afull),
    //                     缩放器输入 FIFO afull}
    output wire [3:0]  load_diag_state,
    output wire [3:0]  load_diag_sector,
    output wire [3:0]  load_diag_flags,
    // 每读完一个图像扇区给一个脉冲：给 manager 当"进度喂狗"，
    // 这样 1920x1080 这种 12151 扇区的大图不会因为总时间超 10s 被掐掉
    output wire        load_progress_pulse,

    output wire        write_req,
    input  wire        write_req_ack,
    input  wire        write_fifo_afull,
    output wire        write_en,
    output wire [31:0] write_data,

    output wire        audio_fifo_wr_en,
    output wire [31:0] audio_fifo_wr_data,
    input  wire [9:0]  audio_fifo_wrusedw,
    input  wire        audio_fifo_full,
    output wire        audio_fifo_rst,

    output wire        SD_nCS,
    output wire        SD_DCLK,
    output wire        SD_MOSI,
    input  wire        SD_MISO
);

localparam [2:0] ST_IDLE          = 3'd0;
localparam [2:0] ST_SCAN_START    = 3'd1;
localparam [2:0] ST_SCAN_ACTIVE   = 3'd2;
localparam [2:0] ST_SCAN_COMPLETE = 3'd3;
localparam [2:0] ST_LOAD_START    = 3'd4;
localparam [2:0] ST_LOAD_ACTIVE   = 3'd5;
localparam [2:0] ST_LOAD_ABORT    = 3'd6;

reg [2:0] state;
reg       directory_start;
reg       loader_start;
reg       loader_abort;
reg       audio_start;
reg       audio_abort;
reg       audio_fifo_clear;
reg       scan_error_seen;
reg       storage_fault_latched;
reg [24:0] sd_response_watchdog;

// 图片槽位：最多这类 BMP 张数（目录扫描用同一个上限）。
// 原来是 4 个写死的 image_cluster0..3 / image_size0..3，
// 卡里第 5 张（后加的 1920x1080）连扫描都进不来 —— 现在改成 8 槽数组。
localparam integer IMG_SLOT_COUNT = 8;

reg [31:0] image_cluster [0:IMG_SLOT_COUNT-1];
reg [31:0] image_size    [0:IMG_SLOT_COUNT-1];
integer    img_i;
reg [31:0] volume_first_fat_lba;
reg [31:0] volume_first_data_lba;
reg [7:0]  volume_sectors_per_cluster;
reg [31:0] bgm_first_cluster;
reg [31:0] bgm_file_size;

wire        directory_busy;
wire        directory_done;
wire        directory_error;
wire        directory_sd_sec_read;
wire [31:0] directory_sd_sec_read_addr;
wire        directory_file_found;
wire [3:0]  directory_file_count;
wire [87:0] directory_file_name;
wire [31:0] directory_file_first_cluster;
wire [31:0] directory_file_size;
wire [31:0] directory_volume_first_fat_lba;
wire [31:0] directory_volume_first_data_lba;
wire [7:0]  directory_volume_sectors_per_cluster;
wire        directory_bgm_found;
wire [31:0] directory_bgm_first_cluster;
wire [31:0] directory_bgm_size;

wire        loader_busy;
wire        loader_done;
wire        loader_error;
wire        loader_write_req;
wire        loader_bmp_data_wr_en;
wire [23:0] loader_bmp_data;
wire        loader_sd_sec_read;
wire [31:0] loader_sd_sec_read_addr;

wire        audio_loader_busy;
wire        audio_loader_error;
wire        audio_loader_sd_sec_read;
wire [31:0] audio_loader_sd_sec_read_addr;
wire        audio_frame_wr_en;
wire [31:0] audio_frame_wr_data;

wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid;
wire        sd_sec_read_end;
wire        sd_init_done;
wire        core_rst;
wire        scan_owner_active;
wire        load_owner_active;
wire        scan_grant;
wire        audio_grant;
wire        image_grant;

// ---- 写侧双线性缩放器接口（1920x1080 以内的任意 24bit BI_RGB BMP -> 640x480）----
// 数据通路变成： fat32_bmp_loader -> image_bilinear_scaler -> write_buf -> SDRAM
// loader 的 write_fifo_afull 改接缩放器的输入缓冲，缩放器的输出反压来自
// write_buf 的 afull。write_en/write_data 的下游语义完全不变。
wire [23:0] scaler_dst_data;
wire        scaler_dst_valid;
wire        scaler_dst_done;
wire [1:0]  scaler_error_code;
wire        scaler_src_afull;
wire [15:0] loader_src_width;
wire [15:0] loader_src_height;
wire        loader_header_valid;

localparam [24:0] SD_RESPONSE_TIMEOUT_CYCLES =
    (SD_CLK_FREQ_HZ / 1000) * SD_RESPONSE_TIMEOUT_MS;

reg write_req_ack_meta;
reg write_req_ack_sync;

reg [31:0] selected_file_cluster;
reg [31:0] selected_file_size;

assign storage_ready = sd_init_done;
assign core_rst      = rst | storage_reinit;
assign write_req     = loader_write_req;
assign write_en      = scaler_dst_valid;
assign write_data    = {scaler_dst_data, 8'b0};
assign audio_fifo_wr_en = audio_frame_wr_en;
assign audio_fifo_wr_data = audio_frame_wr_data;
assign audio_fifo_rst = core_rst | audio_fifo_clear;

assign scan_owner_active = (state == ST_SCAN_START) ||
                           (state == ST_SCAN_ACTIVE) ||
                           (state == ST_SCAN_COMPLETE);
assign load_owner_active = (state == ST_LOAD_START) ||
                           (state == ST_LOAD_ACTIVE) ||
                           (state == ST_LOAD_ABORT);

always @* begin
    selected_file_cluster = image_cluster[target_image_index];
    selected_file_size    = image_size[target_image_index];
end

// write_req_ack is generated in ext_mem_clk; the loader consumes it in clk.
always @(posedge clk or posedge core_rst) begin
    if (core_rst) begin
        write_req_ack_meta <= 1'b0;
        write_req_ack_sync <= 1'b0;
    end else begin
        write_req_ack_meta <= write_req_ack;
        write_req_ack_sync <= write_req_ack_meta;
    end
end

always @(posedge clk or posedge core_rst) begin
    if (core_rst) begin
        state                      <= ST_IDLE;
        directory_start            <= 1'b0;
        loader_start               <= 1'b0;
        loader_abort               <= 1'b0;
        audio_start                <= 1'b0;
        audio_abort                <= 1'b0;
        audio_fifo_clear           <= 1'b0;
        scan_done                  <= 1'b0;
        scan_found_count           <= 4'd0;
        source_done_pulse          <= 1'b0;
        source_error_pulse         <= 1'b0;
        storage_fault_pulse        <= 1'b0;
        state_code                 <= 4'd0;
        scan_error_seen            <= 1'b0;
        storage_fault_latched      <= 1'b0;
        sd_response_watchdog       <= 25'd0;
        for (img_i = 0; img_i < IMG_SLOT_COUNT; img_i = img_i + 1) begin
            image_cluster[img_i] <= 32'd0;
            image_size[img_i]    <= 32'd0;
        end
        volume_first_fat_lba       <= 32'd0;
        volume_first_data_lba      <= 32'd0;
        volume_sectors_per_cluster <= 8'd0;
        bgm_first_cluster          <= 32'd0;
        bgm_file_size              <= 32'd0;
    end else begin
        directory_start    <= 1'b0;
        loader_start       <= 1'b0;
        loader_abort       <= 1'b0;
        audio_start        <= 1'b0;
        audio_abort        <= 1'b0;
        audio_fifo_clear   <= 1'b0;
        source_done_pulse  <= 1'b0;
        source_error_pulse <= 1'b0;
        storage_fault_pulse <= 1'b0;

        if (!sd_sec_read || sd_sec_read_data_valid || sd_sec_read_end) begin
            sd_response_watchdog <= 25'd0;
        end else if (!storage_fault_latched) begin
            if (sd_response_watchdog >= (SD_RESPONSE_TIMEOUT_CYCLES - 1'b1)) begin
                storage_fault_pulse   <= 1'b1;
                storage_fault_latched <= 1'b1;
            end else begin
                sd_response_watchdog <= sd_response_watchdog + 25'd1;
            end
        end

        if (!sd_init_done) begin
            audio_abort                <= 1'b1;
            audio_fifo_clear           <= 1'b1;
            state                      <= ST_IDLE;
            scan_done                  <= 1'b0;
            scan_found_count           <= 4'd0;
            scan_error_seen            <= 1'b0;
            state_code                 <= 4'd0;
            for (img_i = 0; img_i < IMG_SLOT_COUNT; img_i = img_i + 1) begin
                image_cluster[img_i] <= 32'd0;
                image_size[img_i]    <= 32'd0;
            end
            volume_first_fat_lba       <= 32'd0;
            volume_first_data_lba      <= 32'd0;
            volume_sectors_per_cluster <= 8'd0;
            bgm_first_cluster          <= 32'd0;
            bgm_file_size              <= 32'd0;
            storage_fault_latched      <= 1'b0;
            sd_response_watchdog       <= 25'd0;
        end else begin
            if (audio_loader_error)
                audio_fifo_clear <= 1'b1;

            if (scan_owner_active && directory_file_found &&
                (scan_found_count < SCAN_TARGET_COUNT)) begin
                image_cluster[scan_found_count[2:0]] <= directory_file_first_cluster;
                image_size[scan_found_count[2:0]]    <= directory_file_size;
                scan_found_count <= scan_found_count + 4'd1;
            end

            case (state)
                ST_IDLE: begin
                    state_code <= 4'd1;

                    if (scan_start) begin
                        scan_done                  <= 1'b0;
                        scan_found_count           <= 4'd0;
                        scan_error_seen            <= 1'b0;
                        for (img_i = 0; img_i < IMG_SLOT_COUNT; img_i = img_i + 1) begin
                            image_cluster[img_i] <= 32'd0;
                            image_size[img_i]    <= 32'd0;
                        end
                        volume_first_fat_lba       <= 32'd0;
                        volume_first_data_lba      <= 32'd0;
                        volume_sectors_per_cluster <= 8'd0;
                        bgm_first_cluster          <= 32'd0;
                        bgm_file_size              <= 32'd0;
                        audio_abort                <= 1'b1;
                        audio_fifo_clear           <= 1'b1;
                        directory_start            <= 1'b1;
                        state                      <= ST_SCAN_START;
                    end else if (load_start) begin
                        if ((target_image_index < scan_found_count) &&
                            (selected_file_cluster >= 32'd2) &&
                            (selected_file_size != 32'd0) &&
                            (volume_sectors_per_cluster != 8'd0)) begin
                            loader_start <= 1'b1;
                            state        <= ST_LOAD_START;
                        end else begin
                            source_error_pulse <= 1'b1;
                        end
                    end
                end

                ST_SCAN_START: begin
                    state_code <= 4'd2;
                    if (directory_error) begin
                        scan_error_seen <= 1'b1;
                        state           <= ST_SCAN_COMPLETE;
                    end else if (directory_done) begin
                        state <= ST_SCAN_COMPLETE;
                    end else if (directory_busy) begin
                        state <= ST_SCAN_ACTIVE;
                    end
                end

                ST_SCAN_ACTIVE: begin
                    state_code <= 4'd2;
                    if (directory_error)
                        scan_error_seen <= 1'b1;
                    if (directory_done || directory_error)
                        state <= ST_SCAN_COMPLETE;
                end

                ST_SCAN_COMPLETE: begin
                    state_code <= 4'd1;
                    if (!scan_error_seen) begin
                        volume_first_fat_lba       <= directory_volume_first_fat_lba;
                        volume_first_data_lba      <= directory_volume_first_data_lba;
                        volume_sectors_per_cluster <= directory_volume_sectors_per_cluster;
                        if (directory_bgm_found) begin
                            bgm_first_cluster <= directory_bgm_first_cluster;
                            bgm_file_size     <= directory_bgm_size;
                            audio_start       <= 1'b1;
                        end
                    end else begin
                        scan_found_count <= 4'd0;
                    end
                    audio_fifo_clear <= 1'b1;
                    scan_done <= 1'b1;
                    state     <= ST_IDLE;
                end

                ST_LOAD_START: begin
                    state_code <= 4'd3;
                    if (loader_error) begin
                        source_error_pulse <= 1'b1;
                        state              <= ST_IDLE;
                    end else if (loader_busy) begin
                        state <= ST_LOAD_ACTIVE;
                    end
                end

                ST_LOAD_ACTIVE: begin
                    state_code <= 4'd4;
                    if (load_abort) begin
                        loader_abort <= 1'b1;
                        state        <= ST_LOAD_ABORT;
                    end else if (loader_error) begin
                        source_error_pulse <= 1'b1;
                        state              <= ST_IDLE;
                    end else if (loader_done) begin
                        source_done_pulse <= 1'b1;
                        state             <= ST_IDLE;
                    end
                end

                ST_LOAD_ABORT: begin
                    state_code   <= 4'd4;
                    loader_abort <= 1'b1;
                    if (!loader_busy)
                        state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
end

fat32_directory_scan #(
    .MAX_FILES(SCAN_TARGET_COUNT)
) u_directory_scan (
    .clk                       (clk),
    .rst                       (core_rst),
    .start                     (directory_start),
    .busy                      (directory_busy),
    .done                      (directory_done),
    .error                     (directory_error),
    .sd_sec_read               (directory_sd_sec_read),
    .sd_sec_read_addr          (directory_sd_sec_read_addr),
    .sd_sec_read_data          (scan_grant ? sd_sec_read_data : 8'd0),
    .sd_sec_read_data_valid    (scan_grant ? sd_sec_read_data_valid : 1'b0),
    .sd_sec_read_end           (scan_grant ? sd_sec_read_end : 1'b0),
    .file_found                (directory_file_found),
    .file_count                (directory_file_count),
    .file_name                 (directory_file_name),
    .file_first_cluster        (directory_file_first_cluster),
    .file_size                 (directory_file_size),
    .volume_first_fat_lba      (directory_volume_first_fat_lba),
    .volume_first_data_lba     (directory_volume_first_data_lba),
    .volume_sectors_per_cluster(directory_volume_sectors_per_cluster),
    .bgm_found                 (directory_bgm_found),
    .bgm_first_cluster         (directory_bgm_first_cluster),
    .bgm_size                  (directory_bgm_size)
);

wire [3:0] loader_dbg_state;
fat32_bmp_loader #(
    .MIN_SRC_PIXELS(MIN_SRC_PIXELS)
) u_fat32_bmp_loader (
    .clk                    (clk),
    .rst                    (core_rst),
    .start                  (loader_start),
    .abort                  (loader_abort),
    .file_first_cluster     (selected_file_cluster),
    .file_size              (selected_file_size),
    .first_fat_lba          (volume_first_fat_lba),
    .first_data_lba         (volume_first_data_lba),
    .sectors_per_cluster    (volume_sectors_per_cluster),
    .src_width              (loader_src_width),
    .src_height             (loader_src_height),
    .header_valid           (loader_header_valid),
    .dbg_state              (loader_dbg_state),
    .busy                   (loader_busy),
    .done                   (loader_done),
    .error                  (loader_error),
    .write_req              (loader_write_req),
    .write_req_ack          (write_req_ack_sync),
    // 反压来自缩放器的输入缓冲：loader 一个 512 字节扇区 = 171 像素，
    // 缩放器 FIFO 深 256，能吸收一个完整扇区的突发。
    .write_fifo_afull       (scaler_src_afull),
    .bmp_data_wr_en         (loader_bmp_data_wr_en),
    .bmp_data               (loader_bmp_data),
    .sd_sec_read            (loader_sd_sec_read),
    .sd_sec_read_addr       (loader_sd_sec_read_addr),
    .sd_sec_read_data       (image_grant ? sd_sec_read_data : 8'd0),
    .sd_sec_read_data_valid (image_grant ? sd_sec_read_data_valid : 1'b0),
    .sd_sec_read_end        (image_grant ? sd_sec_read_end : 1'b0)
);

// ---------------------------------------------------------------------------
// 上板诊断（只读）。把"卡在哪"引到顶层数码管，避免再靠猜。
// 注意：这里不驱动任何控制逻辑，删掉本段不影响功能。
// ---------------------------------------------------------------------------


reg [3:0] load_diag_sector_r;

always @(posedge clk or posedge rst) begin
    if (rst)
        load_diag_sector_r <= 4'd0;
    else if (image_grant && sd_sec_read_end)
        load_diag_sector_r <= load_diag_sector_r + 4'd1;
end

assign load_diag_state  = loader_dbg_state;
assign load_diag_sector = load_diag_sector_r;
assign load_diag_flags  = {write_req_ack_sync, 1'b0, write_fifo_afull, scaler_src_afull};
assign load_progress_pulse = image_grant && sd_sec_read_end;

// ---------------------------------------------------------------------------
// 写侧双线性缩放器
//   把任意 (<=1920x1080) 24bit BI_RGB BMP 的源像素流实时缩成 640x480。
//   放在 loader 与 write_buf 之间，于是 SDRAM 里永远只存 640x480
//   （307200 字 = 14.7%，双缓冲后 29.4%），读回路 / 滑动动效 / OSD / HDMI
//   以及 frame_fifo_write 的 256 字突发、frame_slide_fifo_read 的
//   FRAME_PIXEL_COUNT=307200 契约全部不需要改动。
//
//   为什么不做在读侧：参考框图把缩放器放在读 FIFO 之后，但 1920x1080@32bit
//   = 2073600 字会占掉 SDRAM 的 98.87%（无法双缓冲），且每显示一帧要读
//   2073600 字，125MHz 下需要 ~123.4 Mword/s，逼近 SDRAM 上限。写侧缩放
//   把这些代价全部消掉。
// ---------------------------------------------------------------------------
image_bilinear_scaler #(
    .DST_WIDTH      (16'd640),
    .DST_HEIGHT     (16'd480),
    .MAX_SRC_WIDTH  (16'd1920),
    .MAX_SRC_HEIGHT (16'd1080),
    .FRAC_BITS      (4'd10),
    .IN_FIFO_DEPTH  (16'd256)
) u_image_bilinear_scaler (
    .clk            (clk),
    .rst            (core_rst),
    .start          (loader_start),
    .src_width      (loader_src_width),
    .src_height     (loader_src_height),
    .cfg_valid      (loader_header_valid),
    .src_data       (loader_bmp_data),
    .src_valid      (loader_bmp_data_wr_en),
    .src_afull      (scaler_src_afull),
    .src_overflow_count (scaler_overflow_count),
    .out_stall      (write_fifo_afull),
    .dst_data       (scaler_dst_data),
    .dst_valid      (scaler_dst_valid),
    .dst_done       (scaler_dst_done),
    .error_code     (scaler_error_code)
);
// scaler_dst_done / scaler_error_code 当前未参与控制流，留给 M6 的
// OSD 标注与 7 段数码管显示用（bit0 = 源尺寸非法，bit1 = 输出像素数不符）。

fat32_wav_loader u_fat32_wav_loader (
    .clk                    (clk),
    .rst                    (core_rst),
    .start                  (audio_start),
    .abort                  (audio_abort),
    .file_first_cluster     (bgm_first_cluster),
    .file_size              (bgm_file_size),
    .first_fat_lba          (volume_first_fat_lba),
    .first_data_lba         (volume_first_data_lba),
    .sectors_per_cluster    (volume_sectors_per_cluster),
    .fifo_wrusedw           (audio_fifo_wrusedw),
    .fifo_full              (audio_fifo_full),
    .audio_frame_wr_en      (audio_frame_wr_en),
    .audio_frame_wr_data    (audio_frame_wr_data),
    .busy                   (audio_loader_busy),
    .error                  (audio_loader_error),
    .sd_sec_read            (audio_loader_sd_sec_read),
    .sd_sec_read_addr       (audio_loader_sd_sec_read_addr),
    .sd_sec_read_data       (audio_grant ? sd_sec_read_data : 8'd0),
    .sd_sec_read_data_valid (audio_grant ? sd_sec_read_data_valid : 1'b0),
    .sd_sec_read_end        (audio_grant ? sd_sec_read_end : 1'b0)
);

sd_sector_arbiter u_sd_sector_arbiter (
    .clk              (clk),
    .rst              (core_rst),
    .scan_req         (directory_sd_sec_read),
    .scan_addr        (directory_sd_sec_read_addr),
    .audio_req        (audio_loader_sd_sec_read),
    .audio_addr       (audio_loader_sd_sec_read_addr),
    .image_req        (loader_sd_sec_read),
    .image_addr       (loader_sd_sec_read_addr),
    .scan_grant       (scan_grant),
    .audio_grant      (audio_grant),
    .image_grant      (image_grant),
    .sd_sec_read      (sd_sec_read),
    .sd_sec_read_addr (sd_sec_read_addr)
);

sd_card_top u_sd_card_top (
    .clk                    (clk),
    .rst                    (core_rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule
