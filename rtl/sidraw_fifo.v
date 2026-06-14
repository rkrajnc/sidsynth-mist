// sidraw_fifo.v
// Small single-clock byte FIFO with a show-ahead (first-word-fall-through)
// vld/rdy read interface, backed by inferred M9K block RAM. The M9K's
// synchronous read latency is hidden behind a 1-entry output register.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module sidraw_fifo #(
  parameter integer AW = 11,        // address width; depth = 2^AW bytes
  parameter integer DW = 8
) (
  input  wire          clk,
  input  wire          rst_n,       // async, active low
  input  wire          flush,       // sync clear (drop all contents)

  // write port
  input  wire          wr_en,
  input  wire [DW-1:0] wr_dat,
  output wire          full,
  output wire [AW:0]   used,        // occupancy incl. output register

  // read port: show-ahead vld/rdy
  output wire [DW-1:0] rd_dat,
  output wire          rd_vld,
  input  wire          rd_rdy
);


localparam integer DEPTH = (1 << AW);

// inferred M9K: single write port, single registered read port. Keep rdata
// out of any reset so Quartus maps it to the M9K output register.
(* ramstyle = "M9K" *) reg [DW-1:0] mem [0:DEPTH-1];

reg  [AW-1:0] wp;            // write pointer
reg  [AW-1:0] rp;            // read pointer (into RAM)
reg  [AW:0]   cnt;           // bytes currently stored in RAM (excl. output reg)
reg  [DW-1:0] rdata;         // output register (head byte)
reg           rdata_vld;     // output register holds a valid byte

wire wr      = wr_en & ~full;
wire ram_ne  = (cnt != {(AW+1){1'b0}});
// can the output register accept a new byte next cycle?
//   - it is empty, or
//   - it is being consumed this cycle
wire out_free = (~rdata_vld) | rd_rdy;
// issue a RAM read this cycle (advances rp, decrements cnt); the byte lands
// in rdata next cycle.
wire issue   = ram_ne & out_free;

assign full   = (cnt == DEPTH[AW:0]);
assign used   = cnt + (rdata_vld ? {{(AW){1'b0}}, 1'b1} : {(AW+1){1'b0}});
assign rd_dat = rdata;
// Suppress the presented byte during a flush: the registered valid clears only
// next edge, so gate it combinationally to hide the stale head byte immediately.
assign rd_vld = rdata_vld & ~flush;


// write port (M9K)
always @(posedge clk) begin
  if (wr) mem[wp] <= wr_dat;
end

// registered read data (M9K output register, no reset)
always @(posedge clk) begin
  if (issue) rdata <= mem[rp];
end

// pointers / occupancy / valid
always @(posedge clk, negedge rst_n) begin
  if (!rst_n) begin
    wp        <= {AW{1'b0}};
    rp        <= {AW{1'b0}};
    cnt       <= {(AW+1){1'b0}};
    rdata_vld <= 1'b0;
  end else if (flush) begin
    wp        <= {AW{1'b0}};
    rp        <= {AW{1'b0}};
    cnt       <= {(AW+1){1'b0}};
    rdata_vld <= 1'b0;
  end else begin
    // write pointer
    if (wr) wp <= wp + {{(AW-1){1'b0}}, 1'b1};

    // read pointer + output-register valid
    if (issue) begin
      rp        <= rp + {{(AW-1){1'b0}}, 1'b1};
      rdata_vld <= 1'b1;                  // rdata becomes valid next cycle
    end else if (rdata_vld && rd_rdy) begin
      rdata_vld <= 1'b0;                  // consumed, nothing to reload
    end

    // RAM occupancy: +1 on write, -1 on issue (move RAM -> output reg)
    case ({wr, issue})
      2'b10:   cnt <= cnt + 1'b1;
      2'b01:   cnt <= cnt - 1'b1;
      default: cnt <= cnt;               // 2'b00 or 2'b11: no net change
    endcase
  end
end


endmodule


`default_nettype wire
