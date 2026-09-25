#!/usr/bin/env python3
"""n5_errors.py -- drive every error path from the network side (stage N5).

The scoreboard proves these paths in simulation. This proves them on hardware,
from a host, over Ethernet: each malformed or illegal request is sent as a real
datagram and the response (or the absence of one, plus the counter that moved)
is checked.

    python3 net/n5_errors.py
    python3 net/n5_errors.py --board 10.10.10.10

Plain sockets, no admin rights. Run Wireshark with net/noc_dissector.lua loaded
to see each error decoded by name.

Three layers can reject a packet, and the point of this suite is that they are
distinguishable:

  network layer  address not answered for      -> no reply, no counter moves
  bridge         address not in the table      -> no reply, udp_no_route moves
  fabric         illegal request or DST_ID     -> T_ERROR, or sunk silently
"""
import argparse, socket, struct, sys

PORT_ADDR, PORT_RAW, PORT_CTL = 5555, 5556, 5557
T_DATA, T_RD, T_WR, T_ERR = 0x0, 0x1, 0x3, 0xF
MEM_ID = 8
ERRS = {0: "none", 1: "E_TYPE", 2: "E_LEN", 3: "E_ALIGN", 4: "E_RANGE"}
STATS = ["tx_count", "rx_count", "tx_drop", "fwd_miss",
         "udp_in", "udp_no_route", "udp_bad_length"]

fails = 0


def hdr(ptype, src, dst, length, tag=0, flags=0):
    return struct.pack(">Q", (ptype & 0xF) << 60 | (src & 0xF) << 56 | (dst & 0xF) << 52
                       | (length & 0xFFFF) << 36 | (tag & 0xFF) << 28 | (flags & 0xF) << 24)


def words(*v):
    return b"".join(struct.pack(">Q", x) for x in v)


def check(what, got, exp):
    global fails
    if got == exp:
        print(f"  ok   {what:<46} {got}")
    else:
        print(f"  FAIL {what:<46} got {got}  exp {exp}")
        fails += 1


def stats(sock, board):
    sock.sendto(struct.pack(">BBBB8x", 2, 0, 0, 0), (board, PORT_CTL))
    sock.settimeout(2.0)
    try:
        data, _ = sock.recvfrom(64)
    except socket.timeout:
        sys.exit("no reply from the control port")
    vals = struct.unpack(">7I", data[4:32])
    return dict(zip(STATS, vals))


def send(sock, addr, port, payload, wait=1.5):
    sock.sendto(payload, (addr, port))
    sock.settimeout(wait)
    try:
        data, _ = sock.recvfrom(2048)
    except socket.timeout:
        return None
    h = struct.unpack(">Q", data[:8])[0]
    return {"type": (h >> 60) & 0xF, "src": (h >> 56) & 0xF,
            "flags": (h >> 24) & 0xF, "tag": (h >> 28) & 0xFF,
            "words": [struct.unpack(">Q", data[8 + 8 * i:16 + 8 * i])[0]
                      for i in range((len(data) - 8) // 8)]}


def err_of(r):
    if r is None:
        return None
    return ERRS.get(r["flags"]) if r["type"] == T_ERR else f"not an error ({r['type']})"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--board", default="10.10.10.10")
    a = ap.parse_args()
    mem = "10.10.10.18"

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("", 0))
    print("== N5: error paths driven from the host ==\n")

    # ---- adapter errors: each comes back as T_ERROR with a code
    print("  -- memory adapter errors (spec section 9) --")
    check("misaligned address 0x1203",
          err_of(send(s, mem, PORT_ADDR, hdr(T_WR, 0, 0xF, 3, 0x91) + words(0x1203, 1, 2))),
          "E_ALIGN")
    check("address past the 1024-word region",
          err_of(send(s, mem, PORT_ADDR, hdr(T_RD, 0, 0xF, 2, 0x92) + words(1024 * 8, 1))),
          "E_RANGE")
    check("read count runs past the end",
          err_of(send(s, mem, PORT_ADDR, hdr(T_RD, 0, 0xF, 2, 0x93) + words(1022 * 8, 4))),
          "E_RANGE")
    check("LENGTH says 5, only 2 words sent",
          err_of(send(s, mem, PORT_ADDR, hdr(T_WR, 0, 0xF, 5, 0x94) + words(0x80, 0xDEAD))),
          "E_LEN")
    check("DATA sent to the memory endpoint",
          err_of(send(s, mem, PORT_ADDR, hdr(T_DATA, 0, 0xF, 2, 0x95) + words(1, 2))),
          "E_TYPE")

    # ---- the tag must come back, or a host cannot match errors to requests
    r = send(s, mem, PORT_ADDR, hdr(T_RD, 0, 0xF, 2, 0x96) + words(0x1203, 1))
    check("error response echoes the request tag", r["tag"] if r else None, 0x96)
    check("error response carries SRC_ID 8", r["src"] if r else None, MEM_ID)

    # ---- illegal destination: the fabric sinks it, and the input must not block
    print("\n  -- illegal destination (spec section 5) --")
    b0 = stats(s, a.board)
    check("DST_ID 12 gets no response",
          send(s, a.board, PORT_RAW, hdr(T_DATA, 0, 12, 2, 0x97) + words(0xDEAD, 0xBEEF), 1.0),
          None)
    r = send(s, a.board, PORT_RAW, hdr(T_DATA, 0, 0, 1, 0x98) + words(0x1234))
    check("the next packet still gets through (no deadlock)",
          r["words"] if r else None, [0x1234])
    b1 = stats(s, a.board)
    check("the sunk packet was pushed to the fabric",
          b1["tx_count"] > b0["tx_count"], True)

    # ---- bridge-level rejections, told apart by which counter moved
    print("\n  -- rejected before the fabric --")
    c0 = stats(s, a.board)
    s.sendto(hdr(T_DATA, 0, 0, 1, 0x99) + b"\x01\x02\x03", (a.board, PORT_ADDR))
    s.sendto(hdr(T_DATA, 0, 0, 0, 0x9A)[:5], (a.board, PORT_ADDR))
    c1 = stats(s, a.board)
    check("two malformed datagrams counted as bad_length",
          c1["udp_bad_length"] - c0["udp_bad_length"], 2)
    check("neither reached the fabric", c1["tx_count"] - c0["tx_count"], 0)

    # An address the board answers for but that is not in the table cannot be
    # produced from the host once the two are kept in step, so this checks the
    # counter exists and stays still rather than trying to force it.
    check("no spurious no-route events", c1["udp_no_route"] - c0["udp_no_route"], 0)

    # ---- still healthy afterwards
    print("\n  -- still healthy --")
    r = send(s, a.board, PORT_ADDR, hdr(T_DATA, 0, 0xF, 2, 0x9B) + words(0xA5A5, 0x5A5A))
    check("normal traffic after every error", r["words"] if r else None, [0xA5A5, 0x5A5A])

    f = stats(s, a.board)
    print("\n  counters:", ", ".join(f"{k}={v}" for k, v in f.items()))
    print("\nN5 PASS" if fails == 0 else f"\nN5 FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()