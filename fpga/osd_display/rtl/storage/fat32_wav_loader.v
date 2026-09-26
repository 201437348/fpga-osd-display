`timescale 1ns/1ps

module fat32_wav_loader #(
    parameter [15:0] HEADER_SCAN_LIMIT_BYTES = 16'd16384,
    parameter [9:0]  FIFO_LOW_WATERMARK      = 10'd256,
    parameter [9:0]  FIFO_HIGH_WATERMARK     = 10'd768
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

    input  wire [9:0]  fifo_wrusedw,
    input  wire        fifo_full,
    output reg         audio_frame_wr_en,
    output reg [31:0]  audio_frame_wr_data,

    output reg         busy,
    output reg         error,

    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

localparam [2:0] ST_IDLE             = 3'd0;
localparam [2:0] ST_START_READER     = 3'd1;
localparam [2:0] ST_WAIT_READER      = 3'd2;
localparam [2:0] ST_REQUEST_SECTOR   = 3'd3;
localparam [2:0] ST_STREAM_SECTOR    = 3'd4;
localparam [2:0] ST_ABORT_FOR_LOOP   = 3'd5;
localparam [2:0] ST_ABORT_FOR_ERROR  = 3'd6;
localparam [2:0] ST_ERROR            = 3'd7;

localparam [3:0] P_RIFF          = 4'd0;
localparam [3:0] P_CHUNK_ID      = 4'd1;
localparam [3:0] P_CHUNK_SIZE    = 4'd2;
localparam [3:0] P_CHUNK_DISPATCH = 4'd3;
localparam [3:0] P_FMT_DATA      = 4'd4;
localparam [3:0] P_FMT_VALIDATE  = 4'd5;
localparam [3:0] P_SKIP_DATA     = 4'd6;
localparam [3:0] P_CHUNK_PAD     = 4'd7;
localparam [3:0] P_PCM_DATA      = 4'd8;
localparam [3:0] P_DRAIN_TAIL    = 4'd9;

localparam [31:0] CHUNK_FMT  = 32'h666D7420;
localparam [31:0] CHUNK_DATA = 32'h64617461;

reg [2:0] loader_state;
reg [3:0] parser_state;
reg       reader_start;
reg       reader_abort;
reg       reader_file_sec_read;
reg       refill_active;
reg       parser_error;
reg       data_complete;

reg [3:0]  riff_byte_index;
reg [2:0]  chunk_byte_index;
reg [31:0] chunk_id;
reg [31:0] chunk_size;
reg [31:0] chunk_remaining;
reg         chunk_pad_pending;
reg [31:0] fmt_byte_index;
reg [15:0] fmt_format_code;
reg [15:0] fmt_channels;
reg [31:0] fmt_sample_rate;
reg [31:0] fmt_byte_rate;
reg [15:0] fmt_block_align;
reg [15:0] fmt_bits_per_sample;
reg [15:0] fmt_valid_bits_per_sample;
reg        fmt_extensible_pcm_valid;
reg         fmt_seen;
reg         pcm_is_24_bit;
reg [31:0] header_bytes_seen;
reg [31:0] data_bytes_remaining;
reg [2:0]  sample_byte_index;
reg [23:0] pcm_left;
reg [23:0] pcm_right;
reg [31:0] file_sec_index;
reg [31:0] file_byte_index;
// 时序优化：file_size - file_byte_index 的镜像计数器，与 file_byte_index
// 同步递减，比较时不再需要 32 位减法器。
reg [31:0] file_bytes_left;
// 时序（100 MHz）：32 位 ==0 / >=LIMIT 比较原来直接挡在每个解析字段寄存器的
// ce 上。改成随计数器一起维护的寄存器标志，每次 -1 / +1 时预判下一值。
reg        file_bytes_left_zero;
reg        header_limit_hit;
// chunk size 的模 3 余数，按长度字节逐个累积（256 ≡ 1 mod 3），
// 取代原先对 32 位值做 32 次串行模 3 归约的长组合链。
reg [1:0]  chunk_size_mod3;

wire        reader_busy;
wire        reader_file_sec_read_ack;
// 时序（100 MHz）：reader 输出字节直接进 WAV 头解析（6 级 LUT + 长走线）是
// sd_card_clk 的最差路径。reader 送来的单拍脉冲（字节 / 扇区结束 / done /
// error / file_complete）整组打一拍再给解析器，相互先后关系不变；
// busy、read_ack 是握手电平，不延迟。
wire        reader_done_raw;
wire        reader_error_raw;
wire [7:0]  reader_file_sec_data_raw;
wire        reader_file_sec_data_valid_raw;
wire        reader_file_sec_read_end_raw;
wire        reader_file_complete_raw;
reg         reader_done;
reg         reader_error;
reg  [7:0]  reader_file_sec_data;
reg         reader_file_sec_data_valid;
reg         reader_file_sec_read_end;
reg         reader_file_complete;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        reader_done                <= 1'b0;
        reader_error               <= 1'b0;
        reader_file_sec_data       <= 8'd0;
        reader_file_sec_data_valid <= 1'b0;
        reader_file_sec_read_end   <= 1'b0;
        reader_file_complete       <= 1'b0;
    end else begin
        reader_done                <= reader_done_raw;
        reader_error               <= reader_error_raw;
        reader_file_sec_data       <= reader_file_sec_data_raw;
        reader_file_sec_data_valid <= reader_file_sec_data_valid_raw;
        reader_file_sec_read_end   <= reader_file_sec_read_end_raw;
        reader_file_complete       <= reader_file_complete_raw;
    end
end
wire        reader_sd_sec_read;
wire [31:0] reader_sd_sec_read_addr;

assign sd_sec_read      = reader_sd_sec_read;

// 本字节并入后的 chunk size 余数（第 0 字节从 0 开始）
wire [1:0] chunk_size_mod3_next =
    add_byte_mod3((chunk_byte_index == 3'd0) ? 2'd0 : chunk_size_mod3,
                  reader_file_sec_data);
assign sd_sec_read_addr = reader_sd_sec_read_addr;

// (acc + b) mod 3。4 ≡ 1 (mod 3)，所以 b 的四个 2 位组直接相加即可：
// 两两相加 (0..6)，再相加 (0..12)，查表归约到 0..2，最后与 acc 相加做
// 一次条件减 3。各级位宽都留足进位。
function [1:0] add_byte_mod3;
    input [1:0] acc;
    input [7:0] b;
    reg [2:0] p0, p1;
    reg [3:0] sum;
    reg [1:0] r;
    reg [2:0] t;
    begin
        p0  = {1'b0, b[1:0]} + {1'b0, b[3:2]};
        p1  = {1'b0, b[5:4]} + {1'b0, b[7:6]};
        sum = {1'b0, p0} + {1'b0, p1};
        case (sum)
            4'd0, 4'd3, 4'd6, 4'd9, 4'd12: r = 2'd0;
            4'd1, 4'd4, 4'd7, 4'd10:       r = 2'd1;
            default:                       r = 2'd2;
        endcase
        t = {1'b0, acc} + {1'b0, r};
        add_byte_mod3 = (t >= 3'd3) ? (t - 3'd3) : t[1:0];
    end
endfunction

// Audio files are commonly much larger than BMP headers and can span tens of
// thousands of FAT32 clusters.  Keep the reader's conservative default for
// other clients, while allowing BGM.WAV to use the full 16-bit chain limit.
fat32_file_sector_reader #(
    .MAX_FILE_CLUSTERS(16'hFFFF)
) u_file_sector_reader (
    .clk                    (clk),
    .rst                    (rst),
    .start                  (reader_start),
    .abort                  (reader_abort),
    .file_first_cluster     (file_first_cluster),
    .file_size              (file_size),
    .first_fat_lba          (first_fat_lba),
    .first_data_lba         (first_data_lba),
    .sectors_per_cluster    (sectors_per_cluster),
    .busy                   (reader_busy),
    .done                   (reader_done_raw),
    .error                  (reader_error_raw),
    .file_sec_read          (reader_file_sec_read),
    .file_sec_index         (file_sec_index),
    .file_sec_read_ack      (reader_file_sec_read_ack),
    .file_sec_data          (reader_file_sec_data_raw),
    .file_sec_data_valid    (reader_file_sec_data_valid_raw),
    .file_sec_read_end      (reader_file_sec_read_end_raw),
    .file_complete          (reader_file_complete_raw),
    .sd_sec_read            (reader_sd_sec_read),
    .sd_sec_read_addr       (reader_sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        loader_state        <= ST_IDLE;
        parser_state        <= P_RIFF;
        reader_start        <= 1'b0;
        reader_abort        <= 1'b0;
        reader_file_sec_read <= 1'b0;
        refill_active       <= 1'b0;
        parser_error        <= 1'b0;
        data_complete       <= 1'b0;
        audio_frame_wr_en   <= 1'b0;
        audio_frame_wr_data <= 32'd0;
        busy                <= 1'b0;
        error               <= 1'b0;
        riff_byte_index     <= 4'd0;
        chunk_byte_index    <= 3'd0;
        chunk_id            <= 32'd0;
        chunk_size          <= 32'd0;
        chunk_remaining     <= 32'd0;
        chunk_pad_pending   <= 1'b0;
        fmt_byte_index      <= 32'd0;
        fmt_format_code     <= 16'd0;
        fmt_channels        <= 16'd0;
        fmt_sample_rate     <= 32'd0;
        fmt_byte_rate       <= 32'd0;
        fmt_block_align     <= 16'd0;
        fmt_bits_per_sample <= 16'd0;
        fmt_valid_bits_per_sample <= 16'd0;
        fmt_extensible_pcm_valid  <= 1'b1;
        fmt_seen            <= 1'b0;
        pcm_is_24_bit       <= 1'b0;
        header_bytes_seen   <= 32'd0;
        data_bytes_remaining <= 32'd0;
        sample_byte_index   <= 3'd0;
        pcm_left            <= 24'd0;
        pcm_right           <= 24'd0;
        file_sec_index      <= 32'd0;
        file_byte_index     <= 32'd0;
        file_bytes_left     <= 32'd0;
        file_bytes_left_zero <= 1'b1;
        header_limit_hit    <= 1'b0;
        chunk_size_mod3     <= 2'd0;
    end else begin
        reader_start      <= 1'b0;
        reader_abort      <= 1'b0;
        audio_frame_wr_en <= 1'b0;
        error             <= 1'b0;

        if (fifo_wrusedw <= FIFO_LOW_WATERMARK)
            refill_active <= 1'b1;
        else if (fifo_wrusedw >= FIFO_HIGH_WATERMARK)
            refill_active <= 1'b0;

        if (abort && (loader_state != ST_IDLE)) begin
            reader_abort         <= 1'b1;
            reader_file_sec_read <= 1'b0;
            loader_state         <= ST_IDLE;
            busy                 <= 1'b0;
            parser_error         <= 1'b0;
            data_complete        <= 1'b0;
        end else if (parser_error && (loader_state != ST_IDLE) &&
                     (loader_state != ST_ABORT_FOR_ERROR) &&
                     (loader_state != ST_ERROR)) begin
            reader_abort         <= 1'b1;
            reader_file_sec_read <= 1'b0;
            loader_state         <= ST_ABORT_FOR_ERROR;
        end else begin
            case (loader_state)
                ST_IDLE: begin
                    busy                 <= 1'b0;
                    reader_file_sec_read <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        parser_error <= 1'b0;
                        data_complete <= 1'b0;
                        loader_state <= ST_START_READER;
                    end
                end

                ST_START_READER: begin
                    reader_start         <= 1'b1;
                    reader_file_sec_read <= 1'b0;
                    parser_state         <= P_RIFF;
                    riff_byte_index      <= 4'd0;
                    chunk_byte_index     <= 3'd0;
                    chunk_id             <= 32'd0;
                    chunk_size           <= 32'd0;
                    chunk_remaining      <= 32'd0;
                    chunk_pad_pending    <= 1'b0;
                    fmt_byte_index       <= 32'd0;
                    fmt_format_code      <= 16'd0;
                    fmt_channels         <= 16'd0;
                    fmt_sample_rate      <= 32'd0;
                    fmt_byte_rate        <= 32'd0;
                    fmt_block_align      <= 16'd0;
                    fmt_bits_per_sample  <= 16'd0;
                    fmt_valid_bits_per_sample <= 16'd0;
                    fmt_extensible_pcm_valid  <= 1'b1;
                    fmt_seen             <= 1'b0;
                    pcm_is_24_bit        <= 1'b0;
                    header_bytes_seen    <= 32'd0;
                    header_limit_hit     <= (HEADER_SCAN_LIMIT_BYTES == 16'd0);
                    data_bytes_remaining <= 32'd0;
                    sample_byte_index    <= 3'd0;
                    pcm_left             <= 24'd0;
                    pcm_right            <= 24'd0;
                    file_sec_index       <= 32'd0;
                    file_byte_index      <= 32'd0;
                    file_bytes_left      <= file_size;
                    file_bytes_left_zero <= (file_size == 32'd0);
                    chunk_size_mod3      <= 2'd0;
                    data_complete        <= 1'b0;
                    loader_state         <= ST_WAIT_READER;
                end

                ST_WAIT_READER: begin
                    if (reader_error || (reader_done && !reader_busy)) begin
                        parser_error <= 1'b1;
                    end else if (reader_busy) begin
                        loader_state <= ST_REQUEST_SECTOR;
                    end
                end

                ST_REQUEST_SECTOR: begin
                    if (reader_file_sec_read_ack) begin
                        reader_file_sec_read <= 1'b0;
                        loader_state         <= ST_STREAM_SECTOR;
                    end else if (refill_active && !fifo_full) begin
                        reader_file_sec_read <= 1'b1;
                    end
                end

                ST_STREAM_SECTOR: begin
                    if (reader_file_sec_data_valid) begin
                        if (parser_state == P_DRAIN_TAIL) begin
                            if (!file_bytes_left_zero) begin
                                file_byte_index <= file_byte_index + 32'd1;
                                file_bytes_left <= file_bytes_left - 32'd1;
                                file_bytes_left_zero <= (file_bytes_left == 32'd1);
                            end
                        end else if (file_bytes_left_zero) begin
                            parser_error <= 1'b1;
                        end else if ((parser_state != P_PCM_DATA) &&
                                     header_limit_hit) begin
                            parser_error <= 1'b1;
                        end else begin
                            file_byte_index <= file_byte_index + 32'd1;
                            file_bytes_left <= file_bytes_left - 32'd1;
                            file_bytes_left_zero <= (file_bytes_left == 32'd1);
                            if ((parser_state != P_PCM_DATA) &&
                                (parser_state != P_DRAIN_TAIL)) begin
                                header_bytes_seen <= header_bytes_seen + 32'd1;
                                header_limit_hit  <= ((header_bytes_seen + 32'd1) >=
                                                      HEADER_SCAN_LIMIT_BYTES);
                            end

                            case (parser_state)
                                P_RIFF: begin
                                    case (riff_byte_index)
                                        4'd0: if (reader_file_sec_data != 8'h52) parser_error <= 1'b1;
                                        4'd1: if (reader_file_sec_data != 8'h49) parser_error <= 1'b1;
                                        4'd2: if (reader_file_sec_data != 8'h46) parser_error <= 1'b1;
                                        4'd3: if (reader_file_sec_data != 8'h46) parser_error <= 1'b1;
                                        4'd8: if (reader_file_sec_data != 8'h57) parser_error <= 1'b1;
                                        4'd9: if (reader_file_sec_data != 8'h41) parser_error <= 1'b1;
                                        4'd10: if (reader_file_sec_data != 8'h56) parser_error <= 1'b1;
                                        4'd11: if (reader_file_sec_data != 8'h45) parser_error <= 1'b1;
                                        default: ;
                                    endcase
                                    if (riff_byte_index == 4'd11) begin
                                        parser_state     <= P_CHUNK_ID;
                                        chunk_byte_index <= 3'd0;
                                        chunk_id         <= 32'd0;
                                    end else begin
                                        riff_byte_index <= riff_byte_index + 4'd1;
                                    end
                                end

                                P_CHUNK_ID: begin
                                    chunk_id <= {chunk_id[23:0], reader_file_sec_data};
                                    if (chunk_byte_index == 3'd3) begin
                                        chunk_byte_index <= 3'd0;
                                        parser_state     <= P_CHUNK_SIZE;
                                    end else begin
                                        chunk_byte_index <= chunk_byte_index + 3'd1;
                                    end
                                end

                                P_CHUNK_SIZE: begin
                                    chunk_size_mod3 <= chunk_size_mod3_next;
                                    case (chunk_byte_index)
                                        3'd0: chunk_size[7:0]   <= reader_file_sec_data;
                                        3'd1: chunk_size[15:8]  <= reader_file_sec_data;
                                        3'd2: chunk_size[23:16] <= reader_file_sec_data;
                                        default: chunk_size[31:24] <= reader_file_sec_data;
                                    endcase
                                    if (chunk_byte_index == 3'd3) begin
                                        chunk_byte_index <= 3'd0;
                                        // RIFF chunk sizes are little-endian. The padding bit is
                                        // bit zero of the first size byte, already retained here.
                                        chunk_pad_pending <= chunk_size[0];
                                        if (chunk_id == CHUNK_FMT) begin
                                            if ({reader_file_sec_data, chunk_size[23:0]} < 32'd16) begin
                                                parser_error <= 1'b1;
                                            end else begin
                                                chunk_remaining <= {reader_file_sec_data,
                                                                    chunk_size[23:0]};
                                                fmt_byte_index  <= 32'd0;
                                                parser_state    <= P_FMT_DATA;
                                            end
                                        end else if (chunk_id == CHUNK_DATA) begin
                                            if (!fmt_seen ||
                                                ({reader_file_sec_data, chunk_size[23:0]} == 32'd0) ||
                                                // 24-bit: 能被 6 整除 = 偶数且模 3 为 0
                                                (pcm_is_24_bit ?
                                                 (chunk_size[0] || (chunk_size_mod3_next != 2'd0)) :
                                                 (chunk_size[1:0] != 2'd0)) ||
                                                // 超出本字节之后的剩余长度
                                                // (> left-1  <=>  >= left, left 此时 >= 1)
                                                ({reader_file_sec_data,
                                                  chunk_size[23:0]} >=
                                                 file_bytes_left)) begin
                                                parser_error <= 1'b1;
                                            end else begin
                                                data_bytes_remaining <= {reader_file_sec_data,
                                                                         chunk_size[23:0]};
                                                sample_byte_index    <= 3'd0;
                                                parser_state         <= P_PCM_DATA;
                                            end
                                        end else if ({reader_file_sec_data,
                                                      chunk_size[23:0]} == 32'd0) begin
                                            chunk_id         <= 32'd0;
                                            chunk_byte_index <= 3'd0;
                                            parser_state     <= reader_file_sec_data[0] ?
                                                                P_CHUNK_PAD : P_CHUNK_ID;
                                        end else begin
                                            chunk_remaining <= {reader_file_sec_data,
                                                                chunk_size[23:0]};
                                            parser_state    <= P_SKIP_DATA;
                                        end
                                    end else begin
                                        chunk_byte_index <= chunk_byte_index + 3'd1;
                                    end
                                end

                                P_FMT_DATA: begin
                                    case (fmt_byte_index)
                                        32'd0:  fmt_format_code[7:0]    <= reader_file_sec_data;
                                        32'd1:  fmt_format_code[15:8]   <= reader_file_sec_data;
                                        32'd2:  fmt_channels[7:0]       <= reader_file_sec_data;
                                        32'd3:  fmt_channels[15:8]      <= reader_file_sec_data;
                                        32'd4:  fmt_sample_rate[7:0]    <= reader_file_sec_data;
                                        32'd5:  fmt_sample_rate[15:8]   <= reader_file_sec_data;
                                        32'd6:  fmt_sample_rate[23:16]  <= reader_file_sec_data;
                                        32'd7:  fmt_sample_rate[31:24]  <= reader_file_sec_data;
                                        32'd8:  fmt_byte_rate[7:0]      <= reader_file_sec_data;
                                        32'd9:  fmt_byte_rate[15:8]     <= reader_file_sec_data;
                                        32'd10: fmt_byte_rate[23:16]    <= reader_file_sec_data;
                                        32'd11: fmt_byte_rate[31:24]    <= reader_file_sec_data;
                                        32'd12: fmt_block_align[7:0]    <= reader_file_sec_data;
                                        32'd13: fmt_block_align[15:8]   <= reader_file_sec_data;
                                        32'd14: fmt_bits_per_sample[7:0] <= reader_file_sec_data;
                                        32'd15: fmt_bits_per_sample[15:8] <= reader_file_sec_data;
                                        32'd18: fmt_valid_bits_per_sample[7:0] <= reader_file_sec_data;
                                        32'd19: fmt_valid_bits_per_sample[15:8] <= reader_file_sec_data;
                                        default: ;
                                    endcase
                                    // WAVE_FORMAT_EXTENSIBLE stores a 16-byte
                                    // sub-format GUID at fmt bytes 24..39.
                                    // Accept only the standard PCM GUID:
                                    // 00000001-0000-0010-8000-00AA00389B71.
                                    case (fmt_byte_index)
                                        32'd24: if (reader_file_sec_data != 8'h01) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd25: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd26: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd27: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd28: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd29: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd30: if (reader_file_sec_data != 8'h10) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd31: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd32: if (reader_file_sec_data != 8'h80) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd33: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd34: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd35: if (reader_file_sec_data != 8'hAA) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd36: if (reader_file_sec_data != 8'h00) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd37: if (reader_file_sec_data != 8'h38) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd38: if (reader_file_sec_data != 8'h9B) fmt_extensible_pcm_valid <= 1'b0;
                                        32'd39: if (reader_file_sec_data != 8'h71) fmt_extensible_pcm_valid <= 1'b0;
                                        default: ;
                                    endcase
                                    if (chunk_remaining == 32'd1) begin
                                        chunk_remaining <= 32'd0;
                                        if (!(((fmt_format_code == 16'd1) &&
                                               (((fmt_byte_rate == 32'd192000) &&
                                                 (fmt_block_align == 16'd4) &&
                                                 (fmt_bits_per_sample == 16'd16)) ||
                                                ((fmt_byte_rate == 32'd288000) &&
                                                 (fmt_block_align == 16'd6) &&
                                                 (fmt_bits_per_sample == 16'd24)))) ||
                                              ((fmt_format_code == 16'hFFFE) &&
                                               (chunk_size == 32'd40) &&
                                               (fmt_valid_bits_per_sample == 16'd24) &&
                                               fmt_extensible_pcm_valid &&
                                               (reader_file_sec_data == 8'h71) &&
                                               (fmt_byte_rate == 32'd288000) &&
                                               (fmt_block_align == 16'd6) &&
                                               (fmt_bits_per_sample == 16'd24))) ||
                                            (fmt_channels != 16'd2) ||
                                            (fmt_sample_rate != 32'd48000)) begin
                                            parser_error <= 1'b1;
                                        end else begin
                                            fmt_seen         <= 1'b1;
                                            pcm_is_24_bit    <= (fmt_bits_per_sample == 16'd24);
                                            chunk_id         <= 32'd0;
                                            chunk_byte_index <= 3'd0;
                                            parser_state     <= chunk_pad_pending ?
                                                                P_CHUNK_PAD : P_CHUNK_ID;
                                        end
                                    end else begin
                                        chunk_remaining <= chunk_remaining - 32'd1;
                                        fmt_byte_index  <= fmt_byte_index + 32'd1;
                                    end
                                end

                                P_SKIP_DATA: begin
                                    if (chunk_remaining == 32'd1) begin
                                        chunk_remaining  <= 32'd0;
                                        chunk_id          <= 32'd0;
                                        chunk_byte_index  <= 3'd0;
                                        parser_state      <= chunk_pad_pending ? P_CHUNK_PAD : P_CHUNK_ID;
                                    end else begin
                                        chunk_remaining <= chunk_remaining - 32'd1;
                                    end
                                end

                                P_CHUNK_PAD: begin
                                    chunk_id         <= 32'd0;
                                    chunk_byte_index <= 3'd0;
                                    parser_state     <= P_CHUNK_ID;
                                end

                                P_PCM_DATA: begin
                                    if (data_bytes_remaining == 32'd0) begin
                                        parser_error <= 1'b1;
                                    end else if (pcm_is_24_bit) begin
                                        case (sample_byte_index)
                                            3'd0: pcm_left[7:0]    <= reader_file_sec_data;
                                            3'd1: pcm_left[15:8]   <= reader_file_sec_data;
                                            3'd2: pcm_left[23:16]  <= reader_file_sec_data;
                                            3'd3: pcm_right[7:0]   <= reader_file_sec_data;
                                            3'd4: pcm_right[15:8]  <= reader_file_sec_data;
                                            default: begin
                                                pcm_right[23:16]    <= reader_file_sec_data;
                                                if (fifo_full) begin
                                                    parser_error <= 1'b1;
                                                end else begin
                                                    audio_frame_wr_en   <= 1'b1;
                                                    audio_frame_wr_data <= {pcm_left[23:8],
                                                                            reader_file_sec_data,
                                                                            pcm_right[15:8]};
                                                end
                                            end
                                        endcase

                                        if (data_bytes_remaining == 32'd1) begin
                                            if (sample_byte_index != 3'd5) begin
                                                parser_error <= 1'b1;
                                            end else begin
                                                data_complete <= 1'b1;
                                                parser_state  <= P_DRAIN_TAIL;
                                            end
                                        end
                                        data_bytes_remaining <= data_bytes_remaining - 32'd1;
                                        if (sample_byte_index == 3'd5)
                                            sample_byte_index <= 3'd0;
                                        else
                                            sample_byte_index <= sample_byte_index + 3'd1;
                                    end else begin
                                        case (sample_byte_index)
                                            3'd0: pcm_left[7:0]  <= reader_file_sec_data;
                                            3'd1: pcm_left[15:8] <= reader_file_sec_data;
                                            3'd2: pcm_right[7:0] <= reader_file_sec_data;
                                            default: begin
                                                pcm_right[15:8] <= reader_file_sec_data;
                                                if (fifo_full) begin
                                                    parser_error <= 1'b1;
                                                end else begin
                                                    audio_frame_wr_en   <= 1'b1;
                                                    audio_frame_wr_data <= {pcm_left,
                                                                            reader_file_sec_data,
                                                                            pcm_right[7:0]};
                                                end
                                            end
                                        endcase

                                        if (data_bytes_remaining == 32'd1) begin
                                            if (sample_byte_index != 3'd3) begin
                                                parser_error <= 1'b1;
                                            end else begin
                                                data_complete <= 1'b1;
                                                parser_state  <= P_DRAIN_TAIL;
                                            end
                                        end
                                        data_bytes_remaining <= data_bytes_remaining - 32'd1;
                                        if (sample_byte_index == 3'd3)
                                            sample_byte_index <= 3'd0;
                                        else
                                            sample_byte_index <= sample_byte_index + 3'd1;
                                    end
                                end

                                P_DRAIN_TAIL: begin
                                end

                                default: parser_error <= 1'b1;
                            endcase
                        end
                    end

                    if (reader_file_sec_read_end) begin
                        reader_file_sec_read <= 1'b0;
                        if (data_complete ||
                            (reader_file_sec_data_valid &&
                             (parser_state == P_PCM_DATA) &&
                             (data_bytes_remaining == 32'd1) &&
                             (sample_byte_index == (pcm_is_24_bit ? 3'd5 : 3'd3)))) begin
                            reader_abort <= 1'b1;
                            loader_state <= ST_ABORT_FOR_LOOP;
                        end else if (reader_error || reader_done || reader_file_complete) begin
                            parser_error <= 1'b1;
                        end else begin
                            file_sec_index <= file_sec_index + 32'd1;
                            loader_state <= ST_REQUEST_SECTOR;
                        end
                    end
                end

                ST_ABORT_FOR_LOOP: begin
                    reader_abort         <= 1'b1;
                    reader_file_sec_read <= 1'b0;
                    if (!reader_busy)
                        loader_state <= ST_START_READER;
                end

                ST_ABORT_FOR_ERROR: begin
                    reader_abort         <= 1'b1;
                    reader_file_sec_read <= 1'b0;
                    if (!reader_busy)
                        loader_state <= ST_ERROR;
                end

                ST_ERROR: begin
                    busy                 <= 1'b0;
                    error                <= 1'b1;
                    reader_file_sec_read <= 1'b0;
                    loader_state         <= ST_IDLE;
                end

                default: begin
                    loader_state         <= ST_IDLE;
                    reader_file_sec_read <= 1'b0;
                    busy                 <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
