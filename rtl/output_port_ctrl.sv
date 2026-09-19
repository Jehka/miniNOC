// output_port_ctrl.sv -- per-output RR arbitration with lock-on-grant (spec v0.2 sec 6)
//
// UNLOCKED: grant = rr scan of req from rr_ptr. The winner is locked at the
//           end of the cycle it is first granted, whether or not its header
//           transferred -- so the offered flit on this output can never switch
//           to another input while stalled (fixes v0.1 stability hole).
// LOCKED:   only owner may transfer; req from owner may drop (its FIFO ran dry
//           mid-packet) without losing the lock.
// Release:  on accepted last flit (eop). rr_ptr <= owner + 1.
module output_port_ctrl
  import noc_pkg::*;
#(
  parameter int N  = N_IN,
  localparam int IW = $clog2(N)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [N-1:0]  req_i,      // input i has a valid head flit routed here
  input  logic [N-1:0]  eop_i,      // eop bit of each input's head flit
  input  logic          out_ready_i,
  output logic [IW-1:0] owner_o,    // mux select
  output logic          have_o,     // an input is selected (locked or granted)
  output logic          out_valid_o,
  output logic          locked_o
);
  logic [N-1:0]  gnt;
  logic [IW-1:0] gnt_idx, owner_q;
  logic          gnt_valid, locked, xfer, done;

  rr_arbiter #(.N(N)) u_arb (
    .clk, .rst_n, .req_i,
    .release_i(done), .release_idx_i(owner_o),
    .gnt_o(gnt), .gnt_idx_o(gnt_idx), .gnt_valid_o(gnt_valid));

  assign owner_o     = locked ? owner_q : gnt_idx;
  assign have_o      = locked || gnt_valid;
  assign out_valid_o = have_o && req_i[owner_o];
  assign xfer        = out_valid_o && out_ready_i;
  assign done        = xfer && eop_i[owner_o];
  assign locked_o    = locked;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      locked  <= 1'b0;
      owner_q <= '0;
    end else if (done) begin
      locked  <= 1'b0;
    end else if (!locked && gnt_valid) begin
      locked  <= 1'b1;
      owner_q <= gnt_idx;
    end
  end

`ifndef SYNTHESIS
  logic [N-1:0] unused_gnt;
  assign unused_gnt = gnt;
  logic          stall_q;
  logic [IW-1:0] stall_owner_q;
  always_ff @(posedge clk) begin
    if (!rst_n) stall_q <= 1'b0;
    else begin
      if (stall_q) begin
        assert (have_o && owner_o == stall_owner_q && out_valid_o)
          else $error("output_port_ctrl: offered flit withdrawn or owner changed during stall");
      end
      stall_q       <= out_valid_o && !out_ready_i;
      stall_owner_q <= owner_o;
      assert (!locked || int'(owner_q) < N) else $error("output_port_ctrl: bad owner");
    end
  end
`endif
endmodule
