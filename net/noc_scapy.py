#!/usr/bin/env python3
"""noc_scapy.py -- host-side traffic and error-path suite for the Mini-NoC bridge.

Stage N3 sends valid encapsulated packets; stage N5 drives every error code from
the network side, to prove on hardware what the simulation scoreboard proves in
Verilator. Mirrors tb_noc_top's P6 phase.

    sudo python3 net/noc_scapy.py --iface eth0 --host 192.168.1.10 valid
    sudo python3 net/noc_scapy.py --iface eth0 errors
    sudo python3 net/noc_scapy.py --iface eth0 sink

Requires scapy (pip install scapy). Run alongside:
    tshark -X lua_script:net/noc_dissector.lua -Y noc
"""
import argparse, struct, sys

try:
    from scapy.all import IP, UDP, Raw, send, sr1, conf
except ImportError:
    sys.exit("scapy not installed: pip install scapy")

PORT_DATA, PORT_RD, PORT_WR = 5555, 5556, 5557
T_DATA, T_RD, T_WR, T_ERR = 0x0, 0x1, 0x3, 0xF
BASE = "192.168.1."          # .10 + dst_id, .18 = memory


def hdr(ptype, src, dst, length, tag=0, flags=0):
    """64-bit NoC header, big-endian (design spec section 4)."""
    w = (ptype & 0xF) << 60 | (src & 0xF) << 56 | (dst & 0xF) << 52 \
        | (length & 0xFFFF) << 36 | (tag & 0xFF) << 28 | (flags & 0xF) << 24
    return struct.pack(">Q", w)


def pkt(ip, port, payload, ttl=64):
    return IP(dst=ip, ttl=ttl) / UDP(sport=40000, dport=port) / Raw(payload)


def words(*vals):
    return b"".join(struct.pack(">Q", v) for v in vals)


def case(name, expect, p, iface, wait=False):
    print(f"\n=== {name}\n    expect: {expect}")
    if wait:
        r = sr1(p, iface=iface, timeout=2, verbose=0)
        print("    reply :", "none (timeout)" if r is None else r.summary())
        if r and Raw in r:
            w = struct.unpack(">Q", bytes(r[Raw])[:8])[0]
            t, fl = (w >> 60) & 0xF, (w >> 24) & 0xF
            if t == T_ERR:
                names = {1: "E_TYPE", 2: "E_LEN", 3: "E_ALIGN", 4: "E_RANGE"}
                print(f"    decoded: T_ERROR flags={fl} ({names.get(fl, '?')})")
    else:
        send(p, iface=iface, verbose=0)
        print("    sent (no reply expected)")


def run_valid(a):
    ep = lambda n: BASE + str(10 + n)
    case("DATA, 4 words, endpoint 3", "delivered, stat_rx_pkts += 1",
         pkt(ep(3), PORT_DATA, hdr(T_DATA, 0, 3, 4) + words(1, 2, 3, 4)), a.iface)
    case("DATA, header only (LENGTH 0)", "delivered, legal per spec section 4",
         pkt(ep(5), PORT_DATA, hdr(T_DATA, 0, 5, 0)), a.iface)
    case("MEM write 2 words @0x40", "MEM_WRITE_RESP",
         pkt(BASE + "18", PORT_WR, hdr(T_WR, 0, 8, 3) + words(0x40, 0xAA, 0xBB)),
         a.iface, wait=True)
    case("MEM read 2 words @0x40", "MEM_READ_RESP with 0xAA, 0xBB",
         pkt(BASE + "18", PORT_RD, hdr(T_RD, 0, 8, 2) + words(0x40, 2)),
         a.iface, wait=True)


def run_errors(a):
    mem = BASE + "18"
    case("misaligned address 0x43", "T_ERROR E_ALIGN (0x3)",
         pkt(mem, PORT_WR, hdr(T_WR, 0, 8, 3) + words(0x43, 1, 2)), a.iface, wait=True)
    case("address past 1024 words", "T_ERROR E_RANGE (0x4)",
         pkt(mem, PORT_RD, hdr(T_RD, 0, 8, 2) + words(1024 * 8, 1)), a.iface, wait=True)
    case("read count runs past end", "T_ERROR E_RANGE (0x4)",
         pkt(mem, PORT_RD, hdr(T_RD, 0, 8, 2) + words(1022 * 8, 4)), a.iface, wait=True)
    case("LENGTH says 5, payload has 2", "T_ERROR E_LEN (0x2)",
         pkt(mem, PORT_WR, hdr(T_WR, 0, 8, 5) + words(0x80, 0xDEAD)), a.iface, wait=True)
    case("DATA sent to the memory endpoint", "T_ERROR E_TYPE (0x1)",
         pkt(mem, PORT_DATA, hdr(T_DATA, 0, 8, 2) + words(1, 2)), a.iface, wait=True)
    case("payload not a multiple of 8 bytes", "rejected, E_LEN",
         pkt(mem, PORT_WR, hdr(T_WR, 0, 8, 2) + b"\x01\x02\x03"), a.iface, wait=True)


def run_sink(a):
    """DST_ID 9-15 has no output port: the fabric sinks it (design spec section 5).
    Proves on hardware that an illegal destination drops rather than deadlocking."""
    case("DST_ID 12, illegal", "dropped, stat_sink_pkts += 1, no deadlock",
         pkt(BASE + "10", PORT_DATA, hdr(T_DATA, 0, 12, 2) + words(0xDEAD, 0xBEEF)),
         a.iface)
    case("follow-up to a legal endpoint", "delivered: the input did not block",
         pkt(BASE + "10", PORT_DATA, hdr(T_DATA, 0, 0, 1) + words(0x1234)), a.iface)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["valid", "errors", "sink", "all"])
    p.add_argument("--iface", default=conf.iface, help="sending interface")
    p.add_argument("--host", default=BASE + "10", help="board address (unused in errors)")
    a = p.parse_args()
    if a.mode in ("valid", "all"):  run_valid(a)
    if a.mode in ("errors", "all"): run_errors(a)
    if a.mode in ("sink", "all"):   run_sink(a)
    print("\nCheck stat_sink_pkts / stat_fwd_miss on the board (LD3 should stay dark "
          "only if no illegal traffic was sent).")


if __name__ == "__main__":
    main()
