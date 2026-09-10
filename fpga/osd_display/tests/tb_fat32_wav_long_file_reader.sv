`timescale 1ns/1ps

module tb_fat32_wav_long_file_reader;

localparam integer FILE_CLUSTERS = 4097;
localparam integer FIRST_FAT_LBA = 20;
localparam integer FIRST_DATA_LBA = 100;

reg clk = 1'b0;
reg rst = 1'b1;
reg start = 1'b0;
reg abort = 1'b0;
reg file_sec_read = 1'b0;
reg [31:0] file_sec_index = 32'd0;
wire file_sec_read_ack;
wire [7:0] file_sec_data;
wire file_sec_data_valid;
wire file_sec_read_end;
wire file_complete;
wire busy;
wire done;
wire error;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
reg [7:0] sd_sec_read_data = 8'd0;
reg sd_sec_read_data_valid = 1'b0;
reg sd_sec_read_end = 1'b0;

reg serving = 1'b0;
reg end_pending = 1'b0;
reg request_complete = 1'b0;
reg [31:0] active_sector = 32'd0;
reg [8:0] response_byte_index = 9'd0;
integer sectors_completed = 0;
integer data_bytes_seen = 0;
integer file_sector;
reg done_seen = 1'b0;
reg file_complete_seen = 1'b0;
reg error_seen = 1'b0;

always #5 clk = ~clk;

fat32_file_sector_reader #(
    .MAX_FILE_CLUSTERS(16'hFFFF)
) dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .abort(abort),
    .file_first_cluster(32'd2),
    .file_size(FILE_CLUSTERS * 512),
    .first_fat_lba(FIRST_FAT_LBA),
    .first_data_lba(FIRST_DATA_LBA),
    .sectors_per_cluster(8'd1),
    .busy(busy),
    .done(done),
    .error(error),
    .file_sec_read(file_sec_read),
    .file_sec_index(file_sec_index),
    .file_sec_read_ack(file_sec_read_ack),
    .file_sec_data(file_sec_data),
    .file_sec_data_valid(file_sec_data_valid),
    .file_sec_read_end(file_sec_read_end),
    .file_complete(file_complete),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end)
);

function automatic [7:0] sector_data;
    input [31:0] sector;
    input [8:0] byte_index;
    reg [31:0] fat_entry_index;
    reg [31:0] fat_entry_value;
    begin
        if ((sector >= FIRST_FAT_LBA) &&
            (sector < (FIRST_FAT_LBA + 33))) begin
            fat_entry_index = ((sector - FIRST_FAT_LBA) << 7) +
                              (byte_index >> 2);
            fat_entry_value = fat_entry_index + 32'd1;
            case (byte_index[1:0])
                2'd0: sector_data = fat_entry_value[7:0];
                2'd1: sector_data = fat_entry_value[15:8];
                2'd2: sector_data = fat_entry_value[23:16];
                default: sector_data = fat_entry_value[31:24];
            endcase
        end else begin
            sector_data = byte_index[7:0];
        end
    end
endfunction

always @(posedge clk) begin
    sd_sec_read_data_valid <= 1'b0;
    sd_sec_read_end <= 1'b0;

    if (end_pending) begin
        sd_sec_read_end <= 1'b1;
        end_pending <= 1'b0;
        request_complete <= 1'b1;
    end else if (request_complete) begin
        if (!sd_sec_read)
            request_complete <= 1'b0;
    end else if (serving) begin
        sd_sec_read_data <= sector_data(active_sector, response_byte_index);
        sd_sec_read_data_valid <= 1'b1;
        if (response_byte_index == 9'd511) begin
            serving <= 1'b0;
            end_pending <= 1'b1;
        end else begin
            response_byte_index <= response_byte_index + 9'd1;
        end
    end else if (sd_sec_read) begin
        serving <= 1'b1;
        active_sector <= sd_sec_read_addr;
        response_byte_index <= 9'd0;
    end

    if (file_sec_data_valid)
        data_bytes_seen <= data_bytes_seen + 1;
    if (file_sec_read_end)
        sectors_completed <= sectors_completed + 1;
    if (done)
        done_seen <= 1'b1;
    if (file_complete)
        file_complete_seen <= 1'b1;
    if (error)
        error_seen <= 1'b1;
end

task automatic read_file_sector;
    input integer requested_sector;
    begin
        @(negedge clk);
        file_sec_index = requested_sector;
        file_sec_read = 1'b1;
        while (!file_sec_read_ack)
            @(posedge clk);
        @(negedge clk);
        file_sec_read = 1'b0;
        while (!file_sec_read_end)
            @(posedge clk);
    end
endtask

initial begin
    repeat (2) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    while (!busy)
        @(posedge clk);

    for (file_sector = 0; file_sector < FILE_CLUSTERS; file_sector = file_sector + 1)
        read_file_sector(file_sector);

    repeat (2) @(posedge clk);
    if (error_seen)
        $fatal(1, "FAIL long WAV reader raised error at cluster %0d", FILE_CLUSTERS);
    if (!done_seen || !file_complete_seen)
        $fatal(1, "FAIL long WAV reader did not complete 4097 clusters");
    if (sectors_completed != FILE_CLUSTERS)
        $fatal(1, "FAIL expected %0d sectors, got %0d", FILE_CLUSTERS, sectors_completed);
    if (data_bytes_seen != (FILE_CLUSTERS * 512))
        $fatal(1, "FAIL expected %0d data bytes, got %0d",
               FILE_CLUSTERS * 512, data_bytes_seen);

    $display("PASS tb_fat32_wav_long_file_reader");
    $finish;
end

initial begin
    #200000000;
    $fatal(1, "FAIL tb_fat32_wav_long_file_reader timed out");
end

endmodule
