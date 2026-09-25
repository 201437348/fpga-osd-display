`timescale 1ns/1ps
module tb_param_menu_controller;
reg clk=0,rst=1,key=1;reg [3:0] sw=0;
wire [7:0] b,c;wire [1:0] ch;wire active,tgl;wire [3:0] vol;
always #5 clk=~clk;
param_menu_controller #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2),.SW_DEBOUNCE_MS(2),.LONG_PRESS_MS(50),.MENU_HOLD_MS(200)) dut(clk,rst,key,sw,b,c,ch,active,tgl,vol);
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
 if(vol!=8) $fatal(1,"volume default %d",vol);
 press(10);if(vol!=8) $fatal(1,"volume saturates high");
 press(70);press(70);if(vol!=6) $fatal(1,"volume down %d",vol);
 if(b!=255 || c!=128) $fatal(1,"volume keeps defaults");
 repeat(7) press(70);if(vol!=0) $fatal(1,"volume saturates low %d",vol);
 press(10);if(vol!=1) $fatal(1,"volume up");
 sw=4'b0000;repeat(40) @(negedge clk);press(70);if(vol!=1 || b!=254) $fatal(1,"volume only in 11");
 $display("PASS tb_param_menu_controller: short/long, saturation, select, restore, volume");$finish;
end
endmodule
