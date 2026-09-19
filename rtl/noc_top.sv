// noc_top.sv -- 8 endpoints + 9x10 switch + memory adapter/BRAM + sink (spec v0.2)
module noc_top
  import noc_pkg::*;
#(
  parameter int FIFO_DEPTH = 16,
  parameter int MEM_AW     = 10
) (
  input  logic                          clk,
  input  logic                          rst_n,
  input  logic [N_EP-1:0][DATA_W-1:0]   tx_data,
  input  logic [N_EP-1:0]               tx_valid,
  output logic [N_EP-1:0]               tx_ready,
  input  logic [N_EP-1:0]               tx_sop,
  input  logic [N_EP-1:0]               tx_eop,
  output logic [N_EP-1:0][DATA_W-1:0]   rx_data,
  output logic [N_EP-1:0]               rx_valid,
  input  logic [N_EP-1:0]               rx_ready,
  output logic [N_EP-1:0]               rx_sop,
  output logic [N_EP-1:0]               rx_eop,
  // status counters
  output logic [31:0]                   stat_sink_pkts,     // packets dropped for illegal DST_ID
  output logic [31:0]                   stat_framing_errs,  // stray / nested-SOP flits at ingress
  output logic [31:0]                   stat_rx_pkts        // packets delivered to endpoint RX FIFOs
);
  logic [N_IN-1:0][FLIT_W-1:0]  sw_in_flit;
  logic [N_IN-1:0]              sw_in_valid, sw_in_ready, bad_dst;
  logic [N_OUT-1:0][FLIT_W-1:0] sw_out_flit;
  logic [N_OUT-1:0]             sw_out_valid, sw_out_ready;
  logic [N_EP-1:0]              framing;

  for (genvar e = 0; e < N_EP; e++) begin : g_ep
    endpoint_port #(.ID(e), .FIFO_DEPTH(FIFO_DEPTH)) u_ep (
      .clk, .rst_n,
      .tx_data(tx_data[e]), .tx_valid(tx_valid[e]), .tx_ready(tx_ready[e]),
      .tx_sop(tx_sop[e]),   .tx_eop(tx_eop[e]),
      .rx_data(rx_data[e]), .rx_valid(rx_valid[e]), .rx_ready(rx_ready[e]),
      .rx_sop(rx_sop[e]),   .rx_eop(rx_eop[e]),
      .sw_tx_flit(sw_in_flit[e]),  .sw_tx_valid(sw_in_valid[e]),  .sw_tx_ready(sw_in_ready[e]),
      .sw_rx_flit(sw_out_flit[e]), .sw_rx_valid(sw_out_valid[e]), .sw_rx_ready(sw_out_ready[e]),
      .err_framing_o(framing[e]));
  end

  noc_switch u_sw (
    .clk, .rst_n,
    .in_flit(sw_in_flit), .in_valid(sw_in_valid), .in_ready(sw_in_ready),
    .out_flit(sw_out_flit), .out_valid(sw_out_valid), .out_ready(sw_out_ready),
    .bad_dst_o(bad_dst));

  // Memory request channel is registered before the adapter. Without this the
  // adapter's decode is in the same cycle as FIFO read -> route decode ->
  // arbiter -> 9:1 mux, which cost ~9.5 ns of the failing v0.2 path on xc7z020.
  // A depth-2 FIFO is a full skid buffer: no combinational path crosses it and
  // throughput is unchanged (the adapter is one-request-at-a-time anyway).
  logic [FLIT_W-1:0] memq_flit;
  logic              memq_valid, memq_ready;
  logic [1:0]        unused_memq_cnt;

  sync_fifo #(.WIDTH(FLIT_W), .DEPTH(2)) u_mem_req_skid (
    .clk, .rst_n,
    .in_data_i (sw_out_flit[MEM_PORT]), .in_valid_i (sw_out_valid[MEM_PORT]),
    .in_ready_o(sw_out_ready[MEM_PORT]),
    .out_data_o(memq_flit), .out_valid_o(memq_valid), .out_ready_i(memq_ready),
    .count_o   (unused_memq_cnt));

  // memory
  logic              mem_we, mem_re;
  logic [MEM_AW-1:0] mem_waddr, mem_raddr;
  logic [DATA_W-1:0] mem_wdata, mem_rdata;

  memory_adapter #(.MEM_AW(MEM_AW)) u_mem (
    .clk, .rst_n,
    .in_flit(memq_flit), .in_valid(memq_valid), .in_ready(memq_ready),
    .out_flit(sw_in_flit[MEM_PORT]), .out_valid(sw_in_valid[MEM_PORT]), .out_ready(sw_in_ready[MEM_PORT]),
    .mem_we, .mem_waddr, .mem_wdata, .mem_re, .mem_raddr, .mem_rdata);

  bram_sdp #(.W(DATA_W), .AW(MEM_AW)) u_bram (
    .clk, .we(mem_we), .waddr(mem_waddr), .wdata(mem_wdata),
    .re(mem_re), .raddr(mem_raddr), .rdata(mem_rdata));

  // sink: always ready
  assign sw_out_ready[SINK_PORT] = 1'b1;

  // ---------------------------------------------------------------- counters
  // Pipelined in two stages. These are ILA/debug statistics with no functional
  // role, but in v0.2.2 the event condition fed a 32-bit increment in the same
  // cycle it was computed, putting route decode -> handshake -> 32-bit carry
  // chain on one path: that was the -3.528 ns critical path on xc7z020.
  // Stage 1 registers the event bits and their population count; stage 2 does
  // the wide add. The counts are unchanged, just two cycles later.
  logic [N_EP-1:0] rx_eop_in;
  for (genvar e = 0; e < N_EP; e++) begin : g_cnt
    assign rx_eop_in[e] = sw_out_valid[e] && sw_out_ready[e] && sw_out_flit[e][FLIT_W-2];
  end

  logic       sink_eop_q;
  logic [3:0] rx_pkts_q, framing_q, bad_dst_q;   // 0..8 fits in 4 bits

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sink_eop_q <= 1'b0; rx_pkts_q <= '0; framing_q <= '0; bad_dst_q <= '0;
    end else begin
      sink_eop_q <= sw_out_valid[SINK_PORT] && sw_out_flit[SINK_PORT][FLIT_W-2];
      rx_pkts_q  <= 4'($countones(rx_eop_in));
      framing_q  <= 4'($countones(framing));
      bad_dst_q  <= 4'($countones(bad_dst));
    end
  end

  logic [31:0] unused_bad_dst_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stat_sink_pkts <= '0; stat_framing_errs <= '0; stat_rx_pkts <= '0; unused_bad_dst_cnt <= '0;
    end else begin
      stat_sink_pkts    <= stat_sink_pkts    + 32'(sink_eop_q);
      stat_framing_errs <= stat_framing_errs + 32'(framing_q);
      stat_rx_pkts      <= stat_rx_pkts      + 32'(rx_pkts_q);
      unused_bad_dst_cnt<= unused_bad_dst_cnt+ 32'(bad_dst_q);
    end
  end
endmodule
