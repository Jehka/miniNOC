
---
title: "Mini-NoC: A Custom Packet-Switched Interconnect and SoC on Zynq-7000"
subtitle: "Design, Verification, FPGA Implementation and IP Network Integration — Consolidated Report v1.0 | SystemVerilog | Vivado 2025.2 | ZedBoard xc7z020"
---
**What this is.** A packet-switched network-on-chip designed from scratch in SystemVerilog, verified against a reference model, implemented on a ZedBoard, and then integrated into a working SoC whose endpoints are reachable as hosts on a real IP network.

Nothing here is a vendor IP core wired together. The flit format, the crossbar, the arbiter, the FIFOs, the memory adapter, the AXI4-Lite bridge and the hardware forwarding table are all original RTL. The software that puts them on a network — the UDP bridge, the ARP and ICMP handling for nine addresses on one MAC, the runtime control plane — is original too. The only vendor components are the Zynq processing system, its Ethernet MAC, and lwIP.

**What works, on hardware.** Eight endpoints and a shared-memory endpoint exchange packets through a 9x10 crossbar at 70 MHz, error-free under randomised backpressure. Each endpoint has its own IPv4 address and answers `ping`. A laptop sends a UDP datagram to 10.10.10.13 and it arrives at endpoint 3, because a forwarding table in the PL looked the address up and rewrote the packet header. That table is rewritten at runtime from the host, so an endpoint can be moved to a different address while traffic is flowing. A router ACL permits endpoints 0-3 and denies 4-7.

**Structure.** Part I is the interconnect: architecture, protocol, RTL and verification. Part II is the network layer: address plan, encapsulation, forwarding and error mapping. Part III records what was built, measured and learned, including the timing-closure history and the bugs worth remembering. The appendix is the v0.1 design review that shaped the protocol.

---

# Part I — The Interconnect

**Purpose.** Define a buildable first-generation packet-switched interconnect with any-to-any endpoint communication, whole-packet round-robin arbitration, buffering, backpressure, ordering, and a shared-memory endpoint.

**Changes in v0.3.0.** Fabric clock set to 70 MHz from an MMCM. Measured maximum for this architecture on xc7z020-1 is 73.6 MHz, limited by the arbitration loop; 100 MHz is not achievable without credit-based flow control.

**Changes in v0.2.3.** Status counters are pipelined: event bits and their population count are registered before the 32-bit increment. Counts are unchanged, two cycles later.

**Changes in v0.2.2.** Each switch input is register-sliced (`skid_reg`) ahead of route decode and arbitration, removing the FIFO LUTRAM read and route-decode logic from the arbitration path. No latency or throughput cost at full rate.

**Changes in v0.2.1.** First ZedBoard implementation run closed at WNS -6.466 ns. Two changes fix it: the memory request channel is registered before the adapter, and the adapter's address checks now use MEM_AW+2-bit arithmetic instead of 65-bit. See section 13.1.

**Changes from v0.1.** Memory becomes a switch input as well as an output (9x10 crossbar). Outputs lock on grant, not on header transfer. Destination is latched per input at SOP. Illegal DST_ID drains to a sink port. SRC_ID is stamped at ingress and stray flits are dropped. LENGTH/EOP precedence, memory request encoding, error responses and the endpoint deadlock rule are now normative. Items marked **[v0.2]** are new or changed.

# 1. Design Goals and Scope

The system is an educational but implementation-oriented packet interconnect intended to progress from RTL simulation to synthesis and FPGA deployment. Eight bidirectional endpoints exchange variable-length packets through a central switch. Shared memory is logical port 8, which both receives requests and sends responses. The implementation uses one synchronous clock domain; CDC is an explicit later extension.

| Parameter       | v0.2 Decision                                                                    |
| --------------- | -------------------------------------------------------------------------------- |
| Endpoints       | 8 bidirectional endpoints                                                        |
| Connectivity    | Any endpoint to any endpoint                                                     |
| Datapath / flit | 64 bits + SOP/EOP sideband                                                       |
| Transfer unit   | Variable-length packet                                                           |
| Switch          | **[v0.2]** 9 inputs (EP0–7, MEM) x 10 outputs (EP0–7, MEM, SINK)         |
| Arbitration     | Per-output round robin                                                           |
| Grant ownership | **[v0.2]** Locked from first grant until accepted EOP                      |
| Flow control    | ready/valid backpressure, flit-level (wormhole) admission                        |
| Buffering       | TX and RX FIFOs per endpoint                                                     |
| Ordering        | FIFO order preserved per input stream                                            |
| Memory          | Port 8; BRAM first; request channel registered before the adapter                |
| Clocking        | Single shared clock;**[v0.3.0]** 70 MHz on xc7z020 (73.6 MHz measured max) |
| Implementation  | SystemVerilog + Vivado + ZedBoard                                                |

# 2. Architectural Overview

```
EP0..EP7 TX FIFO --> [ 9 x 10 crossbar  ] --> EP0..EP7 RX FIFO
MEM responses    --> [ per-output RR +   ] --> MEM requests --> Memory Adapter <--> BRAM
                     [ packet locks      ] --> SINK (illegal DST_ID, always ready)
```

Each endpoint has independent transmit and receive paths. A packet header identifies its destination. Each input latches the destination at SOP and requests exactly one output until its EOP transfers. Each output independently arbitrates, so non-conflicting packets advance in parallel.

# 3. Endpoint Interface

The streaming interface uses ready/valid semantics. A flit transfers only on a clock edge where valid && ready is true. While valid is asserted and ready is low, the producer must hold data, SOP and EOP stable.

| Signal   | Dir. | Width | Meaning                                             |
| -------- | ---- | ----- | --------------------------------------------------- |
| tx_data  | In   | 64    | Transmit flit                                       |
| tx_valid | In   | 1     | Transmit flit is valid                              |
| tx_ready | Out  | 1     | TX FIFO can accept flit (always 1 for a stray flit) |
| tx_sop   | In   | 1     | Start of packet                                     |
| tx_eop   | In   | 1     | End of packet                                       |
| rx_data  | Out  | 64    | Received flit                                       |
| rx_valid | Out  | 1     | Received flit is valid                              |
| rx_ready | In   | 1     | Consumer can accept flit                            |
| rx_sop   | Out  | 1     | Start of packet                                     |
| rx_eop   | Out  | 1     | End of packet                                       |

**[v0.2] Ingress sanitizing (normative).** The endpoint port overwrites SRC_ID with its physical index on every header. A flit without SOP while no packet is open is a stray: it is accepted, dropped and counted as a framing error. SOP while a packet is open is forwarded as a body flit with SOP cleared and counted as a framing error. The switch therefore only ever sees well-framed streams.

