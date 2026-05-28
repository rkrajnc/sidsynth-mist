module uart_simple (
	clk,
	clk_en,
	rst_n,
	tx_vld,
	tx_rdy,
	tx_dat,
	rx_vld,
	rx_rdy,
	rx_mis,
	rx_dat,
	txd,
	rxd
);
	parameter signed [31:0] CLOCK_FREQ = 50000000;
	parameter signed [31:0] BAUDRATE = 31250;
	parameter signed [31:0] OVERSAMPLING = 16;
	parameter signed [31:0] SAMPLEPOINT = 'b1000;
	input wire clk;
	input wire clk_en;
	input wire rst_n;
	input wire tx_vld;
	output wire tx_rdy;
	input wire [7:0] tx_dat;
	output wire rx_vld;
	input wire rx_rdy;
	output wire rx_mis;
	output wire [7:0] rx_dat;
	output wire txd;
	input wire rxd;
	localparam [6:0] RXD_CNT = (CLOCK_FREQ + ((BAUDRATE * OVERSAMPLING) / 2)) / (BAUDRATE * OVERSAMPLING);
	localparam [10:0] TXD_CNT = (CLOCK_FREQ + (BAUDRATE / 2)) / BAUDRATE;
	reg [10:0] tx_timer;
	reg [3:0] tx_bitcounter;
	reg [9:0] tx_reg;
	wire tx_ready;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			tx_timer <= #(1) 10'd0;
		else if (clk_en) begin
			if (tx_vld && tx_ready)
				tx_timer <= #(1) TXD_CNT - 11'd1;
			else if (|tx_timer)
				tx_timer <= #(1) tx_timer - 11'd1;
			else if (|tx_bitcounter)
				tx_timer <= #(1) TXD_CNT - 11'd1;
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			tx_bitcounter <= #(1) 4'd0;
		else if (clk_en) begin
			if (tx_vld && tx_ready)
				tx_bitcounter <= #(1) 4'd11 - 4'd1;
			else if (|tx_bitcounter && ~|tx_timer)
				tx_bitcounter <= #(1) tx_bitcounter - 4'd1;
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			tx_reg <= #(1) 10'b1111111111;
		else if (clk_en) begin
			if (tx_vld && tx_ready)
				tx_reg <= #(1) {1'b1, tx_dat[7:0], 1'b0};
			else if (~|tx_timer)
				tx_reg <= #(1) {1'b1, tx_reg[9:1]};
		end
	assign tx_ready = ~|tx_bitcounter && ~|tx_timer;
	assign tx_rdy = tx_ready;
	assign txd = tx_reg[0];
	reg [1:0] rxd_sync;
	reg rxd_bit;
	wire rx_start;
	reg [6:0] rx_sample_cnt;
	reg [3:0] rx_oversample_cnt;
	wire rx_sample;
	reg rx_sample_d;
	reg [3:0] rx_bit_cnt;
	reg [9:0] rx_recv;
	reg [7:0] rx_reg;
	reg rx_valid;
	wire rx_ready;
	reg rx_miss;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			rxd_sync <= #(1) 2'b11;
		else if (clk_en)
			rxd_sync <= #(1) {rxd_sync[0], rxd};
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			rxd_bit <= #(1) 1'b1;
		else if (clk_en)
			rxd_bit <= #(1) rxd_sync[1];
	assign rx_start = (rxd_bit && !rxd_sync[1]) && ~|rx_bit_cnt;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			rx_sample_cnt <= #(1) RXD_CNT;
		else if (clk_en) begin
			if (rx_start || ~|rx_sample_cnt)
				rx_sample_cnt <= #(1) RXD_CNT;
			else if (|rx_bit_cnt)
				rx_sample_cnt <= #(1) rx_sample_cnt - 7'd1;
		end
	always @(posedge clk)
		if (clk_en) begin
			if (rx_start)
				rx_oversample_cnt <= #(1) OVERSAMPLING[3:0] - 4'd1;
			else if (~|rx_sample_cnt)
				rx_oversample_cnt <= #(1) rx_oversample_cnt - 5'd1;
		end
	assign rx_sample = (rx_oversample_cnt == SAMPLEPOINT[3:0]) && ~|rx_sample_cnt;
	always @(posedge clk)
		if (clk_en)
			rx_sample_d <= #(1) rx_sample;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			rx_bit_cnt <= #(1) 4'd0;
		else if (clk_en) begin
			if (rx_start)
				rx_bit_cnt <= #(1) 4'd10;
			else if (rx_sample && |rx_bit_cnt)
				rx_bit_cnt <= #(1) rx_bit_cnt - 4'd1;
		end
	always @(posedge clk)
		if (clk_en) begin
			if (rx_sample && |rx_bit_cnt)
				rx_recv <= #(1) {rxd_bit, rx_recv[9:1]};
		end
	always @(posedge clk)
		if (clk_en) begin
			if ((~|rx_bit_cnt && rx_recv[9]) && rx_sample_d)
				rx_reg <= #(1) rx_recv[8:1];
		end
	assign rx_dat = rx_reg;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			rx_valid <= #(1) 1'b0;
		else if (clk_en) begin
			if (~|rx_bit_cnt && rx_sample_d)
				rx_valid <= #(1) rx_recv[9];
			else if (rx_rdy)
				rx_valid <= #(1) 1'b0;
		end
	assign rx_vld = rx_valid;
	assign rx_ready = ~|rx_bit_cnt;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			rx_miss <= #(1) 1'b0;
		else if (clk_en) begin
			if (rx_valid && ((~|rx_bit_cnt && rx_recv[9]) && rx_sample_d))
				rx_miss <= #(1) 1'b1;
			else if (rx_rdy)
				rx_miss <= #(1) 1'b0;
		end
	assign rx_mis = rx_miss;
endmodule