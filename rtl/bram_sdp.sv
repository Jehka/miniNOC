// bram_sdp.sv -- simple dual-port RAM, registered read, read holds when re=0.
// Written for Vivado block-RAM inference.
module bram_sdp #(
  parameter int W  = 64,
  parameter int AW = 10
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] waddr,
  input  logic [W-1:0]  wdata,
  input  logic          re,
  input  logic [AW-1:0] raddr,
  output logic [W-1:0]  rdata
);
  (* ram_style = "block" *) logic [W-1:0] mem [2**AW];

  initial begin
    for (int i = 0; i < 2**AW; i++) mem[i] = '0;
    rdata = '0;
  end

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    if (re) rdata      <= mem[raddr];
  end
endmodule
