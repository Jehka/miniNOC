// zed_top.sv -- ZedBoard self-test wrapper for noc_top (P8)
//
// Fabric runs at 70 MHz from an MMCM off the 100 MHz board oscillator. The
// switch's arbitration loop (one input's DST_ID decides another input's ready)
// measured 73.6 MHz on xc7z020-1; see spec v0.2.3 section 12.2/12.3. 70 MHz
// closes with ~0.7 ns margin. Raising it requires credit-based flow control
// with registered ready, which is a v0.3 change, not a tuning exercise.
//
//   SW0  traffic enable          LD0  heartbeat (1 Hz)
//   SW1  random RX backpressure   LD1  PASS: running, no error, >=1024 mem cycles + traffic
//   BTNC reset                   LD2  ERROR (sticky; LD7:4 = first error code)
//                                LD3  sink/framing counter nonzero (must stay off)
//                                LD7:4 error code, or rx activity nibble when no error
module zed_top
  import noc_pkg::*;
#(
  parameter int CLK_HZ = 70_000_000        // fabric clock, after the MMCM
) (
  input  logic       GCLK,      // Y9, 100 MHz
  input  logic       BTNC,      // P16
  input  logic [7:0] SW,
  output logic [7:0] LD
);
  // ---------------- clocking: 100 MHz in -> 70 MHz fabric
  logic clk, mmcm_locked;
`ifdef SYNTHESIS
  logic clk_unbuf, fb_unbuf, fb;
  MMCME2_BASE #(
    .CLKIN1_PERIOD  (10.000),             // 100 MHz in
    .DIVCLK_DIVIDE  (1),
    .CLKFBOUT_MULT_F(7.000),              // VCO 700 MHz (600-1200 legal)
    .CLKOUT0_DIVIDE_F(10.000)             // 70 MHz out
  ) u_mmcm (
    .CLKIN1(GCLK), .CLKFBIN(fb), .CLKFBOUT(fb_unbuf),
    .CLKOUT0(clk_unbuf), .LOCKED(mmcm_locked), .RST(1'b0), .PWRDWN(1'b0),
    .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB());
  BUFG u_fb_bufg  (.I(fb_unbuf),  .O(fb));
  BUFG u_clk_bufg (.I(clk_unbuf), .O(clk));
`else
  // Simulation: no unisims. Drive the fabric from the board clock directly;
  // the self-test checks function, not frequency.
  assign clk         = GCLK;
  assign mmcm_locked = 1'b1;
`endif

  // ---------------- reset: power-on + button, synchronised release
  logic [3:0] por = '0;
  logic [2:0] btn_sync;
  logic       rst_n;
  always_ff @(posedge clk) begin
    btn_sync <= {btn_sync[1:0], BTNC};
    if (btn_sync[2] || !mmcm_locked) por <= '0;   // held in reset until locked
    else if (!(&por))                por <= por + 1;
    rst_n <= &por;
  end

  logic [1:0] sw0_s, sw1_s;
  always_ff @(posedge clk) begin sw0_s <= {sw0_s[0], SW[0]}; sw1_s <= {sw1_s[0], SW[1]}; end

  // ---------------- DUT
  (* mark_debug = "true" *) logic [N_EP-1:0]  tx_valid, tx_ready, tx_sop, tx_eop;
  (* mark_debug = "true" *) logic [N_EP-1:0]  rx_valid, rx_ready, rx_sop, rx_eop;
  logic [N_EP-1:0][DATA_W-1:0] tx_data, rx_data;
  (* mark_debug = "true" *) logic [31:0] stat_sink_pkts, stat_framing_errs, stat_rx_pkts;

  noc_top #(.FIFO_DEPTH(16), .MEM_AW(10)) u_noc (
    .clk(clk), .rst_n,
    .tx_data, .tx_valid, .tx_ready, .tx_sop, .tx_eop,
    .rx_data, .rx_valid, .rx_ready, .rx_sop, .rx_eop,
    .stat_sink_pkts, .stat_framing_errs, .stat_rx_pkts);

  // ---------------- traffic
  logic [N_EP-1:0]        ep_err;
  logic [N_EP-1:0][3:0]   ep_code;
  logic [N_EP-1:0][31:0]  ep_rx, ep_mem;

  for (genvar e = 0; e < N_EP; e++) begin : g_tr
    ep_traffic #(.ID(e), .SEED(32'hC0FF_EE00 + 32'(e * 7919))) u_tr (
      .clk(clk), .rst_n, .enable(sw0_s[1]), .rx_stall_en(sw1_s[1]),
      .tx_data(tx_data[e]), .tx_valid(tx_valid[e]), .tx_ready(tx_ready[e]),
      .tx_sop(tx_sop[e]),   .tx_eop(tx_eop[e]),
      .rx_data(rx_data[e]), .rx_valid(rx_valid[e]), .rx_ready(rx_ready[e]),
      .rx_sop(rx_sop[e]),   .rx_eop(rx_eop[e]),
      .err_o(ep_err[e]), .err_code_o(ep_code[e]), .rx_pkts_o(ep_rx[e]), .mem_cycles_o(ep_mem[e]));
  end

  // ---------------- status
  (* mark_debug = "true" *) logic any_err;
  logic [3:0]  first_code;
  localparam int HB_HALF = CLK_HZ / 2 - 1;      // 1 Hz LED regardless of CLK_HZ
  logic [26:0] hb;
  logic        mem_ok, traffic_ok;

  always_comb begin
    any_err = |ep_err; first_code = '0;
    for (int e = N_EP - 1; e >= 0; e--) if (ep_err[e]) first_code = ep_code[e];
  end

  always_ff @(posedge clk) begin
    hb         <= (hb == 27'(HB_HALF)) ? '0 : hb + 1;
    mem_ok     <= ep_mem[0] >= 1024 && ep_mem[7] >= 1024;
    traffic_ok <= stat_rx_pkts >= 32'd100_000;
    LD[0] <= (hb == 0) ? ~LD[0] : LD[0];
    LD[1] <= !any_err && mem_ok && traffic_ok;
    LD[2] <= any_err;
    LD[3] <= (stat_sink_pkts != 0) || (stat_framing_errs != 0);
    LD[7:4] <= any_err ? first_code : stat_rx_pkts[23:20];
  end
endmodule
