// ep_traffic.sv -- synthesizable traffic generator + checker for one endpoint (P8 self-test)
//
// Generator: LFSR-driven DATA packets to any endpoint (length 0..31), plus a
// memory cycle every so often: WRITE 4 words to this endpoint's private
// region, wait WRITE_RESP, READ them back, wait READ_RESP.
// Checker:   per-source 8-bit sequence (carried in TAG) -> ordering,
//            payload pattern + length/EOP -> integrity, READ_RESP data -> memory.
// Any violation sets err_o (sticky) and records the first cause in err_code_o.
module ep_traffic
  import noc_pkg::*;
#(
  parameter int          ID   = 0,
  parameter logic [31:0] SEED = 32'hACE1_0001,
  // N1: endpoint 0 is the PS bridge, which does not run this checker's protocol,
  // so generators must not send DATA to it. Remaps destination 0 to 1.
  parameter bit          AVOID_EP0 = 1'b0
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              enable,
  input  logic              rx_stall_en,
  // endpoint TX
  output logic [DATA_W-1:0] tx_data,
  output logic              tx_valid,
  input  logic              tx_ready,
  output logic              tx_sop,
  output logic              tx_eop,
  // endpoint RX
  input  logic [DATA_W-1:0] rx_data,
  input  logic              rx_valid,
  output logic              rx_ready,
  input  logic              rx_sop,
  input  logic              rx_eop,
  // status
  output logic              err_o,
  output logic [3:0]        err_code_o,
  output logic [31:0]       rx_pkts_o,
  output logic [31:0]       mem_cycles_o
);
  localparam int MEM_WORDS_PER_EP = 4;

  // payload patterns (shared by generator and checker)
  function automatic logic [63:0] data_pat(logic [3:0] s, logic [3:0] d, logic [7:0] tag, logic [15:0] k);
    return {8'hA5, s, d, tag, 8'h00, k, k ^ 16'hBEEF};
  endfunction
  function automatic logic [63:0] mem_pat(logic [3:0] s, logic [15:0] epoch, logic [15:0] k);
    return {8'h3C, s, 4'h0, epoch, k, ~k};
  endfunction

  // ---------------------------------------------------------------- LFSR
  logic [31:0] lfsr;
  always_ff @(posedge clk) begin
    if (!rst_n) lfsr <= SEED ^ {ID[7:0], 24'h5A5A5A};
    else        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
  end

  // ---------------------------------------------------------------- generator
  typedef enum logic [2:0] {G_IDLE, G_HDR, G_PAY, G_WAIT_WR, G_WAIT_RD} gstate_e;
  typedef enum logic [1:0] {K_DATA, K_WRITE, K_READ} kind_e;
  gstate_e gst;
  kind_e   kind;
  logic [3:0]        g_dst;
  logic [15:0]       g_len, g_k, epoch;
  logic [7:0]        seq [N_EP];
  logic              wr_done, rd_done;   // pulses from checker
  logic [23:0]       wd;                 // response watchdog

  logic [63:0] g_addr;
  assign g_addr = 64'(ID * 32) << 3;     // word ID*32, byte address

  always_comb begin
    tx_valid = (gst == G_HDR) || (gst == G_PAY);
    tx_sop   = (gst == G_HDR);
    tx_eop   = (gst == G_HDR) ? (g_len == 0) : (g_k == g_len - 1);
    tx_data  = '0;
    if (gst == G_HDR) begin
      unique case (kind)
        K_DATA:  tx_data = mk_hdr(T_DATA,          4'(ID), g_dst,       g_len, seq[g_dst[2:0]], 4'h0);
        K_WRITE: tx_data = mk_hdr(T_MEM_WRITE_REQ, 4'(ID), 4'(MEM_PORT), g_len, 8'(epoch),       4'h0);
        default: tx_data = mk_hdr(T_MEM_READ_REQ,  4'(ID), 4'(MEM_PORT), g_len, 8'(epoch),       4'h0);
      endcase
    end else begin
      unique case (kind)
        K_DATA:  tx_data = data_pat(4'(ID), g_dst, seq[g_dst[2:0]], g_k);
        K_WRITE: tx_data = (g_k == 0) ? g_addr : mem_pat(4'(ID), epoch, g_k - 1);
        default: tx_data = (g_k == 0) ? g_addr : 64'(MEM_WORDS_PER_EP);
      endcase
    end
  end

  logic wd_err;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gst <= G_IDLE; kind <= K_DATA; g_dst <= '0; g_len <= '0; g_k <= '0; epoch <= '0; wd <= '0; wd_err <= 1'b0;
      foreach (seq[i]) seq[i] <= '0;
    end else begin
      wd_err <= 1'b0;
      unique case (gst)
        G_IDLE: if (enable) begin
          g_k <= '0;
          if (lfsr[4:0] == 5'd0) begin
            kind <= K_WRITE; g_len <= 16'(1 + MEM_WORDS_PER_EP);
          end else begin
            kind  <= K_DATA;
            g_dst <= (AVOID_EP0 && lfsr[7:5] == 3'd0) ? 4'd1 : {1'b0, lfsr[7:5]};
            g_len <= 16'(lfsr[12:8]);
          end
          gst <= G_HDR;
        end
        G_HDR: if (tx_ready) begin
          if (g_len != 0)          gst <= G_PAY;
          else begin
            gst <= G_IDLE;                                   // header-only DATA packet
            if (kind == K_DATA) seq[g_dst[2:0]] <= seq[g_dst[2:0]] + 1;
          end
        end
        G_PAY: if (tx_ready) begin
          g_k <= g_k + 1;
          if (g_k == g_len - 1) begin
            if (kind == K_DATA) begin seq[g_dst[2:0]] <= seq[g_dst[2:0]] + 1; gst <= G_IDLE; end
            else begin wd <= '0; gst <= (kind == K_WRITE) ? G_WAIT_WR : G_WAIT_RD; end
          end
        end
        G_WAIT_WR: begin
          wd <= wd + 1; wd_err <= &wd;
          if (wr_done) begin kind <= K_READ; g_len <= 16'd2; g_k <= '0; gst <= G_HDR; end
        end
        G_WAIT_RD: begin
          wd <= wd + 1; wd_err <= &wd;
          if (rd_done) begin epoch <= epoch + 1; gst <= G_IDLE; end
        end
        default: gst <= G_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- checker
  // sim-only fault hook: tb_zed_selftest +inject pulses this to prove detection
  logic [DATA_W-1:0] rxd;
`ifndef SYNTHESIS
  logic inject_flip = 1'b0;
  assign rxd = rx_data ^ {{(DATA_W-1){1'b0}}, inject_flip};
`else
  assign rxd = rx_data;
`endif
  assign rx_ready = rx_stall_en ? lfsr[17] : 1'b1;

  logic        in_pkt;
  logic [3:0]  c_type, c_src;
  logic [7:0]  c_tag;
  logic [15:0] c_len, c_k;
  logic [7:0]  exp_seq [N_EP];

  localparam logic [3:0] EC_SEQ = 4'h1, EC_PAY = 4'h2, EC_LEN = 4'h3, EC_HDR = 4'h4,
                         EC_MEM = 4'h5, EC_RESP = 4'h6, EC_WDOG = 4'h7, EC_FRAME = 4'h8;

  task automatic flag(logic [3:0] code);
    if (!err_o) err_code_o <= code;
    err_o <= 1'b1;
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_pkt <= 1'b0; c_type <= '0; c_src <= '0; c_tag <= '0; c_len <= '0; c_k <= '0;
      err_o <= 1'b0; err_code_o <= '0; rx_pkts_o <= '0; mem_cycles_o <= '0;
      wr_done <= 1'b0; rd_done <= 1'b0;
      foreach (exp_seq[i]) exp_seq[i] <= '0;
    end else begin
      wr_done <= 1'b0; rd_done <= 1'b0;
      if (wd_err) flag(EC_WDOG);
      if (rx_valid && rx_ready) begin
        if (rx_sop) begin
          if (in_pkt) flag(EC_FRAME);
          c_type <= rx_data[H_TYPE_HI:H_TYPE_LO];
          c_src  <= rx_data[H_SRC_HI:H_SRC_LO];
          c_tag  <= rx_data[H_TAG_HI:H_TAG_LO];
          c_len  <= rx_data[H_LEN_HI:H_LEN_LO];
          c_k    <= '0;
          in_pkt <= !rx_eop;
          if (rx_data[H_DST_HI:H_DST_LO] != 4'(ID)) flag(EC_HDR);
          unique case (rx_data[H_TYPE_HI:H_TYPE_LO])
            T_DATA: begin
              if (rx_data[H_SRC_HI] || rx_data[H_TAG_HI:H_TAG_LO] != exp_seq[rx_data[H_SRC_LO+2:H_SRC_LO]]) flag(EC_SEQ);
              exp_seq[rx_data[H_SRC_LO+2:H_SRC_LO]] <= rx_data[H_TAG_HI:H_TAG_LO] + 1;
            end
            T_MEM_WRITE_RESP: if (gst != G_WAIT_WR || !rx_eop) flag(EC_RESP); else wr_done <= 1'b1;
            T_MEM_READ_RESP:  if (gst != G_WAIT_RD || rx_data[H_LEN_HI:H_LEN_LO] != 16'(MEM_WORDS_PER_EP)) flag(EC_RESP);
            default: flag(EC_RESP);                                  // T_ERROR or junk
          endcase
          if (rx_eop) begin
            rx_pkts_o <= rx_pkts_o + 1;
            if (rx_data[H_LEN_HI:H_LEN_LO] != 0) flag(EC_LEN);
          end
        end else begin
          if (!in_pkt) flag(EC_FRAME);
          c_k <= c_k + 1;
          if (c_type == T_DATA && rxd != data_pat(c_src, 4'(ID), c_tag, c_k)) flag(EC_PAY);
          if (c_type == T_MEM_READ_RESP && rxd != mem_pat(4'(ID), epoch, c_k)) flag(EC_MEM);
          if (rx_eop) begin
            in_pkt    <= 1'b0;
            rx_pkts_o <= rx_pkts_o + 1;
            if (c_k + 1 != c_len) flag(EC_LEN);
            if (c_type == T_MEM_READ_RESP) begin rd_done <= 1'b1; mem_cycles_o <= mem_cycles_o + 1; end
          end else if (c_k + 1 == c_len) flag(EC_LEN);
        end
      end
    end
  end
endmodule
