`timescale 1ns/1ps

module tb_fat32_wav_loader;

localparam integer DISK_SECTORS = 160;
localparam integer PCM_FRAMES = 128;

reg clk = 1'b0;
reg rst = 1'b1;
reg start = 1'b0;
reg abort = 1'b0;
reg [31:0] file_first_cluster = 32'd2;
reg [31:0] file_size = 32'd0;
reg [31:0] first_fat_lba = 32'd20;
reg [31:0] first_data_lba = 32'd100;
reg [7:0] sectors_per_cluster = 8'd1;
reg [9:0] fifo_wrusedw = 10'd0;
reg fifo_full = 1'b0;
wire audio_frame_wr_en;
wire [31:0] audio_frame_wr_data;
wire busy;
wire error;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
reg [7:0] sd_sec_read_data = 8'd0;
reg sd_sec_read_data_valid = 1'b0;
reg sd_sec_read_end = 1'b0;

reg [7:0] disk [0:(DISK_SECTORS * 512)-1];
reg serving = 1'b0;
reg end_pending = 1'b0;
reg request_complete = 1'b0;
reg [31:0] active_sector = 32'd0;
reg [8:0] response_byte_index = 9'd0;
integer request_count = 0;
reg [31:0] request_log [0:31];
integer frame_count = 0;
reg [31:0] captured_frame [0:191];
reg error_seen = 1'b0;

always #5 clk = ~clk;

fat32_wav_loader dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .abort(abort),
    .file_first_cluster(file_first_cluster),
    .file_size(file_size),
    .first_fat_lba(first_fat_lba),
    .first_data_lba(first_data_lba),
    .sectors_per_cluster(sectors_per_cluster),
    .fifo_wrusedw(fifo_wrusedw),
    .fifo_full(fifo_full),
    .audio_frame_wr_en(audio_frame_wr_en),
    .audio_frame_wr_data(audio_frame_wr_data),
    .busy(busy),
    .error(error),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end)
);

// Model the SD-sector contract used by the file reader: a request stays high
// until 512 bytes have been emitted and the end pulse has followed.
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
        sd_sec_read_data <= disk[(active_sector * 512) + response_byte_index];
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
        request_log[request_count] <= sd_sec_read_addr;
        request_count <= request_count + 1;
    end
end

always @(posedge audio_frame_wr_en) begin
    captured_frame[frame_count] = audio_frame_wr_data;
    frame_count = frame_count + 1;
end

always @(posedge error) begin
    error_seen = 1'b1;
    $display("wav error: loader=%0d parser=%0d reader=%0d file_byte=%0d fmt_idx=%0d last=%h fmt=%h channels=%h rate=%0d byte_rate=%0d align=%h bits=%h validbits=%h guidok=%0b chunk=%h remain=%0d",
             dut.loader_state, dut.parser_state, dut.u_file_sector_reader.state,
             dut.file_byte_index, dut.fmt_byte_index, dut.reader_file_sec_data,
             dut.fmt_format_code, dut.fmt_channels,
             dut.fmt_sample_rate, dut.fmt_byte_rate, dut.fmt_block_align,
             dut.fmt_bits_per_sample, dut.fmt_valid_bits_per_sample,
             dut.fmt_extensible_pcm_valid, dut.chunk_size, dut.chunk_remaining);
end

task automatic expect_bit;
    input actual;
    input expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0b, got %0b", checkpoint, expected, actual);
    end
endtask

task automatic expect_value;
    input [31:0] actual;
    input [31:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic expect_frame;
    input integer index;
    input [15:0] left_value;
    input [15:0] right_value;
    input [255:0] checkpoint;
    begin
        if (captured_frame[index] !== {left_value, right_value})
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint,
                   {left_value, right_value}, captured_frame[index]);
    end
endtask

task automatic put_byte;
    input integer sector;
    input integer offset;
    input [7:0] value;
    begin
        disk[(sector * 512) + offset] = value;
    end
endtask

task automatic put_le16;
    input integer sector;
    input integer offset;
    input [15:0] value;
    begin
        put_byte(sector, offset, value[7:0]);
        put_byte(sector, offset + 1, value[15:8]);
    end
endtask

task automatic put_le24;
    input integer sector;
    input integer offset;
    input [23:0] value;
    begin
        put_byte(sector, offset, value[7:0]);
        put_byte(sector, offset + 1, value[15:8]);
        put_byte(sector, offset + 2, value[23:16]);
    end
endtask

task automatic put_le32;
    input integer sector;
    input integer offset;
    input [31:0] value;
    begin
        put_byte(sector, offset, value[7:0]);
        put_byte(sector, offset + 1, value[15:8]);
        put_byte(sector, offset + 2, value[23:16]);
        put_byte(sector, offset + 3, value[31:24]);
    end
endtask

task automatic put_file_byte;
    input integer file_offset;
    input [7:0] value;
    integer sector;
    integer offset;
    begin
        if (file_offset < 512) begin
            sector = 100;
            offset = file_offset;
        end else begin
            sector = 103;
            offset = file_offset - 512;
        end
        put_byte(sector, offset, value);
    end
endtask

task automatic put_file_le16;
    input integer file_offset;
    input [15:0] value;
    begin
        put_file_byte(file_offset, value[7:0]);
        put_file_byte(file_offset + 1, value[15:8]);
    end
endtask

task automatic put_file_le24;
    input integer file_offset;
    input [23:0] value;
    begin
        put_file_byte(file_offset, value[7:0]);
        put_file_byte(file_offset + 1, value[15:8]);
        put_file_byte(file_offset + 2, value[23:16]);
    end
endtask

task automatic put_file_le32;
    input integer file_offset;
    input [31:0] value;
    begin
        put_file_byte(file_offset, value[7:0]);
        put_file_byte(file_offset + 1, value[15:8]);
        put_file_byte(file_offset + 2, value[23:16]);
        put_file_byte(file_offset + 3, value[31:24]);
    end
endtask

task automatic clear_disk;
    integer index;
    begin
        for (index = 0; index < (DISK_SECTORS * 512); index = index + 1)
            disk[index] = 8'd0;
    end
endtask

task automatic clear_observations;
    integer index;
    begin
        request_count = 0;
        frame_count = 0;
        error_seen = 1'b0;
        for (index = 0; index < 32; index = index + 1)
            request_log[index] = 32'd0;
        for (index = 0; index < 192; index = index + 1)
            captured_frame[index] = 32'd0;
    end
endtask

task automatic make_valid_wav;
    integer index;
    begin
        // RIFF/WAVE, followed by a one-byte padded JUNK chunk. The data
        // payload crosses a file-sector and FAT-cluster boundary.
        put_file_byte(0, 8'h52);
        put_file_byte(1, 8'h49);
        put_file_byte(2, 8'h46);
        put_file_byte(3, 8'h46);
        put_file_le32(4, 32'd558);
        put_file_byte(8, 8'h57);
        put_file_byte(9, 8'h41);
        put_file_byte(10, 8'h56);
        put_file_byte(11, 8'h45);
        put_file_byte(12, 8'h4A);
        put_file_byte(13, 8'h55);
        put_file_byte(14, 8'h4E);
        put_file_byte(15, 8'h4B);
        put_file_le32(16, 32'd1);
        put_file_byte(20, 8'hA5);
        put_file_byte(21, 8'h00);
        put_file_byte(22, 8'h66);
        put_file_byte(23, 8'h6D);
        put_file_byte(24, 8'h74);
        put_file_byte(25, 8'h20);
        put_file_le32(26, 32'd16);
        put_file_le16(30, 16'd1);
        put_file_le16(32, 16'd2);
        put_file_le32(34, 32'd48000);
        put_file_le32(38, 32'd192000);
        put_file_le16(42, 16'd4);
        put_file_le16(44, 16'd16);
        put_file_byte(46, 8'h64);
        put_file_byte(47, 8'h61);
        put_file_byte(48, 8'h74);
        put_file_byte(49, 8'h61);
        put_file_le32(50, PCM_FRAMES * 4);
        for (index = 0; index < PCM_FRAMES; index = index + 1) begin
            put_file_le16(54 + (index * 4), 16'h1000 + index);
            put_file_le16(56 + (index * 4), 16'h2000 + index);
        end
    end
endtask

task automatic make_extensible_pcm_wav;
    begin
        // This matches the official lab_ex5_i2s python/1.wav container:
        // WAVE_FORMAT_EXTENSIBLE with the PCM subtype GUID, an INFO/LIST
        // chunk, then 24-bit stereo PCM data.
        put_file_byte(0, 8'h52);
        put_file_byte(1, 8'h49);
        put_file_byte(2, 8'h46);
        put_file_byte(3, 8'h46);
        put_file_le32(4, 32'd106);
        put_file_byte(8, 8'h57);
        put_file_byte(9, 8'h41);
        put_file_byte(10, 8'h56);
        put_file_byte(11, 8'h45);
        put_file_byte(12, 8'h66);
        put_file_byte(13, 8'h6D);
        put_file_byte(14, 8'h74);
        put_file_byte(15, 8'h20);
        put_file_le32(16, 32'd40);
        put_file_le16(20, 16'hFFFE);
        put_file_le16(22, 16'd2);
        put_file_le32(24, 32'd48000);
        put_file_le32(28, 32'd288000);
        put_file_le16(32, 16'd6);
        put_file_le16(34, 16'd24);
        put_file_le16(36, 16'd22);
        put_file_le16(38, 16'd24);
        put_file_le32(40, 32'd3);
        // KSDATAFORMAT_SUBTYPE_PCM, little-endian GUID byte order.
        put_file_byte(44, 8'h01);
        put_file_byte(45, 8'h00);
        put_file_byte(46, 8'h00);
        put_file_byte(47, 8'h00);
        put_file_byte(48, 8'h00);
        put_file_byte(49, 8'h00);
        put_file_byte(50, 8'h10);
        put_file_byte(51, 8'h00);
        put_file_byte(52, 8'h80);
        put_file_byte(53, 8'h00);
        put_file_byte(54, 8'h00);
        put_file_byte(55, 8'hAA);
        put_file_byte(56, 8'h00);
        put_file_byte(57, 8'h38);
        put_file_byte(58, 8'h9B);
        put_file_byte(59, 8'h71);
        put_file_byte(60, 8'h4C);
        put_file_byte(61, 8'h49);
        put_file_byte(62, 8'h53);
        put_file_byte(63, 8'h54);
        put_file_le32(64, 32'd18);
        put_file_byte(68, 8'h49);
        put_file_byte(69, 8'h4E);
        put_file_byte(70, 8'h46);
        put_file_byte(71, 8'h4F);
        put_file_byte(72, 8'h49);
        put_file_byte(73, 8'h53);
        put_file_byte(74, 8'h46);
        put_file_byte(75, 8'h54);
        put_file_le32(76, 32'd6);
        put_file_byte(80, 8'h54);
        put_file_byte(81, 8'h65);
        put_file_byte(82, 8'h73);
        put_file_byte(83, 8'h74);
        put_file_byte(84, 8'h00);
        put_file_byte(85, 8'h00);
        put_file_byte(86, 8'h64);
        put_file_byte(87, 8'h61);
        put_file_byte(88, 8'h74);
        put_file_byte(89, 8'h61);
        put_file_le32(90, 32'd12);
        put_file_le24(94, 24'h123456);
        put_file_le24(97, 24'h654321);
        put_file_le24(100, 24'h234567);
        put_file_le24(103, 24'h765432);
    end
endtask

task automatic start_loader;
    begin
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endtask

initial begin
    clear_disk();
    clear_observations();
    repeat (2) @(posedge clk);
    rst = 1'b0;

    clear_disk();
    clear_observations();
    // Cluster 2 is LBA 100. Its FAT entry points to fragmented cluster 5,
    // which maps to LBA 103.
    put_le32(20, 8, 32'd5);
    make_valid_wav();
    file_size = 32'd566;
    $display("TEST padded fragmented 16-bit WAV and loop");
    start_loader();
    while (frame_count < (PCM_FRAMES + 2))
        @(posedge clk);
    #1;
    expect_bit(error, 1'b0, "valid WAV has no error");
    expect_frame(0, 16'h1000, 16'h2000, "first PCM frame byte order");
    expect_frame(113, 16'h1071, 16'h2071, "frame before sector boundary");
    expect_frame(114, 16'h1072, 16'h2072, "frame crosses sector boundary");
    expect_frame(115, 16'h1073, 16'h2073, "frame after sector boundary");
    expect_frame(127, 16'h107F, 16'h207F, "last PCM frame");
    expect_frame(128, 16'h1000, 16'h2000, "loop restarts from first frame");
    expect_frame(129, 16'h1001, 16'h2001, "loop second frame");
    expect_value(request_log[0], 32'd100, "first WAV sector request");
    expect_value(request_log[1], 32'd20, "fragmented WAV FAT request");
    expect_value(request_log[2], 32'd103, "fragmented successor request");
    expect_value(request_log[3], 32'd100, "loop rereads first sector");

    @(negedge clk);
    abort = 1'b1;
    @(negedge clk);
    abort = 1'b0;
    repeat (3) @(posedge clk);
    while (serving || end_pending || request_complete)
        @(posedge clk);

    // The official I2S lab's 1.wav uses the extensible PCM container. Its
    // format, LIST metadata, and PCM subtype must work without conversion.
    @(negedge clk);
    rst = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);
    clear_disk();
    clear_observations();
    make_extensible_pcm_wav();
    file_size = 32'd106;
    $display("TEST official-style extensible PCM WAV");
    start_loader();
    while (frame_count < 3)
        @(posedge clk);
    #1;
    expect_bit(error_seen, 1'b0, "extensible PCM WAV has no error");
    expect_frame(0, 16'h1234, 16'h6543, "extensible first PCM frame truncates LSBs");
    expect_frame(1, 16'h2345, 16'h7654, "extensible second PCM frame truncates LSBs");
    expect_frame(2, 16'h1234, 16'h6543, "extensible PCM loops");
    @(negedge clk);
    abort = 1'b1;
    @(negedge clk);
    abort = 1'b0;
    repeat (3) @(posedge clk);
    while (serving || end_pending || request_complete)
        @(posedge clk);

    // A malformed format field must become audio-only error before emitting
    // a PCM frame.
    @(negedge clk);
    rst = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);
    clear_disk();
    clear_observations();
    put_file_byte(0, 8'h52);
    put_file_byte(1, 8'h49);
    put_file_byte(2, 8'h46);
    put_file_byte(3, 8'h46);
    put_file_byte(8, 8'h57);
    put_file_byte(9, 8'h41);
    put_file_byte(10, 8'h56);
    put_file_byte(11, 8'h45);
    put_file_byte(12, 8'h66);
    put_file_byte(13, 8'h6D);
    put_file_byte(14, 8'h74);
    put_file_byte(15, 8'h20);
    put_file_le32(16, 32'd16);
    put_file_le16(20, 16'd1);
    put_file_le16(22, 16'd2);
    put_file_le32(24, 32'd44100);
    put_file_le32(28, 32'd264600);
    put_file_le16(32, 16'd6);
    put_file_le16(34, 16'd24);
    file_size = 32'd36;
    $display("TEST invalid WAV format");
    start_loader();
    @(posedge error);
    #1;
    expect_value(frame_count, 32'd0, "invalid WAV emits no PCM frames");

    $display("PASS tb_fat32_wav_loader");
    $finish;
end

initial begin
    #1000000;
    $display("wav loader=%0d parser=%0d reader=%0d busy=%0b error=%0b error_seen=%0b frames=%0d requests=%0d data_remaining=%0d file_byte=%0d fmt=%h validbits=%h guidok=%0b",
             dut.loader_state, dut.parser_state, dut.u_file_sector_reader.state,
             busy, error, error_seen, frame_count, request_count,
             dut.data_bytes_remaining, dut.file_byte_index, dut.fmt_format_code,
             dut.fmt_valid_bits_per_sample, dut.fmt_extensible_pcm_valid);
    $fatal(1, "FAIL tb_fat32_wav_loader timed out");
end

endmodule
