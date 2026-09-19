// tb_zed_selftest.sv -- runs the on-board self-test (zed_top) in simulation
//   +inject : flip one payload bit on EP3 RX mid-run; the checker must flag it
`timescale 1ns/1ps
module tb_zed_selftest;
  logic GCLK = 0, BTNC = 1;
  logic [7:0] SW = 8'h00, LD;
  always #5 GCLK = ~GCLK;
  zed_top dut (.*);

  initial begin
    automatic bit inject = $test$plusargs("inject");
    repeat (10) @(posedge GCLK); BTNC = 0;
    repeat (40) @(posedge GCLK);
    SW[0] = 1;                                // traffic on
    repeat (150000) @(posedge GCLK);
    SW[1] = 1;                                // random RX backpressure on
    if (inject) begin
      do @(posedge GCLK); while (!(dut.rx_valid[3] && !dut.rx_sop[3] && dut.g_tr[3].u_tr.c_type == 4'h0));
      @(negedge GCLK); dut.g_tr[3].u_tr.inject_flip = 1'b1;
      @(negedge GCLK); dut.g_tr[3].u_tr.inject_flip = 1'b0;
    end
    repeat (150000) @(posedge GCLK);
    SW[0] = 0;                                // stop generating, let things drain
    repeat (20000) @(posedge GCLK);
    $display("self-test: rx_pkts=%0d sink=%0d framing=%0d mem_cycles ep0=%0d ep7=%0d err=%b code=%h",
      dut.stat_rx_pkts, dut.stat_sink_pkts, dut.stat_framing_errs,
      dut.ep_mem[0], dut.ep_mem[7], dut.ep_err, dut.first_code);
    if (inject) begin
      if (dut.any_err) $display("PASS tb_zed_selftest +inject (checker caught corruption, code %0h)", dut.first_code);
      else             $display("FAIL tb_zed_selftest +inject: corruption not detected");
    end else begin
      if (!dut.any_err && dut.stat_rx_pkts > 10000 && dut.ep_mem[0] > 10 && dut.stat_sink_pkts == 0 && dut.stat_framing_errs == 0)
        $display("PASS tb_zed_selftest");
      else $display("FAIL tb_zed_selftest");
    end
    $finish;
  end
endmodule
