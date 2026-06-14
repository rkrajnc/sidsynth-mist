// sdm.sv
// 2nd order direct-form sigma-delta modulator / PDM DAC with TPDF dithering
// 2026, Rok Krajnc <rok.krajnc@gmail.com>

// Topology (double integrator with 1-bit quantizer):
//   u1[n] = u1[n-1] + x_d[n]  - y[n-1]
//   u2[n] = u2[n-1] + u1[n]   - y[n-1]
//   y[n]  = 1 if u2[n] >= 0, else 0     (PDM output)
//
//   where x_d[n] = x[n] + d[n]  (input with TPDF dither applied)
//
//   NTF(z) = (1 - z^-1)^2  ->  2nd order highpass noise shaping
//   STF(z) = 1
//
// TPDF dithering: d[n] = a[n] - b[n], a/b from two independent
// maximal-length Fibonacci LFSRs (16-bit and 15-bit, seeds are
// parameters); triangular PDF, zero-mean, NW-LSB wide.
//
// Feedback scaling: +/-(2^(DW-1)) for y=1/0. Integrator width
// IW = DW+4 provides sufficient guard bits.


`default_nettype none


module sdm #(
  parameter int unsigned DW          = 24,        // input data width (bits)
  parameter int unsigned IW          = 28,        // integrator width (bits, IW >= DW+4)
  parameter int unsigned NW          = 4,         // dither bits
  parameter logic [15:0] LFSR_A_SEED = 16'hACE1,  // seed for LFSR A (must be non-zero)
  parameter logic [14:0] LFSR_B_SEED = 15'h5A3B   // seed for LFSR B (must be non-zero)
) (
  input  wire logic          clk,      // input clock
  input  wire logic          clk_en,   // input PDM-rate clock enable (12MHz)
  input  wire logic          rst_n,    // input async reset, active low
  input  wire logic          in_vld,   // audio-rate sample strobe
  input  wire logic [DW-1:0] in_dat,   // signed DW-bit input (2's complement)
  output wire logic          pdm_out   // 1-bit PDM output
);

//// tpdf dither ////
// Two independent Fibonacci LFSRs:
//   LFSR A: 16-bit, x^16 + x^15 + x^13 + x^4 + 1 (taps 15,14,12,3)
//   LFSR B: 15-bit, x^15 + x^14 + 1              (taps 14,13)

logic [15:0] lfsr_a;
logic [14:0] lfsr_b;
logic        fb_a;
logic        fb_b;

assign fb_a = lfsr_a[15] ^ lfsr_a[14] ^ lfsr_a[12] ^ lfsr_a[3];
assign fb_b = lfsr_b[14] ^ lfsr_b[13];

always_ff @(posedge clk) begin
  if (!rst_n) begin
    lfsr_a <= LFSR_A_SEED;
    lfsr_b <= LFSR_B_SEED;
  end else if (clk_en) begin
    lfsr_a <= {lfsr_a[14:0], fb_a};
    lfsr_b <= {lfsr_b[13:0], fb_b};
  end
end

// TPDF dither in IW-bit signed arithmetic:
//   d = a - b,  a = lfsr_a[15] (current MSB),  b = lfsr_b[14]
//   d in {-1, 0, +1} integer LSBs
logic signed [IW-1:0] dither;

assign dither = {{(IW-NW){1'b0}}, lfsr_a[15:15-NW+1]} - {{(IW-NW){1'b0}}, lfsr_b[14:14-NW+1]};


//// sdm core ////
// internal register for registered output port
logic pdm_out_r;

// integrator states (signed)
logic signed [IW-1:0] u1;
logic signed [IW-1:0] u2;
// registered input sample, sign-extended to IW bits; held for OSR cycles
logic signed [IW-1:0] x_reg;
// dithered input: x_reg + TPDF dither
logic signed [IW-1:0] x_dith;
// combinational next-state signals
logic signed [IW-1:0] u1_next;
logic signed [IW-1:0] u2_next;
// feedback value: +(2^(DW-1)) for pdm_out=1, -(2^(DW-1)) for pdm_out=0,
// built by bit concatenation for unambiguous 2's complement encoding.
logic signed [IW-1:0] y_fb;

always_comb begin
  y_fb   = pdm_out
           ? {{(IW-DW){1'b0}}, 1'b1, {(DW-1){1'b0}}}   // +(2^(DW-1))
           : {{(IW-DW){1'b1}}, 1'b1, {(DW-1){1'b0}}};  // -(2^(DW-1))
  x_dith  = x_reg + dither;
  u1_next = u1 + x_dith  - y_fb;
  u2_next = u2 + u1_next - y_fb;
end

always_ff @(posedge clk) begin
  if (!rst_n) begin
    x_reg     <= '0;
    u1        <= '0;
    u2        <= '0;
    pdm_out_r <= 1'b0;
  end else if (clk_en) begin
    if (in_vld) begin
      x_reg <= {{(IW-DW){in_dat[DW-1]}}, in_dat};  // sign-extend to IW bits
    end
    u1        <= u1_next;
    u2        <= u2_next;
    pdm_out_r <= ~u2_next[IW-1];  // 1 if u2_next >= 0 (MSB=0 means non-negative)
  end
end

assign pdm_out = pdm_out_r;


endmodule : sdm


`default_nettype wire