**[v0.2] Deadlock rule (normative).** Every consumer must drain its RX interface independently of progress on its own TX interface. An endpoint that waits for its TX to complete before reading RX can deadlock against the memory adapter.

# 4. Packet and Flit Format

The first flit is the header. EOP is sideband and is authoritative for switching; the switch never reads LENGTH. LENGTH is checked by the memory adapter.

| Header field | Bits  | Purpose                                                              |
| ------------ | ----- | -------------------------------------------------------------------- |
| TYPE         | 63:60 | Packet operation / message class                                     |
| SRC_ID       | 59:56 | 0–7 endpoints, 8 memory;**[v0.2]** stamped at ingress         |
| DST_ID       | 55:52 | 0–7 endpoints, 8 memory;**[v0.2]** 9–15 routed to SINK       |
| LENGTH       | 51:36 | Number of payload flits after the header; 0 is legal                 |
| TAG          | 35:28 | Transaction identifier, echoed in memory responses                   |
| FLAGS        | 27:24 | **[v0.2]** Error code in T_ERROR responses; otherwise reserved |
| RESERVED     | 23:0  | Must transmit as zero                                                |

| TYPE value | Meaning        |
| ---------- | -------------- |
| 0x0        | DATA           |
| 0x1        | MEM_READ_REQ   |
| 0x2        | MEM_READ_RESP  |
| 0x3        | MEM_WRITE_REQ  |
| 0x4        | MEM_WRITE_RESP |
| 0xF        | T_ERROR        |

# 5. Switching and Routing

The fabric has nine inputs (endpoints 0–7, memory responses) and ten outputs (endpoints 0–7, memory requests, SINK). **[v0.2]** Only the SOP flit is a header, so each input keeps an open-packet flag and a latched destination. When no packet is open, the request is decoded from the head flit; for body flits the latched destination is used.

```
route[i] = open[i] ? dst_q[i] : (DST_ID <= 8 ? DST_ID : SINK)
on accepted flit: open[i] <= !eop; if (!open[i]) dst_q[i] <= decoded
```

The SINK output is always ready and counts dropped packets. Without it, an illegal DST_ID would block its input forever, because FIFO ordering prevents later packets from bypassing it.

# 6. Arbitration and Packet Locking

Every output owns an independent 9-request round-robin arbiter with a rotating priority pointer.

**[v0.2] Lock on grant.** v0.1 locked on header transfer, leaving the grant combinational until that edge. If an output was stalled and a higher-priority input began requesting, the offered flit switched inputs while valid && !ready, violating section 3. v0.2 locks the winner at the end of the first cycle it is granted, whether or not its header transferred.

```
UNLOCKED: owner = rr scan of req[] from rr_ptr
          if granted: locked <= 1; owner_q <= owner   (unless header-only packet completes now)
LOCKED:   owner = owner_q; owner's req may drop mid-packet without losing the lock
RELEASE:  on valid && ready && eop: locked <= 0; rr_ptr <= owner + 1
```

- At most one input may be granted by a given output at a time.
- A packet may not be interleaved with another packet on the same output.
- The offered flit on an output never changes while stalled.
- Round robin bounds the wait of a continuously requesting input to N_IN − 1 packets.

# 7. FIFO and Backpressure Strategy

Each endpoint has a TX FIFO and an RX FIFO, first-word-fall-through, depth parameterized (16 initial). **[v0.2]** Admission is flit-level (wormhole): packet locking already keeps packets contiguous, so no whole-packet reservation is required and packet length is not bounded by FIFO depth. Consequence: a long stalled packet head-of-line blocks its source input.

FIFO in_ready is simply !full, with no pass-through from out_ready, so there is no combinational path from consumer to producer through the crossbar. Backpressure is lossless: no flit is popped until the selected output accepts it.

# 8. Ordering Guarantees

Within one input stream, packets are served in FIFO order and whole-packet locking preserves flit order within each packet. v0.2 does not promise ordering between packets from different sources.

# 9. Shared Memory Endpoint

Memory is port 8. The adapter processes one request at a time and accepts no new request while a response is pending. Addresses are byte addresses and must be a multiple of 8; word = address >> 3. BRAM first; a later adapter may target AXI4 and Zynq PS DDR.

| Operation     | Request (header LENGTH, payload)                     | Response                                        |
| ------------- | ---------------------------------------------------- | ----------------------------------------------- |
| MEM_WRITE_REQ | LENGTH = 1 + n (n ≥ 1); p0 = address; p1..pn = data | MEM_WRITE_RESP, LENGTH 0, same TAG              |
| MEM_READ_REQ  | LENGTH = 2; p0 = address; p1[15:0] = n words         | MEM_READ_RESP, LENGTH n, n data flits, same TAG |

**[v0.2] Errors.** On any violation the adapter drains to EOP and replies T_ERROR, LENGTH 0, same TAG, FLAGS = code. Writes commit as data flits arrive, so a write that fails its LENGTH check has already written the words it carried.

| FLAGS | Name    | Condition                                                                |
| ----- | ------- | ------------------------------------------------------------------------ |
| 0x1   | E_TYPE  | TYPE other than MEM_READ_REQ / MEM_WRITE_REQ sent to memory              |
| 0x2   | E_LEN   | Observed payload flits ≠ LENGTH, header-only request, or illegal LENGTH |
| 0x3   | E_ALIGN | Address not a multiple of 8                                              |
| 0x4   | E_RANGE | Address, write burst or read count outside memory                        |

# 10. Clocking and Reset

All logic runs on one rising-edge clock. Reset is synchronous, active-low, with synchronized release at board level. Arbitration pointers, packet locks, route latches, FIFO state and adapter state return to idle. CDC is excluded from this baseline.

# 11. RTL Module Decomposition

| Module              | Responsibility                                                                   |
| ------------------- | -------------------------------------------------------------------------------- |
| skid_reg            | **[v0.2.2]** 2-entry flop-based register slice, fully registered both ways |
| noc_pkg             | Parameters, header layout, TYPE and error codes                                  |
| rr_arbiter          | N-way round robin, pointer committed on release                                  |
| sync_fifo           | Parameterized FWFT ready/valid FIFO                                              |
| endpoint_port       | TX/RX FIFOs, SRC stamping, stray-flit filtering                                  |
| route_decode        | Per-input destination latch, SINK mapping                                        |
| output_port_ctrl    | Per-output arbiter, lock-on-grant, release on EOP                                |
| noc_switch          | 9x10 crossbar datapath and ready propagation                                     |
| memory_adapter      | Request decode, BRAM access, responses and errors                                |
| bram_sdp            | Simple dual-port block RAM                                                       |
| noc_top             | Endpoints + switch + memory + sink + status counters                             |
| ep_traffic, zed_top | FPGA self-test generator/checker and board wrapper                               |

