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


//// unused IO (v1: MIDI in + audio out only) ////
assign UART_TX    = 1'b1;            // MIDI/UART idle high
assign VGA_HS     = 1'b0;
assign VGA_VS     = 1'b0;
assign VGA_R      = 6'b0;
assign VGA_G      = 6'b0;
assign VGA_B      = 6'b0;
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
assign SPI_DO     = 1'bz;


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

always @(posedge sys_clk or negedge pll_locked) begin
  if (!pll_locked) begin
    rst_sync <= 4'd0;
  end else begin
    rst_sync <= {rst_sync[1:0], 1'b1};
  end
end

assign sys_rst_n = rst_sync[2];


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

assign LED = blinky_r;


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
// single project-wide clk_en net, tied high;
// routed through every module so we can swap in a gating
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
  .mode        (1'b0),          // 6581 model
  .cfg         (2'b00),

  .ld_clk      (sys_clk),
  .ld_addr     (12'd0),
  .ld_data     (16'd0),
  .ld_wr       (1'b0)            // tables keep their compiled-in init values
);


//// .sidraw playback path: ROM -> sidraw_player -> dedicated SID core ////
// ROM -> player byte stream (vld/rdy handshake)
wire [7:0] rom_byte_dat;
wire       rom_byte_vld;
wire       rom_byte_rdy;

sidraw_rom #(
  .MIF_FILE   ("test_tune.hex"),
  .DEPTH      (31875),                // size of test_tune.sidraw (Monty 24s cycle)
  .ADDR_WIDTH (15)                    // 2^15 = 32 KB ROM = 32 M9K blocks
) u_sidraw_rom (
  .clk      (sys_clk),
  .rst_n    (sys_rst_n),
  .byte_dat (rom_byte_dat),
  .byte_vld (rom_byte_vld),
  .byte_rdy (rom_byte_rdy)
);

// auto-start the player one cycle after reset deassertion; the player
// runs to its 0xFF EOF then sits in IDLE. To replay, toggle sys_rst_n.
reg sidraw_start;
reg sidraw_started;
always @(posedge sys_clk, negedge sys_rst_n) begin
  if (!sys_rst_n) begin
    sidraw_start   <= 1'b0;
    sidraw_started <= 1'b0;
  end else begin
    if (!sidraw_started) begin
      sidraw_start   <= 1'b1;
      sidraw_started <= 1'b1;
    end else begin
      sidraw_start   <= 1'b0;
    end
  end
end

// player -> dedicated SID register bus
wire       p_cs;
wire       p_we;
wire [4:0] p_addr;
wire [7:0] p_data;

sidraw_player u_sidraw_player (
  .clk      (sys_clk),
  .rst_n    (sys_rst_n),
  .ce_tick  (ce_1m),                 // cycle-accurate mode: 1 tick = 1 PAL CPU cycle
  .start    (sidraw_start),
  .busy     (),
  .done     (),
  .error    (),
  .byte_dat (rom_byte_dat),
  .byte_vld (rom_byte_vld),
  .byte_rdy (rom_byte_rdy),
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
  .reset       (~sys_rst_n),
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
  .mode        (1'b0),          // 6581 model
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
wire signed [18:0] sid_audio_sum   = sid_audio_l + sid_audio_l_player;
wire signed [17:0] sid_audio_mixed = sid_audio_sum >>> 1;


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


endmodule


`default_nettype wire

