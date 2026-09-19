// tb_rr_arbiter.sv -- P1: directed + contention + packet-lock fairness + random vs model
`timescale 1ns/1ps
module tb_rr_arbiter #(parameter int N = 9);
  localparam int IW = (N > 1) ? $clog2(N) : 1;

  logic clk = 0, rst_n = 0;
  logic [N-1:0]  req;
  logic          rel;
  logic [IW-1:0] rel_idx;
  logic [N-1:0]  gnt;
  logic [IW-1:0] gnt_idx;
  logic          gnt_valid;
  int errors = 0;

  rr_arbiter #(.N(N)) dut (.clk, .rst_n, .req_i(req), .release_i(rel),
    .release_idx_i(rel_idx), .gnt_o(gnt), .gnt_idx_o(gnt_idx), .gnt_valid_o(gnt_valid));

  always #5 clk = ~clk;

  // ---------------- reference model ----------------
  int model_ptr;
  function automatic int model_pick(logic [N-1:0] r, int p);
    for (int k = 0; k < N; k++) begin
      int i = (p + k) % N;
      if (r[i]) return i;
    end
    return -1;
  endfunction

  // compare DUT against model just before every rising edge
  always @(negedge clk) if (rst_n) begin
    #4;
    begin
      int exp = model_pick(req, model_ptr);
      if ((exp < 0) ? gnt_valid : (!gnt_valid || int'(gnt_idx) != exp || gnt != (N'(1) << exp))) begin
        $display("[%0t] MISMATCH req=%b ptr=%0d exp=%0d got_valid=%b idx=%0d gnt=%b",
                 $time, req, model_ptr, exp, gnt_valid, gnt_idx, gnt);
        errors++;
      end
    end
  end
  always @(posedge clk) if (!rst_n) model_ptr <= 0;
                        else if (rel) model_ptr <= (int'(rel_idx) + 1) % N;

  task automatic step(); @(negedge clk); endtask

  initial begin
    req = '0; rel = 0; rel_idx = '0;
    repeat (3) step();
    rst_n = 1;

    // ---- T1: single requester reaches every index from ptr=0 ----
    for (int i = 0; i < N; i++) begin
      req = N'(1) << i; step();
      if (!(gnt_valid && int'(gnt_idx) == i)) begin $display("T1 fail i=%0d", i); errors++; end
    end
    req = '0; step();

    // ---- T2: all request, release every cycle -> strict rotation 0..N-1 ----
    req = '1;
    for (int c = 0; c < 3*N; c++) begin
      #1;
      if (int'(gnt_idx) != (c % N)) begin
        $display("T2 fail cycle=%0d expected=%0d got=%0d", c, c % N, gnt_idx); errors++;
      end
      rel = 1; rel_idx = gnt_idx; step();
    end
    rel = 0; req = '0; step();

    // ---- T3: packet-lock emulation. Owner holds for random length,
    //          pointer frozen; each continuous requester must win
    //          within N packet completions (starvation bound).
    begin
      int waits [N];
      int owner, remaining;
      foreach (waits[i]) waits[i] = 0;
      req = '1; owner = -1; remaining = 0;
      for (int c = 0; c < 4000; c++) begin
        #1;
        rel = 0;
        if (owner < 0) begin owner = gnt_idx; remaining = $urandom_range(0, 12); end
        if (remaining == 0) begin
          rel = 1; rel_idx = IW'(owner);
          for (int i = 0; i < N; i++)
            if (i == owner) waits[i] = 0;
            else if (++waits[i] > N-1) begin
              $display("T3 starvation: input %0d waited %0d packets", i, waits[i]); errors++;
            end
          owner = -1;
        end else remaining--;
        step();
      end
      rel = 0; req = '0; step();
    end

    // ---- T4: random requests, random legal releases, model compare ----
    for (int c = 0; c < 20000; c++) begin
      req = N'($urandom());
      #1;
      rel = gnt_valid && ($urandom_range(0, 3) == 0);
      rel_idx = gnt_idx;
      step();
    end
    rel = 0;

    // ---- T5: reset mid-traffic returns pointer to 0 ----
    req = '1; rel = 1; rel_idx = IW'(N-2); step(); rel = 0;
    rst_n = 0; step(); rst_n = 1; #1;
    if (gnt_idx != 0) begin $display("T5 fail: ptr not reset, idx=%0d", gnt_idx); errors++; end
    step();

    if (errors == 0) $display("PASS tb_rr_arbiter N=%0d", N);
    else             $display("FAIL tb_rr_arbiter N=%0d errors=%0d", N, errors);
    $finish;
  end
endmodule
