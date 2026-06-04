// sidraw_sd_reader.v
// Streams a .sidraw file off the SD card (via the MiST user_io block
// interface) into a small FIFO, presenting the bytes to sidraw_player on
// the same vld/rdy handshake the BRAM-baked sidraw_rom used. This is the
// runtime replacement for sidraw_rom: instead of a tune baked at synthesis
// time, the ARM firmware mounts the file the user picked in the OSD menu
// and serves 512-byte sectors on demand.
//
// Flow control is FPGA-paced: we only request the next sector once the FIFO
// has room for a full 512 bytes, so an arbitrarily large file streams
// through a fixed, tiny buffer without overflow. If the FIFO ever underruns
// (SD latency), sidraw_player simply stalls on byte_rdy -- playback pauses,
// no glitch.
//
// MiST user_io block read handshake (see reference/mist-modules-master/
// user_io.v sd_block):
//   1. core sets sd_lba, raises sd_rd; firmware notices via UIO_GET_SDSTAT
//   2. firmware streams the sector: sd_ack high, then 512 sd_dout bytes each
//      flagged by a 1-clk sd_dout_strobe pulse
//   3. firmware ends the transfer: sd_ack falls
// We run user_io's clk_sd == sys_clk, so sd_ack/sd_dout/sd_dout_strobe are
// already in this clock domain -- no extra CDC here.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module sidraw_sd_reader #(
  parameter integer FIFO_AW   = 11,     // FIFO depth = 2^FIFO_AW bytes (>=1024)
  parameter integer SECTOR_SZ = 512     // SD sector size (SD_BLKSZ=0 -> 512)
) (
  input  wire        clk,
  input  wire        rst_n,             // async, active low

  // control
  input  wire        stop,              // OSD "Stop": hold off new sector fetches
  output reg         start,             // 1-cycle pulse to sidraw_player on (re)mount
  output wire        busy,              // streaming a file (state != IDLE)

  // MiST user_io block interface (we drive sd_lba/sd_rd, sample the rest)
  output reg  [31:0] sd_lba,
  output reg         sd_rd,
  input  wire        sd_ack,            // high for the duration of a sector transfer
  input  wire [ 7:0] sd_dout,           // sector byte, valid on sd_dout_strobe
  input  wire        sd_dout_strobe,    // 1-clk pulse per sector byte
  input  wire        img_mounted,       // 1-clk pulse: a new file was mounted
  input  wire [63:0] img_size,          // mounted file size in bytes

  // byte-stream output to sidraw_player (vld/rdy)
  output wire [ 7:0] byte_dat,
  output wire        byte_vld,
  input  wire        byte_rdy
);


localparam integer FIFO_DEPTH = (1 << FIFO_AW);

//// FSM states ////
localparam [2:0] S_IDLE     = 3'd0;  // no file; wait for img_mounted
localparam [2:0] S_REQ      = 3'd1;  // decide whether to fetch the next sector
localparam [2:0] S_WAIT_ACK = 3'd2;  // sd_rd asserted; wait for transfer to start
localparam [2:0] S_RECV     = 3'd3;  // capturing the sector into the FIFO
localparam [2:0] S_DRAIN    = 3'd4;  // all sectors fetched; FIFO drains to player

reg  [ 2:0] state;
reg  [31:0] n_sectors;               // ceil(img_size / SECTOR_SZ)
reg  [31:0] sec_idx;                 // next sector LBA to request

// FIFO wiring
wire [FIFO_AW:0] fifo_used;
wire             fifo_full;
reg              fifo_wr;
reg  [     7:0]  fifo_wr_dat;
reg              fifo_flush;

// room for a whole sector?  (depth - used) >= SECTOR_SZ
wire fifo_has_room = (FIFO_DEPTH[FIFO_AW:0] - fifo_used) >= SECTOR_SZ[FIFO_AW:0];

assign busy = (state != S_IDLE);


sidraw_fifo #(
  .AW (FIFO_AW),
  .DW (8)
) u_fifo (
  .clk    (clk),
  .rst_n  (rst_n),
  .flush  (fifo_flush),
  .wr_en  (fifo_wr),
  .wr_dat (fifo_wr_dat),
  .full   (fifo_full),
  .used   (fifo_used),
  .rd_dat (byte_dat),
  .rd_vld (byte_vld),
  .rd_rdy (byte_rdy)
);


//// sector-count from file size: n_sectors = ceil(img_size / SECTOR_SZ) ////
// SECTOR_SZ is a power of two (512); use a shift. img_size is 64-bit but
// .sidraw files are at most a few MB, so 32 bits of sector index is ample.
wire [63:0] size_round    = img_size + {{55{1'b0}}, 9'd511};
wire [31:0] n_sectors_calc = size_round[40:9];   // /512, capped to 32 bits


//// main FSM ////
always @(posedge clk, negedge rst_n) begin
  if (!rst_n) begin
    state       <= S_IDLE;
    n_sectors   <= 32'd0;
    sec_idx     <= 32'd0;
    sd_lba      <= 32'd0;
    sd_rd       <= 1'b0;
    start       <= 1'b0;
    fifo_wr     <= 1'b0;
    fifo_wr_dat <= 8'd0;
    fifo_flush  <= 1'b0;
  end else begin
    // pulse-style defaults
    start      <= 1'b0;
    fifo_wr    <= 1'b0;
    fifo_flush <= 1'b0;

    // A (re)mount restarts playback from sector 0, regardless of state.
    if (img_mounted) begin
      n_sectors  <= n_sectors_calc;
      sec_idx    <= 32'd0;
      sd_rd      <= 1'b0;
      fifo_flush <= 1'b1;            // drop any stale bytes
      start      <= 1'b1;            // kick sidraw_player (it waits for bytes)
      state      <= S_REQ;
    end else begin
      case (state)

        S_IDLE: begin
          // wait for img_mounted (handled above)
        end

        S_REQ: begin
          if (sec_idx >= n_sectors) begin
            state <= S_DRAIN;          // whole file fetched
          end else if (!stop && fifo_has_room) begin
            sd_lba <= sec_idx;
            sd_rd  <= 1'b1;
            state  <= S_WAIT_ACK;
          end
          // else: stop asserted or FIFO too full -> hold here
        end

        S_WAIT_ACK: begin
          // hold sd_rd until the firmware starts the transfer
          if (sd_ack) begin
            sd_rd <= 1'b0;
            state <= S_RECV;
          end
        end

        S_RECV: begin
          // push each strobed byte into the FIFO
          if (sd_dout_strobe) begin
            fifo_wr     <= 1'b1;
            fifo_wr_dat <= sd_dout;
          end
          // transfer ends when the firmware drops sd_ack
          if (!sd_ack) begin
            sec_idx <= sec_idx + 32'd1;
            state   <= S_REQ;
          end
        end

        S_DRAIN: begin
          // no more sectors to fetch; player drains the FIFO and stops on
          // the .sidraw 0xFF EOF byte. A fresh img_mounted (above) restarts.
        end

        default: state <= S_IDLE;
      endcase
    end
  end
end


endmodule


`default_nettype wire
