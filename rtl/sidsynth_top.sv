// sidsynth_top.v
// top-level file for the SIDsynth
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module sidsynth_top (
  // clock
  input  wire [ 2-1:0] CLOCK_32,    // 32 MHz
  input  wire [ 2-1:0] CLOCK_27,    // 27 MHz
  input  wire [ 2-1:0] CLOCK_50,    // 50 MHz
  // LED outputs
  output wire          LED,         // LED Yellow
  // UART
  output wire          UART_TX,     // UART Transmitter
  input  wire          UART_RX,     // UART Receiver (MIDI IN via opto-isolator)
  // VGA
  output wire          VGA_HS,      // VGA H_SYNC
  output wire          VGA_VS,      // VGA V_SYNC
  output wire [ 6-1:0] VGA_R,       // VGA Red[5:0]
  output wire [ 6-1:0] VGA_G,       // VGA Green[5:0]
  output wire [ 6-1:0] VGA_B,       // VGA Blue[5:0]
  // SDRAM
  inout  wire [16-1:0] SDRAM_DQ,    // SDRAM Data bus 16 Bits
  output wire [13-1:0] SDRAM_A,     // SDRAM Address bus 13 Bits
  output wire          SDRAM_DQML,  // SDRAM Low-byte Data Mask
  output wire          SDRAM_DQMH,  // SDRAM High-byte Data Mask
  output wire          SDRAM_nWE,   // SDRAM Write Enable
  output wire          SDRAM_nCAS,  // SDRAM Column Address Strobe
  output wire          SDRAM_nRAS,  // SDRAM Row Address Strobe
  output wire          SDRAM_nCS,   // SDRAM Chip Select
  output wire [ 2-1:0] SDRAM_BA,    // SDRAM Bank Address
  output wire          SDRAM_CLK,   // SDRAM Clock
  output wire          SDRAM_CKE,   // SDRAM Clock Enable
  // MINIMIG specific
  output wire          AUDIO_L,     // sigma-delta DAC output left
  output wire          AUDIO_R,     // sigma-delta DAC output right
  // SPI
  inout  wire          SPI_DO,      // inout
  input  wire          SPI_DI,
  input  wire          SPI_SCK,
  input  wire          SPI_SS2,     // fpga
  input  wire          SPI_SS3,     // OSD
  input  wire          SPI_SS4,     // "sniff" mode
  input  wire          CONF_DATA0   // SPI_SS for user_io
);


//// unused IO ////
// SDRAM still unused (full-song buffering via SDRAM is a future step; the
// SD path streams through a small on-chip FIFO instead). VGA + SPI are now
// driven for the OSD menu / SD-file loader below.
assign UART_TX    = 1'b1;            // MIDI/UART idle high
assign SDRAM_DQ   = 16'bzzzzzzzzzzzzzzzz;
assign SDRAM_A    = 13'd0;
assign SDRAM_DQML = 1'b0;
assign SDRAM_DQMH = 1'b0;
assign SDRAM_nWE  = 1'b1;
assign SDRAM_nCAS = 1'b1;
assign SDRAM_nRAS = 1'b1;
assign SDRAM_nCS  = 1'b1;            // disable SDRAM
assign SDRAM_BA   = 2'b0;
assign SDRAM_CLK  = 1'b0;
assign SDRAM_CKE  = 1'b0;


//// clock & reset ////

// clock
// PLL: 27 MHz -> 54 MHz sys clk (M=12, N=1, C0=6; VCO=324 MHz)
// 54 MHz = 54x the SID ce_1m (1.000 MHz exactly, no drift)
wire sys_clk;
wire pll_locked;

