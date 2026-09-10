`timescale 1ns/1ps
`include "video_define.v"

module tb_diag;
    localparam ADDR_BITS    = 21;
    localparam FRAME_PIXELS = 24'd307200; // 640*480
    localparam BUF0_ADDR    = 24'd0;
    localparam TARGET_FRAMES = 5;
    localparam DISPLAY_VALID_AFTER_REQS = 3;

    reg rst = 1'b1;
    reg mem_clk = 1'b0;
    reg video_clk = 1'b0;
    always #4  mem_clk   = ~mem_clk;   // 125MHz
    always #20 video_clk = ~video_clk; // 25MHz

    initial begin
        #200 rst = 1'b0;
    end

    // ---------------- display_valid: gated on real read_req rising edges ----------------
    reg display_valid = 1'b0;
    integer req_rise_count = 0;
    reg video_read_req_prev = 1'b0;

    // ---------------- video timing / delay ----------------
    wire hs_0, vs_0, de_0;
    wire video_read_req, video_read_req_ack;
    wire video_read_en;
    wire [31:0] video_read_data;
    wire hs, vs, de;
    wire [23:0] vout_data_raw;

    video_timing_data video_timing_data_m0 (
        .video_clk    (video_clk),
        .rst          (rst),
        .read_req     (video_read_req),
        .read_req_ack (video_read_req_ack),
        .hs           (hs_0),
        .vs           (vs_0),
        .de           (de_0)
    );

    video_delay video_delay_m0 (
        .video_clk (video_clk),
        .rst       (rst),
        .read_en   (video_read_en),
        .read_data (video_read_data[31:8]),
        .hs        (hs_0),
        .vs        (vs_0),
        .de        (de_0),
        .hs_r      (hs),
        .vs_r      (vs),
        .de_r      (de),
        .vout_data (vout_data_raw)
    );

    // ---------------- SDRAM side wires ----------------
    wire                   App_rd_en;
    wire [ADDR_BITS-1:0]   App_rd_addr;
    wire                   Sdr_rd_en;
    wire [31:0]            Sdr_rd_dout;

    wire                   App_wr_en;
    wire [ADDR_BITS-1:0]   App_wr_addr;
    wire [31:0]            App_wr_din;
    wire [3:0]             App_wr_dm;
    wire [3:0]             frame_read_fifo_underflow_count_per_frame;

    sdram_model #(
        .ADDR_BITS     (ADDR_BITS),
        .MAX_BURST     (128),
        .FIXED_LATENCY (4),
        .GAP_CYCLES    (0)   // ideal: no chunk-boundary gap
    ) sdram_m0 (
        .mem_clk     (mem_clk),
        .rst         (rst),
        .App_rd_en   (App_rd_en),
        .App_rd_addr (App_rd_addr),
        .Sdr_rd_en   (Sdr_rd_en),
        .Sdr_rd_dout (Sdr_rd_dout)
    );

    // ---------------- DUT: frame_read_write ----------------
    frame_read_write #(
        .WRITE_V_FLIP (1),
        .FRAME_WIDTH  (640),
        .FRAME_HEIGHT (480)
    ) dut (
        .rst               (rst),
        .mem_clk           (mem_clk),
        .Sdr_init_done     (1'b1),
        .Sdr_init_ref_vld  (1'b1),
        .Sdr_busy          (1'b0),

        .App_rd_en         (App_rd_en),
        .App_rd_addr       (App_rd_addr),
        .Sdr_rd_en         (Sdr_rd_en),
        .Sdr_rd_dout       (Sdr_rd_dout),

        .read_clk          (video_clk),
        .read_req          (video_read_req),
        .read_req_ack      (video_read_req_ack),
        .read_finish       (),
        .read_addr_0       (BUF0_ADDR),
        .read_addr_1       (FRAME_PIXELS),
        .read_addr_2       (24'd0),
        .read_addr_3       (24'd0),
        .read_addr_index      (2'd0),
        .read_addr_index_old  (2'd0),
        .slide_active      (1'b0),
        .slide_position    (10'd0),
        .read_len          (FRAME_PIXELS),
        .read_en           (video_read_en),
        .display_valid     (display_valid),
        .read_data         (video_read_data),
        .read_fault        (),
        .read_fifo_underflow_count_per_frame (frame_read_fifo_underflow_count_per_frame),

        .App_wr_en         (App_wr_en),
        .App_wr_addr       (App_wr_addr),
        .App_wr_din        (App_wr_din),
        .App_wr_dm         (App_wr_dm),

        .write_clk         (mem_clk),
        .write_req         (1'b0),
        .write_req_ack     (),
        .write_finish      (),
        .write_addr_0      (BUF0_ADDR),
        .write_addr_1      (FRAME_PIXELS),
        .write_addr_2      (24'd0),
        .write_addr_3      (24'd0),
        .write_addr_index  (2'd0),
        .write_len         (FRAME_PIXELS),
        .write_en          (1'b0),
        .write_data        (32'd0),
        .write_fifo_afull  ()
    );

    // ---------------- underflow statistics ----------------
    wire underflow_now = display_valid && video_read_en && dut.read_fifo_empty;

    integer frame_count = 0;
    time    last_edge_time = 0;
    integer raw_count_this_frame = 0;
    integer episode_count_this_frame = 0;
    reg     underflow_prev = 1'b0;

    // Single always block driving video_read_req_prev / display_valid /
    // frame bookkeeping / underflow stats -- all on the same video_clk edge,
    // using standard Verilog NBA semantics (every RHS read here sees the
    // pre-edge value, consistent with dut's own registers).
    always @(posedge video_clk) begin
        if (underflow_now) begin
            raw_count_this_frame <= raw_count_this_frame + 1;
            if (!underflow_prev)
                episode_count_this_frame <= episode_count_this_frame + 1;
        end
        underflow_prev <= underflow_now;

        video_read_req_prev <= video_read_req;
        if (video_read_req && !video_read_req_prev) begin
            req_rise_count <= req_rise_count + 1;
            if ((req_rise_count + 1) >= DISPLAY_VALID_AFTER_REQS)
                display_valid <= 1'b1;

            frame_count <= frame_count + 1;
            $display("[FRAME %0d] t=%0t dt_since_last_edge=%0t(ns) display_valid=%0d raw_underflow_cycles_prev_frame=%0d episode_underflow_prev_frame=%0d rtl_underflow_count_per_frame=%0d",
                      frame_count, $time, ($time - last_edge_time), display_valid,
                      raw_count_this_frame, episode_count_this_frame,
                      dut.read_fifo_underflow_count_per_frame);
            last_edge_time <= $time;
            raw_count_this_frame <= 0;
            episode_count_this_frame <= 0;
            if (frame_count >= TARGET_FRAMES) begin
                $display("=== reached %0d frames, finishing (tb_diag) ===", TARGET_FRAMES);
                $finish;
            end
        end
    end

    // ---------------- fine-grained per-mem_clk trace ----------------
    // Only trace once display_valid is active, and only for a bounded window
    // (a couple of active video lines' worth of mem_clk cycles), to avoid
    // flooding output. Prints on any change of {state,phase,read_fifo_empty}
    // plus periodic wrusedw samples.
    reg [3:0] state_prev = 4'hF;
    reg [1:0] phase_prev = 2'b11;
    reg       empty_prev = 1'b0;
    integer   trace_cycles = 0;
    reg       tracing = 1'b0;

    always @(posedge video_clk) begin
        if (display_valid && !tracing) tracing <= 1'b1;
    end

    always @(posedge mem_clk) begin
        if (tracing && trace_cycles < 20000) begin
            trace_cycles <= trace_cycles + 1;
            if (dut.frame_slide_fifo_read_m0.state !== state_prev ||
                dut.frame_slide_fifo_read_m0.phase !== phase_prev ||
                dut.read_fifo_empty !== empty_prev) begin
                $display("TRACE t=%0t state=%0d phase=%0d wrusedw=%0d empty=%0d App_rd_en=%0d Sdr_rd_en=%0d video_read_en=%0d segrem=%0d",
                          $time, dut.frame_slide_fifo_read_m0.state,
                          dut.frame_slide_fifo_read_m0.phase,
                          dut.wrusedw, dut.read_fifo_empty,
                          App_rd_en, Sdr_rd_en, video_read_en,
                          dut.frame_slide_fifo_read_m0.segment_remaining);
            end
            state_prev <= dut.frame_slide_fifo_read_m0.state;
            phase_prev <= dut.frame_slide_fifo_read_m0.phase;
            empty_prev <= dut.read_fifo_empty;
        end
    end

    // safety timeout
    initial begin
        #1_000_000_000; // 1s sim time safety net
        $display("TIMEOUT: did not reach target frame count");
        $finish;
    end
endmodule
