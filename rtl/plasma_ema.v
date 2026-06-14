// plasma_ema.v
// First-order EMA low-pass (IIR) on one value, updated once per frame, to smooth
// a frame-held SID tap (freq or env/vol) so the plasma reacts gradually.
//
//   acc += ((x << F) - acc) >>> K          // arithmetic shift (floors)
//   y    = (acc + (1 << (F-1))) >> F        // round-to-nearest extraction
//
// The F guard/fractional bits make it converge and the rounded extraction lets
// the output reach x exactly for K < F (a bare `y += (x-y)>>K` stalls). Bit-exact
// with plasma_model.ema_step / ema_out; reset clears acc to 0.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module plasma_ema #(
  parameter DW = 16,   // data width
  parameter F  = 6,    // fractional / guard bits (>= 1, > K to converge exactly)
  parameter K  = 3     // EMA smoothing shift; larger = slower
) (
  input  wire           clk,
  input  wire           rst_n,
  input  wire           en,      // update strobe (assert once per frame)
  input  wire [DW-1:0]  x,       // raw input value
  output wire [DW-1:0]  y        // smoothed output (round-to-nearest)
);


localparam AW = DW + F;          // accumulator width (value held in <<F fixed pt)

reg [AW-1:0] acc;

// target = x << F; diff = target - acc (signed); acc moves by diff >>> K. acc is
// always a convex blend toward target, so it stays in [0, (2^DW-1)<<F] -- AW bits.
wire signed [AW:0] target = $signed({1'b0, x, {F{1'b0}}});
wire signed [AW:0] cur    = $signed({1'b0, acc});
wire signed [AW:0] diff   = target - cur;
wire signed [AW:0] nxt    = cur + (diff >>> K);

always @(posedge clk or negedge rst_n) begin
  if (!rst_n)    acc <= {AW{1'b0}};
  else if (en)   acc <= nxt[AW-1:0];
end

// round-to-nearest: (acc + 2^(F-1)) >> F. the +half can carry into bit AW but
// never past it (acc <= (2^DW-1)<<F), so the DW-bit output never overflows.
wire [AW:0] acc_round = {1'b0, acc} + {{(AW-F){1'b0}}, 1'b1, {(F-1){1'b0}}};
assign y = acc_round[AW-1:F];


endmodule


`default_nettype wire
