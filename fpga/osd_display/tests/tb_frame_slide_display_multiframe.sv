`timescale 1ns/1ps

module tb_frame_slide_display_multiframe;

localparam integer FRAME_WIDTH  = 64;
localparam integer FRAME_HEIGHT = 2;
localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
localparam [9:0] NEW_BASE       = 10'd256;

reg mem_clk = 1'b0;
reg video_clk = 1'b0;
reg rst = 1'b1;
reg Sdr_init_done = 1'b0;
reg Sdr_rd_en = 1'b0;
reg [31:0] Sdr_rd_dout = 32'd0;
reg read_req = 1'b0;
reg [9:0] slide_position = 10'd0;
reg de_in = 1'b0;

wire read_req_ack;
wire read_finish;
wire fifo_aclr;
wire fifo_write_en;
wire [31:0] fifo_write_data;
wire App_rd_en;
wire [9:0] App_rd_addr;
wire [8:0] wrusedw;
wire fifo_read_en;
wire [31:0] fifo_read_data;
wire fifo_read_valid;
wire de_out;
wire [23:0] rgb_out;
wire read_fault;

reg [9:0] return_queue [0:511];
integer queue_head = 0;
integer queue_tail = 0;
integer queue_count = 0;
reg [23:0] observed [0:FRAME_PIXELS-1];
integer observed_count = 0;
integer current_position = 0;
integer frame_number = 0;

always #4 mem_clk = ~mem_clk;
always #20 video_clk = ~video_clk;

frame_slide_fifo_read #(
    .ADDR_BITS       (10),
    .FRAME_WIDTH     (FRAME_WIDTH),
    .FRAME_HEIGHT    (FRAME_HEIGHT),
    .FIFO_DEPTH      (512),
    .FIFO_LEVEL_BITS (9),
    .MAX_BURST       (32),
    .FEATHER_WIDTH   (32),
    .FEATHER_ENABLE  (1),
    .READ_CHUNK_PREROLL_WORDS (4),
    .FIXED_READ_BURST_ENABLE (1)
) scheduler (
    .mem_clk          (mem_clk),
    .rst              (rst),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_busy         (1'b0),
    .App_wr_busy      (1'b0),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),
    .read_req         (read_req),
    .read_req_ack     (read_req_ack),
    .read_finish      (read_finish),
    .read_addr_0      (10'd0),
    .read_addr_1      (NEW_BASE),
    .read_addr_2      (10'd512),
    .read_addr_3      (10'd768),
    .old_buffer_index (2'd0),
    .new_buffer_index (2'd1),
    .slide_active     (1'b1),
    .slide_position   (slide_position),
    .fifo_aclr        (fifo_aclr),
    .wrusedw          (wrusedw),
    .fifo_write_en    (fifo_write_en),
    .fifo_write_data  (fifo_write_data),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .read_busy        (),
    .read_fault       (read_fault)
);

rfifo_32_32_512 #(
    .SHOW_AHEAD_EN (1'b0),
    .OUTREG_EN     ("OUTREG")
) fifo (
    .clkr       (video_clk),
    .clkw       (mem_clk),
    .rst        (fifo_aclr),
    .we         (fifo_write_en),
    .re         (fifo_read_en),
    .di         (fifo_write_data),
    .empty_flag (),
    .full_flag  (),
    .afull      (),
    .aempty     (),
    .wrusedw    (wrusedw),
    .rdusedw    (),
    .valid      (fifo_read_valid),
    .dout       (fifo_read_data)
);

video_delay delay (
    .video_clk (video_clk),
    .rst       (rst),
    .read_en   (fifo_read_en),
    .read_data (fifo_read_data[31:8]),
    .read_data_valid (fifo_read_valid),
    .hs        (1'b0),
    .vs        (1'b0),
    .de        (de_in),
    .hs_r      (),
    .vs_r      (),
    .de_r      (de_out),
    .vout_data (rgb_out)
);

function automatic [31:0] memory_word;
    input integer address;
    integer local_address;
    integer row;
    integer column;
    integer image;
    begin
        image = (address >= NEW_BASE);
        local_address = image ? address - NEW_BASE : address;
        row = local_address / FRAME_WIDTH;
        column = local_address % FRAME_WIDTH;
        memory_word = {
            image ? (8'h90 + row) : (8'h10 + row),
            column[7:0],
            image ? (8'hE0 - column[7:0]) : (8'h40 + column[7:0]),
            8'h00
        };
    end
endfunction

function automatic [6:0] alpha32;
    input integer index;
    begin
        alpha32 = ((index * 64) + 15) / 31;
    end
endfunction

function automatic [7:0] mix_channel;
    input [7:0] source;
    input [7:0] target;
    input [6:0] alpha;
    integer delta;
    begin
        if (target >= source) begin
            delta = (target - source) * alpha;
            mix_channel = source + (delta >> 6);
        end else begin
            delta = (source - target) * alpha;
            mix_channel = source - (delta >> 6);
        end
    end
endfunction

function automatic [31:0] blend_word;
    input [31:0] source;
    input [31:0] target;
    input [6:0] alpha;
    begin
        blend_word = {
            mix_channel(source[31:24], target[31:24], alpha),
            mix_channel(source[23:16], target[23:16], alpha),
            mix_channel(source[15:8], target[15:8], alpha),
            8'h00
        };
    end
endfunction

function automatic [31:0] expected_word;
    input integer position;
    input integer row;
    input integer x;
    integer old_count;
    integer blend_index;
    begin
        if ((position >= 16) && (position <= 48)) begin
            old_count = FRAME_WIDTH - position - 16;
            if (x < old_count)
                expected_word = memory_word(row * FRAME_WIDTH +
                                            position - 16 + x);
            else if (x < old_count + 32) begin
                blend_index = x - old_count;
                expected_word = blend_word(
                    memory_word(row * FRAME_WIDTH + 32 + blend_index),
                    memory_word(NEW_BASE + row * FRAME_WIDTH + blend_index),
                    alpha32(blend_index));
            end else
                expected_word = memory_word(NEW_BASE + row * FRAME_WIDTH +
                                            x - old_count);
        end else if (x < FRAME_WIDTH - position)
            expected_word = memory_word(row * FRAME_WIDTH + position + x);
        else
            expected_word = memory_word(NEW_BASE + row * FRAME_WIDTH +
                                        x - (FRAME_WIDTH - position));
    end
endfunction

always @(posedge mem_clk) begin
    if (App_rd_en) begin
        return_queue[queue_tail] = App_rd_addr;
        queue_tail = (queue_tail + 1) & 511;
        queue_count = queue_count + 1;
    end
end

always @(negedge mem_clk) begin
    Sdr_rd_en = 1'b0;
    if (queue_count != 0) begin
        Sdr_rd_en = 1'b1;
        Sdr_rd_dout = memory_word(return_queue[queue_head]);
        queue_head = (queue_head + 1) & 511;
        queue_count = queue_count - 1;
    end
end

always @(posedge video_clk) begin
    #1;
    if (de_out) begin
        if (observed_count >= FRAME_PIXELS)
            $fatal(1, "FAIL frame=%0d position=%0d extra pixel %h",
                   frame_number, current_position, rgb_out);
        observed[observed_count] = rgb_out;
        observed_count = observed_count + 1;
    end
end

task automatic drive_line;
    integer x;
    begin
        @(negedge video_clk);
        de_in = 1'b1;
        for (x = 0; x < FRAME_WIDTH; x = x + 1)
            @(negedge video_clk);
        de_in = 1'b0;
        repeat (24) @(negedge video_clk);
    end
endtask

task automatic run_frame;
    input integer position;
    integer row;
    integer x;
    reg [31:0] expected;
    begin
        current_position = position;
        observed_count = 0;
        slide_position = position;
        @(negedge mem_clk);
        read_req = 1'b1;
        wait (read_req_ack === 1'b1);
        @(negedge mem_clk);
        read_req = 1'b0;
        wait (read_finish === 1'b1);
        repeat (4) @(negedge video_clk);

        drive_line;
        drive_line;
        repeat (8) @(negedge video_clk);

        if (observed_count != FRAME_PIXELS)
            $fatal(1, "FAIL frame=%0d position=%0d count expected %0d got %0d",
                   frame_number, position, FRAME_PIXELS, observed_count);

        if (delay.align_underflow !== 1'b0)
            $fatal(1, "FAIL frame=%0d alignment queue underflow", frame_number);
        if (delay.align_overflow !== 1'b0)
            $fatal(1, "FAIL frame=%0d alignment queue overflow", frame_number);
        if (delay.align_count !== 3'd0)
            $fatal(1, "FAIL frame=%0d alignment queue retained %0d pixels",
                   frame_number, delay.align_count);

        for (row = 0; row < FRAME_HEIGHT; row = row + 1) begin
            for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
                expected = expected_word(position, row, x);
                if (observed[row * FRAME_WIDTH + x] !== expected[31:8])
                    $fatal(1,
                        "FAIL frame=%0d position=%0d row=%0d x=%0d expected %h got %h",
                        frame_number, position, row, x, expected[31:8],
                        observed[row * FRAME_WIDTH + x]);
            end
        end
        frame_number = frame_number + 1;
    end
endtask

initial begin
    repeat (4) @(posedge mem_clk);
    Sdr_init_done = 1'b1;
    rst = 1'b0;

    run_frame(0);
    run_frame(2);
    run_frame(20);
    run_frame(35);
    run_frame(48);
    run_frame(62);
    run_frame(64);

    if (read_fault !== 1'b0)
        $fatal(1, "FAIL read_fault asserted");
    $display("PASS tb_frame_slide_display_multiframe frames=%0d pixels=%0d",
             frame_number, frame_number * FRAME_PIXELS);
    $finish;
end

initial begin
    #20000000;
    $fatal(1, "FAIL timeout frame=%0d position=%0d observed=%0d",
           frame_number, current_position, observed_count);
end

endmodule
