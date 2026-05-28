// dc_blocker.sv
// 1st-order IIR DC blocker (high-pass), multiplier-free, pipelined,
// AXI-Stream-like flow control on both interfaces.
//
// Removes the slowly-varying DC component from a signed audio stream
// while leaving the audible band intact. Topology (Julius O. Smith
// canonical form):
//
//     y[n] = x[n] - x[n-1] + alpha * y[n-1]
//
// with alpha = 1 - 2^-SHIFT (the leak is a clean shift, no
// multiplier). Internal accumulator Y[n] = y[n] * 2^SHIFT keeps SHIFT
// bits of fractional precision so the leak converges cleanly:
//
//     diff   = x[n] - x[n-1]
//     Y[n]   = Y[n-1] + (diff << SHIFT) - rtz_shr(Y[n-1])
//     y[n]   = saturate(rtz_shr(Y[n]))
//
// Corner frequency:  fc =~ fs / (2*pi * 2^SHIFT)
// At fs = 1 MHz:
//     SHIFT = 14   ->   fc =~ 9.7 Hz    settle ~16 ms
//     SHIFT = 15   ->   fc =~ 4.8 Hz    settle ~33 ms
//     SHIFT = 16   ->   fc =~ 2.4 Hz    settle ~65 ms
//
// Round-toward-zero shift:
//   `>>>` in Verilog rounds toward -infinity, which makes the leak
//   asymmetric (positive Y stalls, negative Y keeps decaying). We
//   bias-add (2^SHIFT - 1) when Y is negative before the shift, so
//   both signs round toward zero and converge symmetrically.
//
// AXI-Stream flow control:
//   in_vld / in_rdy / in_dat        (upstream producer -> module)
//   out_vld / out_rdy / out_dat     (module -> downstream consumer)
//   Transfers happen on posedge clk where both vld && rdy are high.
//   in_vld must remain stable until in_rdy asserts. The module
//   stalls (deasserts in_rdy) when the pipeline is full and
//   downstream isn't accepting.
//
// Pipeline (3 sample-rate stages, each gated by valid + flow control):
//
//   R1:  capture x_prev_r, diff_lsl_r          when in_vld && in_rdy
//   R2:  update y_r with the new sample        when R1->R2 transfer
//   R3:  saturate(rtz_shr(y_r)) -> out_dat_r   when R2->R3 transfer
//
//   Each stage's longest combinational path is one IW-bit adder (R2)
//   or one DW-bit compare/mux (R3); well under the 54 MHz budget on
//   Cyclone III.
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
  // out_consumed: downstream took our current output this cycle
  // rN_can_accept: stage N's register can hold a new value this cycle
  //                (either it's empty, or it's transferring its current value forward)
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
