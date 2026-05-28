`default_nettype none
module ch_msg_router (
	ch_msg,
	ch_vld,
	ch_rdy,
	ctrl_en,
	ctrl_channel,
	vc_msg,
	vc_vld,
	cc_msg,
	cc_vld
);
	reg _sv2v_0;
	input wire [20:0] ch_msg;
	input wire ch_vld;
	output wire ch_rdy;
	input wire ctrl_en;
	input wire [3:0] ctrl_channel;
	output wire [20:0] vc_msg;
	output wire vc_vld;
	output wire [20:0] cc_msg;
	output wire cc_vld;
	assign ch_rdy = ctrl_en;
	reg route_to_vc;
	reg route_to_cc;
	wire msg_active;
	assign msg_active = (ctrl_en && ch_vld) && (ch_msg[17-:4] == ctrl_channel);
	always @(*) begin
		if (_sv2v_0)
			;
		route_to_vc = 1'b0;
		route_to_cc = 1'b0;
		if (msg_active)
			case (ch_msg[20-:3])
				3'd0, 3'd1, 3'd2, 3'd6: route_to_vc = 1'b1;
				3'd3: begin
					route_to_cc = 1'b1;
					if (|{ch_msg[0+:7] == 7'd64, ch_msg[0+:7] == 7'd66, ch_msg[0+:7] == 7'd68, ch_msg[0+:7] == 7'd120, ch_msg[0+:7] == 7'd121, ch_msg[0+:7] == 7'd123, ch_msg[0+:7] == 7'd126, ch_msg[0+:7] == 7'd127})
						route_to_vc = 1'b1;
				end
				default:
					;
			endcase
	end
	assign vc_msg = ch_msg;
	assign vc_vld = route_to_vc;
	assign cc_msg = ch_msg;
	assign cc_vld = route_to_cc;
	initial _sv2v_0 = 0;
endmodule
`default_nettype wire