
# Plan

Two tracks, both complete on hardware. Track A is the packet interconnect,
closing timing at 70 MHz and running error-free on a ZedBoard. Track B puts it
on a real IP network: each endpoint has its own address, a hardware forwarding
table routes by address and is reprogrammable at runtime from the host, and the
endpoint address space is filterable by ordinary router policy.

## Status at a glance

| Stage                                   | State                                       |
| --------------------------------------- | ------------------------------------------- |
| Track A: P0-P9                          | **Done on hardware**                  |
| N1 PS-PL bridge                         | **Done on hardware**                  |
| N2 lwIP echo                            | **Done**                              |
| N3 Encapsulation                        | **Done**                              |
| N4 Forwarding table, ARP, control plane | **Done**                              |
| N5 Error paths from the network         | **Done**                              |
| N6 Routed hop and ACL                   | **Done**                              |
| N7 DMA throughput                       | Optional; baseline measured (3.4 MB/s MMIO) |

**Next, in order of value:**

1. Out-of-context utilization for `noc_top`, so the fabric-only area figure is
   separable from the self-test harness.
2. Write-up: the captures, the timing history, and the two network bugs in
   section 26.1 of the network spec.
3. N7, if throughput becomes interesting: AXI-DMA against the 3.4 MB/s baseline.
4. v0.4 RTL: credit-based flow control to lift the 73.6 MHz ceiling.

---

## Track A — packet interconnect (RTL / FPGA)

| Milestone                              | State                                                  |
| -------------------------------------- | ------------------------------------------------------ |
| P0 Protocol frozen                     | Done (spec v0.2)                                       |
| P1 Round-robin arbiter                 | Done                                                   |
| P2 Lossless FIFO                       | Done                                                   |
| P3 Output arbitration + packet locking | Done                                                   |
| P4 9x10 crossbar, concurrent outputs   | Done                                                   |
| P5 Eight endpoints integrated          | Done                                                   |
| P6 Memory endpoint + BRAM              | Done                                                   |
| P7 System scoreboard, random traffic   | Done                                                   |
| P8 Vivado implementation               | Done — timing met at 70 MHz                           |
| P9 Board bring-up                      | Done — zero errors, including randomized backpressure |

### A remaining (small)

- **Out-of-context utilization for `noc_top`.** Current figures include the
  eight self-test generators; the fabric-only number is the one worth quoting.
- **Record measured area and frequency** in design spec section 13.

### A deferred (v0.4+)

- Credit-based flow control with registered ready, to lift the 73.6 MHz ceiling.
  Changes the section 3 flow-control contract.
- Register slice on each switch output: one cycle of latency, no throughput cost.
- Memory byte enables; AXI4 adapter to PS DDR.
- Fragmentation and reassembly in the fabric.

---

## Track B — network integration

Full specification in `docs/network_integration.md`. Decisions taken: PS GEM with
lwIP; one IP address per endpoint with a runtime-writable forwarding table in the
PL; encapsulation first, translation second.

### N1 — PS-PL bridge  · **Done on hardware**

An AXI4-Lite slave on endpoint 0 lets the PS inject and receive flits. Endpoints
1-7 keep their generators, so PS traffic runs alongside on-chip traffic.

Built: `rtl/axil_noc_bridge.sv`, `fpga/n1_top.sv`, `fpga/n1_bd.tcl`,
`tb/tb_n1_bridge.sv`, `sw/`.
Hardware: loopback with SRC_ID stamping, memory write and read-back, E_ALIGN
error response, 1000 x 32-flit soak with zero bad. MMIO baseline 3.4 MB/s each
way. Loopback is concurrent with generator traffic but not contended (generators
never address endpoint 0); memory requests do contend.

### N2 — lwIP echo, no NoC  · **Done**

Vitis *lwIP Echo Server* template on the same platform, static IP 10.10.10.10,
laptop at 10.10.10.1/24, direct cable.

*Proves:* GEM, PHY, cable and IP configuration, independent of the RTL.
*Artifact:* `ping 10.10.10.10` and a UDP echo from the laptop.

