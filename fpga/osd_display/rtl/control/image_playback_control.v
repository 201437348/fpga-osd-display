module image_playback_control #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer AUTO_INTERVAL_SECONDS = 1
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       key_next,
    input  wire       key_auto,
    input  wire       display_valid,
    input  wire [2:0] image_count,
    input  wire       manager_idle,
    output reg        next_request,
    output reg        auto_request,
    output reg        auto_play_enabled
);

localparam [31:0] AUTO_INTERVAL_CYCLES = CLK_FREQ_HZ * AUTO_INTERVAL_SECONDS;

wire key_next_press;
wire key_auto_press;
reg [31:0] auto_counter;

button_press #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .DEBOUNCE_MS(50)
) u_key_next (
    .clk(clk),
    .rst(rst),
    .button_in(key_next),
    .press_pulse(key_next_press)
);

button_press #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .DEBOUNCE_MS(50)
) u_key_auto (
    .clk(clk),
    .rst(rst),
    .button_in(key_auto),
    .press_pulse(key_auto_press)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_request     <= 1'b0;
        auto_request     <= 1'b0;
        auto_play_enabled <= 1'b0;
        auto_counter     <= 32'd0;
    end else begin
        next_request <= 1'b0;
        auto_request <= 1'b0;

        if (key_next_press && manager_idle && (image_count != 3'd0))
            next_request <= 1'b1;

        if (key_auto_press && (image_count > 3'd1))
            auto_play_enabled <= ~auto_play_enabled;

        // A button action starts a fresh interval and cannot also emit an auto request.
        if (key_next_press || key_auto_press) begin
            auto_counter <= 32'd0;
        end else if (auto_play_enabled && display_valid && manager_idle && (image_count > 3'd1)) begin
            if (auto_counter >= (AUTO_INTERVAL_CYCLES - 1'b1)) begin
                auto_request <= 1'b1;
                auto_counter <= 32'd0;
            end else begin
                auto_counter <= auto_counter + 32'd1;
            end
        end else if (!(key_next_press || key_auto_press)) begin
            auto_counter <= 32'd0;
        end
    end
end

endmodule
