// endpoint_port.sv -- TX/RX FIFO wrapper with ingress sanitizing (spec v0.2 sec 3, 11)
//
// Ingress rules (so the switch only ever sees well-framed streams):
//  * SRC_ID is overwritten with ID on every header flit.
//  * A flit without SOP while no packet is open is a stray: it is accepted
//    (tx_ready=1) and dropped, and err_framing_o pulses.
//  * SOP while a packet is open: forwarded as a body flit with SOP cleared
//    (no stamping), err_framing_o pulses. The receiver sees one malformed packet.
module endpoint_port
  import noc_pkg::*;
#(
  parameter int ID         = 0,
  parameter int FIFO_DEPTH = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  // user TX
  input  logic [DATA_W-1:0] tx_data,
  input  logic              tx_valid,
  output logic              tx_ready,
  input  logic              tx_sop,
  input  logic              tx_eop,
  // user RX
  output logic [DATA_W-1:0] rx_data,
  output logic              rx_valid,
  input  logic              rx_ready,
  output logic              rx_sop,
  output logic              rx_eop,
  // switch side
  output logic [FLIT_W-1:0] sw_tx_flit,
  output logic              sw_tx_valid,
  input  logic              sw_tx_ready,
  input  logic [FLIT_W-1:0] sw_rx_flit,
  input  logic              sw_rx_valid,
  output logic              sw_rx_ready,
  output logic              err_framing_o
);
  localparam int AW = $clog2(FIFO_DEPTH);

  logic              tx_open;
  logic              stray, hdr, fifo_in_ready;
  logic [DATA_W-1:0] tx_d;
  logic [FLIT_W-1:0] tx_flit, rx_flit;
  logic [AW:0]       unused_cnt_tx, unused_cnt_rx;

  assign stray    = tx_valid && !tx_sop && !tx_open;
  assign hdr      = tx_sop && !tx_open;
  assign tx_d     = hdr ? {tx_data[63:60], 4'(ID), tx_data[55:0]} : tx_data;
  assign tx_flit  = {hdr, tx_eop, tx_d};
  assign tx_ready = stray ? 1'b1 : fifo_in_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_open       <= 1'b0;
      err_framing_o <= 1'b0;
    end else begin
      err_framing_o <= tx_valid && tx_ready && (stray || (tx_sop && tx_open));
      if (tx_valid && tx_ready && !stray) tx_open <= !tx_eop;
    end
  end

  sync_fifo #(.WIDTH(FLIT_W), .DEPTH(FIFO_DEPTH)) u_tx_fifo (
    .clk, .rst_n,
    .in_data_i (tx_flit),     .in_valid_i (tx_valid && !stray), .in_ready_o (fifo_in_ready),
    .out_data_o(sw_tx_flit),  .out_valid_o(sw_tx_valid),        .out_ready_i(sw_tx_ready),
    .count_o   (unused_cnt_tx));

  sync_fifo #(.WIDTH(FLIT_W), .DEPTH(FIFO_DEPTH)) u_rx_fifo (
    .clk, .rst_n,
    .in_data_i (sw_rx_flit),  .in_valid_i (sw_rx_valid),        .in_ready_o (sw_rx_ready),
    .out_data_o(rx_flit),     .out_valid_o(rx_valid),           .out_ready_i(rx_ready),
    .count_o   (unused_cnt_rx));

  assign rx_sop  = rx_flit[FLIT_W-1];
  assign rx_eop  = rx_flit[FLIT_W-2];
  assign rx_data = rx_flit[DATA_W-1:0];
endmodule
