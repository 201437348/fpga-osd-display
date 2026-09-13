`timescale 1ns/1ps
`include "video_define.v"

module tb_refresh_sweep #(
    parameter FIFO_DEPTH             = 512,
    parameter FIFO_LEVEL_BITS        = 9,
    parameter REFRESH_STALL_CYCLES   = 1,
    parameter REFRESH_INTERVAL_CYCLES = 977,
    parameter GAP_CYCLES              = 15,
    parameter TARGET_FRAMES           = 24
);
    localparam ADDR_BITS = 21;
    localparam [ADDR_BITS-1:0] FRAME_PIXELS = 21'd307200;
    localparam [ADDR_BITS-1:0] BUF0_ADDR = {ADDR_BITS{1'b0}};
    localparam DISPLAY_VALID_AFTER_REQS = 3;
    localparam DEADLOCK_CONFIRM_CYCLES = 8'd64;

    reg rst = 1'b1;
    reg mem_clk = 1'b0;
    reg video_clk = 1'b0;
    always #4 mem_clk = ~mem_clk;
    always #20 video_clk = ~video_clk;

    initial begin
        #200 rst = 1'b0;
    end

    reg display_valid = 1'b0;
    integer req_rise_count = 0;
    reg video_read_req_prev = 1'b0;

    wire hs_0, vs_0, de_0;
    wire video_read_req, video_read_req_ack;
    wire video_read_en;
    wire [31:0] video_read_data;
    wire hs, vs, de;
    wire [23:0] vout_data_raw;

    video_timing_data video_timing_data_m0 (
        .video_clk(video_clk), .rst(rst),
        .read_req(video_read_req), .read_req_ack(video_read_req_ack),
        .hs(hs_0), .vs(vs_0), .de(de_0)
    );

    video_delay video_delay_m0 (
        .video_clk(video_clk), .rst(rst), .read_en(video_read_en),
        .read_data(video_read_data[31:8]), .hs(hs_0), .vs(vs_0), .de(de_0),
        .hs_r(hs), .vs_r(vs), .de_r(de), .vout_data(vout_data_raw)
    );

    wire App_rd_en;
    wire [ADDR_BITS-1:0] App_rd_addr;
    wire Sdr_rd_en;
    wire [31:0] Sdr_rd_dout;
    wire Sdr_busy;
    wire App_wr_en;
    wire [ADDR_BITS-1:0] App_wr_addr;
    wire [31:0] App_wr_din;
    wire [3:0] App_wr_dm;
    wire [3:0] frame_read_fifo_underflow_count_per_frame;

    sdram_model_refresh #(
        .ADDR_BITS(ADDR_BITS), .MAX_BURST(128), .FIXED_LATENCY(4),
        .GAP_CYCLES(GAP_CYCLES),
        .REFRESH_INTERVAL_CYCLES(REFRESH_INTERVAL_CYCLES),
        .REFRESH_STALL_CYCLES(REFRESH_STALL_CYCLES)
    ) sdram_m0 (
        .mem_clk(mem_clk), .rst(rst), .App_rd_en(App_rd_en),
        .App_rd_addr(App_rd_addr), .Sdr_rd_en(Sdr_rd_en),
        .Sdr_rd_dout(Sdr_rd_dout), .Sdr_busy(Sdr_busy)
    );

    frame_read_write #(
        .BURST_BITS(FIFO_LEVEL_BITS),
        .READ_FIFO_DEPTH(FIFO_DEPTH),
        .WRITE_V_FLIP(1), .FRAME_WIDTH(640), .FRAME_HEIGHT(480)
    ) dut (
        .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(1'b1), .Sdr_busy(Sdr_busy),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .read_clk(video_clk), .read_req(video_read_req),
        .read_req_ack(video_read_req_ack), .read_finish(),
        .read_addr_0(BUF0_ADDR), .read_addr_1(FRAME_PIXELS),
        .read_addr_2({ADDR_BITS{1'b0}}), .read_addr_3({ADDR_BITS{1'b0}}),
        .read_addr_index(2'd0), .read_addr_index_old(2'd0),
        .slide_active(1'b0), .slide_position(10'd0),
        .read_len(FRAME_PIXELS), .read_en(video_read_en),
        .display_valid(display_valid), .read_data(video_read_data),
        .read_fault(),
        .read_fifo_underflow_count_per_frame(frame_read_fifo_underflow_count_per_frame),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr),
        .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
        .write_clk(mem_clk), .write_req(1'b0), .write_req_ack(),
        .write_finish(), .write_addr_0(BUF0_ADDR),
        .write_addr_1(FRAME_PIXELS), .write_addr_2({ADDR_BITS{1'b0}}),
        .write_addr_3({ADDR_BITS{1'b0}}), .write_addr_index(2'd0),
        .write_len(FRAME_PIXELS), .write_en(1'b0),
        .write_data(32'd0), .write_fifo_afull()
    );

    defparam dut.read_buf.DEPTH = FIFO_DEPTH;
    defparam dut.read_buf.AW = FIFO_LEVEL_BITS;

    wire underflow_now = display_valid && video_read_en && dut.read_fifo_empty;
    integer frame_count = 0;
    integer raw_count_this_frame = 0;
    integer episode_count_this_frame = 0;
    integer total_raw_underflow = 0;
    integer total_underflow_episodes = 0;
    integer frames_with_underflow = 0;
    integer dropped_commands = 0;
    integer max_fifo_used = 0;
    reg underflow_prev = 1'b0;
    reg scheduler_stuck = 1'b0;
    reg finished = 1'b0;
    reg [7:0] deadlock_confirm_cycles = 8'd0;

    task print_result;
        input completed;
        begin
            $display("RESULT completed=%0d frames=%0d fifo_depth=%0d fifo_level_bits=%0d refresh_interval=%0d refresh_stall=%0d gap=%0d total_raw_underflow=%0d total_underflow_episodes=%0d frames_with_underflow=%0d dropped_commands=%0d scheduler_stuck=%0d max_fifo_used=%0d",
                completed, frame_count, FIFO_DEPTH, FIFO_LEVEL_BITS,
                REFRESH_INTERVAL_CYCLES, REFRESH_STALL_CYCLES, GAP_CYCLES,
                total_raw_underflow, total_underflow_episodes,
                frames_with_underflow, dropped_commands, scheduler_stuck,
                max_fifo_used);
        end
    endtask

    always @(posedge mem_clk) begin
        if (!rst) begin
            if (App_rd_en && Sdr_busy)
                dropped_commands <= dropped_commands + 1;
            if (dut.wrusedw > max_fifo_used)
                max_fifo_used <= dut.wrusedw;
            if ((dut.frame_slide_fifo_read_m0.state == 4'd5) &&
                (dropped_commands != 0) && sdram_m0.empty &&
                (sdram_m0.en_pipe == {4{1'b0}}) &&
                (sdram_m0.gap_remaining == 16'd0)) begin
                if (deadlock_confirm_cycles == (DEADLOCK_CONFIRM_CYCLES - 1'b1)) begin
                    scheduler_stuck = 1'b1;
                    finished = 1'b1;
                    $display("DEADLOCK: dropped read command cannot return; SDRAM pipeline and queue are empty");
                    print_result(1'b0);
                    $finish;
                end else begin
                    deadlock_confirm_cycles <= deadlock_confirm_cycles + 1'b1;
                end
            end else begin
                deadlock_confirm_cycles <= 8'd0;
            end
        end
    end

    always @(posedge video_clk) begin
        if (underflow_now) begin
            raw_count_this_frame <= raw_count_this_frame + 1;
            total_raw_underflow <= total_raw_underflow + 1;
            if (!underflow_prev) begin
                episode_count_this_frame <= episode_count_this_frame + 1;
                total_underflow_episodes <= total_underflow_episodes + 1;
            end
        end
        underflow_prev <= underflow_now;
        video_read_req_prev <= video_read_req;

        if (video_read_req && !video_read_req_prev) begin
            req_rise_count <= req_rise_count + 1;
            if ((req_rise_count + 1) >= DISPLAY_VALID_AFTER_REQS)
                display_valid <= 1'b1;
            frame_count <= frame_count + 1;
            if (raw_count_this_frame != 0)
                frames_with_underflow <= frames_with_underflow + 1;
            $display("[FRAME %0d] display_valid=%0d raw_underflow=%0d episodes=%0d rtl_episodes=%0d dropped=%0d stuck=%0d fifo_used=%0d",
                frame_count, display_valid, raw_count_this_frame,
                episode_count_this_frame,
                frame_read_fifo_underflow_count_per_frame,
                dropped_commands, scheduler_stuck, dut.wrusedw);
            raw_count_this_frame <= 0;
            episode_count_this_frame <= 0;
            if (frame_count >= TARGET_FRAMES) begin
                finished <= 1'b1;
                print_result(1'b1);
                $finish;
            end
        end
    end

    initial begin
        #1_000_000_000;
        if (!finished) begin
            $display("TIMEOUT: did not reach target frame count");
            print_result(1'b0);
            $finish;
        end
    end
endmodule
