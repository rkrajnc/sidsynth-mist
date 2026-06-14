// plasma.sv
// SID-reactive plasma VGA background -- top of the plasma module. Holds the
// three per-voice phase accumulators (advanced once per frame on frame_adv),
// feeds the combinational plasma_pixel datapath, and registers the RGB output.
//
// frequency drives both flow speed and blob size; brightness comes from each
// voice's 4-bit envelope. No M9K, no DSP multiplier. See doc/sim_notes.md and
// the bit-accurate golden model in sw/plasma_model.py.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module plasma #(
  parameter CW = 8        // output colour width per channel (6 for MiST DAC)
) (
  input  wire             clk,        // pixel clock
  input  wire             rst_n,      // async, active low (pixel-clock domain)
  input  wire             frame_adv,  // 1-cycle pulse once per frame (vsync edge)

  input  wire [9:0]       x,          // current pixel X (from VGA timing)
  input  wire [9:0]       y,          // current pixel Y

  input  wire [15:0]      freq_v1,    // per-voice SID frequency registers
  input  wire [15:0]      freq_v2,
  input  wire [15:0]      freq_v3,
  input  wire [3:0]       vol_v1,     // per-voice 4-bit envelope/volume
  input  wire [3:0]       vol_v2,
  input  wire [3:0]       vol_v3,

  output wire [CW-1:0]    r,
  output wire [CW-1:0]    g,
  output wire [CW-1:0]    b
);


// ---- per-voice phase accumulators: t += (freq>>6)+1 once per frame ----
logic [15:0] t1, t2, t3;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    t1 <= 16'd0;
    t2 <= 16'd0;
    t3 <= 16'd0;
  end else if (frame_adv) begin
    t1 <= t1 + {6'b0, freq_v1[15:6]} + 16'd1;
    t2 <= t2 + {6'b0, freq_v2[15:6]} + 16'd1;
    t3 <= t3 + {6'b0, freq_v3[15:6]} + 16'd1;
  end
end


// ---- combinational pixel datapath ----
wire [7:0] pr, pg, pb;

plasma_pixel u_pix (
  .x     (x),
  .y     (y),
  .t1    (t1),
  .t2    (t2),
  .t3    (t3),
  .freq1 (freq_v1),
  .freq2 (freq_v2),
  .freq3 (freq_v3),
  .vol1  (vol_v1),
  .vol2  (vol_v2),
  .vol3  (vol_v3),
  .r     (pr),
  .g     (pg),
  .b     (pb)
);


// ---- registered outputs (top CW bits feed the DAC) ----
logic [CW-1:0] r_r, g_r, b_r;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    r_r <= {CW{1'b0}};
    g_r <= {CW{1'b0}};
    b_r <= {CW{1'b0}};
  end else begin
    r_r <= pr[7 -: CW];
    g_r <= pg[7 -: CW];
    b_r <= pb[7 -: CW];
  end
end

assign r = r_r;
assign g = g_r;
assign b = b_r;


endmodule


`default_nettype wire
