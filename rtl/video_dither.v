// video_dither.v
// 8-bit -> 6-bit video dithering to hide banding when truncating a smooth
// gradient to the MiST board's 6-bit-per-channel VGA DAC. Extracted from the
// Minimig "amber" scandoubler (Copyright 2006-2013 Dennis van Weeren /
// Jakub Bednarski / Rok Krajnc, GPLv3).
//
// mode: 00=off (plain truncation), 01=temporal, 10=random, 11=both. Output is
// combinational (state is registered), so no pixel latency.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>  (dither algorithm: Minimig amber)


`default_nettype none


module video_dither (
  input  wire        clk,        // pixel clock
  input  wire        rst_n,      // async active-low reset (pixel domain)
  input  wire        vs,         // raw active-low vsync (frame reset on falling edge)
  input  wire        h_par,      // horizontal pixel parity (e.g. h_cnt[0])
  input  wire        v_par,      // vertical line parity (e.g. v_cnt[0])
  input  wire [1:0]  mode,       // 00=off, 01=temporal, 10=random, 11=both
  input  wire [7:0]  r_in,
  input  wire [7:0]  g_in,
  input  wire [7:0]  b_in,
  output wire [5:0]  r_out,
  output wire [5:0]  g_out,
  output wire [5:0]  b_out
);


// ---- frame strobe: falling edge of the active-low vsync (start of vsync) ----
reg vs_d;
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) vs_d <= 1'b1;
  else        vs_d <= vs;
end
wire frame = vs_d & ~vs;


// ---- frame parity (the temporal component): toggles once per frame ----
reg f_par;
always @(posedge clk or negedge rst_n) begin
  if (!rst_n)     f_par <= 1'b0;
  else if (frame) f_par <= ~f_par;
end

wire chk = f_par ^ v_par ^ h_par;


// ---- pseudo-random source: 24-bit LFSR + high-pass mix (amber) ----
reg  [23:0] seed, seed_old, randval;
wire [25:0] hpf_sum = {2'b00, randval} + {2'b00, seed} - {2'b00, seed_old};

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    seed     <= 24'h654321;
    seed_old <= 24'd0;
    randval  <= 24'd0;
  end else if (frame) begin
    seed     <= 24'h654321;
    seed_old <= 24'd0;
    randval  <= 24'd0;
  end else if (|mode) begin
    seed     <= {seed[22:0], ~(seed[23] ^ seed[22] ^ seed[21] ^ seed[16])};
    seed_old <= seed;
    randval  <= hpf_sum[25:2];
  end
end


// ---- carried error (residual low 2 bits) per channel ----
reg [7:0] r_err, g_err, b_err;


// ---- per-channel dither chain (combinational) ----
// stage 1: + previous error, near-white guard
wire [7:0] r_e = (&r_in[7:2]) ? r_in : r_in + {6'd0, r_err[1:0]};
wire [7:0] g_e = (&g_in[7:2]) ? g_in : g_in + {6'd0, g_err[1:0]};
wire [7:0] b_e = (&b_in[7:2]) ? b_in : b_in + {6'd0, b_err[1:0]};

// stage 2: temporal/spatial (+2 on the checkerboard), guard
wire [7:0] r_t = (&r_e[7:2]) ? r_e : r_e + {6'd0, (mode[0] & chk & r_e[1]), 1'b0};
wire [7:0] g_t = (&g_e[7:2]) ? g_e : g_e + {6'd0, (mode[0] & chk & g_e[1]), 1'b0};
wire [7:0] b_t = (&b_e[7:2]) ? b_e : b_e + {6'd0, (mode[0] & chk & b_e[1]), 1'b0};

// stage 3: random (+1 from the noise source), guard
wire [7:0] r_d = (&r_t[7:2]) ? r_t : r_t + {7'd0, mode[1] & randval[0]};
wire [7:0] g_d = (&g_t[7:2]) ? g_t : g_t + {7'd0, mode[1] & randval[0]};
wire [7:0] b_d = (&b_t[7:2]) ? b_t : b_t + {7'd0, mode[1] & randval[0]};

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    r_err <= 8'd0; g_err <= 8'd0; b_err <= 8'd0;
  end else if (frame) begin
    r_err <= 8'd0; g_err <= 8'd0; b_err <= 8'd0;
  end else if (|mode) begin
    r_err <= {6'd0, r_d[1:0]};
    g_err <= {6'd0, g_d[1:0]};
    b_err <= {6'd0, b_d[1:0]};
  end
end

assign r_out = r_d[7:2];
assign g_out = g_d[7:2];
assign b_out = b_d[7:2];


endmodule


`default_nettype wire
