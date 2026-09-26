`timescale 1ns/1ps

module tb_hdmi_audio_acr;

reg clk = 1'b0;
reg rst = 1'b1;
reg audio_valid = 1'b0;
wire acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;
integer acr_count = 0;

always #5 clk = ~clk;

hdmi_audio_acr #(
    .ACR_N(20'd6144),
    .AUDIO_DIV(8'd4)
) dut (
    .clk(clk),
    .rst(rst),
    .audio_valid(audio_valid),
    .acr_valid(acr_valid),
    .acr_cts(acr_cts),
    .acr_n(acr_n)
);

// CTS 必须等于相邻两个 ACR 包之间的实际 clk 周期数（第一个包从复位算起，不核对）
integer clk_since_acr = 0;
always @(posedge clk) begin
    if (rst) begin
        clk_since_acr = 0;
    end else if (acr_valid) begin
        if (acr_n !== 20'd6144)
            $fatal(1, "FAIL ACR N value: got %0d", acr_n);
        if (acr_cts == 20'd0)
            $fatal(1, "FAIL ACR CTS must be nonzero");
        if (acr_count > 0 && acr_cts != clk_since_acr)
            $fatal(1, "FAIL ACR CTS %0d != measured %0d clocks", acr_cts, clk_since_acr);
        acr_count = acr_count + 1;
        clk_since_acr = 1;
    end else begin
        clk_since_acr = clk_since_acr + 1;
    end
end

integer index;
initial begin
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // Every fourth sample-valid pulse creates an ACR packet.  Deliberate
    // gaps prove that the divider counts samples rather than pixel clocks.
    for (index = 0; index < 12; index = index + 1) begin
        @(negedge clk);
        audio_valid = 1'b1;
        @(negedge clk);
        audio_valid = 1'b0;
        repeat (2) @(posedge clk);
    end
    #1;
    if (acr_count != 3)
        $fatal(1, "FAIL expected three ACR packets, got %0d", acr_count);
    if (acr_valid !== 1'b0 || acr_cts !== 20'd0 || acr_n !== 20'd0)
        $fatal(1, "FAIL inactive ACR outputs must be zero");

    $display("PASS tb_hdmi_audio_acr");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "FAIL tb_hdmi_audio_acr timed out");
end

endmodule
