// sync_fifo.sv -- lossless ready/valid FIFO, first-word-fall-through.
//
// * Head flit is visible on out_data_o whenever out_valid_o = 1 (needed so the
//   switch can decode the header without popping it).
// * in_ready_o = !full. It does NOT depend on out_ready_i, so there is no
//   combinational path from the consumer back to the producer. Cost: a full
//   FIFO cannot accept on the same edge it is popped (one cycle of latency at
//   full). Revisit if throughput tests say so.
// * DEPTH must be a power of two. Storage is an unregistered-read array,
//   which Vivado maps to LUTRAM at DEPTH=16, WIDTH=66.
module sync_fifo #(
  parameter int WIDTH = 66,
  parameter int DEPTH = 16,
  localparam int AW   = $clog2(DEPTH)
) (
  input  logic             clk,
  input  logic             rst_n,
  // write side
  input  logic [WIDTH-1:0] in_data_i,
  input  logic             in_valid_i,
  output logic             in_ready_o,
  // read side
  output logic [WIDTH-1:0] out_data_o,
  output logic             out_valid_o,
  input  logic             out_ready_i,
  // status
  output logic [AW:0]      count_o
);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW:0]      wptr, rptr;       // extra MSB distinguishes full from empty
  logic             full, empty, push, pop;

  assign empty       = (wptr == rptr);
  assign full        = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
  assign in_ready_o  = !full;
  assign out_valid_o = !empty;
  assign out_data_o  = mem[rptr[AW-1:0]];
  assign push        = in_valid_i  && in_ready_o;
  assign pop         = out_valid_o && out_ready_i;
  assign count_o     = wptr - rptr;

  always_ff @(posedge clk) begin
    if (push) mem[wptr[AW-1:0]] <= in_data_i;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end else begin
      if (push) wptr <= wptr + 1'b1;
      if (pop)  rptr <= rptr + 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial assert ((DEPTH & (DEPTH-1)) == 0 && DEPTH >= 2) else $fatal(1, "sync_fifo: DEPTH must be pow2 >= 2");
  always_ff @(posedge clk) if (rst_n) begin
    assert (count_o <= (AW+1)'(DEPTH)) else $error("sync_fifo: count overflow");
    assert (!(push && full))           else $error("sync_fifo: push while full");
    assert (!(pop && empty))           else $error("sync_fifo: pop while empty");
  end
`endif
endmodule
