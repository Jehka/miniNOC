// memory_adapter.sv -- packet <-> BRAM bridge, destination/source ID 8 (spec v0.2 sec 9)
//
// MEM_WRITE_REQ : hdr LENGTH = 1 + n (n >= 1) ; p0 = byte addr ; p1..pn = data words
//                 -> MEM_WRITE_RESP, LENGTH 0
// MEM_READ_REQ  : hdr LENGTH = 2 ; p0 = byte addr ; p1[15:0] = n words
//                 -> MEM_READ_RESP, LENGTH n, n data words
// Any violation -> drain to EOP, reply T_ERROR (LENGTH 0, FLAGS = code, same TAG).
// Addresses are byte addresses, must be multiple of 8; word = addr >> 3.
// Writes commit as data flits arrive: a write that later fails its LENGTH
// check has already written the words it carried (reported as E_LEN).
// Requests are processed one at a time; no request is accepted while a
// response is pending.
module memory_adapter
  import noc_pkg::*;
#(
  parameter int MEM_AW = 10
) (
  input  logic              clk,
  input  logic              rst_n,
  // requests from switch output MEM_PORT
  input  logic [FLIT_W-1:0] in_flit,
  input  logic              in_valid,
  output logic              in_ready,
  // responses to switch input MEM_PORT
  output logic [FLIT_W-1:0] out_flit,
  output logic              out_valid,
  input  logic              out_ready,
  // BRAM
  output logic              mem_we,
  output logic [MEM_AW-1:0] mem_waddr,
  output logic [DATA_W-1:0] mem_wdata,
  output logic              mem_re,
  output logic [MEM_AW-1:0] mem_raddr,
  input  logic [DATA_W-1:0] mem_rdata
);
  localparam longint MEM_WORDS = longint'(1) << MEM_AW;

  typedef enum logic [2:0] {S_HDR, S_ADDR, S_RCNT, S_WDATA, S_DRAIN, S_RESP, S_RDATA} state_e;
  state_e state;

  logic [3:0]        rtype, rsrc, err;
  logic [TAG_W-1:0]  rtag;
  logic [LEN_W-1:0]  rlen, cnt, rcount;
  logic [MEM_AW-1:0] addr_w;

  logic              sop, eop, in_xfer, out_xfer;
  logic [DATA_W-1:0] d;
  // Address checks are split into a cheap high-bit test plus arithmetic in
  // MEM_AW+1 bits. The v0.2 code did this in 65-bit arithmetic, which Vivado
  // built as ~16 chained CARRY4 stages and cost ~4 ns on the critical path.
  logic              word_hi_nz;      // address word index outside memory
  logic [MEM_AW-1:0] word_lo;
  logic [MEM_AW+1:0] burst_end;       // word_lo + rlen - 1, saturating in AW+2 bits
  logic [MEM_AW+1:0] read_end;        // addr_w + read count

  assign sop       = in_flit[FLIT_W-1];
  assign eop       = in_flit[FLIT_W-2];
  assign d         = in_flit[DATA_W-1:0];
  assign in_ready  = (state != S_RESP) && (state != S_RDATA);
  assign in_xfer   = in_valid && in_ready;
  assign out_valid = (state == S_RESP) || (state == S_RDATA);
  assign out_xfer  = out_valid && out_ready;
  assign word_hi_nz = |d[63:MEM_AW+3];
  assign word_lo    = d[MEM_AW+2:3];
  assign burst_end  = {2'b0, word_lo} + (MEM_AW+2)'(rlen) - (MEM_AW+2)'(1);
  assign read_end   = {2'b0, addr_w}  + (MEM_AW+2)'(d[15:0]);

  // response flit
  always_comb begin
    logic [3:0] t, fl; logic [LEN_W-1:0] l; logic e;
    if (err != E_NONE)               begin t = T_ERROR;          l = '0;     fl = err;    e = 1'b1; end
    else if (rtype == T_MEM_READ_REQ) begin t = T_MEM_READ_RESP;  l = rcount; fl = E_NONE; e = (rcount == 0); end
    else                              begin t = T_MEM_WRITE_RESP; l = '0;     fl = E_NONE; e = 1'b1; end
    if (state == S_RDATA) out_flit = {1'b0, rcount == 1, mem_rdata};
    else                  out_flit = {1'b1, e, mk_hdr(t, 4'(MEM_PORT), rsrc, l, rtag, fl)};
  end

  // BRAM strobes
  assign mem_we    = (state == S_WDATA) && in_xfer;
  assign mem_waddr = addr_w;
  assign mem_wdata = d;
  always_comb begin
    mem_re    = 1'b0;
    mem_raddr = addr_w;
    if (state == S_RESP && out_xfer && err == E_NONE && rtype == T_MEM_READ_REQ && rcount != 0)
      mem_re = 1'b1;                                   // prefetch first word
    else if (state == S_RDATA && out_xfer && rcount != 1) begin
      mem_re    = 1'b1;                                // fetch next word on accept
      mem_raddr = addr_w + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_HDR; err <= E_NONE; rtype <= '0; rsrc <= '0; rtag <= '0;
      rlen <= '0; cnt <= '0; rcount <= '0; addr_w <= '0;
    end else begin
      unique case (state)
        S_HDR: if (in_xfer) begin
          rtype <= d[H_TYPE_HI:H_TYPE_LO];
          rsrc  <= d[H_SRC_HI:H_SRC_LO];
          rtag  <= d[H_TAG_HI:H_TAG_LO];
          rlen  <= d[H_LEN_HI:H_LEN_LO];
          cnt   <= '0;
          rcount<= '0;
          err   <= E_NONE;
          if (d[H_TYPE_HI:H_TYPE_LO] != T_MEM_READ_REQ && d[H_TYPE_HI:H_TYPE_LO] != T_MEM_WRITE_REQ) begin
            err   <= E_TYPE;
            state <= eop ? S_RESP : S_DRAIN;
          end else if (eop) begin
            err   <= E_LEN;
            state <= S_RESP;
          end else begin
            state <= S_ADDR;
          end
        end

        S_ADDR: if (in_xfer) begin
          cnt <= 1;
          if (eop) begin
            err <= E_LEN; state <= S_RESP;
          end else if (d[2:0] != 3'b000) begin
            err <= E_ALIGN; state <= S_DRAIN;
          end else if (word_hi_nz) begin
            err <= E_RANGE; state <= S_DRAIN;
          end else if (rtype == T_MEM_READ_REQ) begin
            addr_w <= word_lo;
            if (rlen != 2) begin err <= E_LEN; state <= S_DRAIN; end
            else state <= S_RCNT;
          end else begin
            addr_w <= word_lo;
            if (rlen < 2)                            begin err <= E_LEN;   state <= S_DRAIN; end
            else if (burst_end > (MEM_AW+2)'(MEM_WORDS)) begin err <= E_RANGE; state <= S_DRAIN; end
            else state <= S_WDATA;
          end
        end

        S_RCNT: if (in_xfer) begin
          if (!eop) begin
            err <= E_LEN; state <= S_DRAIN;
          end else if (|d[15:MEM_AW+1] || read_end > (MEM_AW+2)'(MEM_WORDS)) begin
            err <= E_RANGE; state <= S_RESP;
          end else begin
            rcount <= d[15:0]; state <= S_RESP;
          end
        end

        S_WDATA: if (in_xfer) begin
          cnt    <= cnt + 1;
          addr_w <= addr_w + 1;
          if (eop) begin
            if (cnt + 1 != rlen) err <= E_LEN;
            state <= S_RESP;
          end else if (cnt + 1 == rlen) begin
            err <= E_LEN; state <= S_DRAIN;                  // LENGTH reached, no EOP
          end
        end

        S_DRAIN: if (in_xfer && eop) state <= S_RESP;

        S_RESP: if (out_xfer) begin
          if (err == E_NONE && rtype == T_MEM_READ_REQ && rcount != 0) state <= S_RDATA;
          else state <= S_HDR;
        end

        S_RDATA: if (out_xfer) begin
          rcount <= rcount - 1;
          addr_w <= addr_w + 1;
          if (rcount == 1) state <= S_HDR;
        end

        default: state <= S_HDR;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    if (state == S_HDR && in_valid)   assert (sop)  else $error("memory_adapter: header flit without SOP");
    if (state != S_HDR && in_xfer)    assert (!sop) else $error("memory_adapter: SOP inside request");
  end
`endif
endmodule