### N3 — Encapsulation  · **Done**

UDP payload is a raw NoC packet (spec section 20). Port 5555 routes by
destination address, 5556 by the DST_ID in the header.

Hardware: `net/n3_test.py` passes — loopback with SRC_ID stamping, memory write
and read-back, E_ALIGN, and a malformed datagram rejected without disturbing the
next. Captures decode by name with `net/noc_dissector.lua`.

Two bugs found, both in the reply path and both invisible from the board's
counters: a reply must leave from the port the request arrived on, and from the
address the client contacted. See network spec 26.1.

### N4 — Forwarding table, ARP and control plane  · **Done**

Built: `rtl/fwd_table.sv` (16 entries in flip-flops, searched in parallel) and
route-by-IP in the bridge: software pushes a packet addressed by IP, hardware
rewrites DST_ID, a miss discards the whole packet and counts it once, replies
carry their source IP through a reverse lookup.

Hardware: probe hit and miss, DST rewrite from a junk value, reverse lookup for
endpoint and memory replies, whole-packet discard with the next packet intact,
live remap of memory from .18 to .20, invalidation checked on the datapath.
Mutants M10 (miss drops only the header) and M11 (datapath ignores the valid
bit) are caught. M11 initially escaped, because invalidation was only checked
through the probe register, which is a separate lookup.

`sw/noc_alias.c` wraps `netif->input` to answer ARP for the alias addresses,
reply to pings, and pass UDP up with the original destination preserved. lwIP
was left unpatched, so BSP regeneration cannot undo it.

UDP port 5557 is a control plane: the host reads and writes table entries at
runtime. `net/n4_remap.py` moves memory from .18 to .20 while running, reads the
same data back at the new address, and restores it — no rebuild, no reboot.

*Artifacts:* `ping` to .10-.18, `arp -a` showing them on one MAC,
`n3_test.py --by-address` passing with every header DST_ID set to 0xF.

### N5 — Error paths from the network side  · **Done**

`net/n5_errors.py` drives every code from the host: E_ALIGN, E_RANGE (address
and burst), E_LEN, E_TYPE. Responses echo the request TAG and carry SRC_ID 8, so
errors can be matched to requests. An illegal DST_ID is sunk and the next packet
still arrives, confirming the input does not block.

A stats operation on the control port exposes the bridge counters, so a dropped
packet is proved dropped and the three rejection layers — network, bridge,
fabric — are distinguishable rather than inferred from a timeout.

### N6 — Routed hop and ACL  · **Done**

Board behind a namespace router (`net/netns_lab.sh`), reached from another
subnet, with an nftables rule permitting 10.10.10.10-.13 and denying .14-.17.

*Proves:* the board is a well-formed host and the NoC destination space is
filterable by ordinary network policy.

### N7 — Throughput (optional)

Replace MMIO with AXI-DMA and AXI-Stream so the PS handles control only. The
forwarding table stays in place and becomes the only routing authority.

*Baseline:* 3.4 MB/s each way over MMIO against roughly 530 MB/s per fabric port.

---

## Tooling

| Tool                        | Use                                                            | Cost           |
| --------------------------- | -------------------------------------------------------------- | -------------- |
| Wireshark + Lua dissector   | Decode the on-chip protocol on the wire                        | Free           |
| Scapy                       | Craft valid and malformed packets; write test captures offline | Free           |
| `ip netns` + `nftables` | Routed hop and ACLs, scripted in-repo                          | Free           |
| FRRouting / containerlab    | Real router CLI and OSPF, if wanted                            | Free           |
| Cisco CML                   | Same demonstration, licensed                                   | Paid, optional |
| Cisco Packet Tracer         | Unusable: no path to physical interfaces                       | —             |

Used in practice: a direct cable through a USB Ethernet adapter, static IPs,
Wireshark with the Lua dissector, plain Python sockets for the test suites, and
WSL2 with mirrored networking for the routed-hop lab. No commercial simulator
was needed at any point.
