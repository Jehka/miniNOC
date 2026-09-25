#!/usr/bin/env python3
"""n4_remap.py -- move an endpoint to a different IP address, live (stage N4).

The address-to-endpoint mapping is a table in the PL, writable at runtime over
AXI-Lite and, since N4, over the network itself. So an endpoint can be moved to
a new address while the board is running: no rebuild, no reboot, no bitstream.

    python3 net/n4_remap.py                       # full demonstration
    python3 net/n4_remap.py --show                # print the table and stop

Sequence: prove memory answers at .18, move it to .20, prove .18 has gone dark
and .20 works, then put it back. Note that the old address is refused at the IP
layer once it is unmapped, so it never reaches the fabric and the hardware miss
counter stays put; that is the layering working, not a gap. Run Wireshark alongside with the dissector to
watch the address change mid-capture.
"""
import argparse, socket, struct, sys

PORT_ADDR, PORT_CTL = 5555, 5557
T_RD, T_RD_RESP, T_WR, T_WR_RESP = 0x1, 0x2, 0x3, 0x4
MEM_ID, MEM_ENTRY = 8, 8
CTL_READ, CTL_WRITE = 0, 1

fails = 0


def hdr(ptype, src, dst, length, tag=0, flags=0):
    return struct.pack(">Q", (ptype & 0xF) << 60 | (src & 0xF) << 56 | (dst & 0xF) << 52
                       | (length & 0xFFFF) << 36 | (tag & 0xFF) << 28 | (flags & 0xF) << 24)


def words(*v):
    return b"".join(struct.pack(">Q", x) for x in v)


def check(what, got, exp):
    global fails
    if got == exp:
        print(f"  ok   {what:<44} {got}")
    else:
        print(f"  FAIL {what:<44} got {got}  exp {exp}")
        fails += 1


def ctl(sock, board, op, idx, ip="0.0.0.0", dst=0, valid=0):
    """Read or write one forwarding-table entry. Returns (ip, dst, valid, misses)."""
    msg = struct.pack(">BBBB4sI", op, idx, dst, valid, socket.inet_aton(ip), 0)[:12]
    sock.sendto(msg, (board, PORT_CTL))
    sock.settimeout(2.0)
    try:
        data, _ = sock.recvfrom(64)
    except socket.timeout:
        return None
    _op, _idx, d, v, a, misses = struct.unpack(">BBBB4sI", data[:12])
    return socket.inet_ntoa(a), d, v, misses


def mem_read(sock, addr, tag, timeout=1.5):
    """Read one word from the memory endpoint at whichever address it holds."""
    sock.sendto(hdr(T_RD, 0, 0xF, 2, tag) + words(0x1200, 1), (addr, PORT_ADDR))
    sock.settimeout(timeout)
    try:
        data, _ = sock.recvfrom(2048)
    except socket.timeout:
        return None
    h = struct.unpack(">Q", data[:8])[0]
    if ((h >> 60) & 0xF) != T_RD_RESP:
        return None
    return struct.unpack(">Q", data[8:16])[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--board", default="10.10.10.10", help="any address the board answers")
    ap.add_argument("--old", default="10.10.10.18")
    ap.add_argument("--new", default="10.10.10.20")
    ap.add_argument("--show", action="store_true", help="print the table and exit")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("", 0))

    if a.show:
        print("entry  address          dst  valid")
        for i in range(16):
            r = ctl(s, a.board, CTL_READ, i)
            if r is None:
                sys.exit("no reply from the control port")
            ip, dst, valid, _ = r
            if valid:
                print(f"  {i:<4} {ip:<16} {dst:<4} {valid}")
        return

    print(f"== forwarding table: moving memory from {a.old} to {a.new} ==\n")

    # Seed a known value so the read-back proves it is the same memory.
    s.sendto(hdr(T_WR, 0, 0xF, 2, 0x81) + words(0x1200, 0xD00DFEED12345678),
             (a.old, PORT_ADDR))
    s.settimeout(2.0)
    try:
        s.recvfrom(2048)
    except socket.timeout:
        sys.exit(f"no write response from {a.old}: is the board running and reachable?")

    check(f"memory readable at {a.old}", mem_read(s, a.old, 0x82), 0xD00DFEED12345678)

    r = ctl(s, a.board, CTL_READ, MEM_ENTRY)
    check(f"table entry {MEM_ENTRY} holds {a.old}", r[0] if r else None, a.old)

    print(f"\n  -- writing entry {MEM_ENTRY}: {a.new} -> endpoint {MEM_ID} --")
    r = ctl(s, a.board, CTL_WRITE, MEM_ENTRY, a.new, MEM_ID, 1)
    check("entry now reads back as", r[0] if r else None, a.new)
    misses_before = r[3] if r else 0

    check(f"memory answers at {a.new}", mem_read(s, a.new, 0x83), 0xD00DFEED12345678)
    check(f"{a.old} no longer answers", mem_read(s, a.old, 0x84), None)

    # The old address is rejected at the IP layer, not by the fabric: once the
    # entry moved, the board stopped answering for it at all, so the packet
    # never reached the bridge and FWD_MISS cannot count it. A miss is counted
    # only for an address the board accepts but the table does not map, which
    # is what the AXI-Lite tests exercise directly.
    r = ctl(s, a.board, CTL_READ, MEM_ENTRY)
    check(f"{a.old} dropped before the fabric (FWD_MISS unchanged)",
          (r[3] - misses_before) if r else None, 0)

    print(f"\n  -- restoring entry {MEM_ENTRY}: {a.old} -> endpoint {MEM_ID} --")
    r = ctl(s, a.board, CTL_WRITE, MEM_ENTRY, a.old, MEM_ID, 1)
    check("entry restored", r[0] if r else None, a.old)
    check(f"memory answers at {a.old} again", mem_read(s, a.old, 0x85), 0xD00DFEED12345678)

    print("\nREMAP PASS" if fails == 0 else f"\nREMAP FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()