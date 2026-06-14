// plasma_channel.v
// One plasma colour channel (combinational): sums two opposite-drifting sine
// waves over the downscaled pixel coordinate, applies a mild 1.5x contrast, and
// scales brightness by the 4-bit envelope. Bit-exact with the per-channel math
// in plasma_model.plasma_pixel.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module plasma_channel (
  input  wire [9:0] x,
  input  wire [9:0] y,
  input  wire [7:0] phase,   // animation phase (t[13:6])
  input  wire [1:0] shift,   // spatial size shift 0..3 (bigger -> bigger blobs)
  input  wire [3:0] vol,     // 4-bit envelope/volume (brightness)
  output wire [7:0] color
);


// variable spatial downscale (0..3). low note -> bigger shift -> bigger blobs.
wire [9:0] xs = x >> shift;
wire [9:0] ys = y >> shift;

// two travelling-wave sine indices, 8-bit (wrap mod 256). opposite phase signs
// make the channel shear in 2D, so it flows (not a static pattern).
wire [7:0] idx_a = xs[7:0] + phase;     // (xs + phase) mod 256
wire [7:0] idx_b = ys[7:0] - phase;     // (ys - phase) mod 256

wire [7:0] wa, wb;
plasma_sine u_sa (.idx(idx_a), .val(wa));
plasma_sine u_sb (.idx(idx_b), .val(wb));

// average the two waves -> 0..255
wire [7:0] field = ({1'b0, wa} + {1'b0, wb}) >> 1;

// contrast_mid: 128 + d + (d>>1), d = field-128, clamped to 0..255.
// d>>1 is an arithmetic shift (matches Python floor for negative d).
wire signed [9:0] d  = $signed({2'b0, field}) - 10'sd128;   // -128..127
wire signed [9:0] dh = d >>> 1;                             // -64..63
wire signed [10:0] cm = 11'sd128 + {d[9], d} + {dh[9], dh}; // -64..318
wire neg = cm[10];
wire ovf = ~cm[10] & (cm[9] | cm[8]);                       // > 255
wire [7:0] fc = neg ? 8'd0 : (ovf ? 8'd255 : cm[7:0]);

// brightness = (fc * vol) >> 4 as a 4-term shift-add tree (vol is 4 bits),
// unsigned. LINEAR (not the exponential `>> (15-vol)`) -- see plasma_model.
wire [11:0] pr = (vol[0] ? {4'b0, fc}       : 12'd0)
               + (vol[1] ? {3'b0, fc, 1'b0} : 12'd0)
               + (vol[2] ? {2'b0, fc, 2'b0} : 12'd0)
               + (vol[3] ? {1'b0, fc, 3'b0} : 12'd0);
assign color = pr[11:4];


endmodule


`default_nettype wire