# 12. Verification Plan

Verification is scoreboard-based: expected streams per (source, destination), with memory responses predicted by a reference model fed from a monitor on the switch-to-memory channel.

- P3 contention: eight inputs to one output, locking and round-robin fairness bound, including first-packet wait.
- P4 concurrency: permutation traffic must drive all eight outputs in the same cycle.
- P5 any-to-any, including header-only and longer-than-FIFO packets.
- P6 memory directed: read/write, boundaries, zero-length read, every error code.
- Ingress robustness: illegal DST_ID and stray flits; later packets still delivered.
- P7 random traffic with random TX gaps and RX stalls; counters match; reset and recovery.
- Mutation testing: known bugs injected into RTL must be detected.

## 12.1 Key Assertions

```
assert $onehot0(grant[o]);
assert !(push && full); assert !(pop && empty);
// output_port_ctrl: after valid && !ready, same owner and valid next cycle
// route_decode: idle input head has SOP; open input head has no SOP
// noc_switch: an input drives at most one output; locked output's owner routes to it
// memory_adapter: request header has SOP; no SOP inside a request
```

## 12.2 Timing-driven revisions (v0.2.1)

The first implementation run (Vivado 2025.2, xc7z020clg484-1, 100 MHz) reported
WNS -6.466 ns with 2116 failing endpoints, all on one path shape: an endpoint TX
FIFO read pointer through route decode, the output-8 arbiter and the crossbar
mux into the memory adapter's state, error and read-count registers. 30 logic
levels, 15 to 17 of them CARRY4.

Two causes, both in this specification's v0.2 form:

1. **Unregistered memory request channel.** The adapter decoded a request in the
   same cycle the switch selected it, so arbitration delay (~9.5 ns of the
   21.9 ns arrival) was in series with adapter decode. v0.2.1 places a
   registered skid stage (depth-2 FIFO) on the switch-to-memory channel. No
   protocol change: the adapter handles one request at a time regardless.
2. **65-bit address arithmetic.** Range and burst-end checks were written over
   the full 64-bit byte address, which synthesises as a long carry chain. Only
   MEM_AW+2 bits can matter; the high address bits reduce to a single OR. v0.2.1
   computes `word_hi_nz`, `burst_end` and `read_end` in MEM_AW+2 bits.

This is a normative addition to section 9: implementations must not place
adapter request decode in the same cycle as switch arbitration.

**v0.2.2.** The same principle applies at the front of the path. Route decode
read the flit at the FIFO head every cycle, so arbitration began only after a
LUTRAM read and three LUT levels (~3.5 ns on the v0.2.1 netlist). Since the head
changes only on a pop, that work belongs in registers: each switch input now has
a flop-based register slice, and the arbiter path starts at a flip-flop. This is
normative: route and request signals presented to arbitration must come from
registers, not from a memory read.

**v0.2.3.** With both datapath causes removed, WNS went from -6.466 to
-3.528 ns and the critical path left the datapath entirely: it ended at
`stat_rx_pkts`, a debug counter, whose event condition fed a 32-bit carry chain
in the same cycle it was computed. Statistics are now two-stage. Observation
logic is not exempt from the timing budget, and a counter that costs clock
frequency is a design error even though it carries no packets.

## 12.3 Measured timing (xc7z020-1, 100 MHz target)

| Version | WNS              | Critical path                                                                  |
| ------- | ---------------- | ------------------------------------------------------------------------------ |
| v0.2    | -6.466 ns        | EP TX FIFO -> route decode -> arbiter -> mux -> memory adapter (65-bit checks) |
| v0.2.2  | -3.528 ns        | route decode ->`stat_rx_pkts` 32-bit counter                                 |
| v0.2.3  | -3.582 ns        | input skid DST_ID -> route -> arbiter -> another input's ready                 |
| v0.3.0  | closes at 70 MHz | clock lowered; see below                                                       |

### The limit

The v0.2.3 path is the arbitration loop: one input's DST_ID determines another
input's ready. It is 82% routing across 13 logic levels, so it is dominated by
wire delay between slices, not by gate count, and removing logic returns little.
Data path delay 12.989 ns plus skew and uncertainty needs ~13.58 ns, i.e.
**73.6 MHz**, which is this architecture's ceiling on this part.

The fabric therefore runs at 70 MHz (MMCM: 100 MHz in, VCO 700 MHz, /10), with
about 0.7 ns of margin. Reset is held until the MMCM locks. Raising the clock
requires breaking the combinational ready loop — credit-based flow control with
registered ready — which changes the flow-control contract in section 3 and is
deferred to a future version.

The 100 MHz figure in earlier drafts was chosen because it is the ZedBoard
oscillator frequency, not because any requirement demanded it.

Each number comes from a routed design. The v0.2 to v0.2.2 step is the combined
effect of the section 12.2 fixes.

# 13. FPGA Implementation Plan

| Phase | Target                                                                      |
| ----- | --------------------------------------------------------------------------- |
| A     | RTL simulation of arbiter, FIFO and one output                              |
| B     | Crossbar simulation                                                         |
| C     | Memory destination and BRAM                                                 |
| D     | Vivado synthesis, timing and utilization                                    |
| E     | ZedBoard self-test: eight generators/checkers, LEDs, ILA on mark_debug nets |
| F     | Optional AXI4 memory adapter to Zynq PS DDR                                 |
| G     | Optional CDC endpoint and multi-router/mesh evolution                       |

# 14. Design Parameters

| Parameter              | Value                                  |
| ---------------------- | -------------------------------------- |
| N_EP                   | 8                                      |
| N_IN / N_OUT           | 9 / 10                                 |
| DATA_W / FLIT_W        | 64 / 66                                |
| DEST_W / TAG_W / LEN_W | 4 / 8 / 16                             |
| FIFO_DEPTH             | 16 flits (power of two, parameterized) |
| MEM_AW                 | 10 (1024 words)                        |
| ARBITRATION            | Round robin, per output                |
| LOCK_MODE              | From first grant until accepted EOP    |

# 15. Decisions Still Open

- Maximum legal packet length for application traffic (the fabric itself imposes none).
- Memory byte enables and burst limits beyond the 16-bit read count.
- CRC for off-chip or multi-router extensions.
- Latency and throughput targets beyond the 70 MHz clock.
- Credit-based flow control with registered ready, to lift the 73.6 MHz ceiling.
- QoS: weighted round robin, virtual channels or traffic classes.
- Whether the SINK should return T_ERROR to the source instead of silently dropping.

# 16. Build Order / Definition of Done

| Milestone    | Definition of done                                                       | Status                                            |
| ------------ | ------------------------------------------------------------------------ | ------------------------------------------------- |
| P0 Protocol  | Header, sideband, handshake, destination map and memory semantics frozen | Done (v0.2)                                       |
| P1 Arbiter   | Round-robin unit passes directed and contention tests                    | Done                                              |
| P2 FIFO      | Lossless FIFO passes full/empty/backpressure tests                       | Done                                              |
| P3 Switch    | Nine inputs contend for one output with locking                          | Done                                              |
| P4 Crossbar  | Independent output arbitration, simultaneous transfers                   | Done                                              |
| P5 Endpoints | Eight endpoint wrappers integrated                                       | Done                                              |
| P6 Memory    | BRAM read/write and error responses verified                             | Done                                              |
| P7 System    | Random traffic scoreboard passes with backpressure                       | Done                                              |
| P8 FPGA      | Vivado implementation closes timing; hardware self-test passes           | Closes at 70 MHz (v0.3.0); board bring-up pending |

# 17. v0.2 Architectural Contract

**The core invariant:** an accepted flit is never dropped, duplicated, reordered within its packet, or interleaved with another packet on the same output, except flits deliberately discarded at ingress (strays) or at SINK (illegal DST_ID), which are counted. The flit offered on any output never changes while stalled. Arbitration is fair among continuously requesting inputs while the destination makes progress.

Any RTL change to packet format, ordering, locking or ready/valid semantics must first update this specification.

---

# Part II — Network Integration

**Purpose.** Make the eight endpoints and the memory endpoint reachable from a real IP network, so the on-chip interconnect is addressable, forwardable and observable with ordinary network tools.

**Relationship to Part I.** This layer adds nothing to the fabric and changes nothing in it: flit format, locking, ordering, backpressure and error codes are exactly as specified in Part I. The bridge is a new endpoint-side component.

# 18. Network Architecture

```
Host  --UDP/IP--> Ethernet --> Zynq PS (GEM + lwIP)
                                  |  AXI-Lite (later AXI-DMA)
                             PL: net_bridge   <- forwarding table
                                  |  flits (66-bit, ready/valid)
                             NoC endpoint 0..7, memory 8
```

The Ethernet MAC is the Zynq PS gigabit MAC (GEM), already wired to the board's PHY. The PL-side MAC alternative was rejected: it requires a licensed or low-quality 1G MAC core, RGMII timing closure against the board PHY, MDIO bring-up and a 125 MHz to 70 MHz clock domain crossing, none of which concerns the interconnect. The consequence is recorded honestly: the datapath is PS-mediated, so latency is tens of microseconds and throughput is bounded by the PS and the AXI path, not by the fabric.

# 19. Address Plan

Each endpoint is a first-class host on the network: one IP address per endpoint, all behind the board's single MAC address. This is the same arrangement a router or VM host presents, and it makes the NoC destination space visible to standard tooling.

| Address     | DST_ID | Role           |
| ----------- | ------ | -------------- |
| 10.10.10.10 | 0      | Endpoint 0     |
| 10.10.10.11 | 1      | Endpoint 1     |
| 10.10.10.12 | 2      | Endpoint 2     |
| 10.10.10.13 | 3      | Endpoint 3     |
| 10.10.10.14 | 4      | Endpoint 4     |
| 10.10.10.15 | 5      | Endpoint 5     |
| 10.10.10.16 | 6      | Endpoint 6     |
| 10.10.10.17 | 7      | Endpoint 7     |
| 10.10.10.18 | 8      | Shared memory  |
| 10.10.10.1  | —     | Host / gateway |

Subnet 10.10.10.0/24, static addressing, no DHCP. **The subnet must not collide with the host's other networks**: an earlier plan used 192.168.1.0/24, which matched the development laptop's home Wi-Fi, so the host routed board traffic over Wi-Fi and the board was unreachable. 10.10.10.0/24 was chosen because nothing else uses it. One MAC address answers ARP for all nine addresses.

**Forwarding table (normative).** The IP-to-DST_ID mapping is not hardcoded. `net_bridge` holds a 16-entry table in the PL, writable over AXI-Lite at runtime, each entry `{valid, ipv4_addr[31:0], dst_id[3:0]}`. A packet whose destination address misses the table is dropped and counted. Remapping an endpoint to a different address requires no rebuild; this is a forwarding plane, and demonstrating a live remap is a deliverable.

**Fallback.** If ARP for nine addresses proves impractical in lwIP, the fallback is one board address with UDP port 5000+N selecting the endpoint. The forwarding table then keys on port instead of address. This is a degradation of the demonstration, not of the datapath.

# 20. Encapsulation (stage 1 format)

The UDP payload is a NoC packet verbatim: the 64-bit header followed by payload words, each word big-endian on the wire. The bridge performs no header translation; it frames flits and asserts SOP/EOP.

| Offset | Size       | Field                                                      |
| ------ | ---------- | ---------------------------------------------------------- |
| 0      | 8          | NoC header word (TYPE, SRC_ID, DST_ID, LENGTH, TAG, FLAGS) |
| 8      | 8 x LENGTH | Payload words                                              |

UDP destination port 5555 for encapsulated traffic. SRC_ID in the transmitted header is ignored and overwritten by `endpoint_port` as in design spec section 3; the bridge sets it to the DST_ID resolved for the sending host, so responses return to the correct endpoint.

**Constraint.** One UDP datagram carries exactly one NoC packet. A packet whose LENGTH exceeds the datagram is rejected with E_LEN.

# 21. Translation (stage 2 format)

Once encapsulation is proven, the bridge builds the NoC header from the IP/UDP headers instead of copying it:

| NoC field | Source                                                                   |
| --------- | ------------------------------------------------------------------------ |
| DST_ID    | Forwarding-table lookup on destination IPv4 address                      |
| SRC_ID    | Forwarding-table lookup on source IPv4 address, else the bridge's own ID |
| LENGTH    | UDP payload length / 8, rejected if not a multiple of 8                  |
| TYPE      | UDP destination port: 5555 DATA, 5556 MEM_READ_REQ, 5557 MEM_WRITE_REQ   |
| TAG       | Low 8 bits of the UDP source port, echoed in responses for correlation   |
| FLAGS     | Zero on ingress; carries the error code on egress                        |

