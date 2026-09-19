// route_decode.sv -- per-input destination latch (spec v0.2 sec 5)
//
// The header is only on the SOP flit. The destination is decoded from the
// head flit when no packet is open, and latched for the body flits.
// DST_ID 0..8 map to outputs 0..8; 9..15 map to SINK_PORT.
module route_decode
  import noc_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  input  logic [FLIT_W-1:0] head_flit,
  input  logic              head_valid,
  input  logic              pop,          // head flit accepted by switch
  output logic [OUT_IW-1:0] route_o,
  output logic              bad_dst_o     // registered pulse: a header was sent to SINK
);
  logic              open_q;
  logic [OUT_IW-1:0] dst_q, hdr_sel;
  logic [3:0]        hdst;
  logic              sop, eop;

  assign sop     = head_flit[FLIT_W-1];
  assign eop     = head_flit[FLIT_W-2];
  assign hdst    = head_flit[H_DST_HI:H_DST_LO];
  assign hdr_sel = (int'(hdst) <= MEM_PORT) ? OUT_IW'(hdst) : OUT_IW'(SINK_PORT);
  assign route_o = open_q ? dst_q : hdr_sel;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      open_q    <= 1'b0;
      dst_q     <= '0;
      bad_dst_o <= 1'b0;
    end else begin
      bad_dst_o <= pop && !open_q && (hdr_sel == OUT_IW'(SINK_PORT));
      if (pop) begin
        open_q <= !eop;
        if (!open_q) dst_q <= hdr_sel;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && head_valid) begin
    assert (open_q || sop)  else $error("route_decode: non-SOP flit at head of idle input");
    assert (!open_q || !sop) else $error("route_decode: SOP flit inside open packet");
  end
`endif
endmodule
