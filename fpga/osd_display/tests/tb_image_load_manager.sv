`timescale 1ns/1ps

module tb_image_load_manager;

reg clk = 1'b0;
reg rst = 1'b1;
reg storage_ready = 1'b0;
reg scan_done = 1'b0;
reg [2:0] scan_found_count = 3'd0;
reg source_done_pulse = 1'b0;
reg source_error_pulse = 1'b0;
reg storage_fault_pulse = 1'b0;
reg write_done_pulse = 1'b0;
reg next_request = 1'b0;
reg auto_request = 1'b0;

wire scan_start;
wire load_start;
wire load_abort;
wire storage_reinit;
wire [1:0] target_image_index;
wire [1:0] write_buffer_index;
wire [1:0] display_buffer_index;
wire [1:0] current_image_index;
wire display_valid;
wire display_test_pattern;
wire [2:0] state;
wire [1:0] retry_count;
wire [3:0] error_code;
wire pending_next;
wire source_done_seen;
wire write_done_seen;
wire [2:0] image_count;
wire load_in_progress;
wire idle;

always #5 clk = ~clk;

image_load_manager #(
    .CLK_FREQ_HZ(4),
    .LOAD_TIMEOUT_SECONDS(1),
    .MAX_LOAD_RETRIES(2),
    .STORAGE_INIT_TIMEOUT_SECONDS(1)
) dut (
    .clk(clk),
    .rst(rst),
    .storage_ready(storage_ready),
    .scan_done(scan_done),
    .scan_found_count(scan_found_count),
    .source_done_pulse(source_done_pulse),
    .source_error_pulse(source_error_pulse),
    .storage_fault_pulse(storage_fault_pulse),
    .write_done_pulse(write_done_pulse),
    .next_request(next_request),
    .auto_request(auto_request),
    .scan_start(scan_start),
    .load_start(load_start),
    .load_abort(load_abort),
    .storage_reinit(storage_reinit),
    .target_image_index(target_image_index),
    .write_buffer_index(write_buffer_index),
    .display_buffer_index(display_buffer_index),
    .current_image_index(current_image_index),
    .display_valid(display_valid),
    .display_test_pattern(display_test_pattern),
    .state(state),
    .retry_count(retry_count),
    .error_code(error_code),
    .pending_next(pending_next),
    .source_done_seen(source_done_seen),
    .write_done_seen(write_done_seen),
    .image_count(image_count),
    .load_in_progress(load_in_progress),
    .idle(idle)
);

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

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

task automatic wait_for_state;
    input [2:0] expected;
    input [255:0] checkpoint;
    integer count;
    begin
        count = 0;
        while ((state !== expected) && (count < 40)) begin
            tick();
            count = count + 1;
        end
        if (state !== expected)
            $fatal(1, "FAIL %0s: state did not reach %0d", checkpoint, expected);
    end
endtask

task automatic finish_scan;
    input [2:0] count;
    begin
        scan_done = 1'b0;
        scan_found_count = count;
        wait_for_state(3'd1, "scan state");
        tick();
        scan_done = 1'b1;
        tick();
        scan_done = 1'b0;
        wait_for_state(3'd2, "load state after scan");
    end
endtask

task automatic complete_current_load;
    input write_first;
    begin
        wait_for_state(3'd3, "verify state");
        if (write_first) begin
            write_done_pulse = 1'b1;
            tick();
            write_done_pulse = 1'b0;
            source_done_pulse = 1'b1;
            tick();
            source_done_pulse = 1'b0;
        end else begin
            source_done_pulse = 1'b1;
            tick();
            source_done_pulse = 1'b0;
            write_done_pulse = 1'b1;
            tick();
            write_done_pulse = 1'b0;
        end
        wait_for_state(3'd5, "idle after commit");
    end
endtask

task automatic finish_preserving_recovery_scan;
    input [2:0] count;
    begin
        scan_done = 1'b0;
        scan_found_count = count;
        wait_for_state(3'd1, "display-preserving recovery scan state");
        tick();
        scan_done = 1'b1;
        tick();
        scan_done = 1'b0;
        wait_for_state(3'd5, "display-preserving recovery returns idle");
    end
endtask

task automatic reset_dut;
    begin
        rst = 1'b1;
        storage_ready = 1'b0;
        scan_done = 1'b0;
        scan_found_count = 3'd0;
        source_done_pulse = 1'b0;
        source_error_pulse = 1'b0;
        storage_fault_pulse = 1'b0;
        write_done_pulse = 1'b0;
        next_request = 1'b0;
        auto_request = 1'b0;
        repeat (2) tick();
        rst = 1'b0;
        tick();
    end
endtask

initial begin
    // No TF card: init never completes, so the fallback pattern must become visible.
    reset_dut();
    repeat (3) tick();
    expect_bit(display_valid, 1'b0, "no-card startup has no committed frame");
    expect_bit(display_test_pattern, 1'b1, "no-card startup enables fallback");
    expect_value(error_code, 4'd4, "no-card startup reports storage-init error");

    reset_dut();
    storage_ready = 1'b1;
    finish_scan(3'd3);
    expect_value(image_count, 3'd3, "scanned image count");
    expect_value(target_image_index, 2'd0, "first image index");
    expect_value(write_buffer_index, 2'd0, "first image buffer");
    complete_current_load(1'b1);
    expect_bit(idle, 1'b1, "manager idle after first commit");
    expect_bit(display_valid, 1'b1, "first frame committed");
    expect_bit(display_test_pattern, 1'b0, "test pattern disabled after commit");
    expect_value(display_buffer_index, 2'd0, "first display buffer");

    // A hung sector request initiates SD recovery but must retain the current
    // SDRAM frame. The recovered directory scan supplies audio metadata only;
    // it must not reload or switch the displayed image.
    storage_fault_pulse = 1'b1;
    tick();
    storage_fault_pulse = 1'b0;
    expect_bit(storage_reinit, 1'b1, "storage fault emits reinit pulse");
    expect_value(state, 3'd0, "storage fault returns to reset wait");
    expect_bit(display_valid, 1'b1, "storage fault retains committed frame");
    expect_value(current_image_index, 2'd0, "storage fault retains current index");
    expect_value(display_buffer_index, 2'd0, "storage fault retains display buffer");
    storage_ready = 1'b0;
    tick();
    storage_ready = 1'b1;
    finish_preserving_recovery_scan(3'd3);
    expect_value(image_count, 3'd3, "recovery refreshes image metadata");
    expect_value(current_image_index, 2'd0, "recovery does not switch image");
    expect_value(display_buffer_index, 2'd0, "recovery does not replace frame");
    expect_bit(load_in_progress, 1'b0, "recovery does not start BMP load");

    next_request = 1'b1;
    tick();
    next_request = 1'b0;
    wait_for_state(3'd2, "manual next starts load");
    expect_value(target_image_index, 2'd1, "manual next target");
    expect_value(write_buffer_index, 2'd1, "manual next inactive buffer");

    // A second request while a load is active must be discarded, not queued.
    next_request = 1'b1;
    tick();
    next_request = 1'b0;
    expect_bit(pending_next, 1'b0, "busy manual next is discarded");

    // Three failed attempts skip image 1 while retaining the committed frame.
    wait_for_state(3'd3, "first failing verify");
    repeat (5) tick();
    wait_for_state(3'd3, "second failing verify");
    repeat (5) tick();
    wait_for_state(3'd3, "third failing verify");
    repeat (5) tick();
    wait_for_state(3'd2, "failed image skipped");
    expect_value(target_image_index, 2'd2, "skip moves to image 2");
    expect_bit(display_valid, 1'b1, "previous frame retained on failure");
    expect_value(display_buffer_index, 2'd0, "previous buffer retained on failure");
    complete_current_load(1'b0);
    expect_value(current_image_index, 2'd2, "next valid image committed");
    expect_value(display_buffer_index, 2'd1, "second buffer committed");

    storage_ready = 1'b0;
    tick();
    expect_value(state, 3'd0, "storage loss returns to reset wait");
    expect_bit(display_valid, 1'b1, "storage loss retains displayed frame");
    expect_bit(display_test_pattern, 1'b0, "storage loss does not replace valid frame");

    // A malformed FAT/BMP source retries immediately instead of consuming the timeout.
    reset_dut();
    storage_ready = 1'b1;
    finish_scan(3'd1);
    wait_for_state(3'd3, "source-error verify");
    source_error_pulse = 1'b1;
    tick();
    source_error_pulse = 1'b0;
    expect_value(state, 3'd2, "source error immediately starts retry");
    expect_bit(load_abort, 1'b1, "source error aborts the active load");
    expect_value(retry_count, 2'd1, "source error increments retry count");
    expect_value(error_code, 4'd5, "source error has a distinct code");

    // Valid source and write completion win even on the final timeout clock.
    reset_dut();
    storage_ready = 1'b1;
    finish_scan(3'd1);
    wait_for_state(3'd3, "deadline completion verify");
    @(negedge clk);
    dut.load_timeout_count = 32'd3;
    source_done_pulse = 1'b1;
    write_done_pulse = 1'b1;
    tick();
    source_done_pulse = 1'b0;
    write_done_pulse = 1'b0;
    wait_for_state(3'd5, "deadline completion commits frame");
    expect_bit(display_valid, 1'b1, "deadline completion remains valid");
    expect_value(error_code, 4'd0, "deadline completion is not a timeout");

    // After all candidate images fail, a manual request resets only storage.
    reset_dut();
    storage_ready = 1'b1;
    finish_scan(3'd2);
    complete_current_load(1'b1);
    next_request = 1'b1;
    tick();
    next_request = 1'b0;
    wait_for_state(3'd3, "reinsert test first failing verify");
    repeat (5) tick();
    wait_for_state(3'd3, "reinsert test second failing verify");
    repeat (5) tick();
    wait_for_state(3'd3, "reinsert test third failing verify");
    repeat (5) tick();
    wait_for_state(3'd5, "all failed state");
    expect_value(error_code, 4'd3, "all failed error code");

    next_request = 1'b1;
    tick();
    expect_bit(storage_reinit, 1'b1, "manual request emits storage reinit");
    expect_value(state, 3'd0, "manual reinit returns to reset wait");
    expect_bit(display_valid, 1'b1, "manual reinit retains committed frame");
    next_request = 1'b0;
    storage_ready = 1'b0;
    tick();
    expect_bit(storage_reinit, 1'b0, "storage reinit is one pulse");
    storage_ready = 1'b1;
    finish_scan(3'd2);
    expect_value(target_image_index, 2'd1, "reinit resumes the requested successor image");

    reset_dut();
    storage_ready = 1'b1;
    finish_scan(3'd1);
    wait_for_state(3'd3, "first-image verify");
    repeat (5) tick();
    wait_for_state(3'd3, "first-image retry one");
    repeat (5) tick();
    wait_for_state(3'd3, "first-image retry two");
    repeat (5) tick();
    while (!display_test_pattern && (dut.state !== 3'd1))
        tick();
    expect_bit(display_valid, 1'b0, "failed first image is not committed");
    expect_bit(display_test_pattern, 1'b1, "failed first image shows test pattern");
    expect_value(error_code, 4'd2, "first-image timeout recorded");

    $display("PASS tb_image_load_manager");
    $finish;
end

endmodule