In this mode the host sends ordinary UDP datagrams containing only data, and the network layer determines the on-chip routing. This is the target format.

# 22. Error Mapping

The adapter's error codes (design spec section 9) become visible at the network layer. An error response is returned to the sender as a UDP datagram on the reply port with the encapsulated T_ERROR packet, FLAGS carrying the code.

| FLAGS | Name    | Network-visible meaning                                       |
| ----- | ------- | ------------------------------------------------------------- |
| 0x1   | E_TYPE  | Unsupported operation for that destination port               |
| 0x2   | E_LEN   | Datagram length disagrees with LENGTH, or not a multiple of 8 |
| 0x3   | E_ALIGN | Memory address not a multiple of 8                            |
| 0x4   | E_RANGE | Memory address or burst outside the 1024-word region          |

Two conditions are network-layer only and have no on-chip equivalent:

| Condition                                  | Behaviour                                                                                     |
| ------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Destination IP misses the forwarding table | Drop, increment`stat_fwd_miss`                                                              |
| Destination resolves to DST_ID 9-15        | Forwarded to the fabric, which sinks it (design spec section 5); counted by`stat_sink_pkts` |

The second is deliberate: it exercises the existing sink path from the network side, proving on hardware that illegal destinations are dropped rather than deadlocking an input.

# 23. Fragmentation

The fabric imposes no packet-length limit; LENGTH allows 65535 payload flits, or 512 kB. A 1500-byte MTU carries at most 184 payload words.

**Policy for v0.4:** no fragmentation. A NoC packet must fit one datagram; longer transfers are rejected with E_LEN. Fragmentation and reassembly, which would require reassembly buffers and a timeout in the bridge, are deferred. Jumbo frames are not assumed.

# 24. Verification

Each stage has one artifact that proves it, independent of the stage below.

| Stage            | Proves                          | Artifact                                                       |
| ---------------- | ------------------------------- | -------------------------------------------------------------- |
| N1 PS-PL bridge  | Flits move between PS and NoC   | Bare-metal C write/read loopback                               |
| N2 lwIP echo     | GEM, PHY and IP config work     | `ping` and UDP echo, no NoC involved                         |
| N3 Encapsulation | End-to-end path                 | Wireshark capture with the NoC dissector decoding TYPE/SRC/DST |
| N4 Forwarding    | Address plan and table          | `ping` to all nine addresses; live remap of one entry        |
| N5 Error paths   | Error codes surface on the wire | Scapy malformed-packet suite, one capture per code             |
| N6 Routed hop    | Board behaves as a host         | Namespace router, ACL permitting endpoints 0-3 and denying 4-7 |

All six stages are complete on hardware; results in section 26.

**Tooling.** A Wireshark Lua dissector (`net/noc_dissector.lua`) decodes the encapsulated format. A Scapy suite (`net/noc_scapy.py`) generates both valid traffic and each error case. A shell script (`net/netns_lab.sh`) builds the routed topology with `ip netns` and `nftables`; no commercial simulator is required. Cisco Packet Tracer cannot be used at all, as it has no path to physical interfaces.

# 25. Stage N1: PS-PL Bridge

`rtl/axil_noc_bridge.sv` is an AXI4-Lite slave that replaces the traffic generator on endpoint 0. The Zynq PS injects and receives flits by register access. Endpoints 1-7 keep their generators, so PS traffic runs concurrently with on-chip traffic. Memory requests genuinely contend, since output 8 is shared with the generators' memory traffic; loopback to endpoint 0 does not, since generators never address it. Generators never address endpoint 0; software must not send DATA to endpoints 1-7, and should use memory at or above byte 0x1000 (generators occupy words 32·ID to 32·ID+3).

| Offset | Name     | Access | Meaning                                                                               |
| ------ | -------- | ------ | ------------------------------------------------------------------------------------- |
| 0x00   | ID       | RO     | 0x4E4F4331 ("NOC1")                                                                   |
| 0x04   | STATUS   | RO     | [0] tx_space, [1] rx_avail, [2] rx_sop, [3] rx_eop, [15:8] rx_count, [23:16] tx_count |
| 0x08   | TX_LO    | RW     | Staged flit bits [31:0]                                                               |
| 0x0C   | TX_HI    | RW     | Staged flit bits [63:32]                                                              |
| 0x10   | TX_PUSH  | WO     | [0] sop, [1] eop; pushes the staged flit, or counts a drop if full                    |
| 0x14   | RX_LO    | RO     | Head flit bits [31:0], no side effect                                                 |
| 0x18   | RX_HI    | RO     | Head flit bits [63:32], no side effect                                                |
| 0x1C   | RX_POP   | WO     | Any value discards the head flit                                                      |
| 0x20   | TX_COUNT | RO     | Flits pushed                                                                          |
| 0x24   | RX_COUNT | RO     | Flits popped                                                                          |
| 0x28   | TX_DROP  | RO     | Pushes rejected because the TX FIFO was full                                          |

A flit costs three bus accesses each way. This is intentionally the slowest path: it proves correctness before the network exists and sets the baseline that AXI-DMA (N7) is measured against.

**Clock.** The PS supplies FCLK_CLK0. The PS derives it by integer division from the IO PLL, so exactly 70 MHz is unavailable; 66.67 MHz is requested, below the fabric's 73.6 MHz ceiling with margin. 71.4 MHz would leave under 0.5 ns.

**N2 verified on hardware** (lwIP echo server, before any NoC involvement): PHY autonegotiated at 1000 Mbps, static address taken without DHCP, `ping 10.10.10.10` answered in under 1 ms with TTL 255, and a TCP echo on port 7 returned its payload. A Wireshark capture shows ARP resolving the board's address to `Xilinx_00:0a:35:00:01:02`, the three-way handshake, and the payload in both directions. Ethernet, PHY, cable and IP configuration are therefore proven independently of the fabric.

Two BSP settings are required and neither is the default in Vitis 2025.2's lwip220: `lwip220_dhcp` false, because a direct cable has no DHCP server and the template otherwise waits forever in its DHCP loop; and `lwip220_lwip_dhcp_does_acd_check` false, because lwIP 2.2.0 rejects address conflict detection when DHCP is off, and the BSP fails to compile.

**N1 verified on hardware** (`sw/n1_main.c`): all functional checks, 1000 x 32-flit loopbacks with zero corrupt or dropped, and an MMIO baseline of **3.4 MB/s each way** (about 285 ns per AXI-Lite access, eight accesses per flit round trip). The fabric itself moves 64 bits per cycle, roughly 530 MB/s per port at 66.67 MHz, so MMIO uses under 1% of it; this is the baseline N7 is measured against.

## 25.1 Forwarding table registers

The table from section 19 lives in the bridge (`rtl/fwd_table.sv`): 16 entries in flip-flops, searched in parallel, lowest index winning on a duplicate address.

| Offset | Name          | Access | Meaning                                             |
| ------ | ------------- | ------ | --------------------------------------------------- |
| 0x2C   | FWD_MISS      | RO     | Packets discarded because their destination missed  |
| 0x30   | FWD_IDX       | RW     | Entry to write or read back                         |
| 0x34   | FWD_IP        | RW     | Staged address for the next commit                  |
| 0x38   | FWD_CTRL      | WO     | [0] commit, [1] valid, [11:8] dst_id                |
| 0x3C   | FWD_ENT_IP    | RO     | Address in entry FWD_IDX                            |
| 0x40   | FWD_ENT_INFO  | RO     | [31] valid, [20:16] valid-entry count, [3:0] dst_id |
| 0x44   | FWD_PROBE_IP  | RW     | Address to look up without touching traffic         |
| 0x48   | FWD_PROBE_RES | RO     | [31] hit, [3:0] dst_id                              |
| 0x4C   | TX_DST_IP     | RW     | Destination for route-by-IP pushes                  |
| 0x50   | RX_SRC_IP     | RO     | Address mapped to the head packet's SRC_ID          |
| 0x54   | RX_SRC_INFO   | RO     | [31] reverse-lookup hit, [3:0] SRC_ID               |

**Route by IP.** TX_PUSH bit 2 on a SOP flit looks up TX_DST_IP and rewrites the header's DST_ID. A miss discards the entire packet, header and every body flit through EOP, and counts once. A new SOP ends a discard even without an EOP, so one malformed packet cannot swallow the next. The forwarding decision is therefore made on the datapath by the table itself, which remains the authority once N7 removes the CPU from the data path.

**Verified in simulation** (`make n1`): entry write and read-back; probe hit and miss; DST_ID rewrite from a junk value; reverse lookup for replies from an endpoint and from memory; whole-packet discard on a miss, with the next packet delivered intact; live remap of memory from .18 to .20 with the old address then missing; and invalidation, checked on the datapath rather than only on the probe. Two mutants target this logic: M10 (miss drops only the header) and M11 (datapath ignores the valid bit). Both are caught; M11 initially escaped, because invalidation was only checked through the probe register, which is a separate lookup.

# 26. Stages N3 to N6: Results on Hardware

All verified on a ZedBoard against a laptop over a direct Ethernet link, host at 10.10.10.1.

## 26.1 N3, encapsulation

`sw/noc_udp.c` binds UDP and hands each datagram's payload to the bridge as a NoC packet. Port 5555 routes by destination address; port 5556 honours the DST_ID already in the header, which reaches an endpoint without depending on its address resolving. `net/n3_test.py` passes: loopback with SRC_ID stamping, memory write and four-word read-back, an E_ALIGN response, and a malformed datagram that is rejected without disturbing the next one.

**Two bugs found here are worth recording, because neither was a hardware fault and both were invisible from the board's own counters, which showed every datagram accepted and answered.**

A reply must leave from the port the request arrived on. Replying through the wrong pcb sent answers from port 5555 to a client that had used 5556; the host firewall tracks UDP flows and dropped them.

A reply must also come from the address the client contacted. Replying from the endpoint's own table address (10.10.10.18 for memory) was refused by the host, which had sent to 10.10.10.10. The rule adopted is the ordinary one: answer from the address that was addressed. In N4, where the client does address the endpoint directly, it gives the same result.

## 26.2 N4, one MAC and nine addresses

lwIP answers ARP only for its netif address and `etharp.c` offers no hook, so `sw/noc_alias.c` wraps `netif->input` after `xemac_add` and inspects frames before lwIP sees them: ARP requests for an alias are answered, ICMP echoes are replied to in place, and UDP has its destination rewritten to the netif address with the original kept for the application. The UDP checksum covers the destination address and is therefore zeroed, which IPv4 permits; the IP header checksum is recomputed. Patching the BSP would have been simpler and would not survive regeneration.

Verified: `ping 10.10.10.13` and `ping 10.10.10.18` answer, `arp -a` shows the addresses resolving to one MAC (00-0a-35-00-01-02), and `n3_test.py --by-address` passes with every header's DST_ID set to 0xF, so routing can only have come from the hardware table.

**Known quirk.** An alias ping returns the requester's TTL (128 from Windows) because the reply is the request turned around in place, while the board's own address returns lwIP's TTL of 255. Harmless, observable in a capture, and left as is.

## 26.3 N4, the table as a control plane

UDP port 5557 reads and writes forwarding-table entries: 12 bytes in, the entry as hardware holds it afterwards out. Writing an entry also updates the set of addresses answered for, without which a newly mapped address would never resolve.

`net/n4_remap.py` demonstrates it: memory is written at 10.10.10.18, moved to 10.10.10.20 from the host, the same data reads back at the new address, the old one goes dark, and the entry is restored. No rebuild, no reboot, no bitstream. The address-to-endpoint mapping is runtime state.

Note the layering: once unmapped, the old address is refused at the network layer and never reaches the fabric, so `FWD_MISS` does not move. A miss is counted only for an address the board accepts but the table does not map.

## 26.4 N5, error paths from the network

`net/n5_errors.py` drives every code in section 22 from the host and checks the response: E_ALIGN, E_RANGE (address and burst), E_LEN, E_TYPE. Error responses echo the request's TAG and carry SRC_ID 8, so a host can match an error to the request that caused it. An illegal DST_ID of 12 is sunk by the fabric with no response, and the packet after it is delivered, confirming the input does not block.

A stats operation on the control port returns `tx_count`, `rx_count`, `tx_drop`, `fwd_miss`, `udp_in`, `udp_no_route` and `udp_bad_length`, so a dropped packet is proved dropped and the three rejection layers are told apart rather than inferred from a timeout.

## 26.5 N6, routed hop and ACL

`net/n6_lab.sh` builds a client namespace behind a router (the development machine, under WSL2 with mirrored networking) so traffic to the endpoints crosses a routing decision.

With a filter permitting 10.10.10.10-.13 and denying .14-.17, endpoints 0 to 3 answer from two hops away, endpoints 4 to 7 do not, and memory at .18 is unaffected. The NoC destination space is filterable by ordinary network policy.

**No NAT is required.** The first version masqueraded the source address, assuming the board had no route back to the client subnet. Deleting the rule and finding every endpoint still reachable showed otherwise: the board's default gateway is the router, so it returns replies by itself. Traffic is routed in both directions with addresses intact.

# 27. Open Decisions

- Whether the memory endpoint should expose read/write as distinct UDP ports or as a TYPE field in an encapsulated header.
- Retry and timeout policy: UDP is lossy, the fabric is not. A dropped response currently looks identical to a lost request.
- Whether `stat_fwd_miss` and per-endpoint packet counters should be readable over AXI-Lite for host-side monitoring.
- AXI-DMA migration: at what stage the PS stops touching payload data.

---

# Part III — Build, Results and Retrospective

# 28. What Was Built

| Layer        | Components                                                                                                                                                            | Origin               |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| Fabric       | `rr_arbiter`, `sync_fifo`, `skid_reg`, `endpoint_port`, `route_decode`, `output_port_ctrl`, `noc_switch`, `memory_adapter`, `bram_sdp`, `noc_top` | Original RTL         |
| SoC          | `axil_noc_bridge` (AXI4-Lite slave), `fwd_table` (IPv4 to DST_ID), `n1_top`                                                                                     | Original RTL         |
| Board        | `ep_traffic` generators and checkers, `zed_top`, constraints, non-project build flow, block-design script                                                         | Original             |
| Software     | `noc_bridge` driver, `noc_udp` bridging and control plane, `noc_alias` ARP/ICMP for nine addresses, `n1_main`, `n3_main`                                    | Original C           |
| Host tooling | Wireshark Lua dissector, four Python suites, routed-hop lab script                                                                                                    | Original             |
| Vendor       | Zynq PS, its Ethernet MAC, lwIP 2.2.0                                                                                                                                 | Xilinx / third party |

# 29. Verification

| Item                                                                   | Result                                               |
| ---------------------------------------------------------------------- | ---------------------------------------------------- |
| Lint,`-Wall`, three top modules                                      | Clean                                                |
| Unit: round-robin arbiter, N = 5, 8, 9                                 | Pass                                                 |
| Unit: FIFO, depths 2, 16, 64                                           | Pass                                                 |
| System scoreboard vs reference model, depths 2/4/16/64, multiple seeds | Pass                                                 |
| Board self-test in simulation                                          | Pass — 72k packets, 250+ memory cycles per endpoint |
| Fault injection, single bit flip                                       | Detected                                             |
| Mutation testing                                                       | 11 of 11 injected bugs caught                        |
| Hardware self-test, including randomised receive backpressure          | Pass — zero errors                                  |
| N1 AXI-Lite bridge on hardware                                         | Pass — 1000-packet soak, zero bad, zero dropped     |
| N3 encapsulation on hardware                                           | Pass                                                 |
| N4 forwarding table, ARP, live remap                                   | Pass                                                 |
| N5 every error path driven from the host                               | Pass                                                 |
| N6 routed hop with ACL                                                 | Pass                                                 |

**On mutation testing.** Eleven deliberate bugs were injected and every one was caught: lock-on-header-transfer instead of lock-on-grant, a route not latched at SOP, a lock released on every flit, a forwarding miss that discards only the header, a table lookup that ignores the valid bit, and others. This is the difference between "the tests pass" and "the tests would notice if the design broke."

One mutant initially escaped. M11 makes the datapath lookup ignore an entry's valid bit; the bench missed it because invalidation was only ever checked through the software probe register, which performs a separate lookup. The bench now sends real traffic to an invalidated address. The escape was more useful than the ten catches.

# 30. Measured Results

## 30.1 Timing

Every figure from a routed design, 100 MHz target unless stated.

| Version | WNS                     | Critical path                                                  | Fix applied                                                          |
| ------- | ----------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------- |
| v0.2    | -6.466 ns               | TX FIFO to route decode to arbiter to mux to memory adapter    | 65-bit address arithmetic; unregistered adapter input                |
| v0.2.1  | not measured            | —                                                             | Checks narrowed to MEM_AW+2 bits; skid on the memory request channel |
| v0.2.2  | -3.528 ns               | route decode to`stat_rx_pkts`, a 32-bit counter              | Register slice on each switch input                                  |
| v0.2.3  | -3.582 ns               | input skid DST_ID to route to arbiter to another input's ready | Status counters pipelined                                            |
| v0.3.0  | **met at 70 MHz** | arbitration loop, 82% routing                                  | Clock set to the measured maximum                                    |

**The ceiling is 73.6 MHz** on this part. The limiting path is the arbitration loop: one input's DST_ID determines another input's ready. It is 82% routing across 13 logic levels, so it is wire-dominated and removing logic returns little. Raising it needs credit-based flow control with registered ready, which changes the flow-control contract in section 3 and is deferred.

100 MHz was the ZedBoard oscillator frequency, never a requirement. Part II runs at 66.67 MHz because the PS derives FCLK by integer division and 70 MHz is not exactly available.

Two observations worth keeping. First, the v0.2.2 critical path ended at a debug counter with no functional role, which was setting the maximum clock frequency for the entire interconnect: observation logic sits in the same timing budget as the datapath. Second, fixing the worst path exposed another within 54 ps of it, because the design has a cluster of similar paths rather than one outlier.

## 30.2 Area

xc7z020-1, including the eight self-test traffic generators:
7518 LUTs (14%), 750 LUTRAM, 4114 registers (3.9%), 2 BRAM. The forwarding table adds about 600 registers. A fabric-only figure requires out-of-context synthesis of `noc_top` and is not yet measured.

## 30.3 Throughput

MMIO through the AXI4-Lite bridge: 1000 packets of 32 flits in 72.9 ms, or **3.4 MB/s each way**, about 285 ns per bus access with eight accesses per flit round trip. The fabric itself moves 64 bits per cycle, roughly 530 MB/s per port at 66.67 MHz, so register access uses under 1% of it. This is the baseline an AXI-DMA path would be measured against.

# 31. Retrospective

**A spec review found the most important bug.** In v0.1 an output locked when it transferred a header. If the output stalled, the lock could move to a different input mid-packet and interleave two packets on one output. Locking on grant fixes it. The bug was found by reading the specification, before any RTL existed, and the mutation suite now includes it as M1.

**Build provenance caused the longest delay.** Three consecutive Vivado runs produced byte-identical timing reports. The RTL fixes were real, but Vivado was reading a different `rtl/` directory, because relative paths resolve against the launch directory. The build script now prints the source directory and a count of expected cells after synthesis, and the bridge's ID register is bumped whenever its register map changes, so a stale bitstream fails on the first line of the acceptance test instead of fourteen lines further down.

The same class of error recurred once more: the Vitis platform keeps its own copy of the hardware, so rebuilding the application picked up new software against an old bitstream. The symptom was new registers reading `0xDEADBEEF`, which is the bridge's own unmapped-address value.

**Two network bugs were invisible from the board.** In N3 the board's counters showed every datagram accepted, pushed through the fabric, and answered — while the host received nothing. A reply must leave from the port the request arrived on, and from the address the client contacted; a stateful host firewall drops anything else. Both are properties of the environment, not of the design, and neither could have been found in simulation.

**Layering showed up in a failing test that was right.** After an endpoint is remapped, its old address is refused at the network layer and never reaches the fabric, so the hardware miss counter does not move. The test expected a miss; the design was correct and the expectation was wrong.

**NAT turned out to be unnecessary.** The routed-hop lab initially masqueraded the client's address, assuming the board had no route back. Deleting the rule and finding every endpoint still reachable proved the board returns replies through its configured gateway on its own. Traffic is routed both ways with addresses intact.

# 32. Still Open

- Credit-based flow control with registered ready, to lift the 73.6 MHz ceiling. Changes the section 3 contract.
- Register slice on each switch output: one cycle of latency per packet, no throughput cost.
- Out-of-context utilization for `noc_top`, to separate fabric area from the test harness.
- AXI-DMA in place of MMIO, against the 3.4 MB/s baseline.
- Fragmentation and reassembly, so a NoC packet may exceed one datagram.
- Memory byte enables; an AXI4 adapter to PS DDR.
- Retry and timeout policy: UDP is lossy, the fabric is not, and a lost response currently looks like a lost request.

---

# Appendix — v0.1 Design Review

# P0 — Spec v0.1 review (all items adopted in spec v0.2 and implemented)

Issues found while reading v0.1 against its own invariant (sec 17). Items 1–4
change RTL structure and must be resolved before P3. Proposed resolutions are
proposals below were all adopted; see the current design spec. Mutation M1 in
scripts/mutate.sh reintroduces the v0.1 lock rule and trips the stall-stability assertion.

## 1. Memory cannot reply: the switch must be 9x9, not 8x9

Sec 9 says the memory endpoint returns MEM_*_RESP to SRC_ID, but sec 2/11 only
give memory an output port (`packet_crossbar_8x9`). There is no path back.
**Proposal:** memory adapter is also switch input 8. Every output arbiter is
`rr_arbiter #(.N(9))`. Rename to `packet_crossbar_9x9`. (Arbiter here is
already parameterized; T1–T5 pass at N = 5, 8, 9.)

## 2. Grant can change mid-offer → violates sec 3 stability rule

Sec 6 locks on header *transfer*. Until that edge the grant is combinational.
If output EP4 is stalled with input 3's header offered (rr_ptr = 2), and input 2
starts requesting EP4, the grant jumps to input 2 and the data on EP4's output
changes while valid && !ready — the exact thing sec 3 forbids, and assertion
12.1 line 4 would fire.
**Proposal:** lock on *grant*, not header transfer. Register `owner` the first
cycle `gnt_valid` rises while unlocked; hold until accepted EOP. Cost: one
cycle before a header can move (or keep the combinational first grant and
register it — both are legal, pick one and write it down).

## 3. Route must be latched per input, not decoded per flit

Sec 5 decodes destination "from the header at the head of each TX FIFO". Only
the SOP flit is a header; body flits would be decoded as garbage.
**Proposal:** `route_decode` keeps `in_pkt[i]` and `dst_q[i]`. On SOP at the
FIFO head, request from the header bits; for body flits, request from `dst_q`.
Assert: a non-SOP flit never appears at the head of an input with `!in_pkt`.

## 4. Illegal DST_ID deadlocks its input forever

DST_ID is 4 bits; 9–15 map to no output. That head packet never gets a grant,
never pops, and blocks every later packet from that endpoint (sec 8 ordering
guarantee means nothing can bypass it).
**Proposal:** add a sink output (index 9, never backpressures) that drains
illegal packets and bumps a per-input `err_bad_dst` counter visible on ILA.
Optional later: sink emits T_ERROR back to SRC_ID.

## 5. SRC_ID is trusted from the producer

Memory responses route to SRC_ID. An endpoint with a bug (or a test driving
junk) sends responses to someone else.
**Proposal:** `endpoint_port` overwrites SRC_ID with its physical index on SOP.
Header then becomes authoritative for routing replies.

## 6. LENGTH vs EOP — which wins, and where is read length?

- Both LENGTH and EOP delimit a packet. **Proposal:** EOP is authoritative for
  the switch (locking never reads LENGTH). Memory adapter checks
  LENGTH == observed payload flits; mismatch → T_ERROR response, packet dropped.
- MEM_READ_REQ carries "address + requested length", but the header LENGTH
  already means payload flits (= 1 here). **Proposal:** READ_REQ header
  LENGTH = 2; payload flit 0 = address, flit 1 [15:0] = requested words.
  Response header LENGTH = requested words.
- LENGTH = 0 (header-only, SOP and EOP on same flit) is legal.

## 7. FIFO admission rule (open item in sec 15)

**Proposal:** flit-level acceptance (wormhole). The packet lock already keeps
packets contiguous per output, so whole-packet reservation buys nothing except
a max-length cap tied to FIFO depth. Accept the consequence and write it down:
a long stalled packet head-of-line blocks its source input.

## 8. Deadlock contract for endpoints

With a single switch the fabric itself has no cyclic buffer dependency, *if*
every consumer drains RX independently of its own TX progress. An endpoint
that waits for its TX to complete before reading RX can deadlock against the
memory adapter (adapter blocked sending a response to it, it blocked sending a
request to the adapter).
**Proposal:** add to sec 3 as a normative rule; memory adapter must also never
make request acceptance depend on a response it has not yet sent to a
*different* endpoint.

## 9. Memory addressing

64-bit byte address into word-wide BRAM. **Proposal for v0.1:** address must be
aligned to 8; low 3 bits non-zero or out-of-range → T_ERROR. No byte enables
until v0.2 (keeps sec 15 item deferred, but defined).

## 10. Smaller things

- TYPE/DST mismatch (MEM_* to 0–7, DATA to 8): switch ignores TYPE; memory
  adapter returns T_ERROR for DATA; endpoints may receive MEM_* freely.
- FIFO: `in_ready = !full` (no pass-through when full) to avoid a
  combinational consumer→producer path through 9 ports of crossbar. Revisit
  only if P7 throughput data demands it.
- Performance target to write down now so P8 has a pass/fail: suggest
  100 MHz on xc7z020 (ZedBoard default clock) as the v0.1 bar.
