// noc_switch.sv -- 9-input x 10-output packet crossbar (spec v0.2 sec 5-7)
//
// in  0..7 : endpoint TX FIFOs     out 0..7 : endpoint RX FIFOs
// in  8    : memory responses      out 8    : memory requests
//                                  out 9    : SINK (illegal DST_ID)
// Each output owns an output_port_ctrl; outputs run concurrently.
// in_ready does not depend on in_valid. No combinational loops: grant depends
// only on registered FIFO state + route latches.
module noc_switch
  import noc_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic [N_IN-1:0][FLIT_W-1:0]  in_flit,
  input  logic [N_IN-1:0]              in_valid,
  output logic [N_IN-1:0]              in_ready,
  output logic [N_OUT-1:0][FLIT_W-1:0] out_flit,
  output logic [N_OUT-1:0]             out_valid,
  input  logic [N_OUT-1:0]             out_ready,
  output logic [N_IN-1:0]              bad_dst_o
);
  // Each input is register-sliced before route decode and arbitration, so the
  // arbiter path starts at a flop instead of a FIFO LUTRAM read plus decode.
  logic [N_IN-1:0][FLIT_W-1:0] h_flit;
  logic [N_IN-1:0]             h_valid, h_ready;

  logic [N_IN-1:0][OUT_IW-1:0] route;
  logic [N_IN-1:0]             eop;
  logic [N_OUT-1:0][N_IN-1:0]  req;
  logic [N_OUT-1:0][IN_IW-1:0] owner;
  logic [N_OUT-1:0]            have, locked;

  for (genvar i = 0; i < N_IN; i++) begin : g_in
    skid_reg #(.WIDTH(FLIT_W)) u_skid (
      .clk, .rst_n,
      .in_data_i (in_flit[i]), .in_valid_i (in_valid[i]), .in_ready_o (in_ready[i]),
      .out_data_o(h_flit[i]),  .out_valid_o(h_valid[i]),  .out_ready_i(h_ready[i]));

    assign eop[i] = h_flit[i][FLIT_W-2];
    route_decode u_rd (
      .clk, .rst_n,
      .head_flit(h_flit[i]), .head_valid(h_valid[i]),
      .pop(h_valid[i] && h_ready[i]),
      .route_o(route[i]), .bad_dst_o(bad_dst_o[i]));
  end

  for (genvar o = 0; o < N_OUT; o++) begin : g_out
    for (genvar i = 0; i < N_IN; i++) begin : g_req
      assign req[o][i] = h_valid[i] && (route[i] == OUT_IW'(o));
    end
    output_port_ctrl #(.N(N_IN)) u_opc (
      .clk, .rst_n,
      .req_i(req[o]), .eop_i(eop), .out_ready_i(out_ready[o]),
      .owner_o(owner[o]), .have_o(have[o]),
      .out_valid_o(out_valid[o]), .locked_o(locked[o]));
    assign out_flit[o] = h_flit[owner[o]];
  end

  always_comb begin
    h_ready = '0;
    for (int o = 0; o < N_OUT; o++)
      if (have[o] && out_ready[o] && route[owner[o]] == OUT_IW'(o))
        h_ready[owner[o]] = 1'b1;
  end

`ifndef SYNTHESIS
  // an input is selected by at most one output that it actually routes to
  always_ff @(posedge clk) if (rst_n) begin
    for (int i = 0; i < N_IN; i++) begin
      automatic int n = 0;
      for (int o = 0; o < N_OUT; o++)
        if (out_valid[o] && int'(owner[o]) == i) n++;
      assert (n <= 1) else $error("noc_switch: input %0d driving %0d outputs", i, n);
    end
    for (int o = 0; o < N_OUT; o++)
      assert (!locked[o] || route[owner[o]] == OUT_IW'(o) || !h_valid[owner[o]])
        else $error("noc_switch: output %0d locked to input not routed to it", o);
  end
`endif
endmodule
