// plasma_sine.v
// 16-entry sine LUT (in fabric logic, no M9K) read with multiplier-free linear
// interpolation. Bit-exact with plasma_model.sine16_interp; the interpolation
// shift-add tree is proven against a real multiply in sw/interp_math.py.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module plasma_sine (
  input  wire [7:0] idx,   // 8-bit sine phase
  output wire [7:0] val    // 0..255 interpolated sine
);


// 16-entry, 8-bit sine table (one full period). frozen from
// plasma_model.SINE16; maps to LUTs, not an M9K block.
function [7:0] sine_lut;
  input [3:0] i;
  begin
    case (i)
      4'd0:  sine_lut = 8'd128;
      4'd1:  sine_lut = 8'd176;
      4'd2:  sine_lut = 8'd218;
      4'd3:  sine_lut = 8'd245;
      4'd4:  sine_lut = 8'd255;
      4'd5:  sine_lut = 8'd245;
      4'd6:  sine_lut = 8'd218;
      4'd7:  sine_lut = 8'd176;
      4'd8:  sine_lut = 8'd128;
      4'd9:  sine_lut = 8'd79;
      4'd10: sine_lut = 8'd37;
      4'd11: sine_lut = 8'd10;
      4'd12: sine_lut = 8'd0;
      4'd13: sine_lut = 8'd10;
      4'd14: sine_lut = 8'd37;
      4'd15: sine_lut = 8'd79;
      default: sine_lut = 8'd128;
    endcase
  end
endfunction


wire [3:0] i = idx[7:4];
wire [3:0] f = idx[3:0];
wire [7:0] a = sine_lut(i);
wire [7:0] b = sine_lut(i + 4'd1);            // index wraps mod 16

// delta = b - a, signed 9-bit (-255..255)
wire signed [8:0] delta = $signed({1'b0, b}) - $signed({1'b0, a});

// P = delta * f as a 4-term shift-add tree (f is 4 bits), signed 13-bit
wire signed [12:0] d1 = {{4{delta[8]}}, delta};           // delta
wire signed [12:0] d2 = {{3{delta[8]}}, delta, 1'b0};     // delta << 1
wire signed [12:0] d4 = {{2{delta[8]}}, delta, 2'b0};     // delta << 2
wire signed [12:0] d8 = {{1{delta[8]}}, delta, 3'b0};     // delta << 3
wire signed [12:0] p  = (f[0] ? d1 : 13'sd0)
                      + (f[1] ? d2 : 13'sd0)
                      + (f[2] ? d4 : 13'sd0)
                      + (f[3] ? d8 : 13'sd0);

// val = a + (P >>> 4); arithmetic shift matches Python's floor-toward-neg-inf.
// the interpolated result always lands in 0..255, so the low 8 bits are exact.
wire signed [13:0] sum = $signed({6'b0, a}) + (p >>> 4);
assign val = sum[7:0];


endmodule


`default_nettype wire
