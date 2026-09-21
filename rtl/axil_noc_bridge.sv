// axil_noc_bridge.sv -- AXI4-Lite slave <-> NoC endpoint (network stage N1)
//
// Lets the Zynq PS inject and receive flits through one endpoint by register
// access. A flit is 64 bits of data plus SOP/EOP, so a push is three writes
// (TX_LO, TX_HI, TX_PUSH) and a receive is three accesses (RX_LO, RX_HI, RX_POP).
// Deliberately simple: this proves the PS<->fabric path before any network
// exists. Throughput is bounded by MMIO; AXI-DMA replaces it in stage N7.
//
// Register map (32-bit, byte offsets). WSTRB is ignored: full-word writes only.
//   0x00 ID        RO  0x4E4F4331 ("NOC1")
//   0x04 STATUS    RO  [0] tx_space  [1] rx_avail  [2] rx_sop  [3] rx_eop
//                      [15:8] rx_count  [23:16] tx_count  (FIFO occupancy, saturating at 255)
//   0x08 TX_LO     RW  staged flit bits [31:0]
//   0x0C TX_HI     RW  staged flit bits [63:32]
//   0x10 TX_PUSH   WO  [0] sop [1] eop [2] route_by_ip -> push {sop,eop,TX_HI,TX_LO};
//                      dropped + counted in TX_DROP if full
//   0x14 RX_LO     RO  head flit bits [31:0]   (no side effect)
//   0x18 RX_HI     RO  head flit bits [63:32]  (no side effect)
//   0x1C RX_POP    WO  any value -> discard head flit if one is present
//   0x20 TX_COUNT  RO  flits pushed into the fabric
//   0x24 RX_COUNT  RO  flits popped by software
//   0x28 TX_DROP   RO  pushes rejected because the TX FIFO was full
//
// Forwarding table (N4). The table maps IPv4 addresses to DST_IDs.
//   0x2C FWD_MISS      RO  packets dropped because their destination IP missed
//   0x30 FWD_IDX       RW  [3:0] entry to write or read back
//   0x34 FWD_IP        RW  staged IPv4 address for the next commit
//   0x38 FWD_CTRL      WO  [0] commit, [1] valid, [11:8] dst_id -> entry[FWD_IDX]
//   0x3C FWD_ENT_IP    RO  IPv4 address held in entry[FWD_IDX]
//   0x40 FWD_ENT_INFO  RO  [31] valid  [20:16] valid-entry count  [3:0] dst_id
//   0x44 FWD_PROBE_IP  RW  address to look up (does not touch traffic)
//   0x48 FWD_PROBE_RES RO  [31] hit  [3:0] dst_id
//   0x4C TX_DST_IP     RW  destination address for route-by-IP pushes
//   0x50 RX_SRC_IP     RO  address mapped to the head packet's SRC_ID (valid on SOP)
//   0x54 RX_SRC_INFO   RO  [31] reverse-lookup hit  [3:0] head packet's SRC_ID
//
// Route by IP: a TX_PUSH with [2] set on a SOP flit looks up TX_DST_IP and
// rewrites the header's DST_ID with the result. On a miss the whole packet is
// discarded (this flit and every body flit until EOP) and FWD_MISS counts it
// once. Software pushes the packet the same way whether it hits or misses.
//
// Software must check STATUS.tx_space before TX_PUSH and STATUS.rx_avail before
// reading RX_LO/HI. Reading RX_* while empty returns stale data, not an error.
module axil_noc_bridge
  import noc_pkg::*;
