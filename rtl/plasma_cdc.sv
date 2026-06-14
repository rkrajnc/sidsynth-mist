// plasma_cdc.sv
// Integration wrapper around the single-clock `plasma` core: owns everything
// between the raw sys_clk SID taps and the pixel-clock core (vsync edge-detect,
// per-frame snapshot + req/ack CDC, per-frame EMA, env->vol map + floor).
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module plasma_cdc #(
  parameter CW        = 8,    // output colour width per channel (6 for MiST DAC)
  parameter EMA_F     = 6,    // EMA guard/fractional bits (see plasma_ema)
  parameter K_FREQ    = 4,    // freq EMA smoothing shift (flow-speed/size glide)
  parameter K_ENV     = 3,    // env EMA smoothing shift (breathing brightness)
  parameter [3:0] VOL_FLOOR = 4'd2   // brightness floor (idle never goes black)
) (
  // ---- SID (sys_clk) domain: raw, live taps ----
  input  wire             clk_sys,
  input  wire             sys_rst_n,
  input  wire [15:0]      freq_v1,    // per-voice SID frequency registers
  input  wire [15:0]      freq_v2,
  input  wire [15:0]      freq_v3,
  input  wire [7:0]       env_v1,     // per-voice 8-bit SID envelope
  input  wire [7:0]       env_v2,
  input  wire [7:0]       env_v3,

  // ---- pixel (clk_pix) domain ----
  input  wire             clk_pix,
  input  wire             pix_rst_n,
  input  wire             vid_vs,     // raw active-low vsync; frame_adv derived
  input  wire [9:0]       x,          // current pixel X (from VGA timing)
  input  wire [9:0]       y,          // current pixel Y

  output wire [CW-1:0]    r,
  output wire [CW-1:0]    g,
  output wire [CW-1:0]    b
);


// ---- frame strobe: falling edge of active-low vid_vs -> one clk_pix pulse
//      per frame (start of vsync, in vblank after the active region) ----
logic vid_vs_d;

always_ff @(posedge clk_pix or negedge pix_rst_n) begin
  if (!pix_rst_n) vid_vs_d <= 1'b1;   // idle high -> no spurious edge at reset
  else            vid_vs_d <= vid_vs;
end

wire frame_adv = vid_vs_d & ~vid_vs;


// ---- pixel domain: request toggles once per frame ----
logic req_tgl;

always_ff @(posedge clk_pix or negedge pix_rst_n) begin
  if (!pix_rst_n)        req_tgl <= 1'b0;
  else if (frame_adv)    req_tgl <= ~req_tgl;
end


// ---- sys_clk domain: sync request, latch the bundle, toggle acknowledge ----
logic req_meta, req_sync, req_sync_d;

always_ff @(posedge clk_sys or negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    req_meta   <= 1'b0;
    req_sync   <= 1'b0;
    req_sync_d <= 1'b0;
  end else begin
    req_meta   <= req_tgl;
    req_sync   <= req_meta;
    req_sync_d <= req_sync;
  end
end

wire cap = req_sync ^ req_sync_d;   // edge on the synced request

logic [15:0] f1_h, f2_h, f3_h;      // coherently-latched bundle (sys_clk)
logic [7:0]  e1_h, e2_h, e3_h;
logic        ack_tgl;

always_ff @(posedge clk_sys or negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    f1_h    <= 16'd0; f2_h <= 16'd0; f3_h <= 16'd0;
    e1_h    <=  8'd0; e2_h <=  8'd0; e3_h <=  8'd0;
    ack_tgl <= 1'b0;
  end else if (cap) begin
    f1_h    <= freq_v1; f2_h <= freq_v2; f3_h <= freq_v3;
    e1_h    <= env_v1;  e2_h <= env_v2;  e3_h <= env_v3;
    ack_tgl <= ~ack_tgl;
  end
end


// ---- pixel domain: sync acknowledge, load the snapshot on its edge ----
logic ack_meta, ack_sync, ack_sync_d;

always_ff @(posedge clk_pix or negedge pix_rst_n) begin
  if (!pix_rst_n) begin
    ack_meta   <= 1'b0;
    ack_sync   <= 1'b0;
    ack_sync_d <= 1'b0;
  end else begin
    ack_meta   <= ack_tgl;
    ack_sync   <= ack_meta;
    ack_sync_d <= ack_sync;
  end
end

wire snap_load = ack_sync ^ ack_sync_d;   // handshake complete -> bundle stable


// ---- per-frame EMA low-pass on the crossed bundle (updates on snap_load).
//      freq smoothed as 16-bit; env as full 8-bit (mapped to 4-bit vol below). ----
wire [15:0] f1_s, f2_s, f3_s;       // smoothed per-frame freq feeding the core
wire [7:0]  e1_s, e2_s, e3_s;       // smoothed per-frame env (pre vol map)

plasma_ema #(.DW(16), .F(EMA_F), .K(K_FREQ)) u_ema_f1 (
  .clk(clk_pix), .rst_n(pix_rst_n), .en(snap_load), .x(f1_h), .y(f1_s));
plasma_ema #(.DW(16), .F(EMA_F), .K(K_FREQ)) u_ema_f2 (
  .clk(clk_pix), .rst_n(pix_rst_n), .en(snap_load), .x(f2_h), .y(f2_s));
plasma_ema #(.DW(16), .F(EMA_F), .K(K_FREQ)) u_ema_f3 (
  .clk(clk_pix), .rst_n(pix_rst_n), .en(snap_load), .x(f3_h), .y(f3_s));

plasma_ema #(.DW(8), .F(EMA_F), .K(K_ENV)) u_ema_e1 (
  .clk(clk_pix), .rst_n(pix_rst_n), .en(snap_load), .x(e1_h), .y(e1_s));
plasma_ema #(.DW(8), .F(EMA_F), .K(K_ENV)) u_ema_e2 (
  .clk(clk_pix), .rst_n(pix_rst_n), .en(snap_load), .x(e2_h), .y(e2_s));
plasma_ema #(.DW(8), .F(EMA_F), .K(K_ENV)) u_ema_e3 (
  .clk(clk_pix), .rst_n(pix_rst_n), .en(snap_load), .x(e3_h), .y(e3_s));


// ---- env[7:4] -> 4-bit vol, clamped to the brightness floor (combinational) ----
wire [3:0] v1_s = (e1_s[7:4] < VOL_FLOOR) ? VOL_FLOOR : e1_s[7:4];
wire [3:0] v2_s = (e2_s[7:4] < VOL_FLOOR) ? VOL_FLOOR : e2_s[7:4];
wire [3:0] v3_s = (e3_s[7:4] < VOL_FLOOR) ? VOL_FLOOR : e3_s[7:4];


// ---- the unchanged single-clock plasma core, fed from the conditioned values ----
plasma #(.CW(CW)) u_plasma (
  .clk       (clk_pix),
  .rst_n     (pix_rst_n),
  .frame_adv (frame_adv),
  .x         (x),
  .y         (y),
  .freq_v1   (f1_s),
  .freq_v2   (f2_s),
  .freq_v3   (f3_s),
  .vol_v1    (v1_s),
  .vol_v2    (v2_s),
  .vol_v3    (v3_s),
  .r         (r),
  .g         (g),
  .b         (b)
);


endmodule


`default_nettype wire
