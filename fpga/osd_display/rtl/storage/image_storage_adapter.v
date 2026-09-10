module image_storage_adapter #(
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]  SCAN_TARGET_COUNT = 3'd4,
    parameter integer SD_CLK_FREQ_HZ = 100_000_000,
    parameter integer SD_RESPONSE_TIMEOUT_MS = 250
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        scan_start,
    input  wire        load_start,
    input  wire        load_abort,
    input  wire        storage_reinit,
    input  wire [1:0]  target_image_index,

    output wire        storage_ready,
    output reg         scan_done,
    output reg [2:0]   scan_found_count,
    output reg         source_done_pulse,
    output reg         source_error_pulse,
    output reg         storage_fault_pulse,
    output reg [3:0]   state_code,

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

reg [31:0] image_cluster0;
reg [31:0] image_cluster1;
reg [31:0] image_cluster2;
reg [31:0] image_cluster3;
reg [31:0] image_size0;
reg [31:0] image_size1;
reg [31:0] image_size2;
reg [31:0] image_size3;
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
wire [2:0]  directory_file_count;
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

localparam [24:0] SD_RESPONSE_TIMEOUT_CYCLES =
    (SD_CLK_FREQ_HZ / 1000) * SD_RESPONSE_TIMEOUT_MS;

reg write_req_ack_meta;
reg write_req_ack_sync;

reg [31:0] selected_file_cluster;
reg [31:0] selected_file_size;

assign storage_ready = sd_init_done;
assign core_rst      = rst | storage_reinit;
assign write_req     = loader_write_req;
assign write_en      = loader_bmp_data_wr_en;
assign write_data    = {loader_bmp_data, 8'b0};
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
    case (target_image_index)
        2'd0: begin
            selected_file_cluster = image_cluster0;
            selected_file_size    = image_size0;
        end
        2'd1: begin
            selected_file_cluster = image_cluster1;
            selected_file_size    = image_size1;
        end
        2'd2: begin
            selected_file_cluster = image_cluster2;
            selected_file_size    = image_size2;
        end
        default: begin
            selected_file_cluster = image_cluster3;
            selected_file_size    = image_size3;
        end
    endcase
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
        scan_found_count           <= 3'd0;
        source_done_pulse          <= 1'b0;
        source_error_pulse         <= 1'b0;
        storage_fault_pulse        <= 1'b0;
        state_code                 <= 4'd0;
        scan_error_seen            <= 1'b0;
        storage_fault_latched      <= 1'b0;
        sd_response_watchdog       <= 25'd0;
        image_cluster0             <= 32'd0;
        image_cluster1             <= 32'd0;
        image_cluster2             <= 32'd0;
        image_cluster3             <= 32'd0;
        image_size0                <= 32'd0;
        image_size1                <= 32'd0;
        image_size2                <= 32'd0;
        image_size3                <= 32'd0;
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
            scan_found_count           <= 3'd0;
            scan_error_seen            <= 1'b0;
            state_code                 <= 4'd0;
            image_cluster0             <= 32'd0;
            image_cluster1             <= 32'd0;
            image_cluster2             <= 32'd0;
            image_cluster3             <= 32'd0;
            image_size0                <= 32'd0;
            image_size1                <= 32'd0;
            image_size2                <= 32'd0;
            image_size3                <= 32'd0;
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
                case (scan_found_count)
                    3'd0: begin
                        image_cluster0 <= directory_file_first_cluster;
                        image_size0    <= directory_file_size;
                    end
                    3'd1: begin
                        image_cluster1 <= directory_file_first_cluster;
                        image_size1    <= directory_file_size;
                    end
                    3'd2: begin
                        image_cluster2 <= directory_file_first_cluster;
                        image_size2    <= directory_file_size;
                    end
                    3'd3: begin
                        image_cluster3 <= directory_file_first_cluster;
                        image_size3    <= directory_file_size;
                    end
                    default: ;
                endcase
                scan_found_count <= scan_found_count + 3'd1;
            end

            case (state)
                ST_IDLE: begin
                    state_code <= 4'd1;

                    if (scan_start) begin
                        scan_done                  <= 1'b0;
                        scan_found_count           <= 3'd0;
                        scan_error_seen            <= 1'b0;
                        image_cluster0             <= 32'd0;
                        image_cluster1             <= 32'd0;
                        image_cluster2             <= 32'd0;
                        image_cluster3             <= 32'd0;
                        image_size0                <= 32'd0;
                        image_size1                <= 32'd0;
                        image_size2                <= 32'd0;
                        image_size3                <= 32'd0;
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
                        scan_found_count <= 3'd0;
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

fat32_bmp_loader u_fat32_bmp_loader (
    .clk                    (clk),
    .rst                    (core_rst),
    .start                  (loader_start),
    .abort                  (loader_abort),
    .file_first_cluster     (selected_file_cluster),
    .file_size              (selected_file_size),
    .first_fat_lba          (volume_first_fat_lba),
    .first_data_lba         (volume_first_data_lba),
    .sectors_per_cluster    (volume_sectors_per_cluster),
    .bmp_width              (16'd640),
    .bmp_height             (16'd480),
    .busy                   (loader_busy),
    .done                   (loader_done),
    .error                  (loader_error),
    .write_req              (loader_write_req),
    .write_req_ack          (write_req_ack_sync),
    .write_fifo_afull       (write_fifo_afull),
    .bmp_data_wr_en         (loader_bmp_data_wr_en),
    .bmp_data               (loader_bmp_data),
    .sd_sec_read            (loader_sd_sec_read),
    .sd_sec_read_addr       (loader_sd_sec_read_addr),
    .sd_sec_read_data       (image_grant ? sd_sec_read_data : 8'd0),
    .sd_sec_read_data_valid (image_grant ? sd_sec_read_data_valid : 1'b0),
    .sd_sec_read_end        (image_grant ? sd_sec_read_end : 1'b0)
);

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
