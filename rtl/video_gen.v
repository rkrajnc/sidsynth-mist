// video_gen.v
// Minimal VGA background generator for the MiST OSD menu overlay.
//
// SIDsynth has no real video content -- it only needs a clean, stable
// progressive video signal for the MiST OSD (osd.v) to overlay the firmware
// menu onto. This wraps the ported vga_ctrl timing generator (default params
// are exactly 640x480@60, H_WHOLE=800 / V_WHOLE=525) and paints a flat
// background colour in the active area. Run it at one pixel per clk on the
// dedicated VGA pixel clock (clk_pix ~= 25.175 MHz).
//
// Outputs feed osd.v: R/G/B + HSync/VSync. osd.v is instantiated with
// USE_BLANKS=0, so it derives blanking from the sync edges and HBlank/VBlank
// are not needed downstream (exposed here only for completeness/debug).
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
  output wire        vga_vblank
);


wire active;
wire blank;
wire hs;
wire vs;

// 640x480@60 from vga_ctrl's default parameters (25.175 MHz dot clock).
// h_match/v_match unused -> tie to 0; counter/status taps left open.
vga_ctrl u_vga_ctrl (
  .clk       (clk_pix),
  .clk_en    (1'b1),
  .rst       (~rst_n),
  .en        (1'b1),
  .h_match   (10'd0),
  .v_match   (10'd0),
  .h_cnt     (),
  .v_cnt     (),
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


endmodule


`default_nettype wire
