// video_gen.v
// Minimal VGA background generator for the MiST OSD menu overlay.
//
// Wraps the ported vga_ctrl timing generator (default params are 640x480@60,
// H_WHOLE=800 / V_WHOLE=525) and paints a flat background colour in the active
// area, run at one pixel per clk on the VGA pixel clock (~25.175 MHz). Outputs
// feed osd.v; HBlank/VBlank are exposed only for completeness/debug.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module video_gen #(
  // flat background colour (6-bit per channel) shown in the active area
  parameter [5:0] BG_R = 6'd0,
  parameter [5:0] BG_G = 6'd4,
  parameter [5:0] BG_B = 6'd16
) (
  input  wire        clk_pix,    // VGA pixel clock (~25.175 MHz)
  input  wire        rst_n,      // async, active low (pixel-clock domain)

  output wire [5:0]  vga_r,
  output wire [5:0]  vga_g,
  output wire [5:0]  vga_b,
  output wire        vga_hs,
  output wire        vga_vs,
  output wire        vga_hblank,
  output wire        vga_vblank,

  // pixel-position taps (for an external pixel generator, e.g. the plasma
  // visualizer). h_cnt/v_cnt are the raw vga_ctrl counters; active is high in
  // the visible area. left unconnected when not needed.
  output wire [9:0]  vga_h_cnt,
  output wire [9:0]  vga_v_cnt,
  output wire        vga_active
);


wire active;
wire blank;
wire hs;
wire vs;
wire [9:0] h_cnt;
wire [9:0] v_cnt;

// 640x480@60 from vga_ctrl's default parameters (25.175 MHz dot clock).
// h_match/v_match unused -> tie to 0; counter/status taps left open.
vga_ctrl u_vga_ctrl (
  .clk       (clk_pix),
  .clk_en    (1'b1),
  .rst       (~rst_n),
  .en        (1'b1),
  .h_match   (10'd0),
  .v_match   (10'd0),
  .h_cnt     (h_cnt),
  .v_cnt     (v_cnt),
  .cnt_match (),
  .active    (active),
  .blank     (blank),
  .a_start   (),
  .a_end     (),
  .f_cnt     (),
  .h_sync    (hs),
  .v_sync    (vs)
);

// flat background in active area, black during blanking
assign vga_r = active ? BG_R : 6'd0;
assign vga_g = active ? BG_G : 6'd0;
assign vga_b = active ? BG_B : 6'd0;

assign vga_hs     = hs;
assign vga_vs     = vs;
assign vga_hblank = blank;
assign vga_vblank = blank;

assign vga_h_cnt  = h_cnt;
assign vga_v_cnt  = v_cnt;
assign vga_active = active;


endmodule


`default_nettype wire
