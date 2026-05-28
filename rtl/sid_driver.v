`default_nettype none
module sid_driver (
	clk,
	clk_en,
	rst_n,
	voice_gate,
	voice_note,
	voice_velocity,
	voice_release_done,
	cs,
	we,
	addr,
	data
);
	input wire clk;
	input wire clk_en;
	input wire rst_n;
	input wire voice_gate;
	input wire [6:0] voice_note;
	input wire [6:0] voice_velocity;
	output reg voice_release_done;
	output reg cs;
	output reg we;
	output reg [4:0] addr;
	output reg [7:0] data;
	localparam [4:0] REG_FREQ_LO = 5'h00;
	localparam [4:0] REG_FREQ_HI = 5'h01;
	localparam [4:0] REG_CTRL = 5'h04;
	localparam [4:0] REG_AD = 5'h05;
	localparam [4:0] REG_SR = 5'h06;
	localparam [4:0] REG_RES_FILT = 5'h17;
	localparam [4:0] REG_MODE_VOL = 5'h18;
	localparam [7:0] PATCH_AD = 8'h88;
	localparam [7:0] PATCH_SR = 8'hf0;
	localparam [7:0] PATCH_RES_FILT = 8'h00;
	localparam [7:0] PATCH_MODE_VOL = 8'h0f;
	localparam [7:0] PATCH_CTRL_ON = 8'h21;
	localparam [7:0] PATCH_CTRL_OFF = 8'h20;
	localparam SETUP_N = 3'd4;
	reg [4:0] setup_addr [0:3];
	reg [7:0] setup_data [0:3];
	initial begin
		setup_addr[0] = REG_AD;
		setup_data[0] = PATCH_AD;
		setup_addr[1] = REG_SR;
		setup_data[1] = PATCH_SR;
		setup_addr[2] = REG_RES_FILT;
		setup_data[2] = PATCH_RES_FILT;
		setup_addr[3] = REG_MODE_VOL;
		setup_data[3] = PATCH_MODE_VOL;
	end
	reg [15:0] note_lut [0:127];
	initial begin
		note_lut[0] = 16'h0089;
		note_lut[1] = 16'h0091;
		note_lut[2] = 16'h009a;
		note_lut[3] = 16'h00a3;
		note_lut[4] = 16'h00ad;
		note_lut[5] = 16'h00b7;
		note_lut[6] = 16'h00c2;
		note_lut[7] = 16'h00ce;
		note_lut[8] = 16'h00da;
		note_lut[9] = 16'h00e7;
		note_lut[10] = 16'h00f4;
		note_lut[11] = 16'h0103;
		note_lut[12] = 16'h0112;
		note_lut[13] = 16'h0123;
		note_lut[14] = 16'h0134;
		note_lut[15] = 16'h0146;
		note_lut[16] = 16'h015a;
		note_lut[17] = 16'h016e;
		note_lut[18] = 16'h0184;
		note_lut[19] = 16'h019b;
		note_lut[20] = 16'h01b3;
		note_lut[21] = 16'h01cd;
		note_lut[22] = 16'h01e9;
		note_lut[23] = 16'h0206;
		note_lut[24] = 16'h0225;
		note_lut[25] = 16'h0245;
		note_lut[26] = 16'h0268;
		note_lut[27] = 16'h028c;
		note_lut[28] = 16'h02b3;
		note_lut[29] = 16'h02dc;
		note_lut[30] = 16'h0308;
		note_lut[31] = 16'h0336;
		note_lut[32] = 16'h0367;
		note_lut[33] = 16'h039b;
		note_lut[34] = 16'h03d2;
		note_lut[35] = 16'h040c;
		note_lut[36] = 16'h0449;
		note_lut[37] = 16'h048b;
		note_lut[38] = 16'h04d0;
		note_lut[39] = 16'h0519;
		note_lut[40] = 16'h0567;
		note_lut[41] = 16'h05b9;
		note_lut[42] = 16'h0610;
		note_lut[43] = 16'h066c;
		note_lut[44] = 16'h06ce;
		note_lut[45] = 16'h0735;
		note_lut[46] = 16'h07a3;
		note_lut[47] = 16'h0817;
		note_lut[48] = 16'h0893;
		note_lut[49] = 16'h0915;
		note_lut[50] = 16'h099f;
		note_lut[51] = 16'h0a32;
		note_lut[52] = 16'h0acd;
		note_lut[53] = 16'h0b72;
		note_lut[54] = 16'h0c20;
		note_lut[55] = 16'h0cd8;
		note_lut[56] = 16'h0d9c;
		note_lut[57] = 16'h0e6b;
		note_lut[58] = 16'h0f46;
		note_lut[59] = 16'h102f;
		note_lut[60] = 16'h1125;
		note_lut[61] = 16'h122a;
		note_lut[62] = 16'h133f;
		note_lut[63] = 16'h1464;
		note_lut[64] = 16'h159a;
		note_lut[65] = 16'h16e3;
		note_lut[66] = 16'h183f;
		note_lut[67] = 16'h19b1;
		note_lut[68] = 16'h1b38;
		note_lut[69] = 16'h1cd6;
		note_lut[70] = 16'h1e8d;
		note_lut[71] = 16'h205e;
		note_lut[72] = 16'h224b;
		note_lut[73] = 16'h2455;
		note_lut[74] = 16'h267e;
		note_lut[75] = 16'h28c8;
		note_lut[76] = 16'h2b34;
		note_lut[77] = 16'h2dc6;
		note_lut[78] = 16'h307f;
		note_lut[79] = 16'h3361;
		note_lut[80] = 16'h366f;
		note_lut[81] = 16'h39ac;
		note_lut[82] = 16'h3d1a;
		note_lut[83] = 16'h40bc;
		note_lut[84] = 16'h4495;
		note_lut[85] = 16'h48a9;
		note_lut[86] = 16'h4cfc;
		note_lut[87] = 16'h518f;
		note_lut[88] = 16'h5669;
		note_lut[89] = 16'h5b8c;
		note_lut[90] = 16'h60fe;
		note_lut[91] = 16'h66c2;
		note_lut[92] = 16'h6cdf;
		note_lut[93] = 16'h7358;
		note_lut[94] = 16'h7a34;
		note_lut[95] = 16'h8178;
		note_lut[96] = 16'h892b;
		note_lut[97] = 16'h9153;
		note_lut[98] = 16'h99f7;
		note_lut[99] = 16'ha31f;
		note_lut[100] = 16'hacd2;
		note_lut[101] = 16'hb719;
		note_lut[102] = 16'hc1fc;
		note_lut[103] = 16'hcd85;
		note_lut[104] = 16'hd9bd;
		note_lut[105] = 16'he6b0;
		note_lut[106] = 16'hf467;
		note_lut[107] = 16'hffff;
		note_lut[108] = 16'hffff;
		note_lut[109] = 16'hffff;
		note_lut[110] = 16'hffff;
		note_lut[111] = 16'hffff;
		note_lut[112] = 16'hffff;
		note_lut[113] = 16'hffff;
		note_lut[114] = 16'hffff;
		note_lut[115] = 16'hffff;
		note_lut[116] = 16'hffff;
		note_lut[117] = 16'hffff;
		note_lut[118] = 16'hffff;
		note_lut[119] = 16'hffff;
		note_lut[120] = 16'hffff;
		note_lut[121] = 16'hffff;
		note_lut[122] = 16'hffff;
		note_lut[123] = 16'hffff;
		note_lut[124] = 16'hffff;
		note_lut[125] = 16'hffff;
		note_lut[126] = 16'hffff;
		note_lut[127] = 16'hffff;
	end
	localparam [2:0] ST_INIT = 3'd0;
	localparam [2:0] ST_ARMED = 3'd1;
	localparam [2:0] ST_NOTE_ON_LO = 3'd2;
	localparam [2:0] ST_NOTE_ON_HI = 3'd3;
	localparam [2:0] ST_NOTE_ON_CTRL = 3'd4;
	localparam [2:0] ST_NOTE_OFF_CTRL = 3'd5;
	reg [2:0] state;
	reg [1:0] init_idx;
	reg gate_d;
	reg [6:0] latch_note;
	reg [6:0] latch_vel;
	wire [15:0] note_freq = note_lut[latch_note];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= ST_INIT;
			init_idx <= 2'd0;
			gate_d <= 1'b0;
			latch_note <= 7'd0;
			latch_vel <= 7'd0;
			cs <= 1'b0;
			we <= 1'b0;
			addr <= 5'd0;
			data <= 8'd0;
			voice_release_done <= 1'b0;
		end
		else if (clk_en) begin
			cs <= 1'b0;
			we <= 1'b0;
			voice_release_done <= 1'b0;
			case (state)
				ST_INIT: begin
					cs <= 1'b1;
					we <= 1'b1;
					addr <= setup_addr[init_idx];
					data <= setup_data[init_idx];
					if (init_idx == (SETUP_N[1:0] - 2'd1)) begin
						state <= ST_ARMED;
						init_idx <= 2'd0;
					end
					else
						init_idx <= init_idx + 2'd1;
				end
				ST_ARMED:
					if (voice_gate && !gate_d) begin
						latch_note <= voice_note;
						latch_vel <= voice_velocity;
						state <= ST_NOTE_ON_LO;
					end
					else if (!voice_gate && gate_d)
						state <= ST_NOTE_OFF_CTRL;
				ST_NOTE_ON_LO: begin
					cs <= 1'b1;
					we <= 1'b1;
					addr <= REG_FREQ_LO;
					data <= note_freq[7:0];
					state <= ST_NOTE_ON_HI;
				end
				ST_NOTE_ON_HI: begin
					cs <= 1'b1;
					we <= 1'b1;
					addr <= REG_FREQ_HI;
					data <= note_freq[15:8];
					state <= ST_NOTE_ON_CTRL;
				end
				ST_NOTE_ON_CTRL: begin
					cs <= 1'b1;
					we <= 1'b1;
					addr <= REG_CTRL;
					data <= PATCH_CTRL_ON;
					state <= ST_ARMED;
				end
				ST_NOTE_OFF_CTRL: begin
					cs <= 1'b1;
					we <= 1'b1;
					addr <= REG_CTRL;
					data <= PATCH_CTRL_OFF;
					voice_release_done <= 1'b1;
					state <= ST_ARMED;
				end
				default: state <= ST_ARMED;
			endcase
			gate_d <= voice_gate;
		end
endmodule
`default_nettype wire