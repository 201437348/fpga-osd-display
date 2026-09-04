module image_storage_adapter #(
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]  SCAN_TARGET_COUNT = 3'd4
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
    output wire [3:0]  state_code,

    output wire        write_req,
    input  wire        write_req_ack,
    input  wire        write_fifo_afull,
    output wire        write_en,
    output wire [31:0] write_data,

    output wire        SD_nCS,
    output wire        SD_DCLK,
    output wire        SD_MOSI,
    input  wire        SD_MISO
);

wire        bmp_ready;
wire        raw_scan_done;
wire        raw_scan_found_valid;
wire [31:0] raw_scan_found_sector;
wire [2:0]  raw_scan_found_total;
wire        bmp_data_wr_en;
wire [23:0] bmp_data;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid;
wire        sd_sec_read_end;
wire        sd_init_done;
wire        core_rst;

reg [31:0] image_sector0;
reg [31:0] image_sector1;
reg [31:0] image_sector2;
reg [31:0] image_sector3;
reg        scan_active_seen;
reg        scan_complete_pending;
reg        load_active_seen;
reg        write_req_ack_meta;
reg        write_req_ack_sync;

wire [31:0] load_sector;

assign storage_ready = sd_init_done;
assign write_en      = bmp_data_wr_en;
assign write_data    = {bmp_data, 8'b0};
assign core_rst      = rst | storage_reinit;

// write_req_ack is generated in ext_mem_clk; bmp_read consumes it in clk.
always @(posedge clk or posedge core_rst) begin
    if (core_rst) begin
        write_req_ack_meta <= 1'b0;
        write_req_ack_sync <= 1'b0;
    end else begin
        write_req_ack_meta <= write_req_ack;
        write_req_ack_sync <= write_req_ack_meta;
    end
end

function [31:0] sector_for_index;
    input [1:0] index;
    begin
        case (index)
            2'd0: sector_for_index = image_sector0;
            2'd1: sector_for_index = image_sector1;
            2'd2: sector_for_index = image_sector2;
            default: sector_for_index = image_sector3;
        endcase
    end
endfunction

assign load_sector = sector_for_index(target_image_index);

always @(posedge clk or posedge core_rst) begin
    if (core_rst) begin
        image_sector0        <= 32'd0;
        image_sector1        <= 32'd0;
        image_sector2        <= 32'd0;
        image_sector3        <= 32'd0;
        scan_found_count     <= 3'd0;
        scan_done            <= 1'b0;
        scan_active_seen     <= 1'b0;
        scan_complete_pending <= 1'b0;
        source_done_pulse    <= 1'b0;
        load_active_seen     <= 1'b0;
    end else begin
        source_done_pulse <= 1'b0;

        if (!sd_init_done) begin
            scan_found_count      <= 3'd0;
            scan_done             <= 1'b0;
            scan_active_seen      <= 1'b0;
            scan_complete_pending <= 1'b0;
            load_active_seen      <= 1'b0;
        end else begin
            if (scan_start) begin
                image_sector0        <= 32'd0;
                image_sector1        <= 32'd0;
                image_sector2        <= 32'd0;
                image_sector3        <= 32'd0;
                scan_found_count     <= 3'd0;
                scan_done            <= 1'b0;
                scan_active_seen     <= 1'b0;
                scan_complete_pending <= 1'b0;
            end else begin
                if (!raw_scan_done)
                    scan_active_seen <= 1'b1;

                if (raw_scan_found_valid && (scan_found_count < 3'd4)) begin
                    case (scan_found_count)
                        3'd0: image_sector0 <= raw_scan_found_sector;
                        3'd1: image_sector1 <= raw_scan_found_sector;
                        3'd2: image_sector2 <= raw_scan_found_sector;
                        3'd3: image_sector3 <= raw_scan_found_sector;
                        default: ;
                    endcase
                    scan_found_count <= scan_found_count + 3'd1;
                end

                // Delay completion one cycle so the final sector and count are stable.
                if (scan_complete_pending) begin
                    scan_done             <= 1'b1;
                    scan_complete_pending <= 1'b0;
                end else if (scan_active_seen && raw_scan_done && !scan_done) begin
                    scan_complete_pending <= 1'b1;
                end
            end

            if (load_abort) begin
                load_active_seen <= 1'b0;
            end else if (load_start) begin
                load_active_seen <= 1'b0;
            end else if (!bmp_ready) begin
                load_active_seen <= 1'b1;
            end else if (load_active_seen) begin
                source_done_pulse <= 1'b1;
                load_active_seen  <= 1'b0;
            end
        end
    end
end

bmp_read u_bmp_read (
    .clk                    (clk),
    .rst                    (core_rst),
    .ready                  (bmp_ready),
    .scan_start             (scan_start),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (raw_scan_done),
    .scan_found_valid       (raw_scan_found_valid),
    .scan_found_sector      (raw_scan_found_sector),
    .scan_found_total       (raw_scan_found_total),
    .load_start             (load_start),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (16'd640),
    .bmp_height             (16'd480),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack_sync),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .write_fifo_afull       (write_fifo_afull),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
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
