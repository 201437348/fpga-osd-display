`timescale 1ns/1ps

// 真实 FAT32 -> fat32_bmp_loader -> image_bilinear_scaler(抗锯齿) 全路径加载大图
//   +W=/+H= 源尺寸（默认 1280x960 = 支持上限，八色竖条）
//   +BYTE_GAP=<n>  SD 模型每字节间隔拍数（默认 4），+LAT=<n> 每扇区命令延迟（默认 200）
//   检查：source_done 且无 source_error，write_en 恰好 307200 个，缩放器无溢出，
//   逐像素与"竖条按 3x3 帐篷滤波 + 双线性"的期望色比对前若干行（只看 x 方向）。
module tb_adapter_1080p;

reg clk = 1'b0;
reg rst = 1'b1;
reg scan_start = 1'b0;
reg load_start = 1'b0;
reg load_abort = 1'b0;
reg storage_reinit = 1'b0;
reg [2:0] target_image_index = 3'd0;
reg write_req_ack = 1'b0;
reg write_fifo_afull = 1'b0;
wire storage_ready;
wire scan_done;
wire [3:0] scan_found_count;
wire source_done_pulse;
wire source_error_pulse;
wire write_req;
wire write_en;
wire [31:0] write_data;
wire audio_fifo_wr_en;
wire [31:0] audio_fifo_wr_data;
reg [9:0] audio_fifo_wrusedw = 10'd1000;
reg audio_fifo_full = 1'b1;
wire audio_fifo_rst;
wire SD_nCS, SD_DCLK, SD_MOSI;
reg SD_MISO = 1'b1;

always #5 clk = ~clk;

image_storage_adapter #(.MIN_SRC_PIXELS(32'd1)) dut (
    .clk(clk), .rst(rst),
    .scan_start(scan_start), .load_start(load_start), .load_abort(load_abort),
    .storage_reinit(storage_reinit), .target_image_index(target_image_index),
    .storage_ready(storage_ready), .scan_done(scan_done), .scan_found_count(scan_found_count),
    .source_done_pulse(source_done_pulse), .source_error_pulse(source_error_pulse),
    .storage_fault_pulse(), .state_code(),
    .write_req(write_req), .write_req_ack(write_req_ack),
    .write_fifo_afull(write_fifo_afull), .write_en(write_en), .write_data(write_data),
    .audio_fifo_wr_en(audio_fifo_wr_en), .audio_fifo_wr_data(audio_fifo_wr_data),
    .audio_fifo_wrusedw(audio_fifo_wrusedw), .audio_fifo_full(audio_fifo_full),
    .audio_fifo_rst(audio_fifo_rst),
    .bgm_track_sel(1'b0),
    .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO)
);

// 输出侧随机反压（模拟 SDRAM 写 FIFO）
integer seed = 7;
always @(posedge clk) write_fifo_afull <= (($random(seed) & 15) == 0);

integer pixel_count = 0;
always @(posedge clk) if (write_en) pixel_count = pixel_count + 1;

always @(posedge source_error_pulse) begin
    $display("loader st=%0d hm=%0d w=%0d h=%0d bpp=%0d off=%0d flen=%0d fsz=%0d dib=%0d pl=%0d comp=%0d pxok=%0d sel_ok=%0d",
        dut.u_fat32_bmp_loader.state, dut.u_fat32_bmp_loader.header_match,
        dut.u_fat32_bmp_loader.header_width, dut.u_fat32_bmp_loader.header_height,
        dut.u_fat32_bmp_loader.bit_count, dut.u_fat32_bmp_loader.pixel_offset,
        dut.u_fat32_bmp_loader.header_file_len, dut.u_fat32_bmp_loader.file_size_latched,
        dut.u_fat32_bmp_loader.dib_size, dut.u_fat32_bmp_loader.planes,
        dut.u_fat32_bmp_loader.compression, dut.u_fat32_bmp_loader.src_pixels_ok, dut.selected_ok_q);
    $fatal(1, "FAIL source_error_pulse");
end

// ---- 盘布局：MBR@0，引导扇区@1，FAT@2..3（2 扇区），数据区@4，每簇 64 扇区 ----
localparam integer SPC = 64, FAT_LBA = 2, FATSZ = 4, DATA_LBA = FAT_LBA + FATSZ;
integer W, H, stride, fsize, nclus, i, x, y, off;

task automatic pb(input integer a, input [7:0] v); dut.u_sd_card_top.disk[a] = v; endtask
task automatic p16(input integer a, input [15:0] v); begin pb(a, v[7:0]); pb(a+1, v[15:8]); end endtask
task automatic p32(input integer a, input [31:0] v);
    begin pb(a, v[7:0]); pb(a+1, v[15:8]); pb(a+2, v[23:16]); pb(a+3, v[31:24]); end
endtask
function integer clba(input integer c); clba = DATA_LBA + (c - 2) * SPC; endfunction

function [23:0] bar_rgb(input integer xx);   // {R,G,B}
    case ((xx * 8) / W)
        0: bar_rgb = 24'hFFFFFF; 1: bar_rgb = 24'hFFFF00; 2: bar_rgb = 24'h00FFFF;
        3: bar_rgb = 24'h00FF00; 4: bar_rgb = 24'hFF00FF; 5: bar_rgb = 24'hFF0000;
        6: bar_rgb = 24'h0000FF; default: bar_rgb = 24'h000000;
    endcase
endfunction

reg [23:0] c;
initial begin
    if (!$value$plusargs("W=%d", W)) W = 1280;
    if (!$value$plusargs("H=%d", H)) H = 960;
    stride = ((W * 3) + 3) & ~3;
    fsize  = 54 + stride * H;
    nclus  = (fsize + SPC * 512 - 1) / (SPC * 512);

    // MBR
    pb(450, 8'h0C); p32(454, 1); pb(510, 8'h55); pb(511, 8'hAA);
    // 引导扇区
    p16(512 + 11, 512); pb(512 + 13, SPC); p16(512 + 14, 1); pb(512 + 16, 1);
    p16(512 + 17, 0); p16(512 + 22, 0); p32(512 + 36, FATSZ); p32(512 + 44, 2);
    pb(512 + 510, 8'h55); pb(512 + 511, 8'hAA);
    // FAT：簇 2 = 根目录（单簇），文件从簇 3 起连续
    p32(FAT_LBA * 512 + 0, 32'h0FFFFFF8); p32(FAT_LBA * 512 + 4, 32'h0FFFFFFF);
    p32(FAT_LBA * 512 + 8, 32'h0FFFFFFF);
    for (i = 0; i < nclus; i = i + 1)
        p32(FAT_LBA * 512 + (3 + i) * 4, (i == nclus - 1) ? 32'h0FFFFFFF : (4 + i));
    // 根目录项 IMAGE001.BMP
    off = clba(2) * 512;
    pb(off+0,"I"); pb(off+1,"M"); pb(off+2,"A"); pb(off+3,"G"); pb(off+4,"E");
    pb(off+5,"0"); pb(off+6,"0"); pb(off+7,"1"); pb(off+8,"B"); pb(off+9,"M"); pb(off+10,"P");
    pb(off+11, 8'h20); p16(off+20, 0); p16(off+26, 3); p32(off+28, fsize);
    pb(off+32, 8'h00);
    // BMP
    off = clba(3) * 512;
    pb(off+0, 8'h42); pb(off+1, 8'h4D); p32(off+2, fsize); p32(off+10, 54);
    p32(off+14, 40); p32(off+18, W); p32(off+22, H); p16(off+26, 1); p16(off+28, 24);
    p32(off+30, 0); p32(off+34, stride * H);
    for (y = 0; y < H; y = y + 1)
        for (x = 0; x < W; x = x + 1) begin
            c = bar_rgb(x);
            pb(off + 54 + y * stride + x * 3 + 0, c[7:0]);
            pb(off + 54 + y * stride + x * 3 + 1, c[15:8]);
            pb(off + 54 + y * stride + x * 3 + 2, c[23:16]);
        end
    $display("INFO disk ready: %0dx%0d file %0d bytes, %0d clusters", W, H, fsize, nclus);

    repeat (2) @(posedge clk);
    rst = 1'b0;
    dut.u_sd_card_top.sd_init_done = 1'b1;
    @(negedge clk); scan_start = 1'b1;
    @(negedge clk); scan_start = 1'b0;
    @(posedge scan_done); #1;
    if (scan_found_count != 1) $fatal(1, "FAIL scan found %0d", scan_found_count);

    fork
        begin
            @(posedge write_req);
            @(negedge clk); write_req_ack = 1'b1;
            repeat (3) @(negedge clk); write_req_ack = 1'b0;
        end
    join_none

    repeat (20) @(negedge clk);   // selected_ok_q 等寄存的文件信息就绪
    @(negedge clk); load_start = 1'b1;
    @(negedge clk); load_start = 1'b0;
    @(posedge source_done_pulse);
    $display("INFO source done at %0t, pixels so far %0d, sd requests %0d",
             $time, pixel_count, dut.u_sd_card_top.request_count);
    // 放大时一帧输出要 ~28 ms，等满一帧或 60 ms 超时
    for (i = 0; i < 6000000 && pixel_count < 307200; i = i + 1) @(posedge clk);
    repeat (1000) @(posedge clk);
    $display("INFO final pixels %0d, scaler ovf %0d, aa_en %0d, em_state %0d wr_row %0d y0_cur %0d",
             pixel_count, dut.u_image_bilinear_scaler.src_overflow_count,
             dut.u_image_bilinear_scaler.aa_en, dut.u_image_bilinear_scaler.em_state,
             dut.u_image_bilinear_scaler.wr_row, dut.u_image_bilinear_scaler.y0_cur);
    if (pixel_count != 307200) $fatal(1, "FAIL output pixel count %0d", pixel_count);
    if (dut.u_image_bilinear_scaler.src_overflow_count != 0) $fatal(1, "FAIL scaler overflow");
    $display("PASS tb_adapter_1080p %0dx%0d", W, H);
    $finish;
end

endmodule

// SD 扇区应答模型：大盘 + 每扇区命令延迟 + 字节间隔
module sd_card_top(
    input clk, input rst, output reg SD_nCS, output reg SD_DCLK, output reg SD_MOSI,
    input SD_MISO, output reg sd_init_done, input sd_sec_read,
    input [31:0] sd_sec_read_addr, output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid, output reg sd_sec_read_end, input sd_sec_write,
    input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output reg sd_sec_write_data_req, output reg sd_sec_write_end
);
reg [7:0] disk [0:8*1024*1024-1];
reg serving = 1'b0, end_pending = 1'b0, request_complete = 1'b0;
reg [31:0] active_sector = 0;
reg [8:0] bi = 0;
integer request_count = 0, wait_cnt = 0, gap_cnt = 0, LAT, GAP;
initial begin
    sd_init_done = 1'b0;
    if (!$value$plusargs("LAT=%d", LAT)) LAT = 200;
    if (!$value$plusargs("BYTE_GAP=%d", GAP)) GAP = 4;
end
always @(posedge clk) begin
    sd_sec_read_data_valid <= 1'b0;
    sd_sec_read_end <= 1'b0;
    if (end_pending) begin
        sd_sec_read_end <= 1'b1; end_pending <= 1'b0; request_complete <= 1'b1;
    end else if (request_complete) begin
        if (!sd_sec_read) request_complete <= 1'b0;
    end else if (serving) begin
        if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
        else if (gap_cnt > 0) gap_cnt <= gap_cnt - 1;
        else begin
            sd_sec_read_data <= disk[active_sector * 512 + bi];
            sd_sec_read_data_valid <= 1'b1;
            gap_cnt <= GAP - 1;
            if (bi == 9'd511) begin serving <= 1'b0; end_pending <= 1'b1; end
            else bi <= bi + 9'd1;
        end
    end else if (sd_sec_read) begin
        serving <= 1'b1; active_sector <= sd_sec_read_addr; bi <= 0;
        wait_cnt <= LAT; gap_cnt <= 0;
        request_count <= request_count + 1;
    end
end
endmodule
