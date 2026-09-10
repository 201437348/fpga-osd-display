`timescale 1ns/1ps

// Loads one FAT32 BMP through logical file sectors. The header pass is kept
// separate from the data pass so SDRAM buffer ownership is known before pixels
// from logical sector zero are emitted.
module fat32_bmp_loader(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        abort,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,
    input  wire [31:0] first_fat_lba,
    input  wire [31:0] first_data_lba,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [15:0] bmp_width,
    input  wire [15:0] bmp_height,

    output reg         busy,
    output reg         done,
    output reg         error,
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
reg [31:0] header_width;
reg [31:0] header_height;
reg [15:0] bit_count;
reg [31:0] compression;
reg [31:0] stream_byte_count;
reg [31:0] next_stream_sector_index;
reg [1:0]  pixel_byte_index;
reg         abort_pending;

wire header_match;
wire stream_pixel_valid;
wire [31:0] reader_session_file_size;

assign sd_sec_read      = reader_sd_sec_read;
assign sd_sec_read_addr = reader_sd_sec_read_addr;

assign header_match = (header_0 == 8'h42) &&
                      (header_1 == 8'h4D) &&
                      (header_width[15:0] == bmp_width) &&
                      (header_height[15:0] == bmp_height) &&
                      (bit_count == 16'd24) &&
                      (compression == 32'd0) &&
                      (header_file_len != 32'd0) &&
                      (pixel_offset < header_file_len) &&
                      (header_file_len <= file_size_latched);

assign stream_pixel_valid = (stream_byte_count >= pixel_offset) &&
                            (stream_byte_count < header_file_len);

// The header probe must finish after logical sector zero and must not trigger
// a FAT lookup for the file's next cluster before the reader is aborted.
assign reader_session_file_size = (state == ST_HEADER_START) ?
                                ((file_size_latched > 32'd512) ? 32'd512 : file_size_latched) :
                                file_size_latched;

fat32_file_sector_reader u_file_sector_reader (
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
        header_width                  <= 32'd0;
        header_height                 <= 32'd0;
        bit_count                     <= 16'd0;
        compression                   <= 32'd0;
        stream_byte_count             <= 32'd0;
        next_stream_sector_index      <= 32'd0;
        pixel_byte_index              <= 2'd0;
        abort_pending                 <= 1'b0;
    end else begin
        done                 <= 1'b0;
        error                <= 1'b0;
        reader_start         <= 1'b0;
        reader_abort         <= 1'b0;
        reader_file_sec_read <= 1'b0;
        bmp_data_wr_en       <= 1'b0;

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
                        header_width               <= 32'd0;
                        header_height              <= 32'd0;
                        bit_count                  <= 16'd0;
                        compression                <= 32'd0;
                        stream_byte_count          <= 32'd0;
                        next_stream_sector_index   <= 32'd0;
                        pixel_byte_index           <= 2'd0;
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
                        case (header_byte_index)
                            10'd0:  header_0 <= reader_file_sec_data;
                            10'd1:  header_1 <= reader_file_sec_data;
                            10'd2:  header_file_len[7:0] <= reader_file_sec_data;
                            10'd3:  header_file_len[15:8] <= reader_file_sec_data;
                            10'd4:  header_file_len[23:16] <= reader_file_sec_data;
                            10'd5:  header_file_len[31:24] <= reader_file_sec_data;
                            10'd10: pixel_offset[7:0] <= reader_file_sec_data;
                            10'd11: pixel_offset[15:8] <= reader_file_sec_data;
                            10'd12: pixel_offset[23:16] <= reader_file_sec_data;
                            10'd13: pixel_offset[31:24] <= reader_file_sec_data;
                            10'd18: header_width[7:0] <= reader_file_sec_data;
                            10'd19: header_width[15:8] <= reader_file_sec_data;
                            10'd20: header_width[23:16] <= reader_file_sec_data;
                            10'd21: header_width[31:24] <= reader_file_sec_data;
                            10'd22: header_height[7:0] <= reader_file_sec_data;
                            10'd23: header_height[15:8] <= reader_file_sec_data;
                            10'd24: header_height[23:16] <= reader_file_sec_data;
                            10'd25: header_height[31:24] <= reader_file_sec_data;
                            10'd28: bit_count[7:0] <= reader_file_sec_data;
                            10'd29: bit_count[15:8] <= reader_file_sec_data;
                            10'd30: compression[7:0] <= reader_file_sec_data;
                            10'd31: compression[15:8] <= reader_file_sec_data;
                            10'd32: compression[23:16] <= reader_file_sec_data;
                            10'd33: compression[31:24] <= reader_file_sec_data;
                            default: ;
                        endcase
                        header_byte_index <= header_byte_index + 10'd1;
                    end

                    if (reader_file_sec_read_end) begin
                        reader_abort <= 1'b1;
                        if (header_match)
                            state <= ST_HEADER_ABORT;
                        else
                            state <= ST_LOCAL_ERROR_ABORT;
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
                        if (stream_pixel_valid) begin
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
                        end
                        stream_byte_count <= stream_byte_count + 32'd1;
                    end

                    if (reader_file_sec_read_end) begin
                        if (reader_file_complete) begin
                            busy <= 1'b0;
                            if (pixel_byte_index == 2'd0) begin
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
