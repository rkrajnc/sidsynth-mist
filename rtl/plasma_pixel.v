// plasma_pixel.v
// Combinational full-pixel plasma: derives the per-voice animation phase and
// the frequency-driven size shift, then renders the three colour channels.
// This is the direct RTL analogue of plasma_model.plasma_pixel and is the unit
// CocoTB compares against the golden model.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module plasma_pixel (
  input  wire [9:0]  x,
  input  wire [9:0]  y,
  input  wire [15:0] t1,    // per-voice phase accumulators
  input  wire [15:0] t2,
  input  wire [15:0] t3,
  input  wire [15:0] freq1, // per-voice SID frequency registers
  input  wire [15:0] freq2,
  input  wire [15:0] freq3,
  input  wire [3:0]  vol1,  // per-voice 4-bit envelope/volume
  input  wire [3:0]  vol2,
  input  wire [3:0]  vol3,
  output wire [7:0]  r,
  output wire [7:0]  g,
  output wire [7:0]  b
);


// 2-bit size bucket from frequency thresholds (4096 / 8192 / 16384). higher
// note -> bigger bucket -> smaller shift -> finer/smaller blobs. matches
// plasma_model.size_shift (returns 3 - bucket).
function [1:0] size_shift;
  input [15:0] f;
  begin
    if      (f >= 16'd16384) size_shift = 2'd0;   // bucket 3 (high)
    else if (f >= 16'd8192)  size_shift = 2'd1;   // bucket 2
    else if (f >= 16'd4096)  size_shift = 2'd2;   // bucket 1
    else                     size_shift = 2'd3;   // bucket 0 (low)
  end
endfunction


// animation phase = t[13:6]
wire [7:0] p1 = t1[13:6];
wire [7:0] p2 = t2[13:6];
wire [7:0] p3 = t3[13:6];

plasma_channel u_r (
  .x(x), .y(y), .phase(p1), .shift(size_shift(freq1)), .vol(vol1), .color(r));
plasma_channel u_g (
  .x(x), .y(y), .phase(p2), .shift(size_shift(freq2)), .vol(vol2), .color(g));
plasma_channel u_b (
  .x(x), .y(y), .phase(p3), .shift(size_shift(freq3)), .vol(vol3), .color(b));


endmodule


`default_nettype wire
