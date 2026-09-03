module probe_top(
    input wire clk,
    input wire rst,
    input wire key_next,
    input wire key_auto,
    input wire SD_MISO,
    output wire SD_nCS,
    output wire SD_DCLK,
    output wire SD_MOSI,
    output wire [23:0] rgb_out,
    output wire [3:0] state_out
);

wire storage_ready;
wire scan_done;
wire [2:0] scan_found_count;
wire source_done_pulse;
wire [3:0] storage_state_code;
wire write_req;
wire write_req_ack = 1'b0;
wire write_en;
wire [31:0] write_data;
wire scan_start;
wire load_start;
wire load_abort;
wire [1:0] target_image_index;
wire [1:0] write_buffer_index;
wire [1:0] display_buffer_index;
wire display_valid;
wire display_test_pattern;
wire [2:0] manager_state;
wire [1:0] retry_count;
wire [3:0] error_code;
wire pending_next;
wire source_done_seen;
wire write_done_seen;
wire [2:0] image_count;
wire load_in_progress;
wire manager_idle;
wire next_request;
wire auto_request;
wire auto_play_enabled;

image_storage_adapter u_storage (
    .clk(clk), .rst(rst), .scan_start(scan_start), .load_start(load_start),
    .load_abort(load_abort), .target_image_index(target_image_index),
    .storage_ready(storage_ready), .scan_done(scan_done),
    .scan_found_count(scan_found_count), .source_done_pulse(source_done_pulse),
    .state_code(storage_state_code), .write_req(write_req),
    .write_req_ack(write_req_ack), .write_en(write_en), .write_data(write_data),
    .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO)
);

image_load_manager u_manager (
    .clk(clk), .rst(rst), .storage_ready(storage_ready), .scan_done(scan_done),
    .scan_found_count(scan_found_count), .source_done_pulse(source_done_pulse),
    .write_done_pulse(1'b0), .next_request(next_request), .auto_request(auto_request),
    .scan_start(scan_start), .load_start(load_start), .load_abort(load_abort),
    .target_image_index(target_image_index), .write_buffer_index(write_buffer_index),
    .display_buffer_index(display_buffer_index), .current_image_index(),
    .display_valid(display_valid), .display_test_pattern(display_test_pattern),
    .state(manager_state), .retry_count(retry_count), .error_code(error_code),
    .pending_next(pending_next), .source_done_seen(source_done_seen),
    .write_done_seen(write_done_seen), .image_count(image_count),
    .load_in_progress(load_in_progress), .idle(manager_idle)
);

image_playback_control u_playback (
    .clk(clk), .rst(rst), .key_next(key_next), .key_auto(key_auto),
    .display_valid(display_valid), .image_count(image_count), .manager_idle(manager_idle),
    .next_request(next_request), .auto_request(auto_request),
    .auto_play_enabled(auto_play_enabled)
);

video_fallback_pattern u_pattern (
    .video_clk(clk), .rst(rst), .vs(1'b0), .de(1'b0), .rgb(rgb_out)
);

assign state_out = {1'b0, manager_state};

endmodule
