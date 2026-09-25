#!/usr/bin/env python3
"""n3_test.py -- drive the board's UDP bridge from the host (stages N3 and N4).

    python3 net/n3_test.py                 # N3: one address, port 5556
    python3 net/n3_test.py --by-address    # N4: an address per endpoint, port 5555

Port 5556 routes by the DST_ID in the header, which works before lwIP answers
ARP for the other endpoint addresses. Port 5555 routes by destination address
and is exercised once N4 is done.

Plain sockets, no scapy and no admin rights. Run Wireshark on the wired adapter
with net/noc_dissector.lua loaded to watch the packets decode.
"""
import argparse, socket, struct, sys

PORT_ADDR, PORT_RAW = 5555, 5556
T_DATA, T_RD, T_RD_RESP, T_WR, T_WR_RESP, T_ERR = 0x0, 0x1, 0x2, 0x3, 0x4, 0xF
MEM_ID = 8
ERRS = {0: "none", 1: "E_TYPE", 2: "E_LEN", 3: "E_ALIGN", 4: "E_RANGE"}
TYPES = {0: "DATA", 1: "MEM_READ_REQ", 2: "MEM_READ_RESP",
         3: "MEM_WRITE_REQ", 4: "MEM_WRITE_RESP", 0xF: "T_ERROR"}

fails = 0


def hdr(ptype, src, dst, length, tag=0, flags=0):
    return struct.pack(">Q", (ptype & 0xF) << 60 | (src & 0xF) << 56 | (dst & 0xF) << 52
                       | (length & 0xFFFF) << 36 | (tag & 0xFF) << 28 | (flags & 0xF) << 24)


def words(*v):
    return b"".join(struct.pack(">Q", x) for x in v)


def decode(b):
    h = struct.unpack(">Q", b[:8])[0]
    return {"type": (h >> 60) & 0xF, "src": (h >> 56) & 0xF, "dst": (h >> 52) & 0xF,
            "len": (h >> 36) & 0xFFFF, "tag": (h >> 28) & 0xFF, "flags": (h >> 24) & 0xF,
            "words": [struct.unpack(">Q", b[8 + 8 * i:16 + 8 * i])[0]
                      for i in range((len(b) - 8) // 8)]}


def exchange(sock, host, port, payload, expect_reply=True, timeout=2.0):
    sock.sendto(payload, (host, port))
    if not expect_reply:
        return None
    sock.settimeout(timeout)
    try:
        data, _ = sock.recvfrom(2048)
        return decode(data)
    except socket.timeout:
        return None


def check(what, got, exp):
    global fails
    if got == exp:
        print(f"  ok   {what:<38} {got}")
    else:
        print(f"  FAIL {what:<38} got {got}  exp {exp}")
        fails += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="10.10.10.10")
    ap.add_argument("--port", type=int, default=PORT_RAW,
                    help=f"{PORT_RAW} routes by header DST_ID, {PORT_ADDR} by address")
    ap.add_argument("--by-address", action="store_true",
                    help="N4: address each endpoint directly on port 5555")
    a = ap.parse_args()

    if a.by_address:
        a.port = PORT_ADDR
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("", 0))
    mode = "by destination address" if a.by_address else "by header DST_ID"
    print(f"== UDP -> NoC, routed {mode} (port {a.port}) ==")

    # N4: each endpoint has its own address, so the destination IP selects it
    # and the header's DST_ID is deliberately junk (0xF) to prove the hardware
    # table rewrites it.
    ep   = lambda n: f"10.10.10.{10 + n}"
    mem  = "10.10.10.18"
    host = (lambda n: ep(n)) if a.by_address else (lambda n: a.host)
    dsel = (lambda n: 0xF)   if a.by_address else (lambda n: n)

    # 1. loopback to endpoint 0: three words out, three words back
    pay = [0x1111222233334444, 0xAAAABBBBCCCCDDDD, 0x0123456789ABCDEF]
    r = exchange(s, host(0), a.port, hdr(T_DATA, 0, dsel(0), 3, 0x71) + words(*pay))
    if r is None:
        print("  FAIL no reply to loopback (is the board running n3_main?)")
        sys.exit(1)
    check("loopback type", TYPES.get(r["type"]), "DATA")
    check("loopback SRC stamped to 0", r["src"], 0)
    check("loopback tag echoed", r["tag"], 0x71)
    check("loopback payload", r["words"], pay)

    # 2. memory write then read back
    data = [0xFEEDFACE00000000 + i for i in range(4)]
    mhost = mem if a.by_address else a.host
    mdst  = 0xF if a.by_address else MEM_ID
    r = exchange(s, mhost, a.port, hdr(T_WR, 0, mdst, 5, 0x72) + words(0x1200, *data))
    check("write response", TYPES.get(r["type"]) if r else None, "MEM_WRITE_RESP")

    r = exchange(s, mhost, a.port, hdr(T_RD, 0, mdst, 2, 0x73) + words(0x1200, 4))
    check("read response", TYPES.get(r["type"]) if r else None, "MEM_READ_RESP")
    check("read-back data", r["words"] if r else None, data)

    # 3. error path: misaligned address comes back as T_ERROR/E_ALIGN
    r = exchange(s, mhost, a.port, hdr(T_RD, 0, mdst, 2, 0x74) + words(0x1203, 1))
    check("error type", TYPES.get(r["type"]) if r else None, "T_ERROR")
    check("error code", ERRS.get(r["flags"]) if r else None, "E_ALIGN")

    # 4. malformed datagram: not a whole number of flits, must be ignored
    exchange(s, host(0), a.port, hdr(T_DATA, 0, dsel(0), 1) + b"\x01\x02\x03",
             expect_reply=False)
    r = exchange(s, host(0), a.port, hdr(T_DATA, 0, dsel(0), 1, 0x75) + words(0xABCD))
    check("bridge still alive after a malformed datagram",
          r["tag"] if r else None, 0x75)

    tag = "N4" if a.by_address else "N3"
    print(f"\n{tag} PASS" if fails == 0 else f"\n{tag} FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()