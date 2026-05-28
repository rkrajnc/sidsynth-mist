`default_nettype none
module voice_ctrl (
	clk,
	clk_en,
	rst_n,
	ch_msg,
	ch_vld,
	ch_rdy,
	voice_gate,
	voice_note,
	voice_velocity,
	voice_aftertouch,
	voice_pitch_bend,
	voice_release_done,
	ctrl_en,
	ctrl_channel,
	ctrl_all_notes_off,
	ctrl_steal_en,
	ctrl_overflow_clr,
	ctrl_mono,
	ctrl_unison,
	cpu_voice_idx,
	cpu_voice_note,
	cpu_voice_vel,
	cpu_voice_gate,
	cpu_voice_state,
	stat_active_count,
	stat_gate_bitmap,
	stat_overflow,
	stat_sustain,
	voice_legato,
	stat_cc_mono,
	stat_legato,
	stat_unison
);
	reg _sv2v_0;
	parameter signed [31:0] NV = 16;
	parameter signed [31:0] AGEW = 16;
	parameter signed [31:0] NSD = 16;
	localparam signed [31:0] NVW = $clog2(NV);
	localparam signed [31:0] NSDW = $clog2(NSD);
	input wire clk;
	input wire clk_en;
	input wire rst_n;
	input wire [20:0] ch_msg;
	input wire ch_vld;
	output wire ch_rdy;
	output wire [NV - 1:0] voice_gate;
	output wire [(NV * 7) - 1:0] voice_note;
	output wire [(NV * 7) - 1:0] voice_velocity;
	output wire [(NV * 7) - 1:0] voice_aftertouch;
	output wire [13:0] voice_pitch_bend;
	input wire [NV - 1:0] voice_release_done;
	input wire ctrl_en;
	input wire [3:0] ctrl_channel;
	input wire ctrl_all_notes_off;
	input wire ctrl_steal_en;
	input wire ctrl_overflow_clr;
	input wire ctrl_mono;
	input wire ctrl_unison;
	input wire [NVW - 1:0] cpu_voice_idx;
	output wire [6:0] cpu_voice_note;
	output wire [6:0] cpu_voice_vel;
	output wire cpu_voice_gate;
	output wire [1:0] cpu_voice_state;
	output wire [NVW:0] stat_active_count;
	output wire [NV - 1:0] stat_gate_bitmap;
	output wire stat_overflow;
	output wire stat_sustain;
	output wire voice_legato;
	output wire stat_cc_mono;
	output wire stat_legato;
	output wire stat_unison;
	reg [1:0] voice_state_r [0:NV - 1];
	reg [6:0] voice_note_r [0:NV - 1];
	reg [6:0] voice_vel_r [0:NV - 1];
	reg [6:0] voice_at_r [0:NV - 1];
	reg [AGEW - 1:0] voice_age_r [0:NV - 1];
	reg [13:0] pitch_bend_r;
	reg sustain_r;
	reg [NV - 1:0] sostenuto_locked_r;
	reg [AGEW - 1:0] age_counter_r;
	reg overflow_r;
	reg cc_mono_r;
	reg legato_r;
	reg voice_legato_r;
	reg unison_prev_r;
	reg [6:0] mono_note_r [0:NSD - 1];
	reg [6:0] mono_vel_r [0:NSD - 1];
	reg [NSDW:0] mono_sp_r;
	reg steal_pending_r;
	assign ch_rdy = ctrl_en && !steal_pending_r;
	wire mono_eff;
	assign mono_eff = (ctrl_mono || cc_mono_r) || ctrl_unison;
	wire [2:0] msg_type;
	wire [3:0] msg_channel;
	wire [6:0] msg_data0;
	wire [6:0] msg_data1;
	assign msg_type = ch_msg[20-:3];
	assign msg_channel = ch_msg[17-:4];
	assign msg_data0 = ch_msg[0+:7];
	assign msg_data1 = ch_msg[7+:7];
	reg [NV - 1:0] note_match;
	reg note_match_any;
	reg [NVW - 1:0] note_match_idx;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				note_match[i] = (voice_state_r[i] != 2'b00) && (voice_note_r[i] == msg_data0);
		end
	end
	function automatic signed [NVW - 1:0] sv2v_cast_0F1F9_signed;
		input reg signed [NVW - 1:0] inp;
		sv2v_cast_0F1F9_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		note_match_any = 1'b0;
		note_match_idx = 1'sb0;
		begin : sv2v_autoblock_2
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				if (note_match[i] && !note_match_any) begin
					note_match_any = 1'b1;
					note_match_idx = sv2v_cast_0F1F9_signed(i);
				end
		end
	end
	reg [NV - 1:0] voice_free;
	reg free_any;
	reg [NVW - 1:0] free_idx;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_3
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				voice_free[i] = voice_state_r[i] == 2'b00;
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
		free_any = 1'b0;
		free_idx = 1'sb0;
		begin : sv2v_autoblock_4
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				if (voice_free[i] && !free_any) begin
					free_any = 1'b1;
					free_idx = sv2v_cast_0F1F9_signed(i);
				end
		end
	end
	localparam signed [31:0] SKW = 2 + AGEW;
	reg [SKW - 1:0] steal_key [0:NV - 1];
	reg [SKW - 1:0] steal_key_r [0:NV - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_5
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				case (voice_state_r[i])
					2'b11: steal_key[i] = {2'd3, ~voice_age_r[i]};
					2'b10: steal_key[i] = {2'd2, ~voice_age_r[i]};
					2'b01: steal_key[i] = {2'd1, ~voice_age_r[i]};
					default: steal_key[i] = 1'sb0;
				endcase
		end
	end
	reg [SKW - 1:0] tree_l1_key [0:(NV / 2) - 1];
	reg [NVW - 1:0] tree_l1_idx [0:(NV / 2) - 1];
	reg [SKW - 1:0] tree_l1_key_r [0:(NV / 2) - 1];
	reg [NVW - 1:0] tree_l1_idx_r [0:(NV / 2) - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_6
			reg signed [31:0] i;
			for (i = 0; i < (NV / 2); i = i + 1)
				if (steal_key_r[2 * i] >= steal_key_r[(2 * i) + 1]) begin
					tree_l1_key[i] = steal_key_r[2 * i];
					tree_l1_idx[i] = sv2v_cast_0F1F9_signed(2 * i);
				end
				else begin
					tree_l1_key[i] = steal_key_r[(2 * i) + 1];
					tree_l1_idx[i] = sv2v_cast_0F1F9_signed((2 * i) + 1);
				end
		end
	end
	reg [SKW - 1:0] tree_l2_key [0:(NV / 4) - 1];
	reg [NVW - 1:0] tree_l2_idx [0:(NV / 4) - 1];
	reg [SKW - 1:0] tree_l2_key_r [0:(NV / 4) - 1];
	reg [NVW - 1:0] tree_l2_idx_r [0:(NV / 4) - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_7
			reg signed [31:0] i;
			for (i = 0; i < (NV / 4); i = i + 1)
				if (tree_l1_key_r[2 * i] >= tree_l1_key_r[(2 * i) + 1]) begin
					tree_l2_key[i] = tree_l1_key_r[2 * i];
					tree_l2_idx[i] = tree_l1_idx_r[2 * i];
				end
				else begin
					tree_l2_key[i] = tree_l1_key_r[(2 * i) + 1];
					tree_l2_idx[i] = tree_l1_idx_r[(2 * i) + 1];
				end
		end
	end
	reg [SKW - 1:0] tree_l3_key [0:(NV / 8) - 1];
	reg [NVW - 1:0] tree_l3_idx [0:(NV / 8) - 1];
	reg [SKW - 1:0] tree_l3_key_r [0:(NV / 8) - 1];
	reg [NVW - 1:0] tree_l3_idx_r [0:(NV / 8) - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_8
			reg signed [31:0] i;
			for (i = 0; i < (NV / 8); i = i + 1)
				if (tree_l2_key_r[2 * i] >= tree_l2_key_r[(2 * i) + 1]) begin
					tree_l3_key[i] = tree_l2_key_r[2 * i];
					tree_l3_idx[i] = tree_l2_idx_r[2 * i];
				end
				else begin
					tree_l3_key[i] = tree_l2_key_r[(2 * i) + 1];
					tree_l3_idx[i] = tree_l2_idx_r[(2 * i) + 1];
				end
		end
	end
	reg [SKW - 1:0] steal_key_best;
	reg [NVW - 1:0] steal_idx;
	reg steal_vld;
	always @(*) begin
		if (_sv2v_0)
			;
		if (tree_l3_key_r[0] >= tree_l3_key_r[1]) begin
			steal_key_best = tree_l3_key_r[0];
			steal_idx = tree_l3_idx_r[0];
		end
		else begin
			steal_key_best = tree_l3_key_r[1];
			steal_idx = tree_l3_idx_r[1];
		end
		steal_vld = steal_key_best != {SKW {1'sb0}};
	end
	reg steal_vld_r;
	reg [NVW - 1:0] steal_idx_r;
	always @(posedge clk) begin
		begin : sv2v_autoblock_9
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				steal_key_r[i] <= steal_key[i];
		end
		begin : sv2v_autoblock_10
			reg signed [31:0] i;
			for (i = 0; i < (NV / 2); i = i + 1)
				begin
					tree_l1_key_r[i] <= tree_l1_key[i];
					tree_l1_idx_r[i] <= tree_l1_idx[i];
				end
		end
		begin : sv2v_autoblock_11
			reg signed [31:0] i;
			for (i = 0; i < (NV / 4); i = i + 1)
				begin
					tree_l2_key_r[i] <= tree_l2_key[i];
					tree_l2_idx_r[i] <= tree_l2_idx[i];
				end
		end
		begin : sv2v_autoblock_12
			reg signed [31:0] i;
			for (i = 0; i < (NV / 8); i = i + 1)
				begin
					tree_l3_key_r[i] <= tree_l3_key[i];
					tree_l3_idx_r[i] <= tree_l3_idx[i];
				end
		end
		steal_vld_r <= steal_vld;
		steal_idx_r <= steal_idx;
	end
	reg [6:0] steal_note_r;
	reg [6:0] steal_vel_r;
	reg mono_match_found;
	reg [NSDW:0] mono_match_pos;
	reg mono_was_top;
	reg [6:0] mono_new_top_note;
	reg [6:0] mono_new_top_vel;
	function automatic signed [((NSDW + 0) >= 0 ? NSDW + 1 : 1 - (NSDW + 0)) - 1:0] sv2v_cast_A89C7_signed;
		input reg signed [((NSDW + 0) >= 0 ? NSDW + 1 : 1 - (NSDW + 0)) - 1:0] inp;
		sv2v_cast_A89C7_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		mono_match_found = 1'b0;
		mono_match_pos = 1'sb0;
		begin : sv2v_autoblock_13
			reg signed [31:0] i;
			for (i = 0; i < NSD; i = i + 1)
				if (((sv2v_cast_A89C7_signed(i) < mono_sp_r) && (mono_note_r[i] == msg_data0)) && !mono_match_found) begin
					mono_match_found = 1'b1;
					mono_match_pos = sv2v_cast_A89C7_signed(i);
				end
		end
		mono_was_top = mono_match_found && (mono_match_pos == (mono_sp_r - sv2v_cast_A89C7_signed(1)));
		mono_new_top_note = 1'sb0;
		mono_new_top_vel = 1'sb0;
		if (mono_sp_r > sv2v_cast_A89C7_signed(1)) begin
			if (mono_was_top) begin
				mono_new_top_note = mono_note_r[mono_sp_r - 2];
				mono_new_top_vel = mono_vel_r[mono_sp_r - 2];
			end
			else begin
				mono_new_top_note = mono_note_r[mono_sp_r - 1];
				mono_new_top_vel = mono_vel_r[mono_sp_r - 1];
			end
		end
	end
	wire msg_active;
	assign msg_active = ((ctrl_en && ch_vld) && ch_rdy) && (msg_channel == ctrl_channel);
	localparam [13:0] voice_ctrl_pkg_PITCH_BEND_CENTER = 14'h2000;
	always @(posedge clk)
		if (!rst_n) begin
			begin : sv2v_autoblock_14
				reg signed [31:0] i;
				for (i = 0; i < NV; i = i + 1)
					begin
						voice_state_r[i] <= 2'b00;
						voice_note_r[i] <= 1'sb0;
						voice_vel_r[i] <= 1'sb0;
						voice_at_r[i] <= 1'sb0;
					end
			end
			pitch_bend_r <= voice_ctrl_pkg_PITCH_BEND_CENTER;
			sustain_r <= 1'b0;
			sostenuto_locked_r <= 1'sb0;
			age_counter_r <= 1'sb0;
			overflow_r <= 1'b0;
			cc_mono_r <= 1'b0;
			legato_r <= 1'b0;
			voice_legato_r <= 1'b0;
			mono_sp_r <= 1'sb0;
			steal_pending_r <= 1'b0;
			unison_prev_r <= 1'b0;
		end
		else if (clk_en) begin : sv2v_autoblock_15
			reg [1:0] v0_st_new;
			reg [6:0] v0_note_new;
			reg [6:0] v0_vel_new;
			reg v0_uni_rep;
			v0_st_new = voice_state_r[0];
			v0_note_new = voice_note_r[0];
			v0_vel_new = voice_vel_r[0];
			v0_uni_rep = 1'b0;
			voice_legato_r <= 1'b0;
			begin : sv2v_autoblock_16
				reg signed [31:0] i;
				for (i = 0; i < NV; i = i + 1)
					if (voice_release_done[i] && (voice_state_r[i] == 2'b11)) begin
						voice_state_r[i] <= 2'b00;
						sostenuto_locked_r[i] <= 1'b0;
					end
			end
			if (ctrl_all_notes_off) begin
				begin : sv2v_autoblock_17
					reg signed [31:0] i;
					for (i = 0; i < NV; i = i + 1)
						begin
							voice_state_r[i] <= 2'b00;
							voice_at_r[i] <= 1'sb0;
						end
				end
				sustain_r <= 1'b0;
				sostenuto_locked_r <= 1'sb0;
				mono_sp_r <= 1'sb0;
			end
			if (ctrl_overflow_clr)
				overflow_r <= 1'b0;
			unison_prev_r <= ctrl_unison;
			if (unison_prev_r && !ctrl_unison) begin
				begin : sv2v_autoblock_18
					reg signed [31:0] i;
					for (i = 1; i < NV; i = i + 1)
						begin
							voice_state_r[i] <= 2'b00;
							voice_at_r[i] <= 1'sb0;
						end
				end
				mono_sp_r <= 1'sb0;
			end
			if (steal_pending_r) begin
				steal_pending_r <= 1'b0;
				if (steal_vld_r) begin
					voice_state_r[steal_idx_r] <= 2'b01;
					voice_note_r[steal_idx_r] <= steal_note_r;
					voice_vel_r[steal_idx_r] <= steal_vel_r;
					voice_at_r[steal_idx_r] <= 1'sb0;
					voice_age_r[steal_idx_r] <= age_counter_r;
					age_counter_r <= age_counter_r + 1'b1;
					overflow_r <= 1'b1;
					sostenuto_locked_r[steal_idx_r] <= 1'b0;
				end
			end
			if (msg_active)
				case (msg_type)
					3'd1:
						if (msg_data1 == 7'd0) begin
							if (mono_eff) begin
								if (mono_match_found) begin
									begin : sv2v_autoblock_19
										reg signed [31:0] i;
										for (i = 0; i < (NSD - 1); i = i + 1)
											if ((sv2v_cast_A89C7_signed(i) >= mono_match_pos) && (sv2v_cast_A89C7_signed(i) < (mono_sp_r - sv2v_cast_A89C7_signed(1)))) begin
												mono_note_r[i] <= mono_note_r[i + 1];
												mono_vel_r[i] <= mono_vel_r[i + 1];
											end
									end
									mono_sp_r <= mono_sp_r - sv2v_cast_A89C7_signed(1);
									if (mono_sp_r == sv2v_cast_A89C7_signed(1)) begin
										if (sustain_r || sostenuto_locked_r[0]) begin
											voice_state_r[0] <= 2'b10;
											v0_st_new = 2'b10;
										end
										else begin
											voice_state_r[0] <= 2'b11;
											v0_st_new = 2'b11;
										end
										v0_uni_rep = 1'b1;
									end
									else if (mono_was_top) begin
										voice_note_r[0] <= mono_new_top_note;
										voice_vel_r[0] <= mono_new_top_vel;
										voice_state_r[0] <= 2'b01;
										voice_legato_r <= legato_r;
										v0_st_new = 2'b01;
										v0_note_new = mono_new_top_note;
										v0_vel_new = mono_new_top_vel;
										v0_uni_rep = 1'b1;
									end
								end
							end
							else if (note_match_any) begin
								if (sustain_r || sostenuto_locked_r[note_match_idx])
									voice_state_r[note_match_idx] <= 2'b10;
								else
									voice_state_r[note_match_idx] <= 2'b11;
							end
						end
						else if (mono_eff) begin
							if (mono_match_found) begin
								begin : sv2v_autoblock_20
									reg signed [31:0] i;
									for (i = 0; i < (NSD - 1); i = i + 1)
										if ((sv2v_cast_A89C7_signed(i) >= mono_match_pos) && (sv2v_cast_A89C7_signed(i) < (mono_sp_r - sv2v_cast_A89C7_signed(1)))) begin
											mono_note_r[i] <= mono_note_r[i + 1];
											mono_vel_r[i] <= mono_vel_r[i + 1];
										end
								end
								mono_note_r[mono_sp_r - 1] <= msg_data0;
								mono_vel_r[mono_sp_r - 1] <= msg_data1;
							end
							else if (mono_sp_r < sv2v_cast_A89C7_signed(NSD)) begin
								mono_note_r[mono_sp_r] <= msg_data0;
								mono_vel_r[mono_sp_r] <= msg_data1;
								mono_sp_r <= mono_sp_r + sv2v_cast_A89C7_signed(1);
							end
							voice_legato_r <= legato_r && ((voice_state_r[0] == 2'b01) || (voice_state_r[0] == 2'b10));
							voice_state_r[0] <= 2'b01;
							voice_note_r[0] <= msg_data0;
							voice_vel_r[0] <= msg_data1;
							voice_at_r[0] <= 1'sb0;
							v0_st_new = 2'b01;
							v0_note_new = msg_data0;
							v0_vel_new = msg_data1;
							v0_uni_rep = 1'b1;
						end
						else if (note_match_any) begin
							voice_state_r[note_match_idx] <= 2'b01;
							voice_vel_r[note_match_idx] <= msg_data1;
							voice_age_r[note_match_idx] <= age_counter_r;
							age_counter_r <= age_counter_r + 1'b1;
							sostenuto_locked_r[note_match_idx] <= 1'b0;
						end
						else if (free_any) begin
							voice_state_r[free_idx] <= 2'b01;
							voice_note_r[free_idx] <= msg_data0;
							voice_vel_r[free_idx] <= msg_data1;
							voice_at_r[free_idx] <= 1'sb0;
							voice_age_r[free_idx] <= age_counter_r;
							age_counter_r <= age_counter_r + 1'b1;
							sostenuto_locked_r[free_idx] <= 1'b0;
						end
						else if (ctrl_steal_en && steal_vld_r) begin
							steal_pending_r <= 1'b1;
							steal_note_r <= msg_data0;
							steal_vel_r <= msg_data1;
						end
					3'd0:
						if (mono_eff) begin
							if (mono_match_found) begin
								begin : sv2v_autoblock_21
									reg signed [31:0] i;
									for (i = 0; i < (NSD - 1); i = i + 1)
										if ((sv2v_cast_A89C7_signed(i) >= mono_match_pos) && (sv2v_cast_A89C7_signed(i) < (mono_sp_r - sv2v_cast_A89C7_signed(1)))) begin
											mono_note_r[i] <= mono_note_r[i + 1];
											mono_vel_r[i] <= mono_vel_r[i + 1];
										end
								end
								mono_sp_r <= mono_sp_r - sv2v_cast_A89C7_signed(1);
								if (mono_sp_r == sv2v_cast_A89C7_signed(1)) begin
									if (sustain_r || sostenuto_locked_r[0]) begin
										voice_state_r[0] <= 2'b10;
										v0_st_new = 2'b10;
									end
									else begin
										voice_state_r[0] <= 2'b11;
										v0_st_new = 2'b11;
									end
									v0_uni_rep = 1'b1;
								end
								else if (mono_was_top) begin
									voice_note_r[0] <= mono_new_top_note;
									voice_vel_r[0] <= mono_new_top_vel;
									voice_state_r[0] <= 2'b01;
									voice_legato_r <= legato_r;
									v0_st_new = 2'b01;
									v0_note_new = mono_new_top_note;
									v0_vel_new = mono_new_top_vel;
									v0_uni_rep = 1'b1;
								end
							end
						end
						else if (note_match_any) begin
							if (sustain_r || sostenuto_locked_r[note_match_idx])
								voice_state_r[note_match_idx] <= 2'b10;
							else
								voice_state_r[note_match_idx] <= 2'b11;
						end
					3'd6: pitch_bend_r <= {msg_data1, msg_data0};
					3'd3:
						if (msg_data0 == 7'd64) begin
							if (msg_data1 >= 7'd64)
								sustain_r <= 1'b1;
							else begin
								sustain_r <= 1'b0;
								begin : sv2v_autoblock_22
									reg signed [31:0] i;
									for (i = 0; i < NV; i = i + 1)
										if (voice_state_r[i] == 2'b10)
											voice_state_r[i] <= 2'b11;
								end
							end
						end
						else if (msg_data0 == 7'd66) begin
							if (msg_data1 >= 7'd64) begin : sv2v_autoblock_23
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									if (voice_state_r[i] == 2'b01)
										sostenuto_locked_r[i] <= 1'b1;
							end
							else begin : sv2v_autoblock_24
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									begin
										if (sostenuto_locked_r[i] && (voice_state_r[i] == 2'b10))
											voice_state_r[i] <= 2'b11;
										sostenuto_locked_r[i] <= 1'b0;
									end
							end
						end
						else if (msg_data0 == 7'd120) begin
							begin : sv2v_autoblock_25
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									begin
										voice_state_r[i] <= 2'b00;
										voice_at_r[i] <= 1'sb0;
									end
							end
							sostenuto_locked_r <= 1'sb0;
							if (mono_eff)
								mono_sp_r <= 1'sb0;
						end
						else if (msg_data0 == 7'd68)
							legato_r <= msg_data1 >= 7'd64;
						else if (msg_data0 == 7'd121) begin
							pitch_bend_r <= voice_ctrl_pkg_PITCH_BEND_CENTER;
							sustain_r <= 1'b0;
							sostenuto_locked_r <= 1'sb0;
							legato_r <= 1'b0;
							begin : sv2v_autoblock_26
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									begin
										voice_at_r[i] <= 1'sb0;
										if (voice_state_r[i] == 2'b10)
											voice_state_r[i] <= 2'b11;
									end
							end
							if (mono_eff)
								mono_sp_r <= 1'sb0;
						end
						else if (msg_data0 == 7'd123) begin
							begin : sv2v_autoblock_27
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									voice_at_r[i] <= 1'sb0;
							end
							if (mono_eff) begin
								mono_sp_r <= 1'sb0;
								if (sustain_r) begin
									if (voice_state_r[0] == 2'b01) begin
										voice_state_r[0] <= 2'b10;
										v0_st_new = 2'b10;
										v0_uni_rep = 1'b1;
									end
								end
								else begin : sv2v_autoblock_28
									reg signed [31:0] i;
									for (i = 0; i < NV; i = i + 1)
										if ((voice_state_r[i] == 2'b01) || (voice_state_r[i] == 2'b10))
											voice_state_r[i] <= 2'b11;
								end
							end
							else if (sustain_r) begin : sv2v_autoblock_29
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									if (voice_state_r[i] == 2'b01)
										voice_state_r[i] <= 2'b10;
							end
							else begin : sv2v_autoblock_30
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									if ((voice_state_r[i] == 2'b01) || (voice_state_r[i] == 2'b10))
										voice_state_r[i] <= 2'b11;
							end
						end
						else if (msg_data0 == 7'd126) begin
							cc_mono_r <= 1'b1;
							begin : sv2v_autoblock_31
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									begin
										voice_state_r[i] <= 2'b00;
										voice_at_r[i] <= 1'sb0;
									end
							end
							sostenuto_locked_r <= 1'sb0;
							mono_sp_r <= 1'sb0;
						end
						else if (msg_data0 == 7'd127) begin
							cc_mono_r <= 1'b0;
							begin : sv2v_autoblock_32
								reg signed [31:0] i;
								for (i = 0; i < NV; i = i + 1)
									begin
										voice_state_r[i] <= 2'b00;
										voice_at_r[i] <= 1'sb0;
									end
							end
							sostenuto_locked_r <= 1'sb0;
							mono_sp_r <= 1'sb0;
						end
					3'd2:
						if (ctrl_unison) begin : sv2v_autoblock_33
							reg signed [31:0] i;
							for (i = 0; i < NV; i = i + 1)
								if (note_match[i])
									voice_at_r[i] <= msg_data1;
						end
						else if (note_match_any)
							voice_at_r[note_match_idx] <= msg_data1;
					default:
						;
				endcase
			if (ctrl_unison && v0_uni_rep) begin : sv2v_autoblock_34
				reg signed [31:0] i;
				for (i = 1; i < NV; i = i + 1)
					begin
						voice_state_r[i] <= v0_st_new;
						voice_note_r[i] <= v0_note_new;
						voice_vel_r[i] <= v0_vel_new;
						voice_at_r[i] <= voice_at_r[0];
					end
			end
		end
	reg [NV - 1:0] voice_gate_w;
	reg [(NV * 7) - 1:0] voice_note_w;
	reg [(NV * 7) - 1:0] voice_velocity_w;
	reg [(NV * 7) - 1:0] voice_aftertouch_w;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_35
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				begin
					voice_gate_w[i] = (voice_state_r[i] == 2'b01) || (voice_state_r[i] == 2'b10);
					voice_note_w[i * 7+:7] = voice_note_r[i];
					voice_velocity_w[i * 7+:7] = voice_vel_r[i];
					voice_aftertouch_w[i * 7+:7] = voice_at_r[i];
				end
		end
	end
	assign voice_gate = voice_gate_w;
	assign voice_note = voice_note_w;
	assign voice_velocity = voice_velocity_w;
	assign voice_aftertouch = voice_aftertouch_w;
	assign voice_pitch_bend = pitch_bend_r;
	assign cpu_voice_note = voice_note_r[cpu_voice_idx];
	assign cpu_voice_vel = voice_vel_r[cpu_voice_idx];
	assign cpu_voice_gate = (voice_state_r[cpu_voice_idx] == 2'b01) || (voice_state_r[cpu_voice_idx] == 2'b10);
	assign cpu_voice_state = voice_state_r[cpu_voice_idx];
	assign stat_gate_bitmap = voice_gate;
	assign stat_sustain = sustain_r;
	assign stat_overflow = overflow_r;
	assign stat_cc_mono = cc_mono_r;
	assign stat_legato = legato_r;
	assign stat_unison = ctrl_unison;
	assign voice_legato = voice_legato_r;
	reg [NVW:0] stat_active_count_w;
	always @(*) begin
		if (_sv2v_0)
			;
		stat_active_count_w = 1'sb0;
		begin : sv2v_autoblock_36
			reg signed [31:0] i;
			for (i = 0; i < NV; i = i + 1)
				stat_active_count_w = stat_active_count_w + {{NVW {1'b0}}, voice_gate[i]};
		end
	end
	assign stat_active_count = stat_active_count_w;
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire