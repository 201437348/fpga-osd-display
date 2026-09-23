module image_load_manager #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer LOAD_TIMEOUT_SECONDS = 10,
    parameter integer LOAD_ABS_TIMEOUT_SECONDS = 60,
    parameter integer MAX_LOAD_RETRIES = 2,
    parameter integer STORAGE_INIT_TIMEOUT_SECONDS = 10
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       storage_ready,
    input  wire       scan_done,
    input  wire [3:0] scan_found_count,
    input  wire       source_done_pulse,
    input  wire       source_error_pulse,
    input  wire       storage_fault_pulse,
    input  wire       write_done_pulse,
    input  wire       load_progress_pulse,
    input  wire       next_request,
    input  wire       auto_request,

    output reg        scan_start,
    output reg        load_start,
    output reg        load_abort,
    output reg        storage_reinit,
    output reg [2:0]  target_image_index,
    output reg [1:0]  write_buffer_index,
    output reg [1:0]  display_buffer_index,
    output reg [2:0]  current_image_index,
    output reg        display_valid,
    output reg        display_test_pattern,
    output reg [2:0]  state,
    output reg [1:0]  retry_count,
    output reg [3:0]  error_code,
    output reg        pending_next,
    output reg        source_done_seen,
    output reg        write_done_seen,
    output reg [3:0]  image_count,
    output wire       load_in_progress,
    output wire       idle
);

localparam [2:0] ST_RESET_WAIT = 3'd0;
localparam [2:0] ST_SCAN       = 3'd1;
localparam [2:0] ST_LOAD       = 3'd2;
localparam [2:0] ST_VERIFY     = 3'd3;
localparam [2:0] ST_COMMIT     = 3'd4;
localparam [2:0] ST_IDLE       = 3'd5;
localparam [2:0] ST_RECOVER    = 3'd6;

localparam [3:0] ERR_NONE       = 4'd0;
localparam [3:0] ERR_SCAN_EMPTY = 4'd1;
localparam [3:0] ERR_TIMEOUT    = 4'd2;
localparam [3:0] ERR_ALL_FAILED = 4'd3;
localparam [3:0] ERR_STORAGE_INIT = 4'd4;
localparam [3:0] ERR_SOURCE = 4'd5;

localparam [31:0] LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * LOAD_TIMEOUT_SECONDS;
localparam [31:0] STORAGE_INIT_TIMEOUT_CYCLES =
    CLK_FREQ_HZ * STORAGE_INIT_TIMEOUT_SECONDS;
// 绝对上限：即使一直在"有进度"，也不能无限拖
localparam [31:0] LOAD_ABS_TIMEOUT_CYCLES =
    CLK_FREQ_HZ * LOAD_ABS_TIMEOUT_SECONDS;

reg [3:0]  skipped_image_count;
reg [31:0] load_timeout_count;
reg [31:0] load_abs_count;
reg [31:0] storage_init_wait_count;
reg        scan_active_seen;
reg        resume_next_after_reinit;
reg        preserve_display_after_reinit;

assign load_in_progress = (state == ST_LOAD) || (state == ST_VERIFY);
assign idle             = (state == ST_IDLE);

// 图片索引 0..7，最多 8 张；在 0..count-1 之间循环
function [2:0] next_image_index;
    input [2:0] current;
    input [3:0] count;
    reg [3:0] nxt;
    begin
        nxt = {1'b0, current} + 4'd1;
        if ((count == 4'd0) || (nxt >= count))
            next_image_index = 3'd0;
        else
            next_image_index = nxt[2:0];
    end
endfunction

function [1:0] inactive_buffer;
    input [1:0] current;
    begin
        inactive_buffer = (current == 2'd0) ? 2'd1 : 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_start          <= 1'b0;
        load_start          <= 1'b0;
        load_abort          <= 1'b0;
        storage_reinit      <= 1'b0;
        target_image_index  <= 2'd0;
        write_buffer_index  <= 2'd0;
        display_buffer_index <= 2'd0;
        current_image_index <= 2'd0;
        display_valid       <= 1'b0;
        display_test_pattern <= 1'b0;
        state               <= ST_RESET_WAIT;
        retry_count         <= 2'd0;
        error_code          <= ERR_NONE;
        pending_next        <= 1'b0;
        image_count         <= 3'd0;
        skipped_image_count <= 3'd0;
        load_timeout_count  <= 32'd0;
        load_abs_count      <= 32'd0;
        storage_init_wait_count <= 32'd0;
        source_done_seen    <= 1'b0;
        write_done_seen     <= 1'b0;
        scan_active_seen    <= 1'b0;
        resume_next_after_reinit <= 1'b0;
        preserve_display_after_reinit <= 1'b0;
    end else begin
        scan_start <= 1'b0;
        load_start <= 1'b0;
        load_abort <= 1'b0;
        storage_reinit <= 1'b0;

        if (storage_fault_pulse) begin
            storage_reinit      <= 1'b1;
            load_abort          <= (state == ST_LOAD) || (state == ST_VERIFY);
            state               <= ST_RESET_WAIT;
            pending_next        <= 1'b0;
            image_count         <= 3'd0;
            retry_count         <= 2'd0;
            skipped_image_count <= 3'd0;
            load_timeout_count  <= 32'd0;
            load_abs_count      <= 32'd0;
            source_done_seen    <= 1'b0;
            write_done_seen     <= 1'b0;
            scan_active_seen    <= 1'b0;
            resume_next_after_reinit <= 1'b0;
            preserve_display_after_reinit <= display_valid;
        end else if (!storage_ready) begin
            // The vendor SD core stays uninitialized when no card is present.
            // Keep a prior frame, but make a no-card startup visible after a guard period.
            if (!display_valid) begin
                if (storage_init_wait_count >= (STORAGE_INIT_TIMEOUT_CYCLES - 1'b1)) begin
                    display_test_pattern <= 1'b1;
                    error_code           <= ERR_STORAGE_INIT;
                end else begin
                    storage_init_wait_count <= storage_init_wait_count + 1'b1;
                end
            end else begin
                storage_init_wait_count <= 32'd0;
            end

            if ((state == ST_LOAD) || (state == ST_VERIFY))
                load_abort <= 1'b1;

            state              <= ST_RESET_WAIT;
            pending_next       <= 1'b0;
            image_count        <= 3'd0;
            retry_count        <= 2'd0;
            skipped_image_count <= 3'd0;
            load_timeout_count <= 32'd0;
            source_done_seen   <= 1'b0;
            write_done_seen    <= 1'b0;
            scan_active_seen   <= 1'b0;
        end else begin
            storage_init_wait_count <= 32'd0;

            case (state)
                ST_RESET_WAIT: begin
                    scan_start       <= 1'b1;
                    scan_active_seen <= 1'b0;
                    state            <= ST_SCAN;
                end

                ST_SCAN: begin
                    // A prior scan_done level must fall after scan_start before it is accepted.
                    if (!scan_done) begin
                        scan_active_seen <= 1'b1;
                    end else if (scan_active_seen) begin
                        image_count <= scan_found_count;
                        if (scan_found_count != 3'd0) begin
                            target_image_index <= (resume_next_after_reinit && display_valid) ?
                                                  next_image_index(current_image_index, scan_found_count) :
                                                  2'd0;
                            write_buffer_index <= display_valid ?
                                                  inactive_buffer(display_buffer_index) : 2'd0;
                            retry_count         <= 2'd0;
                            skipped_image_count <= 3'd0;
                            resume_next_after_reinit <= 1'b0;
                            if (preserve_display_after_reinit && display_valid) begin
                                preserve_display_after_reinit <= 1'b0;
                                state                         <= ST_IDLE;
                            end else begin
                                state <= ST_LOAD;
                            end
                        end else begin
                            error_code <= ERR_SCAN_EMPTY;
                            resume_next_after_reinit <= 1'b0;
                            preserve_display_after_reinit <= 1'b0;
                            if (!display_valid)
                                display_test_pattern <= 1'b1;
                            state <= ST_RECOVER;
                        end
                    end
                end

                ST_LOAD: begin
                    load_start         <= 1'b1;
                    load_timeout_count <= 32'd0;
                    load_abs_count     <= 32'd0;
                    source_done_seen   <= 1'b0;
                    write_done_seen    <= 1'b0;
                    state              <= ST_VERIFY;
                end

                ST_VERIFY: begin
                    if (source_done_pulse)
                        source_done_seen <= 1'b1;
                    if (write_done_pulse)
                        write_done_seen <= 1'b1;

                    if (source_error_pulse ||
                        (!((source_done_seen || source_done_pulse) &&
                           (write_done_seen || write_done_pulse)) &&
                         ((load_timeout_count >= (LOAD_TIMEOUT_CYCLES - 1'b1)) ||
                          (load_abs_count    >= (LOAD_ABS_TIMEOUT_CYCLES - 1'b1))))) begin
                        load_abort <= 1'b1;
                        error_code <= source_error_pulse ? ERR_SOURCE : ERR_TIMEOUT;

                        if (retry_count < MAX_LOAD_RETRIES) begin
                            retry_count <= retry_count + 2'd1;
                            state       <= ST_LOAD;
                        end else if (!display_valid) begin
                            retry_count         <= 2'd0;
                            display_test_pattern <= 1'b1;
                            state               <= ST_RECOVER;
                        end else if ((image_count > 3'd1) &&
                                     (skipped_image_count < (image_count - 4'd1))) begin
                            retry_count         <= 2'd0;
                            skipped_image_count <= skipped_image_count + 3'd1;
                            target_image_index  <= next_image_index(target_image_index, image_count);
                            write_buffer_index  <= inactive_buffer(display_buffer_index);
                            state               <= ST_LOAD;
                        end else begin
                            retry_count <= 2'd0;
                            error_code  <= ERR_ALL_FAILED;
                            state       <= ST_IDLE;
                        end
                    end else if ((source_done_seen || source_done_pulse) &&
                        (write_done_seen || write_done_pulse)) begin
                        state <= ST_COMMIT;
                    end else begin
                        // 每读完一个源扇区就把"无进展"计时清零；
                        // 只有真的卡住（连续 10s 一个扇区都没读完）才判超时。
                        if (load_progress_pulse)
                            load_timeout_count <= 32'd0;
                        else
                            load_timeout_count <= load_timeout_count + 32'd1;
                        load_abs_count <= load_abs_count + 32'd1;
                    end
                end

                ST_COMMIT: begin
                    display_buffer_index <= write_buffer_index;
                    current_image_index  <= target_image_index;
                    display_valid        <= 1'b1;
                    display_test_pattern <= 1'b0;
                    retry_count          <= 2'd0;
                    skipped_image_count  <= 3'd0;
                    error_code           <= ERR_NONE;
                    state                <= ST_IDLE;
                end

                ST_IDLE: begin
                    if ((error_code == ERR_ALL_FAILED) && next_request) begin
                        storage_reinit    <= 1'b1;
                        pending_next      <= 1'b0;
                        retry_count       <= 2'd0;
                        skipped_image_count <= 3'd0;
                        resume_next_after_reinit <= 1'b1;
                        state             <= ST_RESET_WAIT;
                    end else if ((error_code != ERR_ALL_FAILED) &&
                                 (next_request || auto_request)) begin
                        target_image_index <= next_image_index(current_image_index, image_count);
                        write_buffer_index <= inactive_buffer(display_buffer_index);
                        pending_next       <= 1'b0;
                        retry_count        <= 2'd0;
                        skipped_image_count <= 3'd0;
                        state              <= ST_LOAD;
                    end
                end

                ST_RECOVER: begin
                    scan_start       <= 1'b1;
                    scan_active_seen <= 1'b0;
                    state            <= ST_SCAN;
                end

                default: begin
                    state <= ST_RESET_WAIT;
                end
            endcase
        end
    end
end

endmodule
