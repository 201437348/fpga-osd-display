`timescale 1ns/1ps

// frame_read_write 后台巡检读（SCRUB_INTERVAL）完整通路测试。
// 两份 frame_read_write：scrub 开（DUT）/ 关（REF），吃完全相同的视频读、SD 写激励，
// 各自带一个 SDRAM 行为模型（读延迟 + 地址跳变后前两拍返回旧地址的数据 + 随机 Sdr_busy，
// busy 期间出读命令直接判错）。检查：
//   1) DUT 每个显示像素与 REF 一致，且都是当前显示槽写进去的数据；
//   2) 两边 read_fault = 0、每帧 underflow = 0；
//   3) 巡检读地址列 = 0，覆盖全部 8192 个 {row, bank}；相邻两次巡检间隔有上限；
//   4) 写入 SDRAM 的内容两边一致（巡检不改写、不打乱写地址）。
module tb_frame_read_write_scrub;

localparam integer AW      = 21;
localparam integer W       = 640;
localparam integer H       = 8;
localparam integer PIXELS  = W * H;
localparam integer SCRUB_READS_TB = 4;
localparam integer SCRUB_N = 64;       // 缩短间隔：更频繁地打断调度器，也让覆盖测试跑得完

reg rst = 1'b1;
reg mem_clk = 1'b0;
reg video_clk = 1'b0;
reg sd_clk = 1'b0;
always #4  mem_clk   = ~mem_clk;     // 125 MHz
always #20 video_clk = ~video_clk;   // 25 MHz
always #10 sd_clk    = ~sd_clk;      // 50 MHz

function automatic [AW-1:0] slot_base(input integer k);
    slot_base = k * 21'h4000;
endfunction

// ---------------- 共享激励 ----------------
reg        read_req = 1'b0;
reg        read_en = 1'b0;
reg        display_valid = 1'b0;
reg  [2:0] rd_idx = 3'd0;
reg  [2:0] rd_idx_old = 3'd0;
reg        slide_active = 1'b0;
reg  [9:0] slide_pos = 10'd0;
reg        write_req = 1'b0;
reg        write_en = 1'b0;
reg [31:0] write_data = 32'd0;
reg  [2:0] wr_idx = 3'd0;
reg        Sdr_busy = 1'b0;

// ---------------- 两份 DUT + SDRAM 模型 ----------------
wire        rd_en_d, rd_en_r, sdr_rd_en_d, sdr_rd_en_r;
wire [AW-1:0] rd_addr_d, rd_addr_r;
wire [31:0] sdr_dout_d, sdr_dout_r;
wire        wr_en_d, wr_en_r;
wire [AW-1:0] wr_addr_d, wr_addr_r;
wire [31:0] wr_din_d, wr_din_r;
wire [31:0] read_data_d, read_data_r;
wire        fault_d, fault_r;
wire        rvalid_d, rvalid_r;
wire [3:0]  uf_d, uf_r;
wire        ref_req_d, ref_req_r, ref_vld_d, ref_vld_r;
wire        ack_d, ack_r, wack_d, wack_r, wfin_d, wfin_r, afull_d, afull_r;

`define FRW_INST(NAME, SCRUB, REFREQ, REFVLD, RDEN, RDADDR, SRDEN, SDOUT, WREN, WRADDR, WRDIN, RDATA, RVALID, FAULT, UF, ACK, WACK, WFIN, AFULL) \
frame_read_write #( \
    .WRITE_V_FLIP (1), .FRAME_WIDTH (W), .FRAME_HEIGHT (H), \
    .SLIDE_FEATHER_ENABLE (0), .READ_CHUNK_PREROLL_WORDS (4), \
    .FIXED_READ_BURST_ENABLE (1), .SCRUB_INTERVAL (SCRUB) \
) NAME ( \
    .rst (rst), .mem_clk (mem_clk), .Sdr_init_done (1'b1), .Sdr_init_ref_vld (REFVLD), \
    .Sdr_busy (Sdr_busy), .App_ref_req (REFREQ), .App_rd_en (RDEN), .App_rd_addr (RDADDR), \
    .Sdr_rd_en (SRDEN), .Sdr_rd_dout (SDOUT), \
    .read_clk (video_clk), .read_req (read_req), .read_req_ack (ACK), .read_finish (), \
    .read_addr_0 (slot_base(0)), .read_addr_1 (slot_base(1)), .read_addr_2 (slot_base(2)), \
    .read_addr_3 (slot_base(3)), .read_addr_4 (slot_base(4)), .read_addr_5 (slot_base(5)), \
    .read_addr_index (rd_idx), .read_addr_index_old (rd_idx_old), \
    .slide_active (slide_active), .slide_position (slide_pos), .read_len (PIXELS[AW-1:0]), \
    .read_en (read_en), .display_valid (display_valid), .read_data (RDATA), \
    .read_data_valid (RVALID), .read_fault (FAULT), .read_fifo_underflow_count_per_frame (UF), \
    .App_wr_en (WREN), .App_wr_addr (WRADDR), .App_wr_din (WRDIN), .App_wr_dm (), \
    .write_clk (sd_clk), .write_req (write_req), .write_req_ack (WACK), .write_finish (WFIN), \
    .write_addr_0 (slot_base(0)), .write_addr_1 (slot_base(1)), .write_addr_2 (slot_base(2)), \
    .write_addr_3 (slot_base(3)), .write_addr_4 (slot_base(4)), .write_addr_5 (slot_base(5)), \
    .write_addr_index (wr_idx), .write_len (PIXELS[AW-1:0]), .write_en (write_en), \
    .write_data (write_data), .write_fifo_afull (AFULL) \
);

`FRW_INST(dut, SCRUB_N, ref_req_d, ref_vld_d, rd_en_d, rd_addr_d, sdr_rd_en_d, sdr_dout_d, wr_en_d, wr_addr_d, wr_din_d, read_data_d, rvalid_d, fault_d, uf_d, ack_d, wack_d, wfin_d, afull_d)
`FRW_INST(ref0, 0,      ref_req_r, ref_vld_r, rd_en_r, rd_addr_r, sdr_rd_en_r, sdr_dout_r, wr_en_r, wr_addr_r, wr_din_r, read_data_r, rvalid_r, fault_r, uf_r, ack_r, wack_r, wfin_r, afull_r)

sdram_model_scrub m_d (.clk(mem_clk), .rst(rst), .busy(Sdr_busy), .rd_cmd(rd_en_d), .rd_addr(rd_addr_d),
                       .wr_cmd(wr_en_d), .wr_addr(wr_addr_d), .wr_din(wr_din_d),
                       .rd_valid(sdr_rd_en_d), .rd_dout(sdr_dout_d),
                       .ref_req(ref_req_d), .ref_vld(ref_vld_d));
sdram_model_scrub m_r (.clk(mem_clk), .rst(rst), .busy(Sdr_busy), .rd_cmd(rd_en_r), .rd_addr(rd_addr_r),
                       .wr_cmd(wr_en_r), .wr_addr(wr_addr_r), .wr_din(wr_din_r),
                       .rd_valid(sdr_rd_en_r), .rd_dout(sdr_dout_r),
                       .ref_req(ref_req_r), .ref_vld(ref_vld_r));

// ---------------- 随机 Sdr_busy（短脉冲 + 偶尔长停顿） ----------------
integer busy_left = 0;
integer rnd;
always @(posedge mem_clk) begin
    if (rst) begin
        Sdr_busy <= 1'b0;
    end else if (busy_left > 0) begin
        busy_left = busy_left - 1;
        Sdr_busy <= (busy_left != 0);
    end else begin
        rnd = $urandom % 1000;
        if (rnd < 6) begin
            busy_left = 1 + ($urandom % 3);
            Sdr_busy <= 1'b1;
        end else if (rnd == 999) begin
            busy_left = 16;
            Sdr_busy <= 1'b1;
        end else begin
            Sdr_busy <= 1'b0;
        end
    end
end

// ---------------- 巡检统计 ----------------
reg     scrub_seen [0:8191];
integer scrub_count = 0;
integer scrub_unique = 0;
integer last_scrub_t = -1;
integer max_gap = 0;
integer ref_count = 0;
integer last_ref_t = 0;
integer max_ref_gap = 0;
integer cyc = 0;
integer k;
initial for (k = 0; k < 8192; k = k + 1) scrub_seen[k] = 1'b0;

always @(posedge mem_clk) begin
    cyc = cyc + 1;
    if (!rst && dut.scrub_en) begin
        if (rd_addr_d[7:0] !== 8'd0)
            $fatal(1, "FAIL scrub address column not 0: %h", rd_addr_d);
        if (!scrub_seen[rd_addr_d[20:8]]) begin
            scrub_seen[rd_addr_d[20:8]] = 1'b1;
            scrub_unique = scrub_unique + 1;
        end
        scrub_count = scrub_count + 1;
        if (last_scrub_t >= 0 && (cyc - last_scrub_t) > max_gap)
            max_gap = cyc - last_scrub_t;
        last_scrub_t = cyc;
    end
    if (!rst && ref_req_d) begin
        if (ref_count > 0 && (cyc - last_ref_t) > max_ref_gap)
            max_ref_gap = cyc - last_ref_t;
        last_ref_t = cyc;
        ref_count  = ref_count + 1;
    end
    if (!rst && ref_req_r)
        $fatal(1, "FAIL refresh requested with SCRUB_INTERVAL=0");
    if (!rst && (fault_d || fault_r))
        $fatal(1, "FAIL read_fault dut=%b ref=%b at cycle %0d", fault_d, fault_r, cyc);
end

// ---------------- 显示比对（video_clk 域） ----------------
// 按 read_data_valid 采样；两边 valid 必须同拍。显示槽标签只在非滑动帧检查，
// 槽号取 read_en 那一拍的值（read_en 到 valid 的延迟内槽号不会变）。
integer    pix_checked = 0;
integer    frames_checked = 0;
always @(posedge video_clk) begin
    if (rvalid_d !== rvalid_r)
        $fatal(1, "FAIL read_data_valid differs dut=%b ref=%b", rvalid_d, rvalid_r);
    if (display_valid && rvalid_d) begin
        if (read_data_d !== read_data_r)
            $fatal(1, "FAIL pixel mismatch dut=%h ref=%h (pix %0d)", read_data_d, read_data_r, pix_checked);
        if (!slide_active && (read_data_d[31:28] !== {1'b0, rd_idx}))
            $fatal(1, "FAIL pixel %h not from slot %0d (pix %0d)", read_data_d, rd_idx, pix_checked);
        pix_checked = pix_checked + 1;
    end
end

// ---------------- 视频读：一帧 ----------------
task automatic video_frame;
    integer y, x;
    begin
        @(negedge video_clk);
        read_req = 1'b1;
        fork
            begin wait (ack_d === 1'b1); end
            begin wait (ack_r === 1'b1); end
        join
        @(negedge video_clk);
        read_req = 1'b0;
        repeat (200) @(negedge video_clk);          // 预取
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                read_en = 1'b1;
                @(negedge video_clk);
            end
            read_en = 1'b0;
            repeat (160) @(negedge video_clk);      // 行消隐
        end
        repeat (400) @(negedge video_clk);          // 场消隐
        if (display_valid && ((uf_d !== 4'd0) || (uf_r !== 4'd0)))
            $fatal(1, "FAIL underflow dut=%0d ref=%0d", uf_d, uf_r);
        frames_checked = frames_checked + 1;
        $display("[%0t] frame %0d done, pixels=%0d scrubs=%0d", $time, frames_checked, pix_checked, scrub_count);
    end
endtask

// ---------------- SD 写：一整张图 ----------------
task automatic write_image(input [2:0] slot);
    integer n;
    begin
        @(negedge sd_clk);
        wr_idx = slot;
        write_req = 1'b1;
        fork
            begin wait (wack_d === 1'b1); end
            begin wait (wack_r === 1'b1); end
        join
        @(negedge sd_clk);
        write_req = 1'b0;
        n = 0;
        // 写 FIFO 仿真模型是 show-ahead，最后几个字在输出寄存器里不计入 rdusedw，
        // 帧尾 burst 凑不满；多推 8 个填充字（下一次 write ACK 会清 FIFO，不会写进 SDRAM）。
        while (n < PIXELS + 8) begin
            // 两边写 FIFO 的 afull 可能不同步：任一边 afull 都停，保证输入序列一致
            if (!afull_d && !afull_r && ($urandom % 4 != 0)) begin
                write_en   = 1'b1;
                write_data = {1'b0, slot, 4'h0, n[23:0]};
                n = n + 1;
            end else begin
                write_en = 1'b0;
            end
            @(negedge sd_clk);
        end
        write_en = 1'b0;
        fork
            begin wait (wfin_d === 1'b1); end
            begin wait (wfin_r === 1'b1); end
        join
    end
endtask

integer f, s, adr, bad;
initial begin
    repeat (10) @(negedge mem_clk);
    rst = 1'b0;
    repeat (10) @(negedge mem_clk);

    // 1) 显示槽 0 的同时写满 6 个槽（读写并发 + 巡检插入）
    write_image(3'd0);
    display_valid = 1'b1;
    fork
        begin
            for (s = 1; s < 6; s = s + 1) write_image(s[2:0]);
        end
        begin
            for (f = 0; f < 4; f = f + 1) video_frame();
        end
    join

    // 2) 依次显示每个槽
    for (s = 0; s < 6; s = s + 1) begin
        rd_idx = s[2:0];
        video_frame();
    end

    // 3) 滑动切换 + 同时重写旧槽
    fork
        write_image(3'd2);
        begin
            rd_idx_old = 3'd4; rd_idx = 3'd5; slide_active = 1'b1;
            for (f = 0; f < 4; f = f + 1) begin
                slide_pos = f * 150;
                video_frame();
            end
            slide_active = 1'b0;
        end
    join
    rd_idx = 3'd2;
    video_frame();

    // 4) 写入内容一致
    bad = 0;
    for (s = 0; s < 6; s = s + 1)
        for (adr = slot_base(s); adr < slot_base(s) + PIXELS; adr = adr + 1)
            if (m_d.mem[adr] !== m_r.mem[adr]) bad = bad + 1;
    if (bad != 0)
        $fatal(1, "FAIL %0d SDRAM words differ between scrub/no-scrub", bad);

    // 5) 空闲跑满一轮，检查覆盖
    while (scrub_unique < 8192 && cyc < 3000000) @(negedge mem_clk);
    if (scrub_unique != 8192)
        $fatal(1, "FAIL scrub covered %0d / 8192 bank-rows", scrub_unique);
    if (max_gap > SCRUB_N + 400)
        $fatal(1, "FAIL scrub max gap %0d cycles", max_gap);

    // 每 2 个巡检窗口一次刷新（每个窗口 SCRUB_READS_TB 次巡检读）
    if (ref_count < scrub_count / SCRUB_READS_TB / 2 - 2)
        $fatal(1, "FAIL only %0d refreshes for %0d scrub windows", ref_count, scrub_count / SCRUB_READS_TB);
    if (max_ref_gap > 2 * (SCRUB_N + 400) + 200)
        $fatal(1, "FAIL refresh max gap %0d cycles", max_ref_gap);
    $display("PASS tb_frame_read_write_scrub: frames=%0d pixels=%0d scrubs=%0d max_gap=%0d refreshes=%0d max_ref_gap=%0d",
             frames_checked, pix_checked, scrub_count, max_gap, ref_count, max_ref_gap);
    $finish;
end

initial begin
    #80_000_000;
    $fatal(1, "FAIL timeout frames=%0d scrub_unique=%0d", frames_checked, scrub_unique);
end

endmodule

// SDRAM 行为模型：读延迟 3 拍；读数据来自两条命令之前的地址（地址跳变后前两拍是旧数据，
// 和 tb_frame_slide_sdram_preroll 的模型一致）；busy 期间出读命令判错。
module sdram_model_scrub (
    input             clk, input rst, input busy,
    input             rd_cmd, input [20:0] rd_addr,
    input             wr_cmd, input [20:0] wr_addr, input [31:0] wr_din,
    output reg        rd_valid, output reg [31:0] rd_dout,
    input             ref_req, output reg ref_vld
);
// 刷新：ref_req 单拍脉冲，4 拍后 ref_vld（刷新命令占总线）拉高 20 拍；
// 从请求到刷新结束出任何读写命令都判错（busy 上不体现，调度器要自己避开）。
integer ref_delay = 0;
integer ref_left  = 0;
always @(posedge clk) begin
    if (rst) begin
        ref_vld <= 1'b0; ref_delay = 0; ref_left = 0;
    end else begin
        if ((ref_vld || ref_delay != 0) && (rd_cmd || wr_cmd))
            $fatal(1, "FAIL read/write command during refresh");
        if (ref_req) begin
            if (ref_delay != 0 || ref_left != 0)
                $fatal(1, "FAIL refresh requested while previous one in progress");
            ref_delay = 4;
        end else if (ref_delay > 0) begin
            ref_delay = ref_delay - 1;
            if (ref_delay == 0) ref_left = 20;
        end
        if (ref_left > 0) begin
            ref_vld  <= 1'b1;
            ref_left = ref_left - 1;
        end else begin
            ref_vld  <= 1'b0;
        end
    end
end
reg [31:0] mem [0:(1<<21)-1];
reg [20:0] a0 = 21'd0, a1 = 21'd0;
reg [2:0]  v_pipe = 3'd0;
reg [31:0] d_pipe0, d_pipe1, d_pipe2;
always @(posedge clk) begin
    if (rst) begin
        v_pipe <= 3'd0; rd_valid <= 1'b0;
    end else begin
        // 与原版调度器一致：Sdr_busy 只约束读命令，写命令不看 busy
        if (busy && rd_cmd)
            $fatal(1, "FAIL read command while Sdr_busy");
        if (rd_cmd && wr_cmd)
            $fatal(1, "FAIL read and write command in the same cycle");
        if (wr_cmd) mem[wr_addr] <= wr_din;
        v_pipe  <= {v_pipe[1:0], rd_cmd};
        d_pipe0 <= mem[a1];
        d_pipe1 <= d_pipe0;
        d_pipe2 <= d_pipe1;
        if (rd_cmd) begin a1 <= a0; a0 <= rd_addr; end
        rd_valid <= v_pipe[2];
        rd_dout  <= d_pipe2;
    end
end
endmodule