#(
  parameter int FIFO_DEPTH = 64
) (
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite slave (names follow Vivado's interface inference)
  input  logic [7:0]        s_axi_awaddr,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [31:0]       s_axi_wdata,
  input  logic [3:0]        s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,
  input  logic [7:0]        s_axi_araddr,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [31:0]       s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,
  // NoC endpoint (connects to one endpoint's user-side tx/rx)
  output logic [DATA_W-1:0] tx_data,
  output logic              tx_valid,
  input  logic              tx_ready,
  output logic              tx_sop,
  output logic              tx_eop,
  input  logic [DATA_W-1:0] rx_data,
  input  logic              rx_valid,
  output logic              rx_ready,
  input  logic              rx_sop,
  input  logic              rx_eop
);
  localparam int AW = $clog2(FIFO_DEPTH);
  localparam logic [31:0] ID_VALUE = 32'h4E4F_4332;   // "NOC1"

  localparam logic [7:0] R_ID = 8'h00, R_STATUS = 8'h04, R_TX_LO = 8'h08, R_TX_HI = 8'h0C,
                         R_TX_PUSH = 8'h10, R_RX_LO = 8'h14, R_RX_HI = 8'h18, R_RX_POP = 8'h1C,
                         R_TX_COUNT = 8'h20, R_RX_COUNT = 8'h24, R_TX_DROP = 8'h28,
                         R_FWD_MISS = 8'h2C, R_FWD_IDX = 8'h30, R_FWD_IP = 8'h34,
                         R_FWD_CTRL = 8'h38, R_FWD_ENT_IP = 8'h3C, R_FWD_ENT_INFO = 8'h40,
                         R_FWD_PROBE_IP = 8'h44, R_FWD_PROBE_RES = 8'h48,
                         R_TX_DST_IP = 8'h4C, R_RX_SRC_IP = 8'h50, R_RX_SRC_INFO = 8'h54;

  // ------------------------------------------------------------ FIFOs
  logic [FLIT_W-1:0] txf_in, txf_out, rxf_out;
  logic              txf_push, txf_space, txf_valid;
  logic              rxf_valid, rxf_pop;
  logic [AW:0]       txf_cnt, rxf_cnt;

  sync_fifo #(.WIDTH(FLIT_W), .DEPTH(FIFO_DEPTH)) u_txf (
    .clk, .rst_n,
    .in_data_i (txf_in),  .in_valid_i (txf_push), .in_ready_o (txf_space),
    .out_data_o(txf_out), .out_valid_o(txf_valid), .out_ready_i(tx_ready),
    .count_o   (txf_cnt));

  sync_fifo #(.WIDTH(FLIT_W), .DEPTH(FIFO_DEPTH)) u_rxf (
    .clk, .rst_n,
    .in_data_i ({rx_sop, rx_eop, rx_data}), .in_valid_i(rx_valid), .in_ready_o(rx_ready),
    .out_data_o(rxf_out), .out_valid_o(rxf_valid), .out_ready_i(rxf_pop),
    .count_o   (rxf_cnt));

  assign tx_valid = txf_valid;
  assign tx_sop   = txf_out[FLIT_W-1];
  assign tx_eop   = txf_out[FLIT_W-2];
  assign tx_data  = txf_out[DATA_W-1:0];

  // ------------------------------------------------------------ write channel
  // Accept address and data together; one outstanding write.
  logic [31:0] tx_lo, tx_hi, tx_count, rx_count, tx_drop;
  logic        wr_fire;
  logic [7:0]  wr_addr;

  assign s_axi_awready = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
  assign s_axi_wready  = s_axi_awready;
  assign wr_fire       = s_axi_awready;
  assign wr_addr       = {s_axi_awaddr[7:2], 2'b00};
  assign s_axi_bresp   = 2'b00;

  // ------------------------------------------------------------ forwarding table
  logic [3:0]  fwd_idx, fwd_dst_a, fwd_dst_b, fwd_rd_dst, rx_src_id;
  logic [31:0] fwd_ip, fwd_probe_ip, tx_dst_ip, fwd_miss, fwd_rv_ip, fwd_rd_ip;
  logic        fwd_hit_a, fwd_hit_b, fwd_rv_hit, fwd_rd_valid;
  logic [4:0]  fwd_n_valid;

  assign rx_src_id = rxf_out[59:56];               // SRC_ID of the head flit if it is a header

  fwd_table #(.N(16)) u_fwd (
    .clk, .rst_n,
    .wr_en   (wr_fire && (wr_addr == R_FWD_CTRL) && s_axi_wdata[0]),
    .wr_idx  (fwd_idx), .wr_valid(s_axi_wdata[1]), .wr_ip(fwd_ip), .wr_dst(s_axi_wdata[11:8]),
    .fa_ip   (tx_dst_ip),    .fa_hit(fwd_hit_a), .fa_dst(fwd_dst_a),
    .fb_ip   (fwd_probe_ip), .fb_hit(fwd_hit_b), .fb_dst(fwd_dst_b),
    .rv_dst  (rx_src_id),    .rv_hit(fwd_rv_hit), .rv_ip(fwd_rv_ip),
    .rd_idx  (fwd_idx), .rd_valid(fwd_rd_valid), .rd_ip(fwd_rd_ip), .rd_dst(fwd_rd_dst),
    .n_valid (fwd_n_valid));

  // ------------------------------------------------------------ push path
  logic push_sop, push_eop, push_route, push_wr, miss_now, drop_this, dropping;
  logic [63:0] push_word;

  assign push_wr    = wr_fire && (wr_addr == R_TX_PUSH);
  assign push_sop   = s_axi_wdata[0];
  assign push_eop   = s_axi_wdata[1];
  assign push_route = s_axi_wdata[2] && push_sop;
  assign miss_now   = push_route && !fwd_hit_a;
  // A missed packet is discarded through its EOP. A new SOP ends a discard even
  // if software never sent the EOP, so one malformed packet cannot eat the next.
  assign drop_this  = miss_now || (dropping && !push_sop);
  // Route by IP rewrites DST_ID, header bits [55:52] = TX_HI[23:20].
  assign push_word  = push_route ? {tx_hi[31:24], fwd_dst_a, tx_hi[19:0], tx_lo} : {tx_hi, tx_lo};

  assign txf_in   = {push_sop, push_eop, push_word};
  assign txf_push = push_wr && !drop_this && txf_space;
  assign rxf_pop  = wr_fire && (wr_addr == R_RX_POP)  && rxf_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_bvalid <= 1'b0;
      tx_lo <= '0; tx_hi <= '0; tx_count <= '0; rx_count <= '0; tx_drop <= '0;
      fwd_idx <= '0; fwd_ip <= '0; fwd_probe_ip <= '0; tx_dst_ip <= '0;
      fwd_miss <= '0; dropping <= 1'b0;
    end else begin
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
      if (wr_fire) begin
        s_axi_bvalid <= 1'b1;
        unique case (wr_addr)
          R_TX_LO:        tx_lo <= s_axi_wdata;
          R_TX_HI:        tx_hi <= s_axi_wdata;
          R_TX_PUSH: begin
            if (drop_this) begin
              if (miss_now) fwd_miss <= fwd_miss + 1;      // once per packet, at its SOP
              dropping <= !push_eop;
            end else begin
              dropping <= 1'b0;
              if (txf_space) tx_count <= tx_count + 1; else tx_drop <= tx_drop + 1;
            end
          end
          R_RX_POP:       if (rxf_valid) rx_count <= rx_count + 1;
          R_FWD_IDX:      fwd_idx      <= s_axi_wdata[3:0];
          R_FWD_IP:       fwd_ip       <= s_axi_wdata;
          R_FWD_PROBE_IP: fwd_probe_ip <= s_axi_wdata;
          R_TX_DST_IP:    tx_dst_ip    <= s_axi_wdata;
          default: ;                                   // FWD_CTRL handled by u_fwd; RO ignored
        endcase
      end
    end
  end

  // ------------------------------------------------------------ read channel
  logic [7:0] rd_addr;
  logic [7:0] sat_rx, sat_tx;
  assign rd_addr       = {s_axi_araddr[7:2], 2'b00};
  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rresp   = 2'b00;
  assign sat_rx = (32'(rxf_cnt) > 32'd255) ? 8'hFF : 8'(rxf_cnt);
  assign sat_tx = (32'(txf_cnt) > 32'd255) ? 8'hFF : 8'(txf_cnt);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
    end else begin
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid <= 1'b1;
        unique case (rd_addr)
          R_ID:       s_axi_rdata <= ID_VALUE;
          R_STATUS:   s_axi_rdata <= {8'h00, sat_tx, sat_rx,
                                      4'h0, rxf_out[FLIT_W-2], rxf_out[FLIT_W-1] & rxf_valid,
                                      rxf_valid, txf_space};
          R_TX_LO:    s_axi_rdata <= tx_lo;
          R_TX_HI:    s_axi_rdata <= tx_hi;
          R_RX_LO:    s_axi_rdata <= rxf_out[31:0];
          R_RX_HI:    s_axi_rdata <= rxf_out[63:32];
          R_TX_COUNT: s_axi_rdata <= tx_count;
          R_RX_COUNT: s_axi_rdata <= rx_count;
          R_TX_DROP:  s_axi_rdata <= tx_drop;
          R_FWD_MISS:      s_axi_rdata <= fwd_miss;
          R_FWD_IDX:       s_axi_rdata <= {28'h0, fwd_idx};
          R_FWD_IP:        s_axi_rdata <= fwd_ip;
          R_FWD_ENT_IP:    s_axi_rdata <= fwd_rd_ip;
          R_FWD_ENT_INFO:  s_axi_rdata <= {fwd_rd_valid, 10'h0, fwd_n_valid, 12'h0, fwd_rd_dst};
          R_FWD_PROBE_IP:  s_axi_rdata <= fwd_probe_ip;
          R_FWD_PROBE_RES: s_axi_rdata <= {fwd_hit_b, 27'h0, fwd_dst_b};
          R_TX_DST_IP:     s_axi_rdata <= tx_dst_ip;
          R_RX_SRC_IP:     s_axi_rdata <= fwd_rv_ip;
          R_RX_SRC_INFO:   s_axi_rdata <= {fwd_rv_hit, 27'h0, rx_src_id};
          default:    s_axi_rdata <= 32'hDEAD_BEEF;
        endcase
      end
    end
  end

  logic [7:0] unused_bits;
  assign unused_bits = {s_axi_wstrb, s_axi_awaddr[1:0], s_axi_araddr[1:0]};
endmodule