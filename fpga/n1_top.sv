// n1_top.sv -- network stage N1: PS drives endpoint 0 over AXI4-Lite
//
// Endpoint 0 is the axil_noc_bridge, driven by the Zynq PS. Endpoints 1-7 keep
// their on-chip traffic generators and checkers, so every bridge transaction
// crosses a fabric under live contention rather than an idle one. Generators
// never address endpoint 0 (AVOID_EP0), and software must not send DATA to
// endpoints 1-7, whose checkers expect the generator protocol. Memory is shared:
// generators use words 32*ID .. 32*ID+3, so software should stay at or above
// word 512 (byte 0x1000).
//
// Used as a module reference in a block design: clk and rst_n come from the
// PS (FCLK_CLK0, FCLK_RESET0_N); s_axi connects to M_AXI_GP0 via an interconnect.
module n1_top
  import noc_pkg::*;
(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET rst_n" *)
  input  logic        clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  logic        rst_n,

  input  logic [7:0]  s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [7:0]  s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  input  logic [1:0]  sw,            // [0] generator enable, [1] random RX backpressure
  output logic [7:0]  led
);
  // PS reset is asynchronous to FCLK in general; synchronise the release.
  logic [2:0] rst_sync;
  logic       rst_n_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= '0;
    else        rst_sync <= {rst_sync[1:0], 1'b1};
  end
  assign rst_n_s = rst_sync[2];

  logic [1:0] sw0_s, sw1_s;
  always_ff @(posedge clk) begin sw0_s <= {sw0_s[0], sw[0]}; sw1_s <= {sw1_s[0], sw[1]}; end

  logic [N_EP-1:0][DATA_W-1:0] tx_data, rx_data;
  logic [N_EP-1:0] tx_valid, tx_ready, tx_sop, tx_eop;
  logic [N_EP-1:0] rx_valid, rx_ready, rx_sop, rx_eop;
  logic [31:0]     stat_sink_pkts, stat_framing_errs, stat_rx_pkts;

  noc_top #(.FIFO_DEPTH(16), .MEM_AW(10)) u_noc (
    .clk, .rst_n(rst_n_s),
    .tx_data, .tx_valid, .tx_ready, .tx_sop, .tx_eop,
    .rx_data, .rx_valid, .rx_ready, .rx_sop, .rx_eop,
    .stat_sink_pkts, .stat_framing_errs, .stat_rx_pkts);

  // endpoint 0: the PS
  axil_noc_bridge #(.FIFO_DEPTH(64)) u_bridge (
    .clk, .rst_n(rst_n_s),
    .s_axi_awaddr, .s_axi_awvalid, .s_axi_awready,
    .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
    .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
    .s_axi_araddr, .s_axi_arvalid, .s_axi_arready,
    .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .tx_data(tx_data[0]), .tx_valid(tx_valid[0]), .tx_ready(tx_ready[0]),
    .tx_sop(tx_sop[0]),   .tx_eop(tx_eop[0]),
    .rx_data(rx_data[0]), .rx_valid(rx_valid[0]), .rx_ready(rx_ready[0]),
    .rx_sop(rx_sop[0]),   .rx_eop(rx_eop[0]));

  // endpoints 1-7: on-chip traffic
  logic [N_EP-1:0]       ep_err;
  logic [N_EP-1:0][3:0]  ep_code;
  logic [N_EP-1:0][31:0] ep_rx, ep_mem;
  assign ep_err[0] = 1'b0; assign ep_code[0] = '0; assign ep_rx[0] = '0; assign ep_mem[0] = '0;

  for (genvar e = 1; e < N_EP; e++) begin : g_tr
    ep_traffic #(.ID(e), .SEED(32'hC0FF_EE00 + 32'(e * 7919)), .AVOID_EP0(1'b1)) u_tr (
      .clk, .rst_n(rst_n_s), .enable(sw0_s[1]), .rx_stall_en(sw1_s[1]),
      .tx_data(tx_data[e]), .tx_valid(tx_valid[e]), .tx_ready(tx_ready[e]),
      .tx_sop(tx_sop[e]),   .tx_eop(tx_eop[e]),
      .rx_data(rx_data[e]), .rx_valid(rx_valid[e]), .rx_ready(rx_ready[e]),
      .rx_sop(rx_sop[e]),   .rx_eop(rx_eop[e]),
      .err_o(ep_err[e]), .err_code_o(ep_code[e]), .rx_pkts_o(ep_rx[e]), .mem_cycles_o(ep_mem[e]));
  end

  // LEDs: [0] alive  [1] generators clean  [2] generator error  [3] sink/framing moved
  //       [7:4] first error code, or activity nibble
  logic        any_err;
  logic [3:0]  first_code;
  logic [25:0] hb;
  always_comb begin
    any_err = |ep_err; first_code = '0;
    for (int e = N_EP - 1; e >= 1; e--) if (ep_err[e]) first_code = ep_code[e];
  end
  always_ff @(posedge clk) begin
    hb     <= hb + 1;
    led[0] <= hb[25];
    led[1] <= !any_err && (ep_mem[1] >= 32'd64);
    led[2] <= any_err;
    led[3] <= (stat_sink_pkts != 0) || (stat_framing_errs != 0);
    led[7:4] <= any_err ? first_code : stat_rx_pkts[23:20];
  end

  logic [31:0] unused_rx;
  assign unused_rx = ep_rx[1];
endmodule
