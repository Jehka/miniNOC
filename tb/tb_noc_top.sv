// tb_noc_top.sv -- system scoreboard testbench, milestones P3..P7 (spec v0.2 sec 12)
//
// Expected streams are kept per (src, dst). Endpoint DATA packets are pushed
// when generated; memory responses are predicted by a reference model fed by a
// white-box monitor on the switch->memory channel, so the model sees requests
// in exactly the order the adapter does.
`timescale 1ns/1ps
module tb_noc_top #(parameter int FIFO_DEPTH = 16);
  import noc_pkg::*;
  localparam int MEM_AW    = 10;
  localparam int MEM_WORDS = 1 << MEM_AW;

  int SEED;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [N_EP-1:0][DATA_W-1:0] tx_data, rx_data;
  logic [N_EP-1:0] tx_valid, tx_ready, tx_sop, tx_eop;
  logic [N_EP-1:0] rx_valid, rx_ready, rx_sop, rx_eop;
  logic [31:0] stat_sink_pkts, stat_framing_errs, stat_rx_pkts;

  noc_top #(.FIFO_DEPTH(FIFO_DEPTH), .MEM_AW(MEM_AW)) dut (.*);

  // ------------------------------------------------------------------ state
  int errors = 0;
  logic [FLIT_W-1:0] txq  [N_EP][$];          // stimulus per endpoint
  logic [FLIT_W-1:0] expq [128][$];           // expected per [src*N_EP+dst] (flat, pow2 size: v5.020 queue-array codegen)
  int exp_sink = 0, exp_framing = 0, got_rx_pkts = 0;
  int mem_inflight = 0;                         // requests sent to MEM not yet seen by the model
  int p_tx = 100, p_rx = 100;
  int hist_type [16];                          // received header TYPE histogram
  int hist_err  [16];                          // received T_ERROR FLAGS histogram
  logic [63:0] model_mem [MEM_WORDS];
  int  rx_order [N_EP][$];                     // src of each packet header seen per RX
  int  max_concurrency = 0;

  function automatic void err(string s);
    $display("[%0t] ERROR: %s", $time, s); errors++;
  endfunction

  // ------------------------------------------------------------------ drivers
  logic [N_EP-1:0] tx_acc;
  always @(posedge clk) tx_acc <= tx_valid & tx_ready;

  always @(negedge clk) begin
    for (int e = 0; e < N_EP; e++) begin
      if (!rst_n) begin
        tx_valid[e] = 0; tx_sop[e] = 0; tx_eop[e] = 0; tx_data[e] = '0; rx_ready[e] = 0;
      end else begin
        if (!tx_valid[e] || tx_acc[e]) begin
          if (txq[e].size() > 0 && $urandom_range(0, 99) < p_tx) begin
            automatic logic [FLIT_W-1:0] f = txq[e].pop_front();
            tx_valid[e] = 1; tx_sop[e] = f[FLIT_W-1]; tx_eop[e] = f[FLIT_W-2]; tx_data[e] = f[DATA_W-1:0];
          end else begin
            tx_valid[e] = 0; tx_data[e] = {$urandom(), $urandom()};   // junk when invalid
          end
        end
        rx_ready[e] = ($urandom_range(0, 99) < p_rx);
      end
    end
  end

  // ------------------------------------------------------------------ RX monitor + scoreboard
  int cur_src [N_EP];
  logic [N_EP-1:0] rx_stall_q;
  logic [N_EP-1:0][FLIT_W-1:0] rx_prev;
  always @(posedge clk) begin
    if (rst_n) for (int e = 0; e < N_EP; e++) begin
      automatic logic [FLIT_W-1:0] f = {rx_sop[e], rx_eop[e], rx_data[e]};
      if (rx_stall_q[e] && (!rx_valid[e] || f !== rx_prev[e])) err($sformatf("RX%0d changed during stall", e));
      if (rx_valid[e] && rx_ready[e]) begin
        if (rx_sop[e]) begin
          cur_src[e] = int'(rx_data[e][H_SRC_HI:H_SRC_LO]);
          hist_type[rx_data[e][H_TYPE_HI:H_TYPE_LO]]++;
          if (rx_data[e][H_TYPE_HI:H_TYPE_LO] == T_ERROR) hist_err[rx_data[e][H_FLG_HI:H_FLG_LO]]++;
          rx_order[e].push_back(cur_src[e]);
          if (int'(rx_data[e][H_DST_HI:H_DST_LO]) != e) err($sformatf("RX%0d got header for dst %0d", e, rx_data[e][H_DST_HI:H_DST_LO]));
        end
        if (cur_src[e] > MEM_PORT) err($sformatf("RX%0d bad src %0d", e, cur_src[e]));
        else begin
          automatic logic [6:0] qi = 7'(cur_src[e] * N_EP + e);
          automatic logic [FLIT_W-1:0] x;
          if (expq[qi].size() == 0) err($sformatf("RX%0d unexpected flit from src %0d: %h", e, cur_src[e], f));
          else begin
            x = expq[qi].pop_front();
            if (x !== f) err($sformatf("RX%0d src %0d MISMATCH exp %h got %h", e, cur_src[e], x, f));
          end
        end
        if (rx_eop[e]) got_rx_pkts++;
      end
    end
    for (int e = 0; e < N_EP; e++) begin
      rx_stall_q[e] <= rst_n && rx_valid[e] && !rx_ready[e];
      rx_prev[e]    <= {rx_sop[e], rx_eop[e], rx_data[e]};
    end
  end

  // concurrency probe (P4)
  always @(posedge clk) if (rst_n) begin
    automatic int n = $countones(dut.sw_out_valid[N_EP-1:0] & dut.sw_out_ready[N_EP-1:0]);
    if (n > max_concurrency) max_concurrency = n;
  end

  // ------------------------------------------------------------------ memory reference model
  logic [63:0] mreq [$];
  always @(posedge clk) begin
    if (!rst_n) mreq.delete();
    else if (dut.sw_out_valid[MEM_PORT] && dut.sw_out_ready[MEM_PORT]) begin
      mreq.push_back(dut.sw_out_flit[MEM_PORT][DATA_W-1:0]);
      if (dut.sw_out_flit[MEM_PORT][FLIT_W-2]) begin mem_model(); mreq.delete(); end
    end
  end

  function automatic void mem_model();
    logic [63:0] h = mreq[0];
    logic [3:0] t   = h[H_TYPE_HI:H_TYPE_LO];
    int src = int'(h[H_SRC_HI:H_SRC_LO]);
    logic [7:0] tag = h[H_TAG_HI:H_TAG_LO];
    int len = int'(h[H_LEN_HI:H_LEN_LO]);
    int n   = mreq.size() - 1;
    logic [3:0] e = E_NONE;
    longint word = 0; int cnt = 0;
    if (t != T_MEM_READ_REQ && t != T_MEM_WRITE_REQ) e = E_TYPE;
    else if (n <= 1)                    e = E_LEN;
    else begin
      word = longint'(mreq[1] >> 3);
      if (mreq[1][2:0] != 0)            e = E_ALIGN;
      else if (mreq[1][63:3] >= 61'(MEM_WORDS)) e = E_RANGE;
      else if (t == T_MEM_READ_REQ) begin
        if (len != 2 || n != 2)         e = E_LEN;
        else begin
          cnt = int'(mreq[2][15:0]);
          if (word + cnt > MEM_WORDS)   e = E_RANGE;
        end
      end else begin
        if (len < 2)                    e = E_LEN;
        else if (word + len - 1 > MEM_WORDS) e = E_RANGE;
        else begin
          int nw = (n < len ? n : len) - 1;
          for (int k = 0; k < nw; k++) model_mem[int'(word) + k] = mreq[2 + k];
          if (n != len) e = E_LEN;
        end
      end
    end
    mem_inflight--;
    if (src >= N_EP) begin err($sformatf("memory request with src %0d", src)); return; end
    if (e != E_NONE)
      expq[7'((MEM_PORT)*N_EP+(src))].push_back({1'b1, 1'b1, mk_hdr(T_ERROR, 4'd8, 4'(src), 16'd0, tag, e)});
    else if (t == T_MEM_READ_REQ) begin
      expq[7'((MEM_PORT)*N_EP+(src))].push_back({1'b1, cnt == 0, mk_hdr(T_MEM_READ_RESP, 4'd8, 4'(src), 16'(cnt), tag, E_NONE)});
      for (int k = 0; k < cnt; k++)
        expq[7'((MEM_PORT)*N_EP+(src))].push_back({1'b0, k == cnt - 1, model_mem[int'(word) + k]});
    end else
      expq[7'((MEM_PORT)*N_EP+(src))].push_back({1'b1, 1'b1, mk_hdr(T_MEM_WRITE_RESP, 4'd8, 4'(src), 16'd0, tag, E_NONE)});
  endfunction

  // ------------------------------------------------------------------ stimulus helpers
  // Raw packet: header + payload words. SRC bits are randomized to prove stamping.
  task automatic send_raw(int src, logic [3:0] t, int dst, int hdr_len, logic [63:0] pay [$]);
    logic [63:0] h = mk_hdr(t, 4'($urandom()), 4'(dst), 16'(hdr_len), 8'($urandom()), 4'($urandom()));
    logic [63:0] hs = {h[63:60], 4'(src), h[55:0]};
    int n = pay.size();
    txq[src].push_back({1'b1, n == 0, h});
    for (int k = 0; k < n; k++) txq[src].push_back({1'b0, k == n - 1, pay[k]});
    if (dst < N_EP) begin
      expq[7'((src)*N_EP+(dst))].push_back({1'b1, n == 0, hs});
      for (int k = 0; k < n; k++) expq[7'((src)*N_EP+(dst))].push_back({1'b0, k == n - 1, pay[k]});
    end else if (dst > MEM_PORT) exp_sink++;
    else mem_inflight++;   // dst == MEM_PORT: expectation produced by the memory model
  endtask

  task automatic send_data(int src, int dst, int n);
    logic [63:0] pay [$];
    pay.delete();   // workaround: v5.020 does not re-init automatic-task queues
    for (int k = 0; k < n; k++) pay.push_back({$urandom(), $urandom()});
    send_raw(src, T_DATA, dst, n, pay);
  endtask

  task automatic mem_write(int src, longint addr, int nwords);
    logic [63:0] pay [$];
    pay.delete();   // workaround: v5.020 does not re-init automatic-task queues
    pay.push_back(64'(addr));
    for (int k = 0; k < nwords; k++) pay.push_back({$urandom(), $urandom()});
    send_raw(src, T_MEM_WRITE_REQ, MEM_PORT, 1 + nwords, pay);
  endtask

  task automatic mem_read(int src, longint addr, int nwords);
    logic [63:0] pay [$];
    pay.delete();   // workaround: v5.020 does not re-init automatic-task queues
    pay.push_back(64'(addr)); pay.push_back(64'(nwords));
    send_raw(src, T_MEM_READ_REQ, MEM_PORT, 2, pay);
  endtask

  task automatic send_stray(int src);
    txq[src].push_back({1'b0, $urandom_range(0, 1) == 1, {$urandom(), $urandom()}});
    exp_framing++;
  endtask

  function automatic bit all_empty();
    if (mem_inflight != 0) return 0;
    for (int e = 0; e < N_EP; e++) if (txq[e].size()) return 0;
    for (int s = 0; s < N_IN; s++) for (int d = 0; d < N_EP; d++) if (expq[7'((s)*N_EP+(d))].size()) return 0;
    return 1;
  endfunction

  task automatic drain(string phase, int timeout = 200000);
    int t = 0;
    while (!all_empty() && t < timeout) begin @(negedge clk); t++; end
    repeat (20) @(negedge clk);
    if (!all_empty()) begin
      err($sformatf("%s: drain timeout", phase));
      for (int s = 0; s < N_IN; s++) for (int d = 0; d < N_EP; d++)
        if (expq[7'((s)*N_EP+(d))].size()) $display("   pending [%0d->%0d] %0d flits", s, d, expq[7'((s)*N_EP+(d))].size());
    end else $display("  %-28s done at %0t  (errors so far %0d)", phase, $time, errors);
  endtask

  task automatic clear_hist();
    foreach (hist_type[i]) hist_type[i] = 0;
    foreach (hist_err[i])  hist_err[i]  = 0;
    for (int e = 0; e < N_EP; e++) rx_order[e].delete();
  endtask

  task automatic do_reset();
    rst_n = 0; repeat (3) @(negedge clk);
    for (int e = 0; e < N_EP; e++) txq[e].delete();
    for (int s = 0; s < N_IN; s++) for (int d = 0; d < N_EP; d++) expq[7'((s)*N_EP+(d))].delete();
    exp_sink = 0; exp_framing = 0; got_rx_pkts = 0; mem_inflight = 0;
    foreach (model_mem[i]) model_mem[i] = '0;
    rst_n = 1; @(negedge clk);
  endtask

  // ------------------------------------------------------------------ test sequence
  initial begin
    if (!$value$plusargs("seed=%d", SEED)) SEED = 1;
    void'($urandom(SEED));
    foreach (model_mem[i]) model_mem[i] = '0;
    clear_hist();
    repeat (4) @(negedge clk);
    rst_n = 1;
    $display("tb_noc_top FIFO_DEPTH=%0d SEED=%0d", FIFO_DEPTH, SEED);

    // ---- P3: 8 inputs contend for one output, packet locking, RR fairness
    p_tx = 100; p_rx = 60;
    for (int k = 0; k < 20; k++) for (int s = 0; s < N_EP; s++) send_data(s, 3, $urandom_range(0, 24));
    drain("P3 contention -> EP3");
    begin
      int last_seen [N_EP];
      foreach (last_seen[i]) last_seen[i] = -1;
      if (rx_order[3].size() != 160) err($sformatf("P3: EP3 got %0d packets, want 160", rx_order[3].size()));
      foreach (rx_order[3][k]) begin
        automatic int s = rx_order[3][k];
        if (k - last_seen[s] - 1 > N_IN - 1)          // last_seen = -1 also bounds the wait for a first packet
          err($sformatf("P3 fairness: src %0d waited %0d packets", s, k - last_seen[s] - 1));
        last_seen[s] = k;
      end
      foreach (last_seen[s]) if (last_seen[s] < 0) err($sformatf("P3: src %0d never served", s));
    end

    // ---- P4: permutation traffic, outputs must run in parallel
    clear_hist(); p_tx = 100; p_rx = 100;
    for (int k = 0; k < 30; k++) for (int s = 0; s < N_EP; s++) send_data(s, (s + 3) % N_EP, $urandom_range(4, 12));
    drain("P4 permutation");
    if (max_concurrency < N_EP) err($sformatf("P4: max simultaneous outputs %0d, want %0d", max_concurrency, N_EP));
    else $display("  P4 max simultaneous output transfers = %0d", max_concurrency);

    // ---- P5: every endpoint to every endpoint, incl. header-only and self
    clear_hist(); p_tx = 70; p_rx = 70;
    for (int s = 0; s < N_EP; s++) for (int d = 0; d < N_EP; d++) begin
      send_data(s, d, 0); send_data(s, d, $urandom_range(1, 3)); send_data(s, d, FIFO_DEPTH * 2 + 3);
    end
    drain("P5 any-to-any");
    if (hist_type[T_DATA] != 3 * N_EP * N_EP) err($sformatf("P5: %0d DATA packets, want %0d", hist_type[T_DATA], 3*N_EP*N_EP));

    // ---- P6: memory directed
    clear_hist(); p_tx = 100; p_rx = 80;
    mem_write(1, 64'h40, 4);       drain("P6 write 4 @0x40");
    mem_read (2, 64'h40, 4);       drain("P6 read 4 @0x40");
    mem_read (5, 64'h48, 0);       // zero-length read
    mem_write(6, (MEM_WORDS-1)*8, 1);           // last word, legal
    mem_read (6, (MEM_WORDS-1)*8, 1);
    drain("P6 edges (last word, n=0)");
    mem_write(0, 64'h43, 2);                    // E_ALIGN
    mem_read (0, MEM_WORDS*8, 1);               // E_RANGE (addr)
    mem_write(0, (MEM_WORDS-1)*8, 2);           // E_RANGE (burst over end)
    mem_read (0, (MEM_WORDS-2)*8, 3);           // E_RANGE (count over end)
    send_data(0, MEM_PORT, 2);                  // E_TYPE
    begin logic [63:0] p [$]; p.delete(); send_raw(0, T_MEM_READ_REQ, MEM_PORT, 0, p); end            // E_LEN header only
    begin logic [63:0] p [$]; p.delete(); p.push_back(64'h80); p.push_back(1); p.push_back(7);
          send_raw(0, T_MEM_READ_REQ, MEM_PORT, 2, p); end                                 // E_LEN extra flit
    begin logic [63:0] p [$]; p.delete(); p.push_back(64'h80); p.push_back(64'hDEAD); p.push_back(64'hBEEF);
          send_raw(0, T_MEM_WRITE_REQ, MEM_PORT, 5, p); end                                // E_LEN short (writes commit)
    begin logic [63:0] p [$]; p.delete(); p.push_back(64'h100); p.push_back(1); p.push_back(2); p.push_back(3);
          send_raw(0, T_MEM_WRITE_REQ, MEM_PORT, 2, p); end                                // E_LEN long
    mem_read (7, 64'h80, 1);                    // must see DEAD from the short write
    mem_read (7, 64'h100, 2);                   // one word written by the long write
    drain("P6 error responses");
    if (hist_type[T_MEM_WRITE_RESP] != 2) err($sformatf("P6: WRITE_RESP %0d want 2", hist_type[T_MEM_WRITE_RESP]));
    if (hist_type[T_MEM_READ_RESP]  != 5) err($sformatf("P6: READ_RESP %0d want 5",  hist_type[T_MEM_READ_RESP]));
    if (hist_err[E_ALIGN] != 1) err($sformatf("P6: E_ALIGN %0d want 1", hist_err[E_ALIGN]));
    if (hist_err[E_RANGE] != 3) err($sformatf("P6: E_RANGE %0d want 3", hist_err[E_RANGE]));
    if (hist_err[E_TYPE]  != 1) err($sformatf("P6: E_TYPE %0d want 1",  hist_err[E_TYPE]));
    if (hist_err[E_LEN]   != 4) err($sformatf("P6: E_LEN %0d want 4",   hist_err[E_LEN]));
    if (model_mem[16] != 64'hDEAD) err("P6: model sanity (short write)");

    // ---- ingress robustness: illegal DST and stray flits
    clear_hist();
    for (int s = 0; s < N_EP; s++) begin
      send_stray(s);
      send_data(s, 9 + s % 7, $urandom_range(0, 20));   // DST 9..15 -> sink
      send_data(s, (s + 1) % N_EP, 2);                  // must still be delivered after junk
    end
    drain("illegal DST + stray flits");

    // ---- P7: random mixed traffic with backpressure
    clear_hist();
    for (int round = 0; round < 6; round++) begin
      p_tx = $urandom_range(30, 100); p_rx = $urandom_range(15, 100);
      for (int k = 0; k < 500; k++) begin
        automatic int s = $urandom_range(0, N_EP - 1);
        automatic int r = $urandom_range(0, 99);
        if      (r < 70) send_data(s, $urandom_range(0, N_EP - 1), $urandom_range(0, 40));
        else if (r < 80) mem_write(s, 8 * longint'($urandom_range(0, 200)), $urandom_range(1, 20));
        else if (r < 92) mem_read (s, 8 * longint'($urandom_range(0, 200)), $urandom_range(0, 20));
        else if (r < 95) mem_read (s, longint'($urandom_range(0, 2000)), $urandom_range(0, 3));   // often misaligned
        else if (r < 98) send_data(s, $urandom_range(9, 15), $urandom_range(0, 5));
        else             send_stray(s);
      end
      drain($sformatf("P7 random round %0d (tx%%=%0d rx%%=%0d)", round, p_tx, p_rx));
    end

    // counters
    if (stat_sink_pkts != 32'(exp_sink))       err($sformatf("sink count %0d want %0d", stat_sink_pkts, exp_sink));
    if (stat_framing_errs != 32'(exp_framing)) err($sformatf("framing count %0d want %0d", stat_framing_errs, exp_framing));
    if (stat_rx_pkts != 32'(got_rx_pkts))      err($sformatf("rx pkt counter %0d, tb saw %0d", stat_rx_pkts, got_rx_pkts));
    $display("  counters: rx_pkts=%0d sink=%0d framing=%0d", stat_rx_pkts, stat_sink_pkts, stat_framing_errs);

    // ---- reset between transactions, then traffic again
    do_reset();
    if (stat_rx_pkts != 0 || dut.u_sw.g_out[3].u_opc.locked_o) err("reset did not clear state");
    p_tx = 80; p_rx = 80;
    for (int s = 0; s < N_EP; s++) for (int d = 0; d < N_EP; d++) send_data(s, d, $urandom_range(0, 6));
    mem_write(2, 64'h10, 3); mem_read(3, 64'h10, 3);
    drain("post-reset traffic");

    if (errors == 0) $display("PASS tb_noc_top FIFO_DEPTH=%0d SEED=%0d", FIFO_DEPTH, SEED);
    else             $display("FAIL tb_noc_top errors=%0d", errors);
    $finish;
  end

  initial begin #200ms; $display("FAIL tb_noc_top global timeout"); $finish; end
endmodule
