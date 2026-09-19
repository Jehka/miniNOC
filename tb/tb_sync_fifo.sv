// tb_sync_fifo.sv -- P2: lossless ready/valid FIFO, random stalls, scoreboard
`timescale 1ns/1ps
module tb_sync_fifo #(parameter int WIDTH = 66, parameter int DEPTH = 16);
  localparam int AW = $clog2(DEPTH);
  logic clk = 0, rst_n = 0;
  logic [WIDTH-1:0] in_data = '0, out_data;
  logic in_valid = 0, out_ready = 0, in_ready, out_valid;
  logic [AW:0] count;
  int errors = 0, n_in = 0, n_out = 0;
  logic [WIDTH-1:0] sb [$];
  int p_valid = 0, p_ready = 0;   // percent
  logic accepted;                 // handshake happened at last edge

  sync_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (.clk, .rst_n,
    .in_data_i(in_data), .in_valid_i(in_valid), .in_ready_o(in_ready),
    .out_data_o(out_data), .out_valid_o(out_valid), .out_ready_i(out_ready), .count_o(count));

  always #5 clk = ~clk;

  // ---- scoreboard monitor ----
  always @(posedge clk) begin
    accepted <= in_valid && in_ready;
    if (rst_n) begin
      if (in_valid && in_ready) begin sb.push_back(in_data); n_in++; end
      if (out_valid && out_ready) begin
        n_out++;
        if (sb.size() == 0) begin $display("[%0t] output with empty scoreboard", $time); errors++; end
        else begin
          automatic logic [WIDTH-1:0] exp = sb.pop_front();
          if (out_data !== exp) begin $display("[%0t] MISMATCH exp=%h got=%h", $time, exp, out_data); errors++; end
        end
      end
    end
  end

  // ---- output stability during stall (spec sec 3) ----
  logic prev_stall = 0; logic [WIDTH-1:0] prev_data;
  always @(posedge clk) begin
    if (rst_n && prev_stall && out_data !== prev_data) begin
      $display("[%0t] output data changed during stall", $time); errors++;
    end
    prev_stall <= rst_n && out_valid && !out_ready;
    prev_data  <= out_data;
  end

  // ---- legal producer + random consumer ----
  task automatic run(int cycles);
    repeat (cycles) begin
      @(negedge clk);
      if (!in_valid || accepted) begin
        in_valid = ($urandom_range(0, 99) < p_valid);
        in_data  = {$urandom(), $urandom(), $urandom()};
      end
      out_ready = ($urandom_range(0, 99) < p_ready);
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;

    // T1: fill with consumer blocked -> exactly DEPTH accepted, in_ready low
    p_valid = 100; p_ready = 0; run(DEPTH + 4);
    if (in_ready || count != (AW+1)'(DEPTH) || sb.size() != DEPTH) begin
      $display("T1 fail count=%0d in_ready=%b sb=%0d", count, in_ready, sb.size()); errors++;
    end
    // T2: drain with producer idle -> empty, all matched
    in_valid = 0; p_valid = 0; p_ready = 100; run(DEPTH + 4);
    if (out_valid || count != 0 || sb.size() != 0) begin $display("T2 fail count=%0d", count); errors++; end
    // T3: random stall mixes
    p_valid = 90;  p_ready = 10;  run(5000);
    p_valid = 50;  p_ready = 50;  run(5000);
    p_valid = 10;  p_ready = 90;  run(5000);
    p_valid = 100; p_ready = 100; run(5000);
    // flush: finish offered flit, then drain
    while (in_valid && !accepted) begin @(negedge clk); out_ready = 1; end
    in_valid = 0; p_valid = 0; p_ready = 100; run(DEPTH + 4);
    if (sb.size() != 0) begin $display("flush fail: %0d flits stuck/lost", sb.size()); errors++; end
    // T4: reset with data inside -> idle
    p_valid = 100; p_ready = 0; run(6); in_valid = 0;
    rst_n = 0; @(negedge clk); rst_n = 1; sb.delete(); n_out = n_in;
    @(negedge clk);
    if (out_valid || count != 0 || !in_ready) begin $display("T4 fail: reset left state"); errors++; end

    if (errors == 0) $display("PASS tb_sync_fifo WIDTH=%0d DEPTH=%0d flits=%0d", WIDTH, DEPTH, n_in);
    else             $display("FAIL tb_sync_fifo errors=%0d", errors);
    $finish;
  end
endmodule
