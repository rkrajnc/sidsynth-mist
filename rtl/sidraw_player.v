// sidraw_player.v
// .sidraw stream parser: consumes a byte stream conforming to the v1
// .sidraw format (see doc/PLANNING.md), emits SID register-bus writes
// with tick-accurate timing.
//
// Bit-accurate to modules/sidraw_player/sw/sidraw_player_model.py. Each
// FSM state in this RTL mirrors a state in the Python model; cocotb
// compares emitted SID writes against the model's output for the same
// byte buffer.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>


`default_nettype none


module sidraw_player (
  input  wire        clk,
  input  wire        rst_n,         // async, active low
  input  wire        ce_tick,       // tick strobe (frame or cycle, per top wiring)

  // control
  input  wire        start,         // 1-cycle pulse: begin playback from byte 0
  output reg         busy,          // 1 while a stream is in flight
  output reg         done,          // 1-cycle pulse on 0xFF end-of-stream
  output reg         error,         // 1-cycle pulse on bad header / unknown opcode

  // byte-stream source (vld/rdy handshake)
  input  wire [ 7:0] byte_dat,
  input  wire        byte_vld,
  output reg         byte_rdy,

  // SID register bus: cs+we high for 1 clk cycle with addr/data valid
  output reg         sid_cs,
  output reg         sid_we,
  output reg  [ 4:0] sid_addr,
  output reg  [ 7:0] sid_data
);


//// FSM states ////
localparam [3:0] ST_IDLE        = 4'd0;
localparam [3:0] ST_READ_HEADER = 4'd1;
localparam [3:0] ST_READ_OPCODE = 4'd2;
localparam [3:0] ST_READ_ARGS   = 4'd3;
localparam [3:0] ST_EMIT        = 4'd4;
localparam [3:0] ST_WAIT        = 4'd5;
localparam [3:0] ST_DONE        = 4'd6;
localparam [3:0] ST_ERROR       = 4'd7;


//// opcode constants ////
localparam [7:0] OP_WRITE_HI = 8'h18;
localparam [7:0] OP_WAIT_8   = 8'h20;
localparam [7:0] OP_WAIT_16  = 8'h21;
localparam [7:0] OP_WAIT_32  = 8'h22;
localparam [7:0] OP_END      = 8'hFF;


//// header constants ////
localparam [4:0] HDR_LEN = 5'd16;


//// internal regs ////
reg [ 3:0] state;
reg [ 4:0] hdr_cnt;        // 0..15 during header read
reg [ 7:0] op_r;            // latched opcode (currently being processed)
reg [ 2:0] arg_idx;         // which arg byte we're consuming (0..3)
reg [ 2:0] arg_target;      // total arg bytes expected (1, 2 or 4)
reg [31:0] wait_r;          // tick countdown
reg [ 7:0] dd_r;            // latched data byte for SID write
reg        hdr_ok;          // running validity of header bytes so far


//// header byte validation ////
// Only bytes 0..4 are checked (magic + version); bytes 5..15 are flags/
// tick_rate/body_size which the parser does not need to interpret.
wire hdr_byte_ok =
    (hdr_cnt == 5'd0) ? (byte_dat == 8'h53) :  // 'S'
    (hdr_cnt == 5'd1) ? (byte_dat == 8'h49) :  // 'I'
    (hdr_cnt == 5'd2) ? (byte_dat == 8'h44) :  // 'D'
    (hdr_cnt == 5'd3) ? (byte_dat == 8'h52) :  // 'R'
    (hdr_cnt == 5'd4) ? (byte_dat == 8'h01) :  // format version
    1'b1;


//// opcode classification (combinational on latched op_r) ////
wire op_is_write = (op_r <= OP_WRITE_HI);


//// main FSM ////
always @(posedge clk, negedge rst_n) begin
  if (!rst_n) begin
    state      <= ST_IDLE;
    hdr_cnt    <= 5'd0;
    op_r       <= 8'd0;
    arg_idx    <= 3'd0;
    arg_target <= 3'd0;
    wait_r     <= 32'd0;
    dd_r       <= 8'd0;
    hdr_ok     <= 1'b1;
    busy       <= 1'b0;
    done       <= 1'b0;
    error      <= 1'b0;
    byte_rdy   <= 1'b0;
    sid_cs     <= 1'b0;
    sid_we     <= 1'b0;
    sid_addr   <= 5'd0;
    sid_data   <= 8'd0;
  end else begin
    // pulse-style outputs default low each cycle
    done   <= 1'b0;
    error  <= 1'b0;
    sid_cs <= 1'b0;
    sid_we <= 1'b0;

    case (state)

      ST_IDLE: begin
        busy     <= 1'b0;
        byte_rdy <= 1'b0;
        if (start) begin
          state    <= ST_READ_HEADER;
          hdr_cnt  <= 5'd0;
          hdr_ok   <= 1'b1;
          busy     <= 1'b1;
          byte_rdy <= 1'b1;
        end
      end

      ST_READ_HEADER: begin
        if (byte_vld && byte_rdy) begin
          // accumulate header validity; halt if any check fails
          if (!hdr_byte_ok) hdr_ok <= 1'b0;
          if (hdr_cnt == HDR_LEN - 5'd1) begin
            // last header byte just consumed
            if (hdr_ok && hdr_byte_ok) begin
              state    <= ST_READ_OPCODE;
              hdr_cnt  <= 5'd0;
              byte_rdy <= 1'b1;
            end else begin
              state    <= ST_ERROR;
              byte_rdy <= 1'b0;
            end
          end else begin
            hdr_cnt <= hdr_cnt + 5'd1;
          end
        end
      end

      ST_READ_OPCODE: begin
        if (byte_vld && byte_rdy) begin
          op_r    <= byte_dat;
          arg_idx <= 3'd0;
          wait_r  <= 32'd0;            // clear before arg accumulation
          if (byte_dat <= OP_WRITE_HI) begin
            // SID register write: 1 data byte follows
            arg_target <= 3'd1;
            state      <= ST_READ_ARGS;
            byte_rdy   <= 1'b1;
          end else if (byte_dat == OP_WAIT_8) begin
            arg_target <= 3'd1;
            state      <= ST_READ_ARGS;
            byte_rdy   <= 1'b1;
          end else if (byte_dat == OP_WAIT_16) begin
            arg_target <= 3'd2;
            state      <= ST_READ_ARGS;
            byte_rdy   <= 1'b1;
          end else if (byte_dat == OP_WAIT_32) begin
            arg_target <= 3'd4;
            state      <= ST_READ_ARGS;
            byte_rdy   <= 1'b1;
          end else if (byte_dat == OP_END) begin
            state    <= ST_DONE;
            byte_rdy <= 1'b0;
          end else begin
            // 0x19..0x1F (reserved write), 0x23..0x2F, 0x30..0xFE
            state    <= ST_ERROR;
            byte_rdy <= 1'b0;
          end
        end
      end

      ST_READ_ARGS: begin
        if (byte_vld && byte_rdy) begin
          if (op_is_write) begin
            dd_r <= byte_dat;
          end else begin
            // any wait opcode: place byte_dat into wait_r at arg_idx*8 (LE)
            case (arg_idx)
              3'd0: wait_r[ 7: 0] <= byte_dat;
              3'd1: wait_r[15: 8] <= byte_dat;
              3'd2: wait_r[23:16] <= byte_dat;
              3'd3: wait_r[31:24] <= byte_dat;
              default: ;
            endcase
          end

          if (arg_idx + 3'd1 == arg_target) begin
            // last arg byte just consumed
            if (op_is_write) begin
              state    <= ST_EMIT;
              byte_rdy <= 1'b0;
            end else begin
              state    <= ST_WAIT;
              byte_rdy <= 1'b0;
            end
          end else begin
            arg_idx <= arg_idx + 3'd1;
          end
        end
      end

      ST_EMIT: begin
        sid_cs   <= 1'b1;
        sid_we   <= 1'b1;
        sid_addr <= op_r[4:0];       // opcode == register addr for writes
        sid_data <= dd_r;
        state    <= ST_READ_OPCODE;
        byte_rdy <= 1'b1;
      end

      ST_WAIT: begin
        if (wait_r == 32'd0) begin
          state    <= ST_READ_OPCODE;
          byte_rdy <= 1'b1;
        end else if (ce_tick) begin
          wait_r <= wait_r - 32'd1;
        end
      end

      ST_DONE: begin
        done     <= 1'b1;
        busy     <= 1'b0;
        state    <= ST_IDLE;
        byte_rdy <= 1'b0;
      end

      ST_ERROR: begin
        error    <= 1'b1;
        busy     <= 1'b0;
        state    <= ST_IDLE;
        byte_rdy <= 1'b0;
      end

      default: state <= ST_IDLE;
    endcase
  end
end


endmodule


`default_nettype wire
