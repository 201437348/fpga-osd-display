`timescale 1ns/1ps

module tb_frame_slide_full_line #(
    parameter integer FEATHER_ENABLE = 1,
    parameter integer UNIFORM_DIAGNOSTIC = 0,
    parameter integer SDRAM_UNIFORM_DIAGNOSTIC = 0,
    parameter integer ADDRESS_PATTERN_DIAGNOSTIC = 0
);

localparam integer FRAME_WIDTH = 640;
localparam integer FRAME_HEIGHT = 2;
localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
localparam integer NEW_BASE = 2048;

reg mem_clk = 1'b0;
reg rst = 1'b1;
reg Sdr_init_done = 1'b0;
reg Sdr_busy = 1'b0;
reg App_wr_busy = 1'b0;
reg Sdr_rd_en = 1'b0;
reg [31:0] Sdr_rd_dout = 32'd0;
reg read_req = 1'b0;
reg slide_active = 1'b1;
reg [9:0] slide_position = 10'd0;
reg [8:0] wrusedw = 9'd0;

wire read_req_ack;
wire read_finish;
wire fifo_aclr;
wire fifo_write_en;
wire [31:0] fifo_write_data;
wire App_rd_en;
wire [13:0] App_rd_addr;
wire read_busy;
wire read_fault;

reg [13:0] return_queue [0:4095];
reg [31:0] observed [0:FRAME_PIXELS-1];
integer queue_head = 0;
integer queue_tail = 0;
integer queue_count = 0;
integer observed_count = 0;
integer i;

always #4 mem_clk = ~mem_clk;

frame_slide_fifo_read #(
    .ADDR_BITS       (14),
    .FRAME_WIDTH     (FRAME_WIDTH),
    .FRAME_HEIGHT    (FRAME_HEIGHT),
    .FIFO_DEPTH      (512),
    .FIFO_LEVEL_BITS (9),
    .MAX_BURST       (128),
    .FEATHER_WIDTH   (32),
    .FEATHER_ENABLE  (FEATHER_ENABLE),
    .SLIDE_FIFO_UNIFORM_DIAGNOSTIC (UNIFORM_DIAGNOSTIC),
    .SLIDE_SDRAM_UNIFORM_DIAGNOSTIC (SDRAM_UNIFORM_DIAGNOSTIC),
    .SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC (ADDRESS_PATTERN_DIAGNOSTIC),
    .READ_CHUNK_PREROLL_WORDS (4),
    .FIXED_READ_BURST_ENABLE (1)
) dut (
    .mem_clk          (mem_clk),
    .rst              (rst),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_busy         (Sdr_busy),
    .App_wr_busy      (App_wr_busy),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),
    .read_req         (read_req),
    .read_req_ack     (read_req_ack),
    .read_finish      (read_finish),
    .read_addr_0      (14'd0),
    .read_addr_1      (14'd2048),
    .read_addr_2      (14'd4096),
    .read_addr_3      (14'd6144),
    .old_buffer_index (2'd0),
    .new_buffer_index (2'd1),
    .slide_active     (slide_active),
    .slide_position   (slide_position),
    .fifo_aclr        (fifo_aclr),
    .wrusedw          (wrusedw),
    .fifo_write_en    (fifo_write_en),
    .fifo_write_data  (fifo_write_data),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .read_busy        (read_busy),
    .read_fault       (read_fault)
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

function automatic [31:0] address_pattern_word;
    input integer address;
    reg [6:0] phase;
    begin
        phase = address[6:0];
        address_pattern_word = {
            phase, 1'b0,
            ~{phase, 1'b0},
            phase[5:0], 2'b00,
            8'h00
        };
    end
endfunction

function automatic [31:0] source_word;
    input integer address;
    begin
        source_word = ADDRESS_PATTERN_DIAGNOSTIC ?
                      address_pattern_word(address) : memory_word(address);
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
    integer new_column;
    begin
        if (!slide_active) begin
            expected_word = memory_word(NEW_BASE + row * FRAME_WIDTH + x);
        end else if (UNIFORM_DIAGNOSTIC || SDRAM_UNIFORM_DIAGNOSTIC) begin
            expected_word = {
                position[7:0],
                ~position[7:0],
                position[6:0], 1'b0,
                8'h00
            };
        end else if (FEATHER_ENABLE &&
            (position >= 16) && (position <= 624)) begin
            old_count = FRAME_WIDTH - position - 16;
            if (x < old_count) begin
                expected_word = source_word(row * FRAME_WIDTH +
                                            position - 16 + x);
            end else if (x < old_count + 32) begin
                blend_index = x - old_count;
                expected_word = blend_word(
                    source_word(row * FRAME_WIDTH + 608 + blend_index),
                    source_word(NEW_BASE + row * FRAME_WIDTH + blend_index),
                    alpha32(blend_index));
            end else begin
                new_column = 32 + x - old_count - 32;
                expected_word = source_word(NEW_BASE + row * FRAME_WIDTH +
                                            new_column);
            end
        end else if (x < FRAME_WIDTH - position) begin
            expected_word = source_word(row * FRAME_WIDTH + position + x);
        end else begin
            expected_word = source_word(NEW_BASE + row * FRAME_WIDTH +
                                        x - (FRAME_WIDTH - position));
        end
    end
endfunction

always @(posedge mem_clk) begin
    if (App_rd_en) begin
        return_queue[queue_tail] = App_rd_addr;
        queue_tail = (queue_tail + 1) & 4095;
        queue_count = queue_count + 1;
    end
end

always @(negedge mem_clk) begin
    Sdr_rd_en = 1'b0;
    if (queue_count != 0) begin
        Sdr_rd_en = 1'b1;
        Sdr_rd_dout = memory_word(return_queue[queue_head]);
        queue_head = (queue_head + 1) & 4095;
        queue_count = queue_count - 1;
    end

    if (fifo_write_en) begin
        if (observed_count >= FRAME_PIXELS)
            $fatal(1, "FAIL position %0d produced extra pixel %h",
                   slide_position, fifo_write_data);
        observed[observed_count] = fifo_write_data;
        observed_count = observed_count + 1;
    end
end

task automatic run_position;
    input integer position;
    input integer active;
    integer row;
    integer x;
    reg [31:0] expected;
    begin
        observed_count = 0;
        slide_position = position;
        slide_active = active;
        @(negedge mem_clk);
        read_req = 1'b1;
        wait (read_req_ack === 1'b1);
        @(negedge mem_clk);
        read_req = 1'b0;
        wait (read_finish === 1'b1);
        @(negedge mem_clk);

        if (observed_count != FRAME_PIXELS)
            $fatal(1, "FAIL position %0d count expected %0d got %0d",
                   position, FRAME_PIXELS, observed_count);

        for (row = 0; row < FRAME_HEIGHT; row = row + 1) begin
            for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
                expected = expected_word(position, row, x);
                if (observed[row * FRAME_WIDTH + x] !== expected)
                    $fatal(1,
                        "FAIL position %0d row %0d x %0d expected %h got %h",
                        position, row, x, expected,
                        observed[row * FRAME_WIDTH + x]);
            end
        end
    end
endtask

initial begin
    repeat (4) @(posedge mem_clk);
    Sdr_init_done = 1'b1;
    rst = 1'b0;

    run_position(0, 1);
    run_position(2, 1);
    run_position(16, 1);
    run_position(320, 1);
    run_position(624, 1);
    run_position(638, 1);
    run_position(640, 1);
    run_position(319, 0);

    if (read_fault !== 1'b0)
        $fatal(1, "FAIL full-line scan latched read_fault");
    $display("PASS tb_frame_slide_full_line");
    $finish;
end

endmodule
