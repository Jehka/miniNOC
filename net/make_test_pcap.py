#!/usr/bin/env python3
"""make_test_pcap.py -- write a capture of Mini-NoC traffic without a network.

Builds every packet shape the bridge will produce or receive and writes them to
a pcap. Open it in Wireshark with the dissector to check the decoder before any
real packet exists; when N3's first packet then decodes wrongly, the packet is
wrong, not the tooling.

    python3 net/make_test_pcap.py                     # writes noc_sample.pcap
    wireshark -X lua_script:net/noc_dissector.lua noc_sample.pcap

No root, no interface, nothing transmitted. Mirrors the cases in
tb/tb_n1_bridge.sv and sw/n1_main.c.
"""
import argparse, struct

from scapy.all import Ether, IP, UDP, Raw, wrpcap

PORT_DATA, PORT_RD, PORT_WR = 5555, 5556, 5557
T_DATA, T_RD, T_RD_RESP, T_WR, T_WR_RESP, T_ERR = 0x0, 0x1, 0x2, 0x3, 0x4, 0xF
E_TYPE, E_LEN, E_ALIGN, E_RANGE = 1, 2, 3, 4

HOST = "192.168.1.1"
EP   = lambda n: f"192.168.1.{10 + n}"     # endpoint n
MEM  = "192.168.1.18"
MACB, MACH = "00:0a:35:00:01:22", "aa:bb:cc:dd:ee:ff"


def hdr(ptype, src, dst, length, tag=0, flags=0):
    """64-bit NoC header, big-endian (design spec section 4)."""
    w = ((ptype & 0xF) << 60 | (src & 0xF) << 56 | (dst & 0xF) << 52
         | (length & 0xFFFF) << 36 | (tag & 0xFF) << 28 | (flags & 0xF) << 24)
    return struct.pack(">Q", w)


def words(*vals):
    return b"".join(struct.pack(">Q", v) for v in vals)


def to_board(dst_ip, port, payload):
    return (Ether(src=MACH, dst=MACB) / IP(src=HOST, dst=dst_ip)
            / UDP(sport=40000, dport=port) / Raw(payload))


def from_board(src_ip, port, payload):
    return (Ether(src=MACB, dst=MACH) / IP(src=src_ip, dst=HOST)
            / UDP(sport=port, dport=40000) / Raw(payload))


def build():
    pkts, notes = [], []

    def add(p, note):
        pkts.append(p); notes.append(note)

    # --- ordinary traffic
    add(to_board(EP(3), PORT_DATA, hdr(T_DATA, 0, 3, 3) + words(0x1111222233334444,
                                                               0xAAAABBBBCCCCDDDD,
                                                               0x0123456789ABCDEF)),
        "DATA, 3 words, host -> endpoint 3")
    add(to_board(EP(5), PORT_DATA, hdr(T_DATA, 0, 5, 0)),
        "DATA, header only (LENGTH 0, legal)")

    # --- memory request/response pairs
    add(to_board(MEM, PORT_WR, hdr(T_WR, 0, 8, 3, tag=0x21) + words(0x1000, 0xCAFE0001, 0xCAFE0002)),
        "MEM_WRITE_REQ, 2 words at 0x1000")
    add(from_board(MEM, PORT_WR, hdr(T_WR_RESP, 8, 0, 0, tag=0x21)),
        "MEM_WRITE_RESP")
    add(to_board(MEM, PORT_RD, hdr(T_RD, 0, 8, 2, tag=0x22) + words(0x1000, 2)),
        "MEM_READ_REQ, 2 words at 0x1000")
    add(from_board(MEM, PORT_RD, hdr(T_RD_RESP, 8, 0, 2, tag=0x22) + words(0xCAFE0001, 0xCAFE0002)),
        "MEM_READ_RESP with the data")

    # --- every error code, as the adapter returns it
    for tag, code, name, req in (
        (0x31, E_ALIGN, "E_ALIGN", to_board(MEM, PORT_WR, hdr(T_WR, 0, 8, 3, tag=0x31) + words(0x1003, 1, 2))),
        (0x32, E_RANGE, "E_RANGE", to_board(MEM, PORT_RD, hdr(T_RD, 0, 8, 2, tag=0x32) + words(1024 * 8, 1))),
        (0x33, E_LEN,   "E_LEN",   to_board(MEM, PORT_WR, hdr(T_WR, 0, 8, 5, tag=0x33) + words(0x80, 0xDEAD))),
        (0x34, E_TYPE,  "E_TYPE",  to_board(MEM, PORT_DATA, hdr(T_DATA, 0, 8, 2, tag=0x34) + words(1, 2))),
    ):
        add(req, f"request that should fail with {name}")
        add(from_board(MEM, req[UDP].dport, hdr(T_ERR, 8, 0, 0, tag=tag, flags=code)),
            f"T_ERROR response, FLAGS={name}")

    # --- malformed, to check the dissector flags rather than crashes
    add(to_board(EP(2), PORT_DATA, hdr(T_DATA, 0, 2, 9) + words(1, 2)),
        "LENGTH 9 but only 2 payload words: dissector should mark it truncated")
    add(to_board(EP(2), PORT_DATA, hdr(T_DATA, 0, 2, 1) + b"\x01\x02\x03"),
        "payload not a multiple of 8 bytes")
    add(to_board(EP(0), PORT_DATA, hdr(T_DATA, 0, 12, 1) + words(0xDEADBEEF)),
        "DST_ID 12: no such output, the fabric sinks it")

    return pkts, notes


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="noc_sample.pcap")
    a = ap.parse_args()
    pkts, notes = build()
    wrpcap(a.out, pkts)
    print(f"wrote {len(pkts)} packets to {a.out}\n")
    for i, n in enumerate(notes, 1):
        print(f"  {i:2d}. {n}")
    print("\nopen with:  wireshark -X lua_script:net/noc_dissector.lua " + a.out)


if __name__ == "__main__":
    main()