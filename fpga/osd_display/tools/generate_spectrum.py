from pathlib import Path
import math
p=Path('fpga/osd_display/rtl/audio/audio_spectrum_fft.v')
window='\n'.join(f"            8'd{i}: window_coeff = 16'sd{round((.5-.5*math.cos(2*math.pi*i/511))*32767)};" for i in range(256))
cos='\n'.join(f"            8'd{i}: twiddle_re = 16'sd{round(math.cos(2*math.pi*i/512)*32767)};".replace("16'sd-","-16'sd") for i in range(256))
sin='\n'.join(f"            8'd{i}: twiddle_im = 16'sd{round(-math.sin(2*math.pi*i/512)*32767)};".replace("16'sd-","-16'sd") for i in range(256))
s='''`timescale 1ns/1ps
// 512-point, hop-256, radix-2 DIT. RAM is never reset; only initialized
// samples are consumed. One shared signed 16x16 multiplier, registered output.
module audio_spectrum_fft(
    input wire clk, rst, sample_valid,
    input wire signed [23:0] sample_left, sample_right,
    output reg [15:0] mag,
    output reg [9:0] mag_index,
    output reg mag_valid,
    output reg overrun
);
    (* ram_style = "block" *) reg signed [15:0] ring [0:511];
    (* ram_style = "block" *) reg signed [15:0] real_mem [0:511];
    (* ram_style = "block" *) reg signed [15:0] imag_mem [0:511];
    reg [8:0] wr_ptr, origin, pos;
    reg [9:0] filled;
    reg [7:0] hop;
    wire signed [16:0] stereo_sum =
        $signed({sample_left[23],sample_left[23:8]}) +
        $signed({sample_right[23],sample_right[23:8]});
    wire signed [15:0] mono = stereo_sum >>> 1;
    reg signed [23:0] dc_q;
    wire signed [24:0] dc_delta = ($signed(mono) * 25'sd256) - $signed(dc_q);
    wire signed [24:0] highpass = dc_delta >>> 8;
    wire signed [15:0] filtered = highpass > 32767 ? 16'sd32767 :
                                    highpass < -32768 ? -16'sd32768 : highpass[15:0];
    reg [4:0] state;
    localparam IDLE=0, LOAD_READ=1, LOAD_MUL=2, LOAD_WAIT=3, LOAD_WRITE=4,
      READ_A=5, READ_B=6, MUL0=7, MUL1=8, MUL2=9, MUL3=10, MUL_END=11,
      WRITE_A=12, WRITE_B=13, MAG_READ=14, MAG_SEND=15;
    reg [8:0] half_size, group_base, offset;
    reg [3:0] tw_shift;
    wire [8:0] addr_a = group_base + offset;
    wire [8:0] addr_b = addr_a + half_size;
    wire [7:0] phase = offset << tw_shift;
    reg signed [15:0] ar,ai,br,bi,wr,wi,ring_q,win_q;
    reg signed [15:0] mul_a,mul_b;
    reg signed [31:0] product,p0,p1,p2;
    reg signed [32:0] tr,ti;
    wire signed [33:0] sum_r = ($signed(ar) * 34'sd32768) + $signed(tr);
    wire signed [33:0] sum_i = ($signed(ai) * 34'sd32768) + $signed(ti);
    wire signed [33:0] diff_r = ($signed(ar) * 34'sd32768) - $signed(tr);
    wire signed [33:0] diff_i = ($signed(ai) * 34'sd32768) - $signed(ti);
    wire [15:0] abs_r = ar[15] ? -ar : ar;
    wire [15:0] abs_i = ai[15] ? -ai : ai;
    wire [16:0] magnitude = abs_r >= abs_i ? {1'b0,abs_r}+{2'b0,abs_i[15:1]} :
                                                           {1'b0,abs_i}+{2'b0,abs_r[15:1]};
    function [8:0] reverse9;
        input [8:0] a; integer i;
        begin for(i=0;i<9;i=i+1) reverse9[i]=a[8-i]; end
    endfunction
    function signed [15:0] window_coeff;
        input [7:0] a;
        begin case(a)
WINDOW
        endcase end
    endfunction
    function signed [15:0] twiddle_re;
        input [7:0] a;
        begin case(a)
COS
        endcase end
    endfunction
    function signed [15:0] twiddle_im;
        input [7:0] a;
        begin case(a)
SIN
        endcase end
    endfunction
    reg [8:0] mem_addr;
    reg mem_we;
    reg signed [15:0] mem_dr,mem_di;
    reg signed [15:0] mem_qr,mem_qi;
    always @* begin
        mem_addr=addr_a; mem_we=0; mem_dr=0; mem_di=0;
        case(state)
          LOAD_WRITE: begin mem_addr=reverse9(pos); mem_we=1;
             mem_dr=(product+32'sd16384) >>> 15; end
          READ_B: mem_addr=addr_b;
          WRITE_A: begin mem_we=1;mem_dr=(sum_r+34'sd32768) >>> 16;
             mem_di=(sum_i+34'sd32768) >>> 16;end
          WRITE_B: begin mem_addr=addr_b;mem_we=1;
             mem_dr=(diff_r+34'sd32768) >>> 16;mem_di=(diff_i+34'sd32768) >>> 16;end
          MAG_READ: mem_addr=pos;
        endcase
    end
    always @(posedge clk) begin
        if(!rst && sample_valid) ring[wr_ptr]<=filtered;
        ring_q<=ring[(origin+pos)&9'h1ff];
        mem_qr<=real_mem[mem_addr];mem_qi<=imag_mem[mem_addr];
        if(!rst && mem_we) begin real_mem[mem_addr]<=mem_dr;imag_mem[mem_addr]<=mem_di;end
    end
    // The same physical multiplier handles window and all four real products.
    always @* begin
        mul_a=0; mul_b=0;
        case(state)
          LOAD_MUL: begin mul_a=ring_q; mul_b=win_q; end
          MUL0: begin mul_a=br; mul_b=wr; end
          MUL1: begin mul_a=bi; mul_b=wi; end
          MUL2: begin mul_a=br; mul_b=wi; end
          MUL3: begin mul_a=bi; mul_b=wr; end
        endcase
    end
    always @(posedge clk) product <= mul_a * mul_b;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            wr_ptr<=0; filled<=0; hop<=0; dc_q<=0; state<=IDLE;
            origin<=0; pos<=0; half_size<=1; group_base<=0; offset<=0; tw_shift<=8;
            mag<=0; mag_index<=0; mag_valid<=0; overrun<=0;
            ar<=0;ai<=0;br<=0;bi<=0;wr<=0;wi<=0;win_q<=0;
            p0<=0;p1<=0;p2<=0;tr<=0;ti<=0;
        end else begin
            mag_valid<=0;
            if(sample_valid) begin
                wr_ptr<=wr_ptr+1'b1;
                dc_q<=dc_q+(dc_delta >>> 6);
                if(filled<512) filled<=filled+1'b1;
                hop<=hop+1'b1;
                if((filled>=511) && hop==255) begin
                    if(state==IDLE) begin
                        origin<=wr_ptr+1'b1; pos<=0; state<=LOAD_READ;
                    end else overrun<=1;
                end
            end
            case(state)
              LOAD_READ: begin

                win_q<=window_coeff(pos[8] ? ~pos[7:0] : pos[7:0]);
                state<=LOAD_MUL;
              end
              LOAD_MUL: state<=LOAD_WRITE;
              LOAD_WAIT: state<=LOAD_WRITE;
              LOAD_WRITE: begin

                if(pos==511) begin
                    half_size<=1; group_base<=0; offset<=0; tw_shift<=8; state<=READ_A;
                end else begin pos<=pos+1'b1; state<=LOAD_READ; end
              end
              READ_A: begin
                 wr<=twiddle_re(phase); wi<=twiddle_im(phase); state<=READ_B; end
              READ_B: begin ar<=mem_qr;ai<=mem_qi; state<=16; end
              16: begin br<=mem_qr;bi<=mem_qi;state<=MUL0;end
              MUL0: state<=MUL1;
              MUL1: begin p0<=product; state<=MUL2; end
              MUL2: begin p1<=product; state<=MUL3; end
              MUL3: begin p2<=product; state<=MUL_END; end
              MUL_END: begin tr<=$signed(p0)-$signed({p1[31],p1});
                 ti<=$signed(p2)+$signed({product[31],product}); state<=WRITE_A; end
              WRITE_A: begin
                 state<=WRITE_B;
              end
              WRITE_B: begin

                 state<=READ_A;
                 if(offset==half_size-1) begin
                    offset<=0;
                    if({1'b0,group_base}+({1'b0,half_size}<<1)>=512) begin
                        group_base<=0;
                        if(half_size==256) begin pos<=0; state<=MAG_READ; end
                        else begin half_size<=half_size<<1; tw_shift<=tw_shift-1'b1; end
                    end else group_base<=group_base+(half_size<<1);
                 end else offset<=offset+1'b1;
              end
              MAG_READ: state<=17;
              17: begin ar<=mem_qr;ai<=mem_qi;state<=MAG_SEND;end
              MAG_SEND: begin
                 mag<=magnitude[15:0]; mag_index<={1'b0,pos}; mag_valid<=1;
                 if(pos==255) state<=IDLE;
                 else begin pos<=pos+1'b1; state<=MAG_READ; end
              end
            endcase
        end
    end
endmodule
'''
p.write_text(s.replace('WINDOW',window).replace('COS',cos).replace('SIN',sin))
