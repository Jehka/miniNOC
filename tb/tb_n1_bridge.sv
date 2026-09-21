// tb_n1_bridge.sv -- stage N1: PS-side register access through the NoC, under load
//
// An AXI4-Lite master stands in for the Zynq PS and drives endpoint 0 while
// endpoints 1-7 run their generators with randomized RX backpressure. Every
// check is on data that crossed the fabric while it was contended.
`timescale 1ns/1ps
module tb_n1_bridge;
  import noc_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [7:0]  awaddr = 0, araddr = 0;
  logic        awvalid = 0, wvalid = 0, arvalid = 0, bready = 1, rready = 1;
  logic [31:0] wdata = 0;
  logic [3:0]  wstrb = 4'hF;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;
  logic [31:0] rdata;
  logic [1:0]  sw = 2'b11;          // generators on, random RX backpressure on
  logic [7:0]  led;
  int errors = 0;

  n1_top dut (
    .clk, .rst_n,
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .sw, .led);

  localparam logic [7:0] ID = 8'h00, STATUS = 8'h04, TX_LO = 8'h08, TX_HI = 8'h0C,
                         TX_PUSH = 8'h10, RX_LO = 8'h14, RX_HI = 8'h18, RX_POP = 8'h1C,
                         TX_COUNT = 8'h20, RX_COUNT = 8'h24, TX_DROP = 8'h28;

  // ------------------------------------------------------------ AXI-Lite master
  task automatic axi_write(input logic [7:0] a, input logic [31:0] d);
    @(negedge clk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1; #1;
    while (!awready) begin @(negedge clk); #1; end
    @(posedge clk); #1; awvalid = 0; wvalid = 0;
    while (!bvalid) begin @(posedge clk); #1; end
    if (bresp != 2'b00) begin $display("ERROR: bresp %0d", bresp); errors++; end
  endtask

  task automatic axi_read(input logic [7:0] a, output logic [31:0] d);
    @(negedge clk); araddr = a; arvalid = 1; #1;
    while (!arready) begin @(negedge clk); #1; end
    @(posedge clk); #1; arvalid = 0;
    while (!rvalid) begin @(posedge clk); #1; end
    d = rdata;
  endtask

  // ------------------------------------------------------------ flit helpers (what the C driver does)
  task automatic send_flit(input bit sop, input bit eop, input logic [63:0] w);
    logic [31:0] st;
    do axi_read(STATUS, st); while (!st[0]);
    axi_write(TX_LO, w[31:0]);
    axi_write(TX_HI, w[63:32]);
    axi_write(TX_PUSH, {30'b0, eop, sop});
  endtask

  task automatic recv_flit(output bit sop, output bit eop, output logic [63:0] w);
    logic [31:0] st, lo, hi;
    int spins = 0;
    do begin axi_read(STATUS, st); spins++; end while (!st[1] && spins < 20000);
    if (!st[1]) begin $display("ERROR: timeout waiting for rx"); errors++; sop = 0; eop = 1; w = '0; return; end
    axi_read(RX_LO, lo);
    axi_read(RX_HI, hi);
    axi_write(RX_POP, 32'h1);
    sop = st[2]; eop = st[3]; w = {hi, lo};
  endtask

  // send a whole packet: header + payload words
  task automatic send_pkt(input logic [63:0] h, input logic [63:0] pay [$]);
    int n = pay.size();
    send_flit(1'b1, n == 0, h);
    for (int k = 0; k < n; k++) send_flit(1'b0, k == n - 1, pay[k]);
  endtask

  // receive a whole packet into q (header first)
  task automatic recv_pkt(output logic [63:0] q [$]);
    bit sop, eop; logic [63:0] w;
    q.delete();
    recv_flit(sop, eop, w);
    if (!sop) begin $display("ERROR: first received flit has no SOP"); errors++; end
    q.push_back(w);
    while (!eop) begin
      recv_flit(sop, eop, w);
      if (sop) begin $display("ERROR: SOP inside packet"); errors++; end
      q.push_back(w);
    end
  endtask

  function automatic void check(string what, logic [63:0] got, logic [63:0] exp);
    if (got !== exp) begin $display("ERROR: %s got %h exp %h", what, got, exp); errors++; end
    else $display("  ok  %-34s %h", what, got);
  endfunction

  // ------------------------------------------------------------ test
  initial begin
    logic [31:0] r;
    logic [63:0] q [$];
    logic [63:0] pay [$];

    repeat (5) @(negedge clk); rst_n = 1;
    repeat (20) @(negedge clk);

    // 1. identity
    axi_read(ID, r);
    check("ID register", 64'(r), 64'h4E4F4332);

    // let generators get the fabric busy first
    repeat (2000) @(negedge clk);

    // 2. DATA loopback to self through the crossbar
    pay.delete(); pay.push_back(64'h1111_2222_3333_4444); pay.push_back(64'hAAAA_BBBB_CCCC_DDDD);
    pay.push_back(64'h0123_4567_89AB_CDEF);
    send_pkt(mk_hdr(T_DATA, 4'd9, 4'd0, 16'd3, 8'h5A, 4'h0), pay);   // SRC 9 is junk: must be stamped to 0
    recv_pkt(q);
    check("loopback header (SRC stamped 0)", q[0], mk_hdr(T_DATA, 4'd0, 4'd0, 16'd3, 8'h5A, 4'h0));
    if (q.size() != 4) begin $display("ERROR: loopback size %0d", q.size()); errors++; end
    else for (int k = 0; k < 3; k++) check($sformatf("loopback payload %0d", k), q[k+1], pay[k]);

    // 3. memory write then read back, above the generators' region
    pay.delete(); pay.push_back(64'h1000);                       // byte addr 0x1000 = word 512
    for (int k = 0; k < 4; k++) pay.push_back(64'hCAFE_0000_0000_0000 | 64'(k));
    send_pkt(mk_hdr(T_MEM_WRITE_REQ, 4'd0, 4'd8, 16'd5, 8'h21, 4'h0), pay);
    recv_pkt(q);
    check("WRITE_RESP", q[0], mk_hdr(T_MEM_WRITE_RESP, 4'd8, 4'd0, 16'd0, 8'h21, 4'h0));

    pay.delete(); pay.push_back(64'h1000); pay.push_back(64'd4);
    send_pkt(mk_hdr(T_MEM_READ_REQ, 4'd0, 4'd8, 16'd2, 8'h22, 4'h0), pay);
    recv_pkt(q);
    check("READ_RESP header", q[0], mk_hdr(T_MEM_READ_RESP, 4'd8, 4'd0, 16'd4, 8'h22, 4'h0));
    if (q.size() != 5) begin $display("ERROR: read size %0d", q.size()); errors++; end
    else for (int k = 0; k < 4; k++)
      check($sformatf("read-back word %0d", k), q[k+1], 64'hCAFE_0000_0000_0000 | 64'(k));

    // 4. error path from the PS: misaligned address
    pay.delete(); pay.push_back(64'h1003); pay.push_back(64'd1);
    send_pkt(mk_hdr(T_MEM_READ_REQ, 4'd0, 4'd8, 16'd2, 8'h23, 4'h0), pay);
    recv_pkt(q);
    check("E_ALIGN error response", q[0], mk_hdr(T_ERROR, 4'd8, 4'd0, 16'd0, 8'h23, E_ALIGN));

    // 5. counters
    axi_read(TX_DROP, r);  check("TX_DROP", 64'(r), 64'd0);
    axi_read(TX_COUNT, r); check("TX_COUNT (4+6+3+3 flits)", 64'(r), 64'd16);
    axi_read(RX_COUNT, r); check("RX_COUNT (4+1+5+1 flits)", 64'(r), 64'd11);

    // 6. the generators were busy the whole time and stayed clean
    repeat (500) @(negedge clk);
    if (led[2]) begin $display("ERROR: generator error, code %0d", led[7:4]); errors++; end
    else $display("  ok  generators clean under concurrent PS traffic");
    begin
      int total_rx = 0, total_mem = 0;
      for (int e = 1; e < N_EP; e++) begin total_rx += dut.ep_rx[e]; total_mem += dut.ep_mem[e]; end
      $display("  info generators: %0d packets received, %0d memory cycles, at t=%0t", total_rx, total_mem, $time);
      if (total_rx == 0) begin $display("ERROR: generators made no progress"); errors++; end
    end

    if (errors == 0) $display("PASS tb_n1_bridge");
    else             $display("FAIL tb_n1_bridge errors=%0d", errors);
    $finish;
  end

  initial begin #20ms; $display("FAIL tb_n1_bridge timeout"); $finish; end
endmodule
