// fwd_table.sv -- IPv4 -> DST_ID forwarding table (network stage N4, PL half)
//
// 16 entries of {valid, ipv4[31:0], dst_id[3:0]} in flip-flops, written one
// entry at a time and searched in parallel. This is the forwarding plane: the
// PS programs it, the datapath consults it, and remapping an endpoint to a new
// address is a register write, not a rebuild.
//
// Lookups are combinational (16 parallel 32-bit compares + priority select), so
// the caller decides where to register the result. If two valid entries hold
// the same address, the lowest index wins; if two map to the same DST_ID, the
// reverse lookup returns the lowest index's address.
module fwd_table #(
  parameter int N = 16,
  localparam int IW = $clog2(N)
) (
  input  logic          clk,
  input  logic          rst_n,
  // write one entry
  input  logic          wr_en,
  input  logic [IW-1:0] wr_idx,
  input  logic          wr_valid,
  input  logic [31:0]   wr_ip,
  input  logic [3:0]    wr_dst,
  // forward lookup A: datapath (route-by-IP pushes)
  input  logic [31:0]   fa_ip,
  output logic          fa_hit,
  output logic [3:0]    fa_dst,
  // forward lookup B: software probe register
  input  logic [31:0]   fb_ip,
  output logic          fb_hit,
  output logic [3:0]    fb_dst,
  // reverse lookup: DST_ID -> IP, for addressing replies
  input  logic [3:0]    rv_dst,
  output logic          rv_hit,
  output logic [31:0]   rv_ip,
  // read back one entry
  input  logic [IW-1:0] rd_idx,
  output logic          rd_valid,
  output logic [31:0]   rd_ip,
  output logic [3:0]    rd_dst,
  output logic [IW:0]   n_valid       // number of valid entries
);
  logic [N-1:0]       v;
  logic [N-1:0][31:0] ip;
  logic [N-1:0][3:0]  dst;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v <= '0;
    end else if (wr_en) begin
      v  [wr_idx] <= wr_valid;
      ip [wr_idx] <= wr_ip;
      dst[wr_idx] <= wr_dst;
    end
  end

  // Priority search from index 0 upward: lowest matching index wins.
  always_comb begin
    fa_hit = 1'b0; fa_dst = '0;
    fb_hit = 1'b0; fb_dst = '0;
    rv_hit = 1'b0; rv_ip  = '0;
    for (int i = N - 1; i >= 0; i--) begin
      if (v[i] && ip[i]  == fa_ip)  begin fa_hit = 1'b1; fa_dst = dst[i]; end
      if (v[i] && ip[i]  == fb_ip)  begin fb_hit = 1'b1; fb_dst = dst[i]; end
      if (v[i] && dst[i] == rv_dst) begin rv_hit = 1'b1; rv_ip  = ip[i];  end
    end
  end

  assign rd_valid = v[rd_idx];
  assign rd_ip    = ip[rd_idx];
  assign rd_dst   = dst[rd_idx];
  assign n_valid  = (IW+1)'($countones(v));
endmodule