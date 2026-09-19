# Plan

Two tracks. Track A (the interconnect) is complete through synthesis and closes
timing. Track B (network integration) is the next body of work.

---

## Track A — packet interconnect (RTL / FPGA)

| Milestone | State |
|---|---|
| P0 Protocol frozen | Done (spec v0.2) |
| P1 Round-robin arbiter | Done |
| P2 Lossless FIFO | Done |
| P3 Output arbitration + packet locking | Done |
| P4 9x10 crossbar, concurrent outputs | Done |
| P5 Eight endpoints integrated | Done |
| P6 Memory endpoint + BRAM | Done |
| P7 System scoreboard, random traffic | Done |
| P8 Vivado implementation | **Timing met at 70 MHz** |
| P9 Board bring-up | **Next** — program, SW0, confirm LD1 |

### A remaining

1. **Board bring-up.** Program the bitstream, SW0 up, confirm LD1 green and LD2/LD3 dark. Then SW1 for random RX backpressure, which is the case most likely to expose an arbitration bug that simulation stalls did not reach.
2. **Out-of-context utilization for `noc_top`.** Current figures (7518 LUTs, 4114 FF, 2 BRAM) include the eight self-test generators. The fabric-only number is the one worth quoting.
3. **Record measured area and frequency** in design spec section 13 alongside the timing table.

### A deferred (v0.4+)

- Credit-based flow control with registered ready, to lift the 73.6 MHz ceiling. Changes the section 3 flow-control contract.
- Register slice on each switch output: one cycle of latency per packet, no throughput cost.
- Memory byte enables; AXI4 adapter to PS DDR.
- Fragmentation/reassembly in the fabric.

---

## Track B — network integration

Full specification in `docs/network_integration.md`. Decisions taken: PS GEM
with lwIP; IP alias per endpoint with a runtime-writable forwarding table;
encapsulation first, translation second.

### N1 — PS-PL bridge, no Ethernet

Replace one `ep_traffic` instance with an AXI-Lite slave exposing a flit write
register, a flit read register and status. Write flits from bare-metal C, read
them back through the fabric.

*Proves:* the bridge works before the network exists.
*Artifact:* C loopback program, console transcript.

### N2 — lwIP echo, no NoC

Standard Xilinx lwIP echo template on the PS. Static IP 192.168.1.10.

*Proves:* GEM, PHY, cabling and IP configuration, independent of your RTL.
*Artifact:* `ping` and a UDP echo from the laptop.

### N3 — Encapsulation, one endpoint

Join N1 and N2. UDP payload is a raw NoC packet (spec section 20). One endpoint
reachable on port 5555.

*Proves:* the end-to-end path.
*Artifact:* Wireshark capture with `net/noc_dissector.lua` decoding TYPE, SRC_ID,
DST_ID, LENGTH, TAG.

### N4 — Forwarding table and ARP

Answer ARP for nine addresses behind one MAC. Implement the PL forwarding table
(16 entries, AXI-Lite writable). All nine addresses reachable.

*Proves:* the address plan; this is the core networking work.
*Artifact:* `ping` to .10-.18; `arp -a` showing nine IPs on one MAC; a live
remap of one endpoint to a different address with no rebuild.

*Risk:* lwIP ARP for multiple addresses is the one step that may resist. Fallback
is one address with port-per-endpoint (spec section 19), which degrades the
demonstration but not the datapath.

### N5 — Error paths from the network side

Drive each error code from the host with crafted packets.

*Proves:* E_TYPE, E_LEN, E_ALIGN, E_RANGE and the sink path fire on hardware,
not just in simulation.
*Artifact:* `net/noc_scapy.py` suite, one capture per code; `stat_sink_pkts` and
`stat_fwd_miss` incrementing as predicted.

### N6 — Routed hop and ACL

Board behind a router, reached from another subnet, with a filter on the
endpoint address range.

*Proves:* the board is a well-formed host and the NoC destination space is
filterable by ordinary network policy.
*Artifact:* `net/netns_lab.sh` topology; ACL permitting 192.168.1.10-.13 and
denying .14-.17, with pings before and after.

### N7 — Throughput (optional)

Replace AXI-Lite with AXI-DMA and AXI-Stream so the PS handles control only.

*Artifact:* `iperf3` or a custom sender, before and after numbers.

---

## Tooling

| Tool | Use | Cost |
|---|---|---|
| Wireshark + Lua dissector | Decode the on-chip protocol on the wire | Free |
| Scapy | Craft valid and malformed packets | Free |
| `ip netns` + `nftables` | Routed hop, ACLs, reproducible in-repo | Free |
| FRRouting / containerlab | Real router CLI, OSPF, if wanted | Free |
| Cisco CML | Same demonstration, licensed | Paid, optional |
| Cisco Packet Tracer | **Unusable** — no path to physical interfaces | — |

Stages N1-N5 need only a direct cable, static IPs and Wireshark.
