module video_delay
#(
	parameter DATA_WIDTH = 24                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output                      read_en,            // Read data enable
	input[DATA_WIDTH - 1:0]     read_data,          // Read data
	input                       read_data_valid,    // Registered FIFO output valid
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid

	output                      hs_r,                 // horizontal synchronization
	output                      vs_r,                 // vertical synchronization
	output                      de_r,                 // video valid
	output[DATA_WIDTH - 1:0]    vout_data           // video data

);
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;
reg [DATA_WIDTH - 1:0] align_fifo [0:3];
reg [1:0] align_wr_ptr;
reg [1:0] align_rd_ptr;
reg [2:0] align_count;
reg align_overflow;
reg align_underflow;

// The vendor FIFO's OUTREG path reports data two clocks after a read request.
// Request three stages before capture so valid data reaches the small queue
// before the matching active pixel is emitted at de_d[19].
assign read_en = de_d[16];
assign hs_r = hs_d[20];
assign vs_r = vs_d[20];
assign de_r = de_d[20];
assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1) begin
		vout_data_r <= {DATA_WIDTH{1'b0}};
		align_wr_ptr <= 2'd0;
		align_rd_ptr <= 2'd0;
		align_count <= 3'd0;
		align_overflow <= 1'b0;
		align_underflow <= 1'b0;
	end else begin
		if (read_data_valid && !de_d[19]) begin
			if (align_count < 3'd4) begin
				align_fifo[align_wr_ptr] <= read_data;
				align_wr_ptr <= align_wr_ptr + 2'd1;
				align_count <= align_count + 3'd1;
			end else begin
				align_overflow <= 1'b1;
			end
		end else if (!read_data_valid && de_d[19]) begin
			if (align_count != 3'd0) begin
				vout_data_r <= align_fifo[align_rd_ptr];
				align_rd_ptr <= align_rd_ptr + 2'd1;
				align_count <= align_count - 3'd1;
			end else begin
				vout_data_r <= {DATA_WIDTH{1'b0}};
				align_underflow <= 1'b1;
			end
		end else if (read_data_valid && de_d[19]) begin
			if (align_count != 3'd0) begin
				vout_data_r <= align_fifo[align_rd_ptr];
				align_fifo[align_wr_ptr] <= read_data;
				align_rd_ptr <= align_rd_ptr + 2'd1;
				align_wr_ptr <= align_wr_ptr + 2'd1;
			end else begin
				vout_data_r <= read_data;
			end
		end else begin
			vout_data_r <= {DATA_WIDTH{1'b0}};
		end
	end
end
always @(posedge video_clk or posedge rst)begin
	if(rst)begin
    	hs_d <= 20'b0;
        vs_d <= 20'b0;
        de_d <= 20'b0;
    end
	else begin
    	
    	hs_d <= {hs_d[19:0],hs};
        vs_d <= {vs_d[19:0],vs};
        de_d <= {de_d[19:0],de};
    end
end
endmodule
