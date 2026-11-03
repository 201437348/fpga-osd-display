`timescale 1ns/1ps

module fat32_directory_scan #(
    parameter [3:0]  MAX_FILES = 4'd8,
    parameter [15:0] MAX_ROOT_DIR_CLUSTERS = 16'd64
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    output reg         busy,
    output reg         done,
    output reg         error,

    output reg         sd_sec_read,
    output reg [31:0]  sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,

    output reg         file_found,
    output reg [3:0]   file_count,
    output reg [87:0]  file_name,
    output reg [31:0]  file_first_cluster,
    output reg [31:0]  file_size,
    output reg [31:0]  volume_first_fat_lba,
    output reg [31:0]  volume_first_data_lba,
    output reg [7:0]   volume_sectors_per_cluster,
    output reg         bgm_found,
    output reg [31:0]  bgm_first_cluster,
    output reg [31:0]  bgm_size,
    // 第二首背景音乐 BGM2.WAV（串口屏切歌用；不存在时 bgm2_found=0）
    output reg         bgm2_found,
    output reg [31:0]  bgm2_first_cluster,
    output reg [31:0]  bgm2_size
);

localparam [3:0] ST_IDLE         = 4'd0;
localparam [3:0] ST_READ_LBA0    = 4'd1;
localparam [3:0] ST_PARSE_LBA0   = 4'd2;
localparam [3:0] ST_READ_BOOT    = 4'd3;
localparam [3:0] ST_PARSE_BOOT   = 4'd4;
localparam [3:0] ST_READ_DIR     = 4'd5;
localparam [3:0] ST_READ_FAT     = 4'd6;
localparam [3:0] ST_PARSE_FAT    = 4'd7;
localparam [3:0] ST_CALC_DATA_LBA = 4'd8;
localparam [3:0] ST_CALC_ROOT_OFFSET = 4'd9;
localparam [3:0] ST_START_DIR    = 4'd10;
localparam [3:0] ST_CALC_NEXT_DIR_OFFSET = 4'd11;
localparam [3:0] ST_START_NEXT_DIR = 4'd12;
localparam [3:0] ST_CHECK_BOOT_BPB = 4'd13;

reg [3:0]  state;
reg [8:0]  sector_byte_index;

reg        mbr_signature_55;
reg        mbr_signature_aa;
reg [7:0]  mbr_entry_type;
reg [31:0] mbr_entry_start;
reg        mbr_partition_found;
reg [31:0] mbr_partition_start;
reg [31:0] boot_sector_lba;

reg        boot_signature_55;
reg        boot_signature_aa;
reg [15:0] bpb_bytes_per_sector;
reg [7:0]  bpb_sectors_per_cluster;
reg [15:0] bpb_reserved_sectors;
reg [7:0]  bpb_fat_count;
reg [15:0] bpb_root_entry_count;
reg [15:0] bpb_fat_size16;
reg [31:0] bpb_fat_size32;
reg [31:0] bpb_root_cluster;
reg        boot_bpb_invalid;
reg [31:0] first_fat_lba;
reg [31:0] first_data_lba;
reg [31:0] layout_fat_start_lba;
reg [31:0] layout_fat_sectors;
reg [31:0] layout_root_cluster_delta;
reg [31:0] layout_root_sector_offset;
reg [31:0] next_dir_cluster;
reg [31:0] next_dir_cluster_delta;
reg [31:0] next_dir_sector_offset;

reg [31:0] current_dir_cluster;
reg [31:0] current_dir_sector_lba;
reg [7:0]  dir_sector_in_cluster;
reg [15:0] dir_clusters_seen;
reg        dir_end_seen;
reg        dir_limit_seen;

reg [7:0]  dir_entry_first_byte;
reg [87:0] dir_entry_name;
reg [7:0]  dir_entry_attr;
reg [31:0] dir_entry_first_cluster;
reg [31:0] dir_entry_size;

reg [8:0]  fat_byte_offset;
reg [31:0] fat_next_cluster;

function is_power_of_two;
    input [7:0] value;
    begin
        is_power_of_two = (value != 8'd0) && ((value & (value - 8'd1)) == 8'd0);
    end
endfunction

function is_regular_bmp;
    input [7:0]  first_byte;
    input [7:0]  attr;
    input [87:0] short_name;
    input [31:0] first_cluster;
    input [31:0] size;
    begin
        is_regular_bmp = (first_byte != 8'h00) &&
                         (first_byte != 8'hE5) &&
                         ((attr & 8'h18) == 8'h00) &&
                         (short_name[23:16] == 8'h42) &&
                         (short_name[15:8]  == 8'h4D) &&
                         (short_name[7:0]   == 8'h50) &&
                         (first_cluster >= 32'd2) &&
                         (size != 32'd0);
    end
endfunction

// 曲目 1：BGM.WAV 或 BGM1.WAV；曲目 2：BGM2.WAV（8.3 短名，空格补齐）
function is_bgm_wav;
    input [7:0]  first_byte;
    input [7:0]  attr;
    input [87:0] short_name;
    input [31:0] first_cluster;
    input [31:0] size;
    input        track2;
    begin
        is_bgm_wav = (first_byte != 8'h00) &&
                     (first_byte != 8'hE5) &&
                     ((attr & 8'h18) == 8'h00) &&
                     (track2 ? (short_name == 88'h42_47_4D_32_20_20_20_20_57_41_56)
                             : ((short_name == 88'h42_47_4D_20_20_20_20_20_57_41_56) ||
                                (short_name == 88'h42_47_4D_31_20_20_20_20_57_41_56))) &&
                     (first_cluster >= 32'd2) &&
                     (size != 32'd0);
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state                  <= ST_IDLE;
        busy                   <= 1'b0;
        done                   <= 1'b0;
        error                  <= 1'b0;
        sd_sec_read            <= 1'b0;
        sd_sec_read_addr       <= 32'd0;
        file_found             <= 1'b0;
        file_count             <= 4'd0;
        file_name              <= 88'd0;
        file_first_cluster     <= 32'd0;
        file_size              <= 32'd0;
        volume_first_fat_lba   <= 32'd0;
        volume_first_data_lba  <= 32'd0;
        volume_sectors_per_cluster <= 8'd0;
        bgm_found              <= 1'b0;
        bgm_first_cluster      <= 32'd0;
        bgm_size               <= 32'd0;
        bgm2_found             <= 1'b0;
        bgm2_first_cluster     <= 32'd0;
        bgm2_size              <= 32'd0;
        sector_byte_index      <= 9'd0;
        mbr_signature_55       <= 1'b0;
        mbr_signature_aa       <= 1'b0;
        mbr_entry_type         <= 8'd0;
        mbr_entry_start        <= 32'd0;
        mbr_partition_found    <= 1'b0;
        mbr_partition_start    <= 32'd0;
        boot_sector_lba        <= 32'd0;
        boot_signature_55      <= 1'b0;
        boot_signature_aa      <= 1'b0;
        bpb_bytes_per_sector   <= 16'd0;
        bpb_sectors_per_cluster <= 8'd0;
        bpb_reserved_sectors   <= 16'd0;
        bpb_fat_count          <= 8'd0;
        bpb_root_entry_count   <= 16'd0;
        bpb_fat_size16         <= 16'd0;
        bpb_fat_size32         <= 32'd0;
        bpb_root_cluster       <= 32'd0;
        boot_bpb_invalid       <= 1'b0;
        first_fat_lba          <= 32'd0;
        first_data_lba         <= 32'd0;
        layout_fat_start_lba   <= 32'd0;
        layout_fat_sectors     <= 32'd0;
        layout_root_cluster_delta <= 32'd0;
        layout_root_sector_offset <= 32'd0;
        next_dir_cluster       <= 32'd0;
        next_dir_cluster_delta <= 32'd0;
        next_dir_sector_offset <= 32'd0;
        current_dir_cluster    <= 32'd0;
        current_dir_sector_lba <= 32'd0;
        dir_sector_in_cluster  <= 8'd0;
        dir_clusters_seen      <= 16'd0;
        dir_end_seen           <= 1'b0;
        dir_limit_seen         <= 1'b0;
        dir_entry_first_byte   <= 8'd0;
        dir_entry_name         <= 88'd0;
        dir_entry_attr         <= 8'd0;
        dir_entry_first_cluster <= 32'd0;
        dir_entry_size         <= 32'd0;
        fat_byte_offset        <= 9'd0;
        fat_next_cluster       <= 32'd0;
    end else begin
        done       <= 1'b0;
        error      <= 1'b0;
        file_found <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy        <= 1'b0;
                sd_sec_read <= 1'b0;

                if (start) begin
                    busy                    <= 1'b1;
                    sd_sec_read_addr        <= 32'd0;
                    sector_byte_index       <= 9'd0;
                    file_count              <= 4'd0;
                    file_name               <= 88'd0;
                    file_first_cluster      <= 32'd0;
                    file_size               <= 32'd0;
                    volume_first_fat_lba    <= 32'd0;
                    volume_first_data_lba   <= 32'd0;
                    volume_sectors_per_cluster <= 8'd0;
                    bgm_found               <= 1'b0;
                    bgm_first_cluster       <= 32'd0;
                    bgm_size                <= 32'd0;
                    bgm2_found              <= 1'b0;
                    bgm2_first_cluster      <= 32'd0;
                    bgm2_size               <= 32'd0;
                    mbr_signature_55        <= 1'b0;
                    mbr_signature_aa        <= 1'b0;
                    mbr_entry_type          <= 8'd0;
                    mbr_entry_start         <= 32'd0;
                    mbr_partition_found     <= 1'b0;
                    mbr_partition_start     <= 32'd0;
                    layout_fat_start_lba    <= 32'd0;
                    layout_fat_sectors      <= 32'd0;
                    layout_root_cluster_delta <= 32'd0;
                    layout_root_sector_offset <= 32'd0;
                    next_dir_cluster        <= 32'd0;
                    next_dir_cluster_delta  <= 32'd0;
                    next_dir_sector_offset  <= 32'd0;
                    dir_end_seen            <= 1'b0;
                    dir_limit_seen          <= 1'b0;
                    state                   <= ST_READ_LBA0;
                end
            end

            ST_READ_LBA0: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_data_valid) begin
                    case (sector_byte_index)
                        9'd450, 9'd466, 9'd482, 9'd498:
                            mbr_entry_type <= sd_sec_read_data;
                        9'd454, 9'd470, 9'd486, 9'd502:
                            mbr_entry_start[7:0] <= sd_sec_read_data;
                        9'd455, 9'd471, 9'd487, 9'd503:
                            mbr_entry_start[15:8] <= sd_sec_read_data;
                        9'd456, 9'd472, 9'd488, 9'd504:
                            mbr_entry_start[23:16] <= sd_sec_read_data;
                        9'd457, 9'd473, 9'd489, 9'd505: begin
                            mbr_entry_start[31:24] <= sd_sec_read_data;
                            if (!mbr_partition_found &&
                                ((mbr_entry_type == 8'h0B) || (mbr_entry_type == 8'h0C)) &&
                                ({sd_sec_read_data, mbr_entry_start[23:0]} != 32'd0)) begin
                                mbr_partition_found <= 1'b1;
                                mbr_partition_start <= {sd_sec_read_data,
                                                        mbr_entry_start[23:0]};
                            end
                        end
                        9'd510: mbr_signature_55 <= (sd_sec_read_data == 8'h55);
                        9'd511: mbr_signature_aa <= (sd_sec_read_data == 8'hAA);
                        default: ;
                    endcase
                    sector_byte_index <= sector_byte_index + 9'd1;
                end

                if (sd_sec_read_end) begin
                    sd_sec_read       <= 1'b0;
                    sector_byte_index <= 9'd0;
                    state             <= ST_PARSE_LBA0;
                end
            end

            ST_PARSE_LBA0: begin
                sd_sec_read <= 1'b0;

                if (!mbr_signature_55 || !mbr_signature_aa) begin
                    done  <= 1'b1;
                    error <= 1'b1;
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end else begin
                    boot_sector_lba <= mbr_partition_found ? mbr_partition_start : 32'd0;
                    sd_sec_read_addr <= mbr_partition_found ? mbr_partition_start : 32'd0;
                    boot_signature_55       <= 1'b0;
                    boot_signature_aa       <= 1'b0;
                    bpb_bytes_per_sector    <= 16'd0;
                    bpb_sectors_per_cluster <= 8'd0;
                    bpb_reserved_sectors    <= 16'd0;
                    bpb_fat_count           <= 8'd0;
                    bpb_root_entry_count    <= 16'd0;
                    bpb_fat_size16          <= 16'd0;
                    bpb_fat_size32          <= 32'd0;
                    bpb_root_cluster        <= 32'd0;
                    boot_bpb_invalid        <= 1'b0;
                    sector_byte_index       <= 9'd0;
                    state                   <= ST_READ_BOOT;
                end
            end

            ST_READ_BOOT: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_data_valid) begin
                    case (sector_byte_index)
                        9'd11: bpb_bytes_per_sector[7:0] <= sd_sec_read_data;
                        9'd12: bpb_bytes_per_sector[15:8] <= sd_sec_read_data;
                        9'd13: bpb_sectors_per_cluster <= sd_sec_read_data;
                        9'd14: bpb_reserved_sectors[7:0] <= sd_sec_read_data;
                        9'd15: bpb_reserved_sectors[15:8] <= sd_sec_read_data;
                        9'd16: bpb_fat_count <= sd_sec_read_data;
                        9'd17: bpb_root_entry_count[7:0] <= sd_sec_read_data;
                        9'd18: bpb_root_entry_count[15:8] <= sd_sec_read_data;
                        9'd22: bpb_fat_size16[7:0] <= sd_sec_read_data;
                        9'd23: bpb_fat_size16[15:8] <= sd_sec_read_data;
                        9'd36: bpb_fat_size32[7:0] <= sd_sec_read_data;
                        9'd37: bpb_fat_size32[15:8] <= sd_sec_read_data;
                        9'd38: bpb_fat_size32[23:16] <= sd_sec_read_data;
                        9'd39: bpb_fat_size32[31:24] <= sd_sec_read_data;
                        9'd44: bpb_root_cluster[7:0] <= sd_sec_read_data;
                        9'd45: bpb_root_cluster[15:8] <= sd_sec_read_data;
                        9'd46: bpb_root_cluster[23:16] <= sd_sec_read_data;
                        9'd47: bpb_root_cluster[31:24] <= sd_sec_read_data;
                        9'd510: boot_signature_55 <= (sd_sec_read_data == 8'h55);
                        9'd511: boot_signature_aa <= (sd_sec_read_data == 8'hAA);
                        default: ;
                    endcase
                    sector_byte_index <= sector_byte_index + 9'd1;
                end

                if (sd_sec_read_end) begin
                    sd_sec_read       <= 1'b0;
                    sector_byte_index <= 9'd0;
                    state             <= ST_PARSE_BOOT;
                end
            end

            ST_PARSE_BOOT: begin
                sd_sec_read <= 1'b0;

                boot_bpb_invalid <= !boot_signature_55 || !boot_signature_aa ||
                                    (bpb_bytes_per_sector != 16'd512) ||
                                    !is_power_of_two(bpb_sectors_per_cluster) ||
                                    (bpb_sectors_per_cluster > 8'd128) ||
                                    (bpb_reserved_sectors == 16'd0) ||
                                    (bpb_fat_count == 8'd0) ||
                                    (bpb_root_entry_count != 16'd0) ||
                                    (bpb_fat_size16 != 16'd0) ||
                                    (bpb_fat_size32 == 32'd0) ||
                                    (bpb_root_cluster < 32'd2);
                layout_fat_start_lba <= boot_sector_lba +
                                        {16'd0, bpb_reserved_sectors};
                layout_fat_sectors <= bpb_fat_count * bpb_fat_size32;
                layout_root_cluster_delta <= bpb_root_cluster - 32'd2;
                state <= ST_CHECK_BOOT_BPB;
            end

            ST_CHECK_BOOT_BPB: begin
                sd_sec_read <= 1'b0;

                if (boot_bpb_invalid) begin
                    done  <= 1'b1;
                    error <= 1'b1;
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end else begin
                    state <= ST_CALC_DATA_LBA;
                end
            end

            ST_CALC_DATA_LBA: begin
                sd_sec_read <= 1'b0;
                first_fat_lba <= layout_fat_start_lba;
                first_data_lba <= layout_fat_start_lba + layout_fat_sectors;
                state <= ST_CALC_ROOT_OFFSET;
            end

            ST_CALC_ROOT_OFFSET: begin
                sd_sec_read <= 1'b0;
                layout_root_sector_offset <= layout_root_cluster_delta *
                                             bpb_sectors_per_cluster;
                state <= ST_START_DIR;
            end

            ST_START_DIR: begin
                sd_sec_read <= 1'b0;
                volume_first_fat_lba <= first_fat_lba;
                volume_first_data_lba <= first_data_lba;
                volume_sectors_per_cluster <= bpb_sectors_per_cluster;
                current_dir_cluster <= bpb_root_cluster;
                current_dir_sector_lba <= first_data_lba + layout_root_sector_offset;
                sd_sec_read_addr <= first_data_lba + layout_root_sector_offset;
                    dir_sector_in_cluster <= 8'd0;
                    dir_clusters_seen     <= 16'd1;
                    dir_end_seen          <= 1'b0;
                    dir_limit_seen        <= 1'b0;
                state <= ST_READ_DIR;
            end

            ST_READ_DIR: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_data_valid) begin
                    case (sector_byte_index[4:0])
                        5'd0: begin
                            dir_entry_first_byte <= sd_sec_read_data;
                            dir_entry_name[87:80] <= sd_sec_read_data;
                            dir_entry_attr <= 8'd0;
                            dir_entry_first_cluster <= 32'd0;
                            dir_entry_size <= 32'd0;
                            if (sd_sec_read_data == 8'h00)
                                dir_end_seen <= 1'b1;
                        end
                        5'd1:  dir_entry_name[79:72] <= sd_sec_read_data;
                        5'd2:  dir_entry_name[71:64] <= sd_sec_read_data;
                        5'd3:  dir_entry_name[63:56] <= sd_sec_read_data;
                        5'd4:  dir_entry_name[55:48] <= sd_sec_read_data;
                        5'd5:  dir_entry_name[47:40] <= sd_sec_read_data;
                        5'd6:  dir_entry_name[39:32] <= sd_sec_read_data;
                        5'd7:  dir_entry_name[31:24] <= sd_sec_read_data;
                        5'd8:  dir_entry_name[23:16] <= sd_sec_read_data;
                        5'd9:  dir_entry_name[15:8] <= sd_sec_read_data;
                        5'd10: dir_entry_name[7:0] <= sd_sec_read_data;
                        5'd11: dir_entry_attr <= sd_sec_read_data;
                        5'd20: dir_entry_first_cluster[23:16] <= sd_sec_read_data;
                        5'd21: dir_entry_first_cluster[31:24] <= sd_sec_read_data;
                        5'd26: dir_entry_first_cluster[7:0] <= sd_sec_read_data;
                        5'd27: dir_entry_first_cluster[15:8] <= sd_sec_read_data;
                        5'd28: dir_entry_size[7:0] <= sd_sec_read_data;
                        5'd29: dir_entry_size[15:8] <= sd_sec_read_data;
                        5'd30: dir_entry_size[23:16] <= sd_sec_read_data;
                        5'd31: begin
                            dir_entry_size[31:24] <= sd_sec_read_data;
                            if (!dir_end_seen && (file_count < MAX_FILES) &&
                                is_regular_bmp(dir_entry_first_byte, dir_entry_attr,
                                               dir_entry_name, dir_entry_first_cluster,
                                               {sd_sec_read_data, dir_entry_size[23:0]})) begin
                                file_found         <= 1'b1;
                                file_name          <= dir_entry_name;
                                file_first_cluster <= dir_entry_first_cluster;
                                file_size          <= {sd_sec_read_data, dir_entry_size[23:0]};
                                file_count         <= file_count + 4'd1;
                                if ((file_count + 4'd1) >= MAX_FILES)
                                    dir_limit_seen <= 1'b1;
                            end
                            if (!bgm_found &&
                                is_bgm_wav(dir_entry_first_byte, dir_entry_attr,
                                           dir_entry_name, dir_entry_first_cluster,
                                           {sd_sec_read_data, dir_entry_size[23:0]}, 1'b0)) begin
                                bgm_found         <= 1'b1;
                                bgm_first_cluster <= dir_entry_first_cluster;
                                bgm_size          <= {sd_sec_read_data, dir_entry_size[23:0]};
                            end
                            if (!bgm2_found &&
                                is_bgm_wav(dir_entry_first_byte, dir_entry_attr,
                                           dir_entry_name, dir_entry_first_cluster,
                                           {sd_sec_read_data, dir_entry_size[23:0]}, 1'b1)) begin
                                bgm2_found         <= 1'b1;
                                bgm2_first_cluster <= dir_entry_first_cluster;
                                bgm2_size          <= {sd_sec_read_data, dir_entry_size[23:0]};
                            end
                        end
                        default: ;
                    endcase
                    sector_byte_index <= sector_byte_index + 9'd1;
                end

                if (sd_sec_read_end) begin
                    sd_sec_read       <= 1'b0;
                    sector_byte_index <= 9'd0;

                    if (dir_end_seen) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= ST_IDLE;
                    end else if ((dir_sector_in_cluster + 8'd1) < bpb_sectors_per_cluster) begin
                        dir_sector_in_cluster     <= dir_sector_in_cluster + 8'd1;
                        current_dir_sector_lba    <= current_dir_sector_lba + 32'd1;
                        sd_sec_read_addr          <= current_dir_sector_lba + 32'd1;
                    end else begin
                        fat_byte_offset <= {current_dir_cluster[6:0], 2'b00};
                        fat_next_cluster <= 32'd0;
                        sd_sec_read_addr <= first_fat_lba + (current_dir_cluster >> 7);
                        state            <= ST_READ_FAT;
                    end
                end
            end

            ST_READ_FAT: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_data_valid) begin
                    if (sector_byte_index == fat_byte_offset)
                        fat_next_cluster[7:0] <= sd_sec_read_data;
                    else if (sector_byte_index == (fat_byte_offset + 9'd1))
                        fat_next_cluster[15:8] <= sd_sec_read_data;
                    else if (sector_byte_index == (fat_byte_offset + 9'd2))
                        fat_next_cluster[23:16] <= sd_sec_read_data;
                    else if (sector_byte_index == (fat_byte_offset + 9'd3))
                        fat_next_cluster[31:24] <= sd_sec_read_data;
                    sector_byte_index <= sector_byte_index + 9'd1;
                end

                if (sd_sec_read_end) begin
                    sd_sec_read       <= 1'b0;
                    sector_byte_index <= 9'd0;
                    state             <= ST_PARSE_FAT;
                end
            end

            ST_PARSE_FAT: begin
                sd_sec_read <= 1'b0;

                if (fat_next_cluster[27:0] >= 28'hFFFFFF8) begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end else if ((fat_next_cluster[27:0] < 28'd2) ||
                             (fat_next_cluster[27:0] == 28'hFFFFFF7) ||
                             (dir_clusters_seen >= MAX_ROOT_DIR_CLUSTERS)) begin
                    done  <= 1'b1;
                    error <= 1'b1;
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end else begin
                    next_dir_cluster <= {4'd0, fat_next_cluster[27:0]};
                    next_dir_cluster_delta <= {4'd0, fat_next_cluster[27:0]} -
                                              32'd2;
                    state <= ST_CALC_NEXT_DIR_OFFSET;
                end
            end

            ST_CALC_NEXT_DIR_OFFSET: begin
                sd_sec_read <= 1'b0;
                next_dir_sector_offset <= next_dir_cluster_delta *
                                          bpb_sectors_per_cluster;
                state <= ST_START_NEXT_DIR;
            end

            ST_START_NEXT_DIR: begin
                sd_sec_read <= 1'b0;
                current_dir_cluster <= next_dir_cluster;
                current_dir_sector_lba <= first_data_lba + next_dir_sector_offset;
                sd_sec_read_addr <= first_data_lba + next_dir_sector_offset;
                dir_sector_in_cluster <= 8'd0;
                dir_clusters_seen <= dir_clusters_seen + 16'd1;
                state <= ST_READ_DIR;
            end

            default: begin
                state       <= ST_IDLE;
                busy        <= 1'b0;
                sd_sec_read <= 1'b0;
            end
        endcase
    end
end

endmodule
