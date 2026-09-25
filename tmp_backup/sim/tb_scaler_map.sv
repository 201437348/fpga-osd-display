`timescale 1ns/1ps
module tb;
  reg clk=0, rst=1, start=0, cfg_valid=0;
  always #5 clk=~clk;
  reg [15:0] W, H;
  reg [23:0] sd; reg sv=0;
  wire afull; wire [7:0] ovf; wire [23:0] dd; wire dv, done; wire [1:0] err;
  image_bilinear_scaler dut(.clk(clk),.rst(rst),.start(start),.src_width(W),.src_height(H),
    .cfg_valid(cfg_valid),.src_data(sd),.src_valid(sv),.src_afull(afull),.src_overflow_count(ovf),
    .out_stall(1'b0),.dst_data(dd),.dst_valid(dv),.dst_done(done),.error_code(err));
  integer ox, oy, n; integer x,y;
  // pixel encodes: R = x>>3 (0..239), G = y>>3 (0..134), B = marker
  initial begin
    if(!$value$plusargs("W=%d",W)) W=1920;
    if(!$value$plusargs("H=%d",H)) H=1080;
    #50 rst=0; #20 start=1; #10 start=0; #10 cfg_valid=1;
    for (y=0;y<H;y=y+1) for (x=0;x<W;x=x+1) begin
      @(posedge clk); while (afull) @(posedge clk);
      sd = {x[10:3], y[10:3], 8'h00}; sv=1; @(posedge clk); sv=0;
      repeat(6) @(posedge clk);
    end
  end
  initial begin ox=0; oy=0; n=0; end
  always @(posedge clk) if (dv) begin
    if ((ox==0||ox==639||ox==320) && (oy==0||oy==479||oy==240))
      $display("out(%0d,%0d) <- src x~%0d y~%0d", ox, oy, dd[23:16]*8, dd[15:8]*8);
    n=n+1; if (ox==639) begin ox=0; oy=oy+1; end else ox=ox+1;
  end
  always @(posedge clk) if (done) begin $display("done n=%0d err=%b ovf=%0d",n,err,ovf); $finish; end
endmodule
