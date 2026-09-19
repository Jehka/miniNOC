-- noc_dissector.lua -- Wireshark dissector for encapsulated Mini-NoC packets
--
--   wireshark -X lua_script:net/noc_dissector.lua
--   tshark  -X lua_script:net/noc_dissector.lua -Y noc
--
-- Decodes the stage-1 encapsulation format (network spec section 20): the UDP
-- payload is a NoC packet verbatim, 64-bit header then payload words, big-endian.

local noc = Proto("noc", "Mini-NoC packet")

local types = {
  [0x0] = "DATA", [0x1] = "MEM_READ_REQ",  [0x2] = "MEM_READ_RESP",
  [0x3] = "MEM_WRITE_REQ", [0x4] = "MEM_WRITE_RESP", [0xF] = "T_ERROR"
}
local errs = {
  [0x0] = "none", [0x1] = "E_TYPE", [0x2] = "E_LEN",
  [0x3] = "E_ALIGN", [0x4] = "E_RANGE"
}

local f_type  = ProtoField.uint8 ("noc.type",   "TYPE",     base.HEX, types, 0xF0)
local f_src   = ProtoField.uint8 ("noc.src",    "SRC_ID",   base.DEC, nil,   0x0F)
local f_dst   = ProtoField.uint8 ("noc.dst",    "DST_ID",   base.DEC, nil,   0xF0)
local f_len   = ProtoField.uint16("noc.length", "LENGTH",   base.DEC)
local f_tag   = ProtoField.uint8 ("noc.tag",    "TAG",      base.DEC)
local f_flags = ProtoField.uint8 ("noc.flags",  "FLAGS",    base.HEX, errs)
local f_word  = ProtoField.uint64("noc.word",   "Payload word", base.HEX)
local f_trunc = ProtoField.bool  ("noc.trunc",  "Truncated (LENGTH exceeds datagram)")

noc.fields = { f_type, f_src, f_dst, f_len, f_tag, f_flags, f_word, f_trunc }

function noc.dissector(buf, pinfo, tree)
  if buf:len() < 8 then return 0 end
  pinfo.cols.protocol = "NoC"

  local t     = buf(0,1):bitfield(0,4)
  local src   = buf(0,1):bitfield(4,4)
  local dst   = buf(1,1):bitfield(0,4)
  local len   = buf(1,3):bitfield(4,16)
  local tag   = buf(3,2):bitfield(4,8)
  local flags = buf(4,2):bitfield(4,4)

  local st = tree:add(noc, buf(), string.format("Mini-NoC: %s  %d -> %d  len %d",
                      types[t] or string.format("0x%x", t), src, dst, len))
  local hdr = st:add(noc, buf(0,8), "Header")
  hdr:add(f_type,  buf(0,1))
  hdr:add(f_src,   buf(0,1))
  hdr:add(f_dst,   buf(1,1))
  hdr:add(f_len,   buf(1,3), len)
  hdr:add(f_tag,   buf(3,2), tag)
  hdr:add(f_flags, buf(4,2), flags)

  if t == 0xF then
    pinfo.cols.info = string.format("NoC ERROR %s  src %d -> dst %d",
                                    errs[flags] or flags, src, dst)
  else
    pinfo.cols.info = string.format("NoC %s  %d -> %d  %d words",
                                    types[t] or t, src, dst, len)
  end

  local avail = math.floor((buf:len() - 8) / 8)
  if len > avail then
    st:add(f_trunc, true):set_generated()
    st:add_expert_info(PI_MALFORMED, PI_WARN,
      string.format("LENGTH %d but only %d payload words present", len, avail))
  end

  local pay = st:add(noc, buf(8), string.format("Payload (%d words)", avail))
  for i = 0, avail - 1 do
    pay:add(f_word, buf(8 + i*8, 8))
  end
  return buf:len()
end

-- 5555 encapsulated data, 5556/5557 memory ops (network spec section 21)
local udp = DissectorTable.get("udp.port")
udp:add(5555, noc)
udp:add(5556, noc)
udp:add(5557, noc)
