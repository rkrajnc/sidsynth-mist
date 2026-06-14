// dc_blocker.sv
// Multiplier-free, pipelined 1st-order IIR DC blocker (high-pass) with
// AXI-Stream-like flow control on both interfaces.
//
// y[n] = x[n] - x[n-1] + alpha*y[n-1], alpha = 1 - 2^-SHIFT (so the
// leak is a clean shift). A SHIFT-bit fractional accumulator and a
// round-toward-zero shift make the residual converge symmetrically to
// zero. fc =~ fs / (2*pi * 2^SHIFT); at 1 MHz, SHIFT=15 gives ~4.8 Hz.
//
// 3 sample-rate pipeline stages, each gated by valid + flow control:
//   R1: capture x_prev_r, diff_lsl_r
//   R2: update y_r
//   R3: saturate(rtz_shr(y_r)) -> out_dat_r
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module dc_blocker #(
  parameter int unsigned DW    = 18,   // input/output data width (signed)
  parameter int unsigned SHIFT = 15    // log2 time constant; fc =~ fs/(2*pi*2^SHIFT)
) (
  input  wire logic                  clk,
  input  wire logic                  rst_n,    // async, active low

  // upstream AXI-Stream
  input  wire logic                  in_vld,
  output wire logic                  in_rdy,
  input  wire logic signed [DW-1:0]  in_dat,

  // downstream AXI-Stream
  output wire logic                  out_vld,
  input  wire logic                  out_rdy,
  output wire logic signed [DW-1:0]  out_dat
);

  // internal accumulator width: DW + SHIFT + 2 headroom bits
  localparam int unsigned IW = DW + SHIFT + 2;

  // DW-range saturation bounds, sign-extended to (IW - SHIFT)
  localparam logic signed [IW-SHIFT-1:0] OUT_SAT_MAX =
      (IW-SHIFT)'(  (1 << (DW-1)) - 1 );
  localparam logic signed [IW-SHIFT-1:0] OUT_SAT_MIN =
      (IW-SHIFT)'( -(1 << (DW-1))     );

  // round-to-zero bias for the >>> SHIFT shifts
  localparam logic signed [IW-1:0] RTZ_BIAS = IW'((1 << SHIFT) - 1);


  //// pipeline registers ////
  logic signed [DW-1:0]  x_prev_r;
  logic signed [IW-1:0]  diff_lsl_r;
  logic                  vld_r1;

  logic signed [IW-1:0]  y_r;
  logic                  vld_r2;

  logic signed [DW-1:0]  out_dat_r;
  logic                  vld_out_r;


  //// flow control: propagate stalls back through the pipeline ////
  // out_consumed: downstream took our output this cycle. rN_can_accept:
  // stage N can take a new value (it's empty or transferring forward).
  logic out_consumed;
  logic r2_to_out;       // transfer R2's data into out_dat_r
  logic r1_to_r2;        // transfer R1's data into R2 (i.e. update y_r)
  logic in_to_r1;        // transfer in_dat into R1
  logic out_can_accept;
  logic r2_can_accept;
  logic r1_can_accept;

  assign out_consumed   = vld_out_r && out_rdy;
  assign out_can_accept = !vld_out_r || out_consumed;
  assign r2_to_out      = vld_r2 && out_can_accept;
  assign r2_can_accept  = !vld_r2 || r2_to_out;
  assign r1_to_r2       = vld_r1 && r2_can_accept;
  assign r1_can_accept  = !vld_r1 || r1_to_r2;
  assign in_to_r1       = in_vld && r1_can_accept;

  assign in_rdy  = r1_can_accept;
  assign out_vld = vld_out_r;
  assign out_dat = out_dat_r;


  //// stage 1 combinational: diff_lsl = (in_dat - x_prev_r) << SHIFT ////
  logic signed [IW-1:0]  in_ext;
  logic signed [IW-1:0]  xprev_ext;
  logic signed [IW-1:0]  diff_lsl_next;

  always_comb begin
    in_ext        = IW'(in_dat);
    xprev_ext     = IW'(x_prev_r);
    diff_lsl_next = (in_ext - xprev_ext) <<< SHIFT;
  end


  //// stage 2 combinational: y_next = y_r + diff_lsl_r - rtz_shr(y_r) ////
  logic signed [IW-1:0]  y_round_bias;
  logic signed [IW-1:0]  y_shr_rtz;
  logic signed [IW-1:0]  y_next;

  always_comb begin
    y_round_bias = y_r[IW-1] ? RTZ_BIAS : '0;
    y_shr_rtz    = (y_r + y_round_bias) >>> SHIFT;
    y_next       = y_r + diff_lsl_r - y_shr_rtz;
  end


  //// stage 3 combinational: saturate(rtz_shr(y_r)) ////
  logic signed [IW-1:0]            out_round_bias;
  logic signed [IW-SHIFT-1:0]      y_shifted;
  logic signed [DW-1:0]            out_sat;

  always_comb begin
    out_round_bias = y_r[IW-1] ? RTZ_BIAS : '0;
    y_shifted      = (IW-SHIFT)'((y_r + out_round_bias) >>> SHIFT);
    if (y_shifted > OUT_SAT_MAX) begin
      out_sat = DW'(OUT_SAT_MAX);
    end else if (y_shifted < OUT_SAT_MIN) begin
      out_sat = DW'(OUT_SAT_MIN);
    end else begin
      out_sat = y_shifted[DW-1:0];
    end
  end


  //// registered pipeline + flow control ////
  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      x_prev_r   <= '0;
      diff_lsl_r <= '0;
      vld_r1     <= 1'b0;

      y_r        <= '0;
      vld_r2     <= 1'b0;

      out_dat_r  <= '0;
      vld_out_r  <= 1'b0;
    end else begin
      // R1: takes a new sample, or transfers forward
      if (in_to_r1) begin
        x_prev_r   <= in_dat;
        diff_lsl_r <= diff_lsl_next;
        vld_r1     <= 1'b1;
      end else if (r1_to_r2) begin
        vld_r1 <= 1'b0;
      end

      // R2 (y_r and vld_r2): update y_r when r1_to_r2 transfer fires,
      // clear vld_r2 when r2_to_out drains it
      if (r1_to_r2) begin
        y_r    <= y_next;
        vld_r2 <= 1'b1;
      end else if (r2_to_out) begin
        vld_r2 <= 1'b0;
      end

      // R3 (out_dat_r and vld_out_r): capture saturated output when
      // r2_to_out fires, clear vld_out_r when downstream consumes it
      if (r2_to_out) begin
        out_dat_r <= out_sat;
        vld_out_r <= 1'b1;
      end else if (out_consumed) begin
        vld_out_r <= 1'b0;
      end
    end
  end


endmodule


`default_nettype wire
