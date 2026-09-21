# Plan

Two tracks. Track A, the interconnect, is complete and runs on hardware. Track B,
network integration, is under way: the PS-to-fabric bridge and the hardware
forwarding table work on the board. Everything from here that touches a real
network waits on an Ethernet cable.

## Status at a glance

| Stage                           | State                                               |
| ------------------------------- | --------------------------------------------------- |
| Track A: P0-P9                  | **Done on hardware**                          |
| N1 PS-PL bridge                 | **Done on hardware**                          |
| N2 lwIP echo                    | Needs Ethernet cable                                |
| N3 Encapsulation                | Needs cable; application code can be written now    |
| N4 Forwarding table             | **PL half done on hardware**; ARP needs cable |
| N5 Error paths from the network | Needs cable                                         |
| N6 Routed hop and ACL           | Needs cable                                         |
| N7 DMA throughput               | Optional; baseline measured                         |

**Next session, no cable needed:**

1. Test `net/noc_dissector.lua` on a Scapy-written `.pcap` (no packets sent).
2. Write the lwIP UDP application for N3 against the existing bridge driver.

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

### N2 — lwIP echo, no NoC  · *needs cable*

Vitis *lwIP Echo Server* template on the same platform, static IP 192.168.1.10,
laptop at 192.168.1.1/24, direct cable.

*Proves:* GEM, PHY, cable and IP configuration, independent of the RTL.
*Artifact:* `ping 192.168.1.10` and a UDP echo from the laptop.

### N3 — Encapsulation, one endpoint  · *needs cable*

Join N1 and N2: UDP payload is a raw NoC packet (spec section 20), port 5555.
The application code can be written and compiled before the cable arrives.

*Proves:* the end-to-end path.
*Artifact:* Wireshark capture with `net/noc_dissector.lua` decoding the fields.

### N4 — Forwarding table and ARP  · **PL half done on hardware**

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

Remaining: lwIP answering ARP for nine addresses behind one MAC.
*Artifact:* `ping` to .10-.18, `arp -a` showing nine IPs on one MAC.

*Risk:* multi-address ARP in lwIP may resist. Fallback is one address with
port-per-endpoint (spec section 19), degrading the demonstration but not the
datapath.

### N5 — Error paths from the network side  · *needs cable*

Drive each error code from the host with `net/noc_scapy.py`.

*Proves:* E_TYPE, E_LEN, E_ALIGN, E_RANGE and the sink path fire from the
network, not just from software.
*Artifact:* one capture per code; `FWD_MISS` and `stat_sink_pkts` incrementing
as predicted.

### N6 — Routed hop and ACL  · *needs cable*

Board behind a namespace router (`net/netns_lab.sh`), reached from another
subnet, with an nftables rule permitting 192.168.1.10-.13 and denying .14-.17.

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

N1 and the PL half of N4 need no network. N2 onward need a direct cable (a USB
Ethernet adapter too, if the laptop has no port), static IPs and Wireshark.