pll pll_inst (
  .areset (1'b0),
  .inclk0 (CLOCK_27[0]),
  .c0     (sys_clk),
  .locked (pll_locked)
);

// reset
reg  [3-1:0] rst_sync;
wire         sys_rst_n;

// OSD "Restart" (status[1]) requests a full reset of the whole sys_clk domain
// -- a panic/recovery to the initial state (clears stuck notes, both SIDs,
// filters, DC/SDM, the reader/player FSMs). user_io is NOT in this reset (it
// free-runs on the SPI link), so the ARM link + OSD survive; playback does NOT
// auto-resume -- the reader returns to idle and the user re-selects a file.
// restart_req is synced off pll_locked, not sys_rst_n, since it DRIVES the
// reset and must not be cleared by it. Driven in the "OSD playback control"
// section once uio_status exists.
wire         restart_req;

always @(posedge sys_clk or negedge pll_locked) begin
  if (!pll_locked)      rst_sync <= 3'd0;
  else if (restart_req) rst_sync <= 3'd0;            // OSD Restart: re-run reset
  else                  rst_sync <= {rst_sync[1:0], 1'b1};
end

assign sys_rst_n = rst_sync[2];


//// VGA pixel clock (separate PLL: 27 MHz -> 25.2 MHz) ////
// Dedicated dot clock for the OSD menu video. 25.2 MHz with the 640x480
// (800x525 total) timing in video_gen is a proper 60 Hz VGA mode. Kept
// independent of the 54 MHz system PLL so the audio clocking is untouched.
wire clk_pix;
wire pix_locked;

pll_pix pll_pix_inst (
  .areset (1'b0),
  .inclk0 (CLOCK_27[0]),
  .c0     (clk_pix),
  .locked (pix_locked)
);

// pixel-domain reset (sync release off pix_locked)
reg  [3-1:0] pix_rst_sync;
wire         pix_rst_n;

always @(posedge clk_pix or negedge pix_locked) begin
  if (!pix_locked) pix_rst_sync <= 3'd0;
  else             pix_rst_sync <= {pix_rst_sync[1:0], 1'b1};
end

assign pix_rst_n = pix_rst_sync[2];


//// MiST user_io: ARM SPI link (config string, OSD menu, SD file mount) ////
// The stock MiST firmware reads CONF_STR to build the OSD menu and file
// browser. Core name "SIDSYNTH" makes the firmware change into a /SIDSYNTH
// directory on the SD card, so tunes are loaded from there. The 'S' entry
// mounts the picked file as a block device; sidraw_sd_reader then streams
// 512-byte sectors on demand. 'T2,Toggle playing' and 'T1,Restart' are
// momentary toggles: the firmware pulses status[2]/status[1] high-then-low,
// and the FPGA acts on them (see "OSD playback control" + "reset" below):
// T2 flips the internal play/stop state; T1 triggers a full reset of the
// sys_clk domain (everything but user_io) -- a panic/recovery to the initial
// state, NOT a replay (playback stays stopped until the user re-selects a
// file). Using a momentary toggle (not a level 'O' option) lets the FPGA "do
// the right thing" regardless of the firmware bit's absolute value.
//
// 'O3,SID model' is a persistent setting (not an action), so a level 'O'
// option is the right tool: the firmware owns status[3] and the menu shows
// the current value. status[3]=0 -> 6581 (default), 1 -> 8580; it drives the
// `mode` input of BOTH SID cores (global select).
//
// CONF_STR byte format follows menu-8bit.c parsing. The file-extension field
// ('SID') and the exact mount-entry syntax should be confirmed on hardware
// during bring-up (see modules/top/CLAUDE.md).
localparam CONF_STR = "SIDSYNTH;;S0,SID,Load tune;T2,Toggle playing;O3,SID model,6581,8580;T1,Restart;V,SIDSYNTH v_0_3";

wire [63:0] uio_status;
wire        uio_sdo;          // user_io SPI MISO

// SD block interface between user_io and sidraw_sd_reader
wire [31:0] sd_lba;
wire        sd_rd;
wire        sd_ack;
wire [ 7:0] sd_dout;
wire        sd_dout_strobe;
wire        img_mounted;
wire [63:0] img_size;

user_io #(
  .STRLEN    ($bits(CONF_STR)/8),
  .SD_IMAGES (1)
) u_user_io (
  .conf_str       (CONF_STR),
  .conf_addr      (),
  .conf_chr       (8'h00),
  .clk_sys        (sys_clk),
  .clk_sd         (sys_clk),
  .SPI_CLK        (SPI_SCK),
  .SPI_SS_IO      (CONF_DATA0),
  .SPI_MISO       (uio_sdo),
  .SPI_MOSI       (SPI_DI),
  .status         (uio_status),
  .buttons        (),
  .sd_lba         (sd_lba),
  .sd_rd          (sd_rd),
  .sd_wr          (1'b0),
  .sd_ack         (sd_ack),
  .sd_conf        (1'b0),
  .sd_sdhc        (1'b1),
  .sd_dout        (sd_dout),
  .sd_dout_strobe (sd_dout_strobe),
  .sd_din         (8'h00),
  .sd_din_strobe  (),
  .sd_buff_addr   (),
  .img_mounted    (img_mounted),
  .img_size       (img_size)
);

//// OSD playback control: "Toggle playing" + "Restart" ////
// 'T' menu entries are momentary: the firmware pulses the status bit high
// then immediately low (menu-8bit.c). status is set in the SPI domain, so
//   status[2] = "Toggle playing" -> flip internal play/stop state
//   status[1] = "Restart"        -> full core reset (driven via restart_req)
//
// Sync "Toggle playing" into sys_clk + rising-edge detect.
reg [1:0] toggle_sync;
reg       toggle_d;

always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    toggle_sync <= 2'b0;
    toggle_d    <= 1'b0;
  end else begin
    toggle_sync <= {toggle_sync[0], uio_status[2]};
    toggle_d    <= toggle_sync[1];
  end
end

wire toggle_pulse = toggle_sync[1] & ~toggle_d;      // rising edge: Toggle playing

// "Restart" (status[1]) -> full core reset (see reset section). Synced off
// pll_locked, NOT sys_rst_n, so the core reset it drives can't reset the
// synchroniser mid-pulse. Level-held for the firmware's toggle-pulse width,
// then released through rst_sync.
reg [2:0] restart_sync_r;
always @(posedge sys_clk or negedge pll_locked) begin
  if (!pll_locked) restart_sync_r <= 3'd0;
  else             restart_sync_r <= {restart_sync_r[1:0], uio_status[1]};
end
assign restart_req = restart_sync_r[2];

// play/stop state for the .sidraw branch. A new load (img_mounted) auto-plays;
// "Toggle playing" flips it. sidraw_stop gates sector fetches (reader .stop),
// freezes the player tick, and mutes the player audio branch (see uses below).
reg playing;
always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n)        playing <= 1'b1;   // default: play once a tune loads
  else if (img_mounted)  playing <= 1'b1;   // new .sidraw load: auto-play
  else if (toggle_pulse) playing <= ~playing;
end

wire sidraw_stop = ~playing;

// Playback-SID reset pulse. Asserted on every new .sidraw load (img_mounted)
// so a freshly loaded tune begins from clean SID register state -- clears stuck
// notes and any residual registers the previous tune left behind -- WITHOUT
// disturbing the MIDI chain (a full reset would). Stretched a few cycles so
// sid_top fully clears. (OSD "Restart" is the heavier hammer: a full core reset
// via restart_req, which already resets this SID, so it isn't wired here.)
reg [3:0] sidp_rst_cnt;
reg       sidp_reset;
always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    sidp_rst_cnt <= 4'd0;
    sidp_reset   <= 1'b1;
  end else if (img_mounted) begin
    sidp_rst_cnt <= 4'hf;
    sidp_reset   <= 1'b1;
  end else if (sidp_rst_cnt != 4'd0) begin
    sidp_rst_cnt <= sidp_rst_cnt - 4'd1;
    sidp_reset   <= 1'b1;
  end else begin
    sidp_reset   <= 1'b0;
  end
end

// SPI readback: drive SPI_DO from user_io only when CONF_DATA0 selects it;
// no other SPI slave on this core drives MISO (osd is input-only).
assign SPI_DO = CONF_DATA0 ? 1'bz : uio_sdo;

// OSD "SID model" select (status[3]): 0 = 6581 (default), 1 = 8580. Drives the
// `mode` input of both SID cores globally. mode is a combinational select
// inside sid_top (filter curve / waveform mixing), safe to change live.
wire sid_model_8580 = uio_status[3];


//// LED blinky ////
// one toggle per second at 54 MHz sys_clk (54 M cycles).
localparam BLINK_RELOAD = 54000000;
localparam CW           = $clog2(BLINK_RELOAD);

reg  [CW-1:0] blinky_cnt;
reg           blinky_r;

always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    blinky_cnt <= BLINK_RELOAD;
    blinky_r   <= 1'b0;
  end else begin
    if (~|blinky_cnt) begin
      blinky_cnt <= BLINK_RELOAD;
      blinky_r   <= !blinky_r;
    end else begin
      blinky_cnt <= blinky_cnt - 'd1;
    end
  end
end

// LED is driven in the "SD diagnostic instrumentation" section below
// (heartbeat while idle, solid once the player emits a SID write). When
// DEBUG_SD=0 it falls back to the plain heartbeat.


//// ce_1m strobe (54-cycle divider from sys_clk -> 1.000 MHz) ////
reg [6-1:0] ce_cnt;
reg         ce_1m;

always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    ce_cnt <= 6'd0;
    ce_1m  <= 1'b0;
  end else begin
    if (ce_cnt == 6'd53) begin
      ce_cnt <= 6'd0;
      ce_1m  <= 1'b1;
    end else begin
      ce_cnt <= ce_cnt + 6'd1;
      ce_1m  <= 1'b0;
    end
  end
end


//// ce_9m strobe (6-cycle divider from sys_clk -> 9.000 MHz) ////
// Drives the SDM PDM rate. Kept << sys_clk so the MiST board's audio
// IO + passive 1-pole RC can settle to full swing -- on this hardware,
// toggling at the full 54 MHz produces reduced-amplitude analog-ish
// output that costs dynamic range and radiates more RF.
reg [3-1:0] ce9_cnt;
reg         ce_9m;

always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    ce9_cnt <= 3'd0;
    ce_9m   <= 1'b0;
  end else begin
    if (ce9_cnt == 3'd5) begin
      ce9_cnt <= 3'd0;
      ce_9m   <= 1'b1;
    end else begin
      ce9_cnt <= ce9_cnt + 3'd1;
      ce_9m   <= 1'b0;
    end
  end
end


//// clock-enable ////
// single project-wide clk_en net. Tied high in M1b-midi (no clock
// gating yet); routed through every module so we can swap in a gating
// source later without touching the instantiations.
wire sys_clk_en = 1'b1;


//// MIDI front-end: UART_RX -> uart_simple -> midi_parser -> ch_msg_router ////

// uart_simple -> midi_parser
wire [7:0] uart_rx_dat;
wire       uart_rx_vld;

uart_simple #(
  .CLOCK_FREQ   (54_000_000),
  .BAUDRATE     (31250),
  .OVERSAMPLING (16),
  .SAMPLEPOINT  ('b01000)
) u_uart (
  .clk    (sys_clk),
  .clk_en (sys_clk_en),
  .rst_n  (sys_rst_n),
  .tx_vld (1'b0),                 // we never TX MIDI
  .tx_rdy (),
  .tx_dat (8'h00),
  .rx_vld (uart_rx_vld),
  .rx_rdy (1'b1),                 // always consume RX bytes
  .rx_mis (),                     // ignore missed-byte flag for v1
  .rx_dat (uart_rx_dat),
  .txd    (),                     // UART_TX driven separately (idle high)
  .rxd    (UART_RX)
);

// midi_parser: typed channel-message bus (21 bits = midi_ch_msg_t) +
// 58-bit sys-message bus (unused in M1b-midi).
wire [20:0] mp_ch_msg;
wire        mp_ch_vld;
wire        mp_ch_rdy;
wire [57:0] mp_sys_msg;           // unconnected downstream
wire        mp_sys_vld;
// realtime pulses are exposed but unused in M1b-midi

midi_parser u_midi_parser (
  .clk             (sys_clk),
  .clk_en          (sys_clk_en),
  .rst_n           (sys_rst_n),
  .rx_dat          (uart_rx_dat),
  .rx_vld          (uart_rx_vld),
  .ch_msg          (mp_ch_msg),
  .ch_vld          (mp_ch_vld),
  .ch_rdy          (mp_ch_rdy),
  .sys_msg         (mp_sys_msg),
  .sys_vld         (mp_sys_vld),
  .sys_rdy         (1'b1),         // always-ready sink (sys msgs are dropped)
  .rt_clock_tick   (),
  .rt_start        (),
  .rt_continue     (),
  .rt_stop         (),
  .rt_active_sense (),
  .rt_reset        ()
);

// ch_msg_router: routes voice-relevant messages to voice_ctrl, others to
// cc_ctrl (M5; tied off here).
wire [20:0] vc_msg;
wire        vc_vld;
wire [20:0] cc_msg;                // unconnected (no cc_ctrl in M1b-midi)
wire        cc_vld;

ch_msg_router u_ch_msg_router (
  .ch_msg       (mp_ch_msg),
  .ch_vld       (mp_ch_vld),
  .ch_rdy       (mp_ch_rdy),
  .ctrl_en      (1'b1),
  .ctrl_channel (4'd0),            // MIDI channel 1 (0-indexed)
  .vc_msg       (vc_msg),
  .vc_vld       (vc_vld),
  .cc_msg       (cc_msg),
  .cc_vld       (cc_vld)
);


//// voice allocator ////
// voice_ctrl is hardcoded for NV=16 by its internal age tree (3 stages,
// each halving NV; needs NV>=16). M1b-midi runs in CPU-driven mono mode
// (ctrl_mono=1), which constrains allocation to voice slot 0 with
// last-note priority -- exactly what a single-SID monophonic test needs.
// At M4 (NV=4 sound) we'll either fix voice_ctrl to support smaller NV
// or stay at NV=16 + a voice-mux squashing 4 slots into the chip array.
localparam int VC_NV = 16;

wire [VC_NV-1:0]            vc_voice_gate;
wire [VC_NV-1:0][7-1:0]     vc_voice_note;
wire [VC_NV-1:0][7-1:0]     vc_voice_velocity;
wire [VC_NV-1:0][7-1:0]     vc_voice_aftertouch;
wire [14-1:0]               vc_voice_pitch_bend;
wire [VC_NV-1:0]            vc_voice_release_done;

voice_ctrl #(
  .NV   (VC_NV),
  .AGEW (16),
  .NSD  (16)
) u_voice_ctrl (
  .clk                 (sys_clk),
  .clk_en              (sys_clk_en),
  .rst_n               (sys_rst_n),
  .ch_msg              (vc_msg),
  .ch_vld              (vc_vld),
  .ch_rdy              (),                  // ignore back-pressure for v1
  .voice_gate          (vc_voice_gate),
  .voice_note          (vc_voice_note),
  .voice_velocity      (vc_voice_velocity),
  .voice_aftertouch    (vc_voice_aftertouch),
  .voice_pitch_bend    (vc_voice_pitch_bend),
  .voice_release_done  (vc_voice_release_done),
  .ctrl_en             (1'b1),
  .ctrl_channel        (4'd0),
  .ctrl_all_notes_off  (1'b0),
  .ctrl_steal_en       (1'b0),
  .ctrl_overflow_clr   (1'b0),
  .ctrl_mono           (1'b1),              // force slot 0 + last-note priority
  .ctrl_unison         (1'b0),
  .cpu_voice_idx       ({$clog2(VC_NV){1'b0}}),
  .cpu_voice_note      (),
  .cpu_voice_vel       (),
  .cpu_voice_gate      (),
  .cpu_voice_state     (),
  .stat_active_count   (),
  .stat_gate_bitmap    (),
  .stat_overflow       (),
  .stat_sustain        (),
  .voice_legato        (),
  .stat_cc_mono        (),
  .stat_legato         (),
  .stat_unison         ()
);


//// SID register-bus driver ////
// M1b-midi version: gate/note/velocity from voice_ctrl slot 0 -> register
// writes on the SID bus. note_lut (128 x 16-bit) lives inside the driver.
// Output goes to drv_*, which is one half of the 2:1 bus mux below.
wire       drv_cs;
wire       drv_we;
wire [4:0] drv_addr;
wire [7:0] drv_data;
wire       sid_release_done;

sid_driver u_sid_driver (
  .clk                (sys_clk),
  .clk_en             (sys_clk_en),
  .rst_n              (sys_rst_n),
  .voice_gate         (vc_voice_gate[0]),
  .voice_note         (vc_voice_note[0]),
  .voice_velocity     (vc_voice_velocity[0]),
  .voice_release_done (sid_release_done),
  .cs                 (drv_cs),
  .we                 (drv_we),
  .addr               (drv_addr),
  .data               (drv_data)
);

// feed sid_driver's 1-cycle release pulse back to voice_ctrl slot 0.
// other slots: tied to 0 (they should never be active in mono mode, but
// safer to wire defensively).
assign vc_voice_release_done = {{(VC_NV-1){1'b0}}, sid_release_done};


//// MIDI SID core: dedicated to the sid_driver chain ////
wire signed [17:0] sid_audio_l;
wire         [7:0] sid_data_out;     // currently unused; for future readback regs

sid_top #(
  .MULTI_FILTERS (1),
  .DUAL          (0)
) u_sid (
  .reset       (~sys_rst_n),   // sid_top uses active-high reset
  .clk         (sys_clk),
  .ce_1m       (ce_1m),

  .cs          (drv_cs),
  .we          (drv_we),
  .addr        (drv_addr),
  .data_in     (drv_data),
  .data_out    (sid_data_out),

  .fc_offset_l (13'd0),
  .pot_x_l     (8'd0),
  .pot_y_l     (8'd0),
  .ext_in_l    (18'd0),
  .audio_l     (sid_audio_l),

  .fc_offset_r (13'd0),
  .pot_x_r     (8'd0),
  .pot_y_r     (8'd0),
  .ext_in_r    (18'd0),
  .audio_r     (),

  .filter_en   (1'b1),
  .mode        (sid_model_8580),  // 0 = 6581, 1 = 8580 (OSD "SID model")
  .cfg         (2'b00),

  .ld_clk      (sys_clk),
  .ld_addr     (12'd0),
  .ld_data     (16'd0),
  .ld_wr       (1'b0)            // tables keep their compiled-in init values
);


//// .sidraw playback path: SD -> sidraw_player -> dedicated SID core ////
// sidraw_sd_reader streams the picked file off the SD card (via user_io
// block reads) and feeds a sidraw_player, which drives a SECOND sid_top
// instance via its own private SID register bus. Two SID cores let us
// avoid mux RTL on the bus and let the MIDI chain keep responding to keys
// while the .sidraw plays in parallel. Audio from both SIDs is summed
// pre-dc_blocker (each >>>1 to fit 18 bits; the ~4 kLSB SID DC bias
// survives the average unchanged).

// SD reader -> player byte stream (vld/rdy handshake). Replaces the
// BRAM-baked sidraw_rom: the file the user picks in the OSD menu is mounted
// by the firmware and streamed sector-by-sector through a small FIFO. The
// reader pulses `sidraw_start` when a file mounts; sidraw_player then waits
// for bytes on the handshake (it stalls cleanly if the FIFO underruns).
wire [7:0] sd_byte_dat;
wire       sd_byte_vld;
wire       sd_byte_rdy;
wire       sidraw_start;

sidraw_sd_reader #(
  .FIFO_AW   (11),                    // 2 KB FIFO (2 M9K) -- ample headroom
  .SECTOR_SZ (512)
) u_sidraw_sd_reader (
  .clk            (sys_clk),
  .rst_n          (sys_rst_n),
  .stop           (sidraw_stop),      // OSD "Stop": hold off new sector fetches
  .start          (sidraw_start),
  .busy           (),
  .sd_lba         (sd_lba),
  .sd_rd          (sd_rd),
  .sd_ack         (sd_ack),
  .sd_dout        (sd_dout),
  .sd_dout_strobe (sd_dout_strobe),
  .img_mounted    (img_mounted),
  .img_size       (img_size),
  .byte_dat       (sd_byte_dat),
  .byte_vld       (sd_byte_vld),
  .byte_rdy       (sd_byte_rdy)
);

// Stop also freezes playback timing: gate the player's tick so the SID
// envelopes/oscillators hold, and mute the player's audio branch so a held
// note doesn't drone while stopped.
wire player_ce_tick = ce_1m & ~sidraw_stop;

// player -> dedicated SID register bus
wire       p_cs;
wire       p_we;
wire [4:0] p_addr;
wire [7:0] p_data;
wire       plr_error;        // diagnostic: player parse-error pulse (SD diag section)

sidraw_player u_sidraw_player (
  .clk      (sys_clk),
  .rst_n    (sys_rst_n),
  .ce_tick  (player_ce_tick),        // cycle-accurate mode; gated low while stopped
  .start    (sidraw_start),
  .busy     (),
  .done     (),
  .error    (plr_error),
  .byte_dat (sd_byte_dat),
  .byte_vld (sd_byte_vld),
  .byte_rdy (sd_byte_rdy),
  .sid_cs   (p_cs),
  .sid_we   (p_we),
  .sid_addr (p_addr),
  .sid_data (p_data)
);

// dedicated SID core for .sidraw playback (mirrors u_sid's config)
wire signed [17:0] sid_audio_l_player;

sid_top #(
  .MULTI_FILTERS (1),
  .DUAL          (0)
) u_sid_player (
  .reset       (~sys_rst_n | sidp_reset),   // also reset on new load / OSD Restart
  .clk         (sys_clk),
  .ce_1m       (ce_1m),

  .cs          (p_cs),
  .we          (p_we),
  .addr        (p_addr),
  .data_in     (p_data),
  .data_out    (),

  .fc_offset_l (13'd0),
  .pot_x_l     (8'd0),
  .pot_y_l     (8'd0),
  .ext_in_l    (18'd0),
  .audio_l     (sid_audio_l_player),

  .fc_offset_r (13'd0),
  .pot_x_r     (8'd0),
  .pot_y_r     (8'd0),
  .ext_in_r    (18'd0),
  .audio_r     (),

  .filter_en   (1'b1),
  .mode        (sid_model_8580),  // 0 = 6581, 1 = 8580 (OSD "SID model")
  .cfg         (2'b00),

  .ld_clk      (sys_clk),
  .ld_addr     (12'd0),
  .ld_data     (16'd0),
  .ld_wr       (1'b0)
);

// 50/50 mix of the two SIDs. Each audio_l is 18-bit SIGNED with a
// ~4000-LSB positive DC bias; the sum is sign-extended to 19 bits and
// arithmetic-shifted right by 1, preserving sign and DC level. dc_blocker
// downstream removes the bias before SDM.
//
// NOTE: this MUST be a signed add + arithmetic (>>>) shift. An unsigned
// add / bit-slice misreads the sign bit when the combined SID output dips
// below zero -- which happens when all three voices hit near-full envelope
// simultaneously (a chord) with their pulses aligned low -- wrapping the
// sample to near full scale. That produced the audible attack-onset click.
// mute the .sidraw branch while stopped (player tick is frozen, so the SID
// would otherwise hold its last waveform as a drone)
wire signed [17:0] sid_audio_player_eff = sidraw_stop ? 18'sd0 : sid_audio_l_player;
wire signed [18:0] sid_audio_sum        = sid_audio_l + sid_audio_player_eff;
wire signed [17:0] sid_audio_mixed      = sid_audio_sum >>> 1;


//// DC blocker between SID and SDM DAC ////
// SID's audio_l carries a ~4000-LSB constant DC bias (VOICE_DC_6581
// baked into every voice DCA, plus MIXER_DC_6581). Strip it before
// the PDM stage so the external RC isn't pinned to a DC offset.
// sid_top has no native flow control -- drive in_vld = ce_1m. SDM
// has no flow control either, so out_rdy is tied to 1.
wire        dcblock_vld;
wire [17:0] dcblock_audio;

dc_blocker #(
  .DW    (18),
  .SHIFT (15)             // fc ~ 5 Hz at fs = 1 MHz
) u_dc_blocker (
  .clk     (sys_clk),
  .rst_n   (sys_rst_n),
  .in_vld  (ce_1m),
  .in_rdy  (),            // always 1 -- pipeline drains in 3 cycles, samples are 54 cycles apart
  .in_dat  (sid_audio_mixed),
  .out_vld (dcblock_vld),
  .out_rdy (1'b1),
  .out_dat (dcblock_audio)
);


//// dc_blocker -> sdm sample latch ////
// The SDM clk_en runs at 9 MHz (every 6th sys_clk) but dcblock_vld is a
// 1-cycle pulse at sys_clk rate; the two won't line up. Register the
// dc_blocker output and hold it stable, then drive the SDM with a
// sticky in_vld so it reloads x_reg idempotently on every ce_9m. Stays
// silent (in_vld=0) until the first sample arrives so the SDM doesn't
// integrate garbage during boot.
reg [18-1:0] sdm_in_dat_r;
reg          sdm_in_vld_r;

always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    sdm_in_dat_r <= 18'd0;
    sdm_in_vld_r <= 1'b0;
  end else begin
    if (dcblock_vld) begin
      sdm_in_dat_r <= dcblock_audio;
      sdm_in_vld_r <= 1'b1;
    end
  end
end


//// SD audio out (mono; copies SID output to both pins) ////
wire sid_pdm;

sdm #(
  .DW (18),
  .IW (22),
  .NW (4)
) u_sdm_dac (
  .clk     (sys_clk),
  .clk_en  (ce_9m),         // 9 MHz PDM rate (sys_clk / 6); MiST IO can't settle faster
  .rst_n   (sys_rst_n),
  .in_vld  (sdm_in_vld_r),  // sticky high after first dc_blocker sample
  .in_dat  (sdm_in_dat_r),  // held stable; SDM reloads x_reg every ce_9m
  .pdm_out (sid_pdm)
);

assign AUDIO_L = sid_pdm;
assign AUDIO_R = sid_pdm;


//// VGA + OSD menu ////
// video_gen makes a plain 640x480@60 background on the dedicated pixel
// clock; osd.v overlays the MiST firmware menu (driven over SPI_SS3) onto
// it. SIDsynth has no real video content -- this exists purely so the OSD
// file browser is visible. Sync passes straight through; osd.v only tints
// the RGB inside the menu box.
wire [5:0] vid_r;
wire [5:0] vid_g;
wire [5:0] vid_b;
wire       vid_hs;
wire       vid_vs;
wire       vid_hblank;
wire       vid_vblank;

video_gen u_video_gen (
  .clk_pix    (clk_pix),
  .rst_n      (pix_rst_n),
  .vga_r      (vid_r),
  .vga_g      (vid_g),
  .vga_b      (vid_b),
  .vga_hs     (vid_hs),
  .vga_vs     (vid_vs),
  .vga_hblank (vid_hblank),
  .vga_vblank (vid_vblank)
);


//// SD diagnostic instrumentation ////
// The .sidraw SD path has no on-board observability: when nothing comes out
// of the speaker there's no way to tell whether the firmware mounted the file
// at all, whether sectors are being served, or whether the player ever ran.
// This block lights up the pipeline so it can be bisected on real hardware.
//
// Six sticky flags track how far a playback attempt got, in pipeline order:
//   mounted  : user_io pulsed img_mounted             (firmware mount reached FPGA)
//   sd_rd    : reader asserted sd_rd                   (a sector was requested)
//   sd_data  : user_io strobed a sector byte           (firmware is serving data)
//   fifo_byte: FIFO presented a byte to the player     (data crossed the FIFO)
//   sid_write: player drove a SID register write        (parser ran -> audio)
//   error    : player hit a bad header / opcode
// All flags clear on every img_mounted, so each file selection restarts the
// indicator from scratch.
//
// VGA: the background stays the normal dim blue until a mount reaches the
// FPGA, then flips to a solid stage colour (priority-encoded, furthest stage
// wins). Reading the colour after picking a file tells you where it stalled:
//   (background unchanged) no mount      -> firmware/CONF_STR never mounted
//   purple                 mounted only  -> reader never requested a sector
//                                           (stop asserted? img_size -> 0 sectors?)
//   cyan                   sd_rd, no data-> firmware not serving the read
//   orange                 data, no fifo -> sd_dout capture / FIFO write issue
//   yellow                 fifo, no write-> bytes reach player but no SID write
//                                           (header rejected? parser stuck)
//   green                  sid_write     -> end-to-end OK (should be audible)
//   red                    error         -> player halted on bad header/opcode
//
// LED: 1 Hz heartbeat = FPGA alive; solid = player has emitted >=1 SID write.
//
// Set DEBUG_SD=0 to revert to the plain heartbeat LED and flat background.
localparam DEBUG_SD = 1'b1;

// sticky stage flags (sys_clk domain)
reg dbg_mounted;
reg dbg_sd_rd;
reg dbg_sd_data;
reg dbg_fifo;
reg dbg_write;
reg dbg_error;

always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    dbg_mounted <= 1'b0;
    dbg_sd_rd   <= 1'b0;
    dbg_sd_data <= 1'b0;
    dbg_fifo    <= 1'b0;
    dbg_write   <= 1'b0;
    dbg_error   <= 1'b0;
  end else if (img_mounted) begin
    // fresh mount: restart the indicator for the newly picked file
    dbg_mounted <= 1'b1;
    dbg_sd_rd   <= 1'b0;
    dbg_sd_data <= 1'b0;
    dbg_fifo    <= 1'b0;
    dbg_write   <= 1'b0;
    dbg_error   <= 1'b0;
  end else begin
    if (sd_rd)          dbg_sd_rd   <= 1'b1;
    if (sd_dout_strobe) dbg_sd_data <= 1'b1;
    if (sd_byte_vld)    dbg_fifo    <= 1'b1;
    if (p_cs & p_we)    dbg_write   <= 1'b1;
    if (plr_error)      dbg_error   <= 1'b1;
  end
end

// LED: heartbeat until the player writes a SID register, then solid on.
assign LED = (DEBUG_SD && dbg_write) ? 1'b1 : blinky_r;

// cross the (slow, sticky) flag bus into the pixel-clock domain. sys_clk and
// clk_pix are already declared async (set_clock_groups in sidsynth_mist.sdc),
// so this 2-FF synchroniser is a clean CDC -- no extra SDC needed.
wire [5:0] dbg_bus = {dbg_error, dbg_write, dbg_fifo, dbg_sd_data, dbg_sd_rd, dbg_mounted};

reg [5:0] dbg_sync0;
reg [5:0] dbg_sync1;

always @(posedge clk_pix, negedge pix_rst_n) begin
  if (!pix_rst_n) begin
    dbg_sync0 <= 6'd0;
    dbg_sync1 <= 6'd0;
  end else begin
    dbg_sync0 <= dbg_bus;
    dbg_sync1 <= dbg_sync0;
  end
end

wire d_mounted = dbg_sync1[0];
wire d_sd_rd   = dbg_sync1[1];
wire d_sd_data = dbg_sync1[2];
wire d_fifo    = dbg_sync1[3];
wire d_write   = dbg_sync1[4];
wire d_error   = dbg_sync1[5];

// priority-encoded stage colour (furthest stage reached wins; error overrides)
reg [5:0] dbg_r;
reg [5:0] dbg_g;
reg [5:0] dbg_b;

always @* begin
  if      (d_error)   begin dbg_r = 6'd63; dbg_g = 6'd0;  dbg_b = 6'd0;  end // red
  else if (d_write)   begin dbg_r = 6'd0;  dbg_g = 6'd63; dbg_b = 6'd0;  end // green
  else if (d_fifo)    begin dbg_r = 6'd63; dbg_g = 6'd63; dbg_b = 6'd0;  end // yellow
  else if (d_sd_data) begin dbg_r = 6'd63; dbg_g = 6'd24; dbg_b = 6'd0;  end // orange
  else if (d_sd_rd)   begin dbg_r = 6'd0;  dbg_g = 6'd48; dbg_b = 6'd48; end // cyan
  else                begin dbg_r = 6'd40; dbg_g = 6'd0;  dbg_b = 6'd40; end // purple
end

// override the background with the stage colour only after a mount, and only
// in the visible area (blanking stays black so osd's sync handling is intact).
wire vid_active = ~vid_hblank;
wire dbg_paint  = DEBUG_SD && d_mounted && vid_active;

wire [5:0] osd_r_in = dbg_paint ? dbg_r : vid_r;
wire [5:0] osd_g_in = dbg_paint ? dbg_g : vid_g;
wire [5:0] osd_b_in = dbg_paint ? dbg_b : vid_b;


osd #(
  .OUT_COLOR_DEPTH (6),
  .OSD_AUTO_CE     (1'b1),
  .USE_BLANKS      (1'b0)
) u_osd (
  .clk_sys    (clk_pix),
  .ce         (1'b1),
  .SPI_SCK    (SPI_SCK),
  .SPI_SS3    (SPI_SS3),
  .SPI_DI     (SPI_DI),
  .rotate     (2'b00),
  .R_in       (osd_r_in),
  .G_in       (osd_g_in),
  .B_in       (osd_b_in),
  .HBlank     (vid_hblank),
  .VBlank     (vid_vblank),
  .HSync      (vid_hs),
  .VSync      (vid_vs),
  .R_out      (VGA_R),
  .G_out      (VGA_G),
  .B_out      (VGA_B),
  .osd_enable ()
);

assign VGA_HS = vid_hs;
assign VGA_VS = vid_vs;


endmodule


`default_nettype wire

