`timescale 1ns/1ps
// 多图顺序加载（同一个 adapter 不复位）：复现"小图之后的 1080p 加载不完"
//   盘上 4 张：32x32、640x480、1280x960、800x480（支持范围 32x32..1280x960 的两端），
//   按 +ORDER 顺序逐张加载，每张检查 source_done + 307200 像素 + 无溢出。

// 真实 FAT32 -> fat32_bmp_loader -> image_bilinear_scaler(抗锯齿) 全路径加载大图
//   +W=/+H= 源尺寸（默认 1920x1080，八色竖条，与板上图 3 一致）
//   +BYTE_GAP=<n>  SD 模型每字节间隔拍数（默认 4），+LAT=<n> 每扇区命令延迟（默认 200）
//   检查：source_done 且无 source_error，write_en 恰好 307200 个，缩放器无溢出，
//   逐像素与"竖条按 3x3 帐篷滤波 + 双线性"的期望色比对前若干行（只看 x 方向）。
module tb_adapter_seq;

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
always @(posedge clk) if (dut.loader_start) pixel_count = 0; else if (write_en) pixel_count = pixel_count + 1;
always @(posedge clk) if (dut.loader_start) $display("INFO loader_start at %0t, pixels so far %0d, granted %0d", $time, pixel_count, dut.write_granted);
always @(negedge dut.write_granted) $display("INFO write_granted fell at %0t", $time);
always @(posedge dut.write_granted) $display("INFO write_granted rose at %0t, pixels so far %0d", $time, pixel_count);

always @(posedge source_error_pulse) begin
    $display("loader st=%0d hm=%0d w=%0d h=%0d bpp=%0d off=%0d flen=%0d fsz=%0d dib=%0d pl=%0d comp=%0d pxok=%0d sel_ok=%0d",
        dut.u_fat32_bmp_loader.state, dut.u_fat32_bmp_loader.header_match,
        dut.u_fat32_bmp_loader.header_width, dut.u_fat32_bmp_loader.header_height,
        dut.u_fat32_bmp_loader.bit_count, dut.u_fat32_bmp_loader.pixel_offset,
        dut.u_fat32_bmp_loader.header_file_len, dut.u_fat32_bmp_loader.file_size_latched,
        dut.u_fat32_bmp_loader.dib_size, dut.u_fat32_bmp_loader.planes,
        dut.u_fat32_bmp_loader.compression, dut.u_fat32_bmp_loader.src_pixels_ok, dut.selected_ok_q);
    $fatal(1, "FAIL source_error_pulse img %0d", target_image_index);
end

// ---- 盘布局：MBR@0，引导@1，FAT@2..9，数据区@10，每簇 SPC 扇区 ----
localparam integer FAT_LBA = 2, FATSZ = 64, DATA_LBA = FAT_LBA + FATSZ, NF = 4;
integer SPC;
integer FW [0:NF-1], FH [0:NF-1], FCL [0:NF-1], FSZ [0:NF-1];
integer i, j, x, y, off, stride, nclus, nextc, k, t0, abort_at, rq0;

task automatic pb(input integer a, input [7:0] v); dut.u_sd_card_top.disk[a] = v; endtask
task automatic p16(input integer a, input [15:0] v); begin pb(a, v[7:0]); pb(a+1, v[15:8]); end endtask
task automatic p32(input integer a, input [31:0] v);
    begin pb(a, v[7:0]); pb(a+1, v[15:8]); pb(a+2, v[23:16]); pb(a+3, v[31:24]); end
endtask
function integer clba(input integer c); clba = DATA_LBA + (c - 2) * SPC; endfunction
// +FRAG=1：4 个文件按簇交错存放（file j 第 i 簇 = 3 + i*NF + j），模拟删文件再拷贝后的碎片化
integer FRAG;
function integer fcl(input integer jj, input integer ii);
    fcl = FRAG ? (3 + ii * NF + jj) : (FCL[jj] + ii);
endfunction
// 文件内字节地址 -> 盘上字节地址
task automatic fb(input integer jj, input integer bo, input [7:0] v);
    pb(clba(fcl(jj, bo / (SPC * 512))) * 512 + bo % (SPC * 512), v);
endtask
task automatic fb32(input integer jj, input integer bo, input [31:0] v);
    begin fb(jj, bo, v[7:0]); fb(jj, bo+1, v[15:8]); fb(jj, bo+2, v[23:16]); fb(jj, bo+3, v[31:24]); end
endtask

function [23:0] bar_rgb(input integer xx, input integer ww);
    case ((xx * 8) / ww)
        0: bar_rgb = 24'hFFFFFF; 1: bar_rgb = 24'hFFFF00; 2: bar_rgb = 24'h00FFFF;
        3: bar_rgb = 24'h00FF00; 4: bar_rgb = 24'hFF00FF; 5: bar_rgb = 24'hFF0000;
        6: bar_rgb = 24'h0000FF; default: bar_rgb = 24'h000000;
    endcase
endfunction

reg [23:0] c;
reg [8*16-1:0] order;
initial begin
    if (!$value$plusargs("SPC=%d", SPC)) SPC = 64;
    if (!$value$plusargs("FRAG=%d", FRAG)) FRAG = 0;
    if (!$value$plusargs("ORDER=%s", order)) order = "0123";
    // +ABORT_AT=n：第一张读到 n 个扇区时 abort，3 拍后重新 load_start 同一张
    // （= image_load_manager 预加载被 3 s 自动轮播 pl_preempt 后前台重读）
    if (!$value$plusargs("ABORT_AT=%d", abort_at)) abort_at = 0;
    FW[0] = 32;   FH[0] = 32;
    FW[1] = 640;  FH[1] = 480;
    FW[2] = 1280; FH[2] = 960;
    FW[3] = 800;  FH[3] = 480;

    pb(450, 8'h0C); p32(454, 1); pb(510, 8'h55); pb(511, 8'hAA);
    p16(512 + 11, 512); pb(512 + 13, SPC); p16(512 + 14, 1); pb(512 + 16, 1);
    p16(512 + 17, 0); p16(512 + 22, 0); p32(512 + 36, FATSZ); p32(512 + 44, 2);
    pb(512 + 510, 8'h55); pb(512 + 511, 8'hAA);
    p32(FAT_LBA * 512 + 0, 32'h0FFFFFF8); p32(FAT_LBA * 512 + 4, 32'h0FFFFFFF);
    p32(FAT_LBA * 512 + 8, 32'h0FFFFFFF);          // 簇 2 = 根目录
    nextc = 3;
    for (j = 0; j < NF; j = j + 1) begin
        stride = ((FW[j] * 3) + 3) & ~3;
        FSZ[j] = 54 + stride * FH[j];
        FCL[j] = FRAG ? (3 + j) : nextc;
        nclus  = (FSZ[j] + SPC * 512 - 1) / (SPC * 512);
        for (i = 0; i < nclus; i = i + 1)
            p32(FAT_LBA * 512 + fcl(j, i) * 4, (i == nclus - 1) ? 32'h0FFFFFFF : fcl(j, i + 1));
        // 目录项 IMAGE00j.BMP
        off = clba(2) * 512 + j * 32;
        pb(off+0,"I"); pb(off+1,"M"); pb(off+2,"A"); pb(off+3,"G"); pb(off+4,"E");
        pb(off+5,"0"); pb(off+6,"0"); pb(off+7,"0" + j); pb(off+8,"B"); pb(off+9,"M"); pb(off+10,"P");
        pb(off+11, 8'h20); p16(off+20, 0); p16(off+26, FCL[j]); p32(off+28, FSZ[j]);
        fb(j, 0, 8'h42); fb(j, 1, 8'h4D); fb32(j, 2, FSZ[j]); fb32(j, 10, 54);
        fb32(j, 14, 40); fb32(j, 18, FW[j]); fb32(j, 22, FH[j]);
        fb(j, 26, 8'd1); fb(j, 27, 8'd0); fb(j, 28, 8'd24); fb(j, 29, 8'd0);
        fb32(j, 30, 0); fb32(j, 34, stride * FH[j]);
        for (y = 0; y < FH[j]; y = y + 1)
            for (x = 0; x < FW[j]; x = x + 1) begin
                c = bar_rgb(x, FW[j]);
                fb(j, 54 + y * stride + x * 3 + 0, c[7:0]);
                fb(j, 54 + y * stride + x * 3 + 1, c[15:8]);
                fb(j, 54 + y * stride + x * 3 + 2, c[23:16]);
            end
        $display("INFO file %0d: %0dx%0d %0d bytes cluster %0d..%0d", j, FW[j], FH[j], FSZ[j], fcl(j, 0), fcl(j, nclus - 1));
        if (fcl(j, nclus) > nextc) nextc = fcl(j, nclus);
    end
    pb(clba(2) * 512 + NF * 32, 8'h00);
    if (clba(nextc) * 512 > 32*1024*1024) $fatal(1, "FAIL disk too small");

    repeat (2) @(posedge clk);
    rst = 1'b0;
    dut.u_sd_card_top.sd_init_done = 1'b1;
    @(negedge clk); scan_start = 1'b1;
    @(negedge clk); scan_start = 1'b0;
    @(posedge scan_done); #1;
    if (scan_found_count != NF) $fatal(1, "FAIL scan found %0d", scan_found_count);

    for (k = 15; k >= 0; k = k - 1) begin
        if (order[k*8 +: 8] >= "0" && order[k*8 +: 8] <= "9") begin
            target_image_index = order[k*8 +: 8] - "0";
            pixel_count = 0;
            t0 = $time / 1000;
            fork
                begin
                    @(posedge write_req);
                    @(negedge clk); write_req_ack = 1'b1;
                    repeat (3) @(negedge clk); write_req_ack = 1'b0;
                end
            join_none
            repeat (20) @(negedge clk);
            @(negedge clk); load_start = 1'b1;
            @(negedge clk); load_start = 1'b0;
            if (abort_at > 0) begin
                rq0 = dut.u_sd_card_top.request_count;
                wait (dut.u_sd_card_top.request_count >= rq0 + abort_at);
                $display("INFO abort img %0d after %0d sectors, pixels %0d at %0t",
                         target_image_index, abort_at, pixel_count, $time);
                @(negedge clk); load_abort = 1'b1;
                @(negedge clk); load_abort = 1'b0;
                repeat (2) @(negedge clk);
                pixel_count = 0;
                fork
                    begin
                        @(posedge write_req);
                        @(negedge clk); write_req_ack = 1'b1;
                        repeat (3) @(negedge clk); write_req_ack = 1'b0;
                    end
                join_none
                @(negedge clk); load_start = 1'b1;
                @(negedge clk); load_start = 1'b0;
                abort_at = 0;
            end
            fork : wait_done
                begin @(posedge source_done_pulse); disable wait_done; end
                begin
                    for (i = 0; i < 400000000; i = i + 1) @(posedge clk);
                    $display("FAIL img %0d no source_done: loader st %0d adapter st %0d req %0d pixels %0d",
                             target_image_index, dut.u_fat32_bmp_loader.state, dut.state,
                             dut.u_sd_card_top.request_count, pixel_count);
                    $fatal(1, "FAIL no source_done");
                end
            join
            for (i = 0; i < 8000000 && pixel_count < 307200; i = i + 1) @(posedge clk);
            repeat (2000) @(posedge clk);
            $display("INFO img %0d (%0dx%0d): pixels %0d, ovf %0d, aa %0d, %0d us",
                     target_image_index, FW[target_image_index], FH[target_image_index],
                     pixel_count, dut.u_image_bilinear_scaler.src_overflow_count,
                     dut.u_image_bilinear_scaler.aa_en, $time / 1000 - t0);
            if (pixel_count != 307200) $fatal(1, "FAIL img %0d output pixel count %0d", target_image_index, pixel_count);
            if (dut.u_image_bilinear_scaler.src_overflow_count != 0) $fatal(1, "FAIL scaler overflow");
            // 模拟 frame_fifo_write 收尾后 loader 撤 req
            wait (!write_req);
            repeat (100) @(negedge clk);
        end
    end
    $display("PASS tb_adapter_seq order %0s SPC %0d", order, SPC);
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
reg [7:0] disk [0:32*1024*1024-1];
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
