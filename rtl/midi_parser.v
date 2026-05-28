`default_nettype none
module midi_parser (
	clk,
	clk_en,
	rst_n,
	rx_dat,
	rx_vld,
	ch_msg,
	ch_vld,
	ch_rdy,
	sys_msg,
	sys_vld,
	sys_rdy,
	rt_clock_tick,
	rt_start,
	rt_continue,
	rt_stop,
	rt_active_sense,
	rt_reset
);
	input wire clk;
	input wire clk_en;
	input wire rst_n;
	input wire [7:0] rx_dat;
	input wire rx_vld;
	output wire [20:0] ch_msg;
	output wire ch_vld;
	input wire ch_rdy;
	output wire [57:0] sys_msg;
	output wire sys_vld;
	input wire sys_rdy;
	output wire rt_clock_tick;
	output wire rt_start;
	output wire rt_continue;
	output wire rt_stop;
	output wire rt_active_sense;
	output wire rt_reset;
	function automatic is_status_byte;
		input reg [7:0] byte_in;
		is_status_byte = byte_in[7];
	endfunction
	function automatic is_data_byte;
		input reg [7:0] byte_in;
		is_data_byte = !byte_in[7];
	endfunction
	function automatic is_realtime;
		input reg [7:0] byte_in;
		is_realtime = byte_in[7:3] == 5'b11111;
	endfunction
	function automatic is_system_common;
		input reg [7:0] byte_in;
		is_system_common = byte_in[7:3] == 5'b11110;
	endfunction
	function automatic [2:0] get_expected_data_bytes;
		input reg [7:0] status;
		reg [3:0] msg_type;
		begin
			msg_type = status[7:4];
			(* full_case, parallel_case *)
			case (msg_type)
				4'h8, 4'h9, 4'ha, 4'hb, 4'he: get_expected_data_bytes = 3'd2;
				4'hc, 4'hd: get_expected_data_bytes = 3'd1;
				default:
					(* full_case, parallel_case *)
					case (status)
						8'hf1, 8'hf3: get_expected_data_bytes = 3'd1;
						8'hf2: get_expected_data_bytes = 3'd2;
						8'hf0: get_expected_data_bytes = 3'd7;
						default: get_expected_data_bytes = 3'd0;
					endcase
			endcase
		end
	endfunction
	reg [3:0] state;
	reg [7:0] status_byte;
	reg [7:0] running_status;
	reg [15:0] sysex_addr;
	reg [1:0] sysex_size;
	reg [31:0] sysex_data;
	reg [3:0] nibble_count;
	reg [6:0] data1_reg;
	reg [20:0] ch_msg_r;
	reg ch_vld_r;
	reg [57:0] sys_msg_r;
	reg sys_vld_r;
	reg rt_clock_tick_r;
	reg rt_start_r;
	reg rt_continue_r;
	reg rt_stop_r;
	reg rt_active_sense_r;
	reg rt_reset_r;
	localparam [10:0] midi_pkg_MIDI_MSG_ACTIVE_SENSING = 11'h7f1;
	localparam [10:0] midi_pkg_MIDI_MSG_CLOCK = 11'h7c1;
	localparam [10:0] midi_pkg_MIDI_MSG_CONTINUE = 11'h7d9;
	localparam [10:0] midi_pkg_MIDI_MSG_RESET = 11'h7f9;
	localparam [10:0] midi_pkg_MIDI_MSG_SONG_POSITION = 11'h793;
	localparam [10:0] midi_pkg_MIDI_MSG_SONG_SELECT = 11'h79a;
	localparam [10:0] midi_pkg_MIDI_MSG_START = 11'h7d1;
	localparam [10:0] midi_pkg_MIDI_MSG_STOP = 11'h7e1;
	localparam [10:0] midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE = 11'h780;
	localparam [10:0] midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE_END = 11'h7b9;
	localparam [10:0] midi_pkg_MIDI_MSG_TIME_CODE = 11'h78a;
	localparam [10:0] midi_pkg_MIDI_MSG_TUNE_REQUEST = 11'h7b1;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= #(1) 4'd0;
			status_byte <= #(1) 8'h00;
			running_status <= #(1) 8'h00;
			sysex_addr <= #(1) 16'h0000;
			sysex_size <= #(1) 2'b00;
			sysex_data <= #(1) 32'h00000000;
			nibble_count <= #(1) 4'd0;
			data1_reg <= #(1) 7'h00;
			ch_msg_r <= #(1) 1'sb0;
			ch_vld_r <= #(1) 1'b0;
			sys_msg_r <= #(1) 1'sb0;
			sys_vld_r <= #(1) 1'b0;
			rt_clock_tick_r <= #(1) 1'b0;
			rt_start_r <= #(1) 1'b0;
			rt_continue_r <= #(1) 1'b0;
			rt_stop_r <= #(1) 1'b0;
			rt_active_sense_r <= #(1) 1'b0;
			rt_reset_r <= #(1) 1'b0;
		end
		else if (clk_en) begin
			rt_clock_tick_r <= #(1) 1'b0;
			rt_start_r <= #(1) 1'b0;
			rt_continue_r <= #(1) 1'b0;
			rt_stop_r <= #(1) 1'b0;
			rt_active_sense_r <= #(1) 1'b0;
			rt_reset_r <= #(1) 1'b0;
			ch_vld_r <= #(1) 1'b0;
			sys_vld_r <= #(1) 1'b0;
			if (rx_vld && is_realtime(rx_dat))
				(* parallel_case *)
				case (rx_dat)
					midi_pkg_MIDI_MSG_CLOCK[10-:8]: rt_clock_tick_r <= #(1) 1'b1;
					midi_pkg_MIDI_MSG_START[10-:8]: rt_start_r <= #(1) 1'b1;
					midi_pkg_MIDI_MSG_CONTINUE[10-:8]: rt_continue_r <= #(1) 1'b1;
					midi_pkg_MIDI_MSG_STOP[10-:8]: rt_stop_r <= #(1) 1'b1;
					midi_pkg_MIDI_MSG_ACTIVE_SENSING[10-:8]: rt_active_sense_r <= #(1) 1'b1;
					midi_pkg_MIDI_MSG_RESET[10-:8]: rt_reset_r <= #(1) 1'b1;
					default:
						;
				endcase
			else if (rx_vld)
				(* parallel_case *)
				case (state)
					4'd0:
						if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (rx_dat == midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE[10-:8]) begin
								state <= #(1) 4'd1;
								nibble_count <= #(1) 4'd0;
								sysex_addr <= #(1) 16'h0000;
								running_status <= #(1) 8'h00;
							end
							else if (is_system_common(rx_dat)) begin
								running_status <= #(1) 8'h00;
								(* parallel_case *)
								case (rx_dat)
									midi_pkg_MIDI_MSG_TIME_CODE[10-:8]: state <= #(1) 4'd4;
									midi_pkg_MIDI_MSG_SONG_POSITION[10-:8]: state <= #(1) 4'd4;
									midi_pkg_MIDI_MSG_SONG_SELECT[10-:8]: state <= #(1) 4'd4;
									midi_pkg_MIDI_MSG_TUNE_REQUEST[10-:8]: begin
										sys_msg_r[57-:8] <= #(1) rx_dat;
										sys_msg_r[47-:16] <= #(1) 16'h0000;
										sys_msg_r[49-:2] <= #(1) 2'd0;
										sys_msg_r[31-:32] <= #(1) 32'h00000000;
										sys_vld_r <= #(1) 1'b1;
										state <= #(1) 4'd0;
									end
									default: state <= #(1) 4'd0;
								endcase
							end
							else begin
								running_status <= #(1) rx_dat;
								if (get_expected_data_bytes(rx_dat) > 0)
									state <= #(1) 4'd6;
							end
						end
						else if (is_data_byte(rx_dat)) begin
							if (running_status != 8'h00) begin
								status_byte <= #(1) running_status;
								data1_reg <= #(1) rx_dat[6:0];
								if (get_expected_data_bytes(running_status) == 3'd1) begin
									ch_msg_r[20-:3] <= #(1) running_status[6:4];
									ch_msg_r[17-:4] <= #(1) running_status[3:0];
									ch_msg_r[0+:7] <= #(1) rx_dat[6:0];
									ch_msg_r[7+:7] <= #(1) 7'h00;
									ch_vld_r <= #(1) 1'b1;
									state <= #(1) 4'd0;
								end
								else
									state <= #(1) 4'd7;
							end
						end
					4'd1:
						if (is_data_byte(rx_dat)) begin
							sysex_addr <= #(1) {sysex_addr[11:0], rx_dat[3:0]};
							nibble_count <= #(1) nibble_count + 4'd1;
							if (nibble_count == 4'd3) begin
								state <= #(1) 4'd2;
								nibble_count <= #(1) 4'd0;
							end
						end
						else if (rx_dat == midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE_END[10-:8])
							state <= #(1) 4'd0;
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					4'd2:
						if (is_data_byte(rx_dat)) begin
							sysex_size <= #(1) rx_dat[1:0];
							state <= #(1) 4'd3;
							nibble_count <= #(1) 4'd0;
							sysex_data <= #(1) 32'h00000000;
						end
						else if (rx_dat == midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE_END[10-:8])
							state <= #(1) 4'd0;
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					4'd3:
						if (is_data_byte(rx_dat)) begin
							sysex_data <= #(1) {sysex_data[27:0], rx_dat[3:0]};
							nibble_count <= #(1) nibble_count + 4'd1;
							if ((((sysex_size == 2'b00) && (nibble_count == 4'd1)) || ((sysex_size == 2'b01) && (nibble_count == 4'd3))) || ((sysex_size == 2'b10) && (nibble_count == 4'd7)))
								nibble_count <= #(1) 4'd15;
						end
						else if (rx_dat == midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE_END[10-:8]) begin
							sys_msg_r[57-:8] <= #(1) midi_pkg_MIDI_MSG_SYSTEM_EXCLUSIVE[10-:8];
							sys_msg_r[47-:16] <= #(1) sysex_addr;
							sys_msg_r[49-:2] <= #(1) sysex_size;
							sys_msg_r[31-:32] <= #(1) sysex_data;
							sys_vld_r <= #(1) 1'b1;
							state <= #(1) 4'd0;
						end
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					4'd4:
						if (is_data_byte(rx_dat)) begin
							data1_reg <= #(1) rx_dat[6:0];
							if (get_expected_data_bytes(status_byte) == 3'd1) begin
								sys_msg_r[57-:8] <= #(1) status_byte;
								sys_msg_r[47-:16] <= #(1) 16'h0000;
								sys_msg_r[49-:2] <= #(1) 2'b00;
								sys_msg_r[31-:32] <= #(1) {25'd0, rx_dat[6:0]};
								sys_vld_r <= #(1) 1'b1;
								state <= #(1) 4'd0;
							end
							else
								state <= #(1) 4'd5;
						end
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					4'd5:
						if (is_data_byte(rx_dat)) begin
							sys_msg_r[57-:8] <= #(1) status_byte;
							sys_msg_r[47-:16] <= #(1) 16'h0000;
							sys_msg_r[49-:2] <= #(1) 2'b00;
							sys_msg_r[31-:32] <= #(1) {18'd0, rx_dat[6:0], data1_reg};
							sys_vld_r <= #(1) 1'b1;
							state <= #(1) 4'd0;
						end
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					4'd6:
						if (is_data_byte(rx_dat)) begin
							data1_reg <= #(1) rx_dat[6:0];
							if (get_expected_data_bytes(status_byte) == 3'd1) begin
								ch_msg_r[20-:3] <= #(1) status_byte[6:4];
								ch_msg_r[17-:4] <= #(1) status_byte[3:0];
								ch_msg_r[0+:7] <= #(1) rx_dat[6:0];
								ch_msg_r[7+:7] <= #(1) 7'h00;
								ch_vld_r <= #(1) 1'b1;
								state <= #(1) 4'd0;
							end
							else
								state <= #(1) 4'd7;
						end
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					4'd7:
						if (is_data_byte(rx_dat)) begin
							ch_msg_r[20-:3] <= #(1) status_byte[6:4];
							ch_msg_r[17-:4] <= #(1) status_byte[3:0];
							ch_msg_r[0+:7] <= #(1) data1_reg;
							ch_msg_r[7+:7] <= #(1) rx_dat[6:0];
							ch_vld_r <= #(1) 1'b1;
							state <= #(1) 4'd0;
						end
						else if (is_status_byte(rx_dat)) begin
							status_byte <= #(1) rx_dat;
							if (!is_system_common(rx_dat)) begin
								running_status <= #(1) rx_dat;
								state <= #(1) 4'd6;
							end
							else begin
								running_status <= #(1) 8'h00;
								state <= #(1) 4'd0;
							end
						end
					default: state <= #(1) 4'd0;
				endcase
		end
	assign ch_msg = ch_msg_r;
	assign ch_vld = ch_vld_r;
	assign sys_msg = sys_msg_r;
	assign sys_vld = sys_vld_r;
	assign rt_clock_tick = rt_clock_tick_r;
	assign rt_start = rt_start_r;
	assign rt_continue = rt_continue_r;
	assign rt_stop = rt_stop_r;
	assign rt_active_sense = rt_active_sense_r;
	assign rt_reset = rt_reset_r;
endmodule
`default_nettype wire