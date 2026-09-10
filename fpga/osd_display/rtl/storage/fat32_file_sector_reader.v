`timescale 1ns/1ps

module fat32_file_sector_reader #(
    parameter [15:0] MAX_FILE_CLUSTERS = 16'd4096
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

    output reg         busy,
    output reg         done,
    output reg         error,

    input  wire        file_sec_read,
    input  wire [31:0] file_sec_index,
    output reg         file_sec_read_ack,
    output reg [7:0]   file_sec_data,
    output reg         file_sec_data_valid,
    output reg         file_sec_read_end,
    output reg         file_complete,

    output reg         sd_sec_read,
    output reg [31:0]  sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

localparam [2:0] ST_IDLE      = 3'd0;
localparam [2:0] ST_READY     = 3'd1;
localparam [2:0] ST_READ_DATA = 3'd2;
localparam [2:0] ST_READ_FAT  = 3'd3;
localparam [2:0] ST_PARSE_FAT = 3'd4;
localparam [2:0] ST_CALC_CLUSTER_DELTA = 3'd5;
localparam [2:0] ST_CALC_CLUSTER_OFFSET = 3'd6;

reg [2:0]  state;
reg [31:0] first_fat_lba_latched;
reg [31:0] first_data_lba_latched;
reg [7:0]  sectors_per_cluster_latched;
reg [31:0] total_file_sectors;
reg [31:0] next_file_sec_index;
reg [31:0] current_cluster;
reg [31:0] current_cluster_delta;
reg [31:0] current_cluster_sector_offset;
reg [7:0]  sector_in_cluster;
reg [15:0] clusters_seen;
reg [8:0]  sector_byte_index;
reg [8:0]  fat_byte_offset;
reg [31:0] fat_next_cluster;
reg         request_is_final;

function is_power_of_two;
    input [7:0] value;
    begin
        is_power_of_two = (value != 8'd0) && ((value & (value - 8'd1)) == 8'd0);
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state                       <= ST_IDLE;
        busy                        <= 1'b0;
        done                        <= 1'b0;
        error                       <= 1'b0;
        file_sec_read_ack           <= 1'b0;
        file_sec_data               <= 8'd0;
        file_sec_data_valid         <= 1'b0;
        file_sec_read_end           <= 1'b0;
        file_complete               <= 1'b0;
        sd_sec_read                 <= 1'b0;
        sd_sec_read_addr            <= 32'd0;
        first_fat_lba_latched       <= 32'd0;
        first_data_lba_latched      <= 32'd0;
        sectors_per_cluster_latched <= 8'd0;
        total_file_sectors          <= 32'd0;
        next_file_sec_index         <= 32'd0;
        current_cluster             <= 32'd0;
        current_cluster_delta       <= 32'd0;
        current_cluster_sector_offset <= 32'd0;
        sector_in_cluster           <= 8'd0;
        clusters_seen               <= 16'd0;
        sector_byte_index           <= 9'd0;
        fat_byte_offset             <= 9'd0;
        fat_next_cluster            <= 32'd0;
        request_is_final            <= 1'b0;
    end else begin
        done                <= 1'b0;
        error               <= 1'b0;
        file_sec_read_ack   <= 1'b0;
        file_sec_data_valid <= 1'b0;
        file_sec_read_end   <= 1'b0;
        file_complete       <= 1'b0;

        if (abort && (state != ST_IDLE)) begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            sd_sec_read <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    busy        <= 1'b0;
                    sd_sec_read <= 1'b0;

                    if (start) begin
                        if ((file_first_cluster < 32'd2) ||
                            (file_size == 32'd0) ||
                            !is_power_of_two(sectors_per_cluster) ||
                            (sectors_per_cluster > 8'd128)) begin
                            done  <= 1'b1;
                            error <= 1'b1;
                        end else begin
                            busy                        <= 1'b1;
                            first_fat_lba_latched       <= first_fat_lba;
                            first_data_lba_latched      <= first_data_lba;
                            sectors_per_cluster_latched <= sectors_per_cluster;
                            total_file_sectors <= (file_size >> 9) +
                                                  ((file_size[8:0] != 9'd0) ? 32'd1 : 32'd0);
                            next_file_sec_index <= 32'd0;
                            current_cluster     <= file_first_cluster;
                            current_cluster_delta <= 32'd0;
                            current_cluster_sector_offset <= 32'd0;
                            sector_in_cluster   <= 8'd0;
                            clusters_seen       <= 16'd1;
                            state               <= ST_CALC_CLUSTER_DELTA;
                        end
                    end
                end

                ST_READY: begin
                    sd_sec_read <= 1'b0;

                    if (file_sec_read) begin
                        if ((file_sec_index != next_file_sec_index) ||
                            (file_sec_index >= total_file_sectors)) begin
                            done  <= 1'b1;
                            error <= 1'b1;
                            busy  <= 1'b0;
                            state <= ST_IDLE;
                        end else begin
                            file_sec_read_ack <= 1'b1;
                            request_is_final <= ((file_sec_index + 32'd1) >= total_file_sectors);
                            sd_sec_read_addr <= first_data_lba_latched +
                                                current_cluster_sector_offset +
                                                {24'd0, sector_in_cluster};
                            sector_byte_index <= 9'd0;
                            state <= ST_READ_DATA;
                        end
                    end
                end

                ST_READ_DATA: begin
                    sd_sec_read <= 1'b1;

                    if (sd_sec_read_data_valid) begin
                        file_sec_data       <= sd_sec_read_data;
                        file_sec_data_valid <= 1'b1;
                    end

                    if (sd_sec_read_end) begin
                        sd_sec_read       <= 1'b0;
                        file_sec_read_end <= 1'b1;
                        next_file_sec_index <= next_file_sec_index + 32'd1;

                        if (request_is_final) begin
                            file_complete <= 1'b1;
                            done          <= 1'b1;
                            busy          <= 1'b0;
                            state         <= ST_IDLE;
                        end else if ((sector_in_cluster + 8'd1) <
                                     sectors_per_cluster_latched) begin
                            sector_in_cluster <= sector_in_cluster + 8'd1;
                            state             <= ST_READY;
                        end else begin
                            fat_byte_offset   <= {current_cluster[6:0], 2'b00};
                            fat_next_cluster  <= 32'd0;
                            sector_byte_index <= 9'd0;
                            sd_sec_read_addr  <= first_fat_lba_latched +
                                                 (current_cluster >> 7);
                            state <= ST_READ_FAT;
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

                    if ((fat_next_cluster[27:0] < 28'd2) ||
                        (fat_next_cluster[27:0] >= 28'hFFFFFF0) ||
                        (clusters_seen >= MAX_FILE_CLUSTERS)) begin
                        done  <= 1'b1;
                        error <= 1'b1;
                        busy  <= 1'b0;
                        state <= ST_IDLE;
                    end else begin
                        current_cluster   <= {4'd0, fat_next_cluster[27:0]};
                        sector_in_cluster <= 8'd0;
                        clusters_seen     <= clusters_seen + 16'd1;
                        state             <= ST_CALC_CLUSTER_DELTA;
                    end
                end

                ST_CALC_CLUSTER_DELTA: begin
                    sd_sec_read <= 1'b0;
                    current_cluster_delta <= current_cluster - 32'd2;
                    state <= ST_CALC_CLUSTER_OFFSET;
                end

                ST_CALC_CLUSTER_OFFSET: begin
                    sd_sec_read <= 1'b0;
                    current_cluster_sector_offset <= current_cluster_delta *
                                                     sectors_per_cluster_latched;
                    state <= ST_READY;
                end

                default: begin
                    state       <= ST_IDLE;
                    busy        <= 1'b0;
                    sd_sec_read <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
