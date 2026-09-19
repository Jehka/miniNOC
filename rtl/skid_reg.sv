// skid_reg.sv -- 2-entry flop-based register slice (v0.2.2)
//
// Unlike sync_fifo, the output comes straight from flip-flops, not from a
// LUTRAM read. That matters where the consumer's logic is deep: the switch
// reads route/valid/eop from the head every cycle, so on the v0.2.1 netlist
// the arbiter path started with a RAMD32 read plus three LUT levels of route
// decode (~3.5 ns) before arbitration even began.
//
// Lossless and fully registered in both directions: in_ready = !v1 and
// out_valid/out_data are registers, so no combinational path crosses it.
// Costs 2*WIDTH flops per instance and no extra latency at full rate.
module skid_reg #(
  parameter int WIDTH = 66
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] in_data_i,
  input  logic             in_valid_i,
  output logic             in_ready_o,
  output logic [WIDTH-1:0] out_data_o,
  output logic             out_valid_o,
  input  logic             out_ready_i
);
  logic [WIDTH-1:0] d0, d1;
  logic             v0, v1;
  logic             acc_in, acc_out;

  assign in_ready_o  = !v1;          // room for the skid entry
  assign out_valid_o = v0;
  assign out_data_o  = d0;
  assign acc_in      = in_valid_i  && in_ready_o;
  assign acc_out     = out_valid_o && out_ready_i;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v0 <= 1'b0;
      v1 <= 1'b0;
    end else begin
      unique case ({acc_in, acc_out})
        2'b10: if (!v0) begin d0 <= in_data_i; v0 <= 1'b1; end
               else      begin d1 <= in_data_i; v1 <= 1'b1; end
        2'b01: if (v1)  begin d0 <= d1;        v1 <= 1'b0; end
               else      begin                  v0 <= 1'b0; end
        2'b11: if (v1)  begin d0 <= d1; d1 <= in_data_i;   end
               else      begin d0 <= in_data_i;            end
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    assert (!(acc_in && v1))  else $error("skid_reg: accepted while full");
    assert (!(acc_out && !v0)) else $error("skid_reg: popped while empty");
    assert (!(v1 && !v0))      else $error("skid_reg: skid entry without head");
  end
`endif
endmodule
