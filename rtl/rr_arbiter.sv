// rr_arbiter.sv -- N-way round-robin arbiter with externally committed pointer.
//
// Grant is purely combinational from (req, rr_ptr): the first set request found
// scanning upward from rr_ptr with wrap-around. The pointer only moves when the
// owner explicitly releases (release_i), landing at release_idx_i + 1. This lets
// output_port_ctrl keep the pointer frozen for an entire packet and rotate
// fairness only on accepted EOP (spec sec 6).
//
// N need not be a power of two (N = 9 once memory is also a switch input).
module rr_arbiter #(
  parameter int N   = 8,
  localparam int IW = (N > 1) ? $clog2(N) : 1
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [N-1:0]  req_i,
  input  logic          release_i,      // commit: last grant to release_idx_i finished
  input  logic [IW-1:0] release_idx_i,
  output logic [N-1:0]  gnt_o,          // one-hot or zero
  output logic [IW-1:0] gnt_idx_o,
  output logic          gnt_valid_o
);

  logic [IW-1:0] rr_ptr;

  // Scan from rr_ptr with wrap. Explicit subtract instead of % so the
  // loop maps to a clean priority structure for non-power-of-2 N.
  always_comb begin
    int idx;
    gnt_o       = '0;
    gnt_idx_o   = '0;
    gnt_valid_o = 1'b0;
    for (int k = 0; k < N; k++) begin
      idx = int'(rr_ptr) + k;
      if (idx >= N) idx -= N;
      if (!gnt_valid_o && req_i[idx]) begin
        gnt_o[idx]  = 1'b1;
        gnt_idx_o   = IW'(idx);
        gnt_valid_o = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_ptr <= '0;
    end else if (release_i) begin
      rr_ptr <= (int'(release_idx_i) == N-1) ? '0 : release_idx_i + 1'b1;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    assert ($onehot0(gnt_o))                       else $error("rr_arbiter: grant not onehot0");
    assert (!gnt_valid_o || req_i[gnt_idx_o])      else $error("rr_arbiter: grant without request");
    assert (!(|req_i) || gnt_valid_o)              else $error("rr_arbiter: request pending, no grant");
    assert (!release_i || int'(release_idx_i) < N) else $error("rr_arbiter: release idx out of range");
  end
`endif
endmodule
