`timescale 1ns/1ps

module tb_image_load_manager;

reg clk = 1'b0;
reg rst = 1'b1;
reg storage_ready = 1'b0;
reg scan_done = 1'b0;
reg [3:0] scan_found_count = 4'd0;
reg source_done_pulse = 1'b0;
reg source_error_pulse = 1'b0;
reg storage_fault_pulse = 1'b0;
reg write_done_pulse = 1'b0;
reg next_request = 1'b0;
reg auto_request = 1'b0;
reg prev_request = 1'b0;
reg load_progress_pulse = 1'b0;
// Legacy checks below keep the display "unsettled" so no background preload
// starts; the cache section at the end raises it.
reg display_settled = 1'b0;

wire scan_start;
wire load_start;
wire load_abort;
wire storage_reinit;
wire [2:0] target_image_index;
wire [2:0] write_buffer_index;
wire [2:0] display_buffer_index;
wire [2:0] current_image_index;
wire display_valid;
wire display_test_pattern;
wire [2:0] state;
wire [1:0] retry_count;
wire [3:0] error_code;
wire pending_next;
wire source_done_seen;
wire write_done_seen;
wire [3:0] image_count;
wire load_in_progress;
wire idle;
wire commit_pulse;
wire preloading;

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
    .load_progress_pulse(load_progress_pulse),
    .display_settled(display_settled),
    .next_request(next_request),
    .auto_request(auto_request),
    .prev_request(prev_request),
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
    .idle(idle),
    .commit_pulse(commit_pulse),
    .preloading(preloading)
);

integer commit_count = 0;
always @(posedge commit_pulse) commit_count = commit_count + 1;
integer abort_count = 0;
always @(posedge load_abort) abort_count = abort_count + 1;

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
    input [3:0] count;
    begin
        scan_done = 1'b0;
        scan_found_count = count;
        wait_for_state(3'd1, "scan state");
        tick();
        scan_done = 1'b1;
        tick();
        scan_done = 1'b0;
        wait_for_state(3'd2, "load state after scan");   // via ST_SELECT (miss)
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
    input [3:0] count;
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
        scan_found_count = 4'd0;
        display_settled = 1'b0;
        source_done_pulse = 1'b0;
        source_error_pulse = 1'b0;
        storage_fault_pulse = 1'b0;
        write_done_pulse = 1'b0;
        next_request = 1'b0;
        auto_request = 1'b0;
        prev_request = 1'b0;
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

    // -----------------------------------------------------------------
    // Six-slot cache, 5 images: after one round every image stays in SDRAM
    // -----------------------------------------------------------------
    reset_dut();
    commit_count = 0;
    storage_ready = 1'b1;
    finish_scan(4'd5);
    complete_current_load(1'b1);
    expect_value(display_buffer_index, 3'd0, "cache: first image in slot 0");
    expect_value(commit_count, 1, "cache: first load commits once");
    display_settled = 1'b1;

    // Priority +1, +2, -1, +3 (-2 == +3 for 5 images): 1, 2, 4, 3 -> slots 1..4.
    wait_for_state(3'd3, "cache: preload +1 verify");
    expect_bit(preloading, 1'b1, "cache: preload flag");
    expect_bit(idle, 1'b1, "cache: preload still reports idle");
    expect_value(target_image_index, 3'd1, "cache: preload target 1");
    expect_value(write_buffer_index, 3'd1, "cache: preload slot 1");
    complete_current_load(1'b1);
    expect_value(display_buffer_index, 3'd0, "cache: preload keeps display");
    expect_value(current_image_index, 3'd0, "cache: preload keeps current");
    expect_value(commit_count, 1, "cache: preload does not commit");
    wait_for_state(3'd3, "cache: preload +2 verify");
    expect_value(target_image_index, 3'd2, "cache: preload target 2");
    expect_value(write_buffer_index, 3'd2, "cache: preload slot 2");
    complete_current_load(1'b0);
    wait_for_state(3'd3, "cache: preload -1 verify");
    expect_value(target_image_index, 3'd4, "cache: preload target 4 (prev)");
    expect_value(write_buffer_index, 3'd3, "cache: preload slot 3");
    complete_current_load(1'b1);
    wait_for_state(3'd3, "cache: preload +3 verify");
    expect_value(target_image_index, 3'd3, "cache: preload target 3");
    expect_value(write_buffer_index, 3'd4, "cache: preload slot 4");

    // A request during a preload whose successor is cached switches at once.
    next_request = 1'b1;
    tick();
    next_request = 1'b0;
    expect_value(current_image_index, 3'd1, "cache: hit during preload");
    expect_value(display_buffer_index, 3'd1, "cache: hit slot during preload");
    expect_value(commit_count, 2, "cache: hit during preload commits");
    expect_bit(preloading, 1'b1, "cache: preload continues");
    complete_current_load(1'b1);
    expect_value(display_buffer_index, 3'd1, "cache: preload completion keeps display");

    // All five images cached: nothing more to load.
    repeat (40) tick();
    expect_value(state, 3'd5, "cache: all cached, stays idle");
    expect_bit(preloading, 1'b0, "cache: no further preload");

    // A full forward round (next and auto) and a prev step are all hits.
    begin : walk
        integer k;
        reg [2:0] exp_img [0:4];
        reg [2:0] exp_slot [0:4];
        exp_img[0] = 3'd2; exp_slot[0] = 3'd2;
        exp_img[1] = 3'd3; exp_slot[1] = 3'd4;
        exp_img[2] = 3'd4; exp_slot[2] = 3'd3;
        exp_img[3] = 3'd0; exp_slot[3] = 3'd0;
        exp_img[4] = 3'd1; exp_slot[4] = 3'd1;
        for (k = 0; k < 5; k = k + 1) begin
            if (k % 2) auto_request = 1'b1; else next_request = 1'b1;
            tick();
            next_request = 1'b0;
            auto_request = 1'b0;
            repeat (3) tick();
            expect_value(current_image_index, exp_img[k], "cache: walk image");
            expect_value(display_buffer_index, exp_slot[k], "cache: walk slot");
            expect_value(commit_count, 3 + k, "cache: walk commits");
            repeat (20) tick();
            expect_value(state, 3'd5, "cache: walk starts no load");
            expect_bit(preloading, 1'b0, "cache: walk starts no preload");
        end
    end
    prev_request = 1'b1; tick(); prev_request = 1'b0;
    repeat (3) tick();
    expect_value(current_image_index, 3'd0, "cache: prev hit");
    expect_value(display_buffer_index, 3'd0, "cache: prev hit slot");
    expect_value(commit_count, 8, "cache: prev hit commits");
    repeat (20) tick();
    expect_value(state, 3'd5, "cache: prev hit starts no load");

    // -----------------------------------------------------------------
    // Six images: slot 5 is used, a failing preload is dropped quietly
    // -----------------------------------------------------------------
    reset_dut();
    commit_count = 0;
    storage_ready = 1'b1;
    finish_scan(4'd6);
    complete_current_load(1'b1);
    display_settled = 1'b1;
    // Priority +1, +2, -1, +3, -2: 1, 2, 5, 3, 4.
    wait_for_state(3'd3, "six: preload 1");
    expect_value(target_image_index, 3'd1, "six: preload target 1");
    complete_current_load(1'b1);
    wait_for_state(3'd3, "six: preload 2");
    expect_value(target_image_index, 3'd2, "six: preload target 2");
    complete_current_load(1'b1);
    wait_for_state(3'd3, "six: failing preload verify");
    expect_bit(preloading, 1'b1, "six: failing preload is a preload");
    expect_value(target_image_index, 3'd5, "six: preload target 5 (prev)");
    expect_value(write_buffer_index, 3'd3, "six: failing preload slot 3");
    begin : fail_preload
        integer n;
        n = 0;
        while (preloading && (n < 200)) begin tick(); n = n + 1; end
    end
    expect_bit(preloading, 1'b0, "six: failing preload gives up");
    expect_value(error_code, 4'd0, "six: preload failure reports no error");
    expect_value(current_image_index, 3'd0, "six: preload failure keeps image");
    wait_for_state(3'd3, "six: preload 3");
    expect_value(target_image_index, 3'd3, "six: preload target 3");
    expect_value(write_buffer_index, 3'd3, "six: 3 reuses the freed slot");
    complete_current_load(1'b1);
    wait_for_state(3'd3, "six: preload 4");
    expect_value(target_image_index, 3'd4, "six: preload target 4");
    expect_value(write_buffer_index, 3'd4, "six: preload slot 4");
    complete_current_load(1'b1);
    repeat (60) tick();
    expect_value(state, 3'd5, "six: failed preload is not retried");

    // Prev miss from idle loads image 5 in the foreground into slot 5.
    prev_request = 1'b1; tick(); prev_request = 1'b0;
    wait_for_state(3'd3, "six: prev miss verify");
    expect_bit(preloading, 1'b0, "six: prev miss is foreground");
    expect_value(target_image_index, 3'd5, "six: prev miss target 5");
    expect_value(write_buffer_index, 3'd5, "six: prev miss slot 5");
    complete_current_load(1'b1);
    expect_value(current_image_index, 3'd5, "six: prev miss loads 5");
    expect_value(display_buffer_index, 3'd5, "six: display slot 5");
    expect_value(commit_count, 2, "six: prev miss commits");
    // Everything is cached now: 5 -> 0 is a hit into slot 0.
    next_request = 1'b1; tick(); next_request = 1'b0;
    repeat (3) tick();
    expect_value(current_image_index, 3'd0, "six: wrap hit");
    expect_value(display_buffer_index, 3'd0, "six: wrap hit slot 0");
    repeat (20) tick();
    expect_value(state, 3'd5, "six: wrap hit starts no load");

    // -----------------------------------------------------------------
    // Board repro: five images, "LOAD 5/5" (preload of image 4 = -1) is
    // running; next, next are hits, the third next (image 3) misses and
    // must abort the preload and load 3 in the foreground right away.
    // -----------------------------------------------------------------
    reset_dut();
    commit_count = 0;
    abort_count = 0;
    // Keep the no-progress watchdog (4 cycles here) fed while the test waits.
    load_progress_pulse = 1'b1;
    storage_ready = 1'b1;
    finish_scan(4'd5);
    complete_current_load(1'b1);
    display_settled = 1'b1;
    wait_for_state(3'd3, "preempt: preload 1");
    complete_current_load(1'b1);
    wait_for_state(3'd3, "preempt: preload 2");
    complete_current_load(1'b1);
    wait_for_state(3'd3, "preempt: preload 4 verify");
    expect_value(target_image_index, 3'd4, "preempt: LOAD 5/5");
    expect_value(write_buffer_index, 3'd3, "preempt: preload 4 slot 3");
    repeat (3) tick();
    next_request = 1'b1; tick(); next_request = 1'b0;
    repeat (3) tick();
    expect_value(current_image_index, 3'd1, "preempt: first next hits");
    next_request = 1'b1; tick(); next_request = 1'b0;
    repeat (3) tick();
    expect_value(current_image_index, 3'd2, "preempt: second next hits");
    expect_value(abort_count, 0, "preempt: hits do not abort");
    expect_bit(preloading, 1'b1, "preempt: preload still running");
    next_request = 1'b1; tick(); next_request = 1'b0;
    expect_value(abort_count, 1, "preempt: miss aborts the preload");
    expect_bit(preloading, 1'b0, "preempt: preload dropped");
    wait_for_state(3'd3, "preempt: foreground verify");
    expect_bit(preloading, 1'b0, "preempt: foreground load");
    expect_value(target_image_index, 3'd3, "preempt: foreground target 3");
    expect_value(write_buffer_index, 3'd3, "preempt: reuses aborted slot 3");
    expect_bit(pending_next, 1'b0, "preempt: nothing left pending");
    complete_current_load(1'b1);
    expect_value(current_image_index, 3'd3, "preempt: image 3 shown");
    expect_value(display_buffer_index, 3'd3, "preempt: slot 3 shown");
    expect_value(commit_count, 4, "preempt: commits");

    // The aborted image 4 is preloaded again. Once its source is fully
    // read a miss for it just waits (no abort) and then hits.
    wait_for_state(3'd3, "preempt: re-preload 4");
    expect_bit(preloading, 1'b1, "preempt: re-preload is a preload");
    expect_value(target_image_index, 3'd4, "preempt: re-preload target 4");
    source_done_pulse = 1'b1; tick(); source_done_pulse = 1'b0;
    repeat (3) tick();
    next_request = 1'b1; tick(); next_request = 1'b0;
    expect_value(abort_count, 1, "preempt: source done, no abort");
    expect_bit(pending_next, 1'b1, "preempt: request pending");
    expect_value(current_image_index, 3'd3, "preempt: still on 3");
    write_done_pulse = 1'b1; tick(); write_done_pulse = 1'b0;
    repeat (10) tick();
    expect_value(current_image_index, 3'd4, "preempt: pending hit shows 4");
    expect_value(commit_count, 5, "preempt: pending hit commits");
    expect_bit(pending_next, 1'b0, "preempt: pending cleared");
    load_progress_pulse = 1'b0;

    $display("PASS tb_image_load_manager");
    $finish;
end

endmodule
