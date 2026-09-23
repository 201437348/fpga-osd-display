`timescale 1ns/1ps
module tb_param_menu_controller;
reg clk=0,rst=1,key=1;reg [3:0] sw=0;
wire [7:0] b,c;wire [1:0] ch;wire active,tgl;
always #5 clk=~clk;
param_menu_controller #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2),.SW_DEBOUNCE_MS(2),.LONG_PRESS_MS(50),.MENU_HOLD_MS(200)) dut(clk,rst,key,sw,b,c,ch,active,tgl);
task press(input integer duration);
begin @(negedge clk);key=0;repeat(duration) @(negedge clk);key=1;repeat(30) @(negedge clk);end endtask
initial begin
 repeat(3) @(negedge clk);rst=0;repeat(30) @(negedge clk);
 if(b!=255 || c!=128) $fatal(1,"default");
 press(70);if(b!=254) $fatal(1,"long once %d",b);
 press(10);if(b!=255) $fatal(1,"short");
 press(10);if(b!=255) $fatal(1,"saturation");
 sw=4'b1001;repeat(40) @(negedge clk);press(10);
 if(c!=144 || b!=255) $fatal(1,"contrast selection");
 sw=4'b0011;repeat(40) @(negedge clk);
 if(b!=255 || c!=128) $fatal(1,"restore");
 $display("PASS tb_param_menu_controller: short/long, saturation, select, restore");$finish;
end
endmodule
