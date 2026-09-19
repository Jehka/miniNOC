// noc_pkg.sv -- shared parameters, header layout, helpers (spec v0.2)
package noc_pkg;
  localparam int N_EP      = 8;             // bidirectional endpoints
  localparam int N_IN      = N_EP + 1;      // switch inputs : EP0-7 TX, MEM responses
  localparam int N_OUT     = N_EP + 2;      // switch outputs: EP0-7 RX, MEM requests, SINK
  localparam int MEM_PORT  = 8;
  localparam int SINK_PORT = 9;
  localparam int IN_IW     = $clog2(N_IN);
  localparam int OUT_IW    = $clog2(N_OUT);

  localparam int DATA_W    = 64;
  localparam int FLIT_W    = DATA_W + 2;    // {sop, eop, data}
  localparam int LEN_W     = 16;
  localparam int TAG_W     = 8;

  // header bit positions
  localparam int H_TYPE_HI = 63, H_TYPE_LO = 60;
  localparam int H_SRC_HI  = 59, H_SRC_LO  = 56;
  localparam int H_DST_HI  = 55, H_DST_LO  = 52;
  localparam int H_LEN_HI  = 51, H_LEN_LO  = 36;
  localparam int H_TAG_HI  = 35, H_TAG_LO  = 28;
  localparam int H_FLG_HI  = 27, H_FLG_LO  = 24;

  localparam logic [3:0] T_DATA           = 4'h0;
  localparam logic [3:0] T_MEM_READ_REQ   = 4'h1;
  localparam logic [3:0] T_MEM_READ_RESP  = 4'h2;
  localparam logic [3:0] T_MEM_WRITE_REQ  = 4'h3;
  localparam logic [3:0] T_MEM_WRITE_RESP = 4'h4;
  localparam logic [3:0] T_ERROR          = 4'hF;

  // FLAGS values carried in T_ERROR responses
  localparam logic [3:0] E_NONE  = 4'h0;
  localparam logic [3:0] E_TYPE  = 4'h1;   // unsupported TYPE sent to memory
  localparam logic [3:0] E_LEN   = 4'h2;   // LENGTH / EOP mismatch or illegal length
  localparam logic [3:0] E_ALIGN = 4'h3;   // address not a multiple of 8
  localparam logic [3:0] E_RANGE = 4'h4;   // address/burst outside memory

  function automatic logic [DATA_W-1:0] mk_hdr(
      logic [3:0] ptype, logic [3:0] src, logic [3:0] dst,
      logic [LEN_W-1:0] len, logic [TAG_W-1:0] tag, logic [3:0] flags);
    return {ptype, src, dst, len, tag, flags, 24'h0};
  endfunction
endpackage
