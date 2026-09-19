---
title: "8-Endpoint Bidirectional Packet Interconnect / Mini-NoC"
subtitle: "Architecture & RTL Design Specification — Version 0.3.0 | SystemVerilog | Vivado | ZedBoard / Zynq-7000"
---

**Purpose.** Define a buildable first-generation packet-switched interconnect with any-to-any endpoint communication, whole-packet round-robin arbitration, buffering, backpressure, ordering, and a shared-memory endpoint.

**Changes in v0.3.0.** Fabric clock set to 70 MHz from an MMCM. Measured maximum for this architecture on xc7z020-1 is 73.6 MHz, limited by the arbitration loop; 100 MHz is not achievable without credit-based flow control.

**Changes in v0.2.3.** Status counters are pipelined: event bits and their population count are registered before the 32-bit increment. Counts are unchanged, two cycles later.

**Changes in v0.2.2.** Each switch input is register-sliced (`skid_reg`) ahead of route decode and arbitration, removing the FIFO LUTRAM read and route-decode logic from the arbitration path. No latency or throughput cost at full rate.

**Changes in v0.2.1.** First ZedBoard implementation run closed at WNS -6.466 ns. Two changes fix it: the memory request channel is registered before the adapter, and the adapter's address checks now use MEM_AW+2-bit arithmetic instead of 65-bit. See section 13.1.

**Changes from v0.1.** Memory becomes a switch input as well as an output (9x10 crossbar). Outputs lock on grant, not on header transfer. Destination is latched per input at SOP. Illegal DST_ID drains to a sink port. SRC_ID is stamped at ingress and stray flits are dropped. LENGTH/EOP precedence, memory request encoding, error responses and the endpoint deadlock rule are now normative. Items marked **[v0.2]** are new or changed.

# 1. Design Goals and Scope

The system is an educational but implementation-oriented packet interconnect intended to progress from RTL simulation to synthesis and FPGA deployment. Eight bidirectional endpoints exchange variable-length packets through a central switch. Shared memory is logical port 8, which both receives requests and sends responses. The implementation uses one synchronous clock domain; CDC is an explicit later extension.

| Parameter | v0.2 Decision |
|---|---|
| Endpoints | 8 bidirectional endpoints |
| Connectivity | Any endpoint to any endpoint |
| Datapath / flit | 64 bits + SOP/EOP sideband |
| Transfer unit | Variable-length packet |
| Switch | **[v0.2]** 9 inputs (EP0–7, MEM) x 10 outputs (EP0–7, MEM, SINK) |
| Arbitration | Per-output round robin |
| Grant ownership | **[v0.2]** Locked from first grant until accepted EOP |
| Flow control | ready/valid backpressure, flit-level (wormhole) admission |
| Buffering | TX and RX FIFOs per endpoint |
| Ordering | FIFO order preserved per input stream |
| Memory | Port 8; BRAM first; request channel registered before the adapter |
| Clocking | Single shared clock; **[v0.3.0]** 70 MHz on xc7z020 (73.6 MHz measured max) |
| Implementation | SystemVerilog + Vivado + ZedBoard |

# 2. Architectural Overview

```
EP0..EP7 TX FIFO --> [ 9 x 10 crossbar  ] --> EP0..EP7 RX FIFO
MEM responses    --> [ per-output RR +   ] --> MEM requests --> Memory Adapter <--> BRAM
                     [ packet locks      ] --> SINK (illegal DST_ID, always ready)
```

Each endpoint has independent transmit and receive paths. A packet header identifies its destination. Each input latches the destination at SOP and requests exactly one output until its EOP transfers. Each output independently arbitrates, so non-conflicting packets advance in parallel.

# 3. Endpoint Interface

The streaming interface uses ready/valid semantics. A flit transfers only on a clock edge where valid && ready is true. While valid is asserted and ready is low, the producer must hold data, SOP and EOP stable.

| Signal | Dir. | Width | Meaning |
|---|---|---|---|
| tx_data | In | 64 | Transmit flit |
| tx_valid | In | 1 | Transmit flit is valid |
| tx_ready | Out | 1 | TX FIFO can accept flit (always 1 for a stray flit) |
| tx_sop | In | 1 | Start of packet |
| tx_eop | In | 1 | End of packet |
| rx_data | Out | 64 | Received flit |
| rx_valid | Out | 1 | Received flit is valid |
| rx_ready | In | 1 | Consumer can accept flit |
| rx_sop | Out | 1 | Start of packet |
| rx_eop | Out | 1 | End of packet |

**[v0.2] Ingress sanitizing (normative).** The endpoint port overwrites SRC_ID with its physical index on every header. A flit without SOP while no packet is open is a stray: it is accepted, dropped and counted as a framing error. SOP while a packet is open is forwarded as a body flit with SOP cleared and counted as a framing error. The switch therefore only ever sees well-framed streams.

**[v0.2] Deadlock rule (normative).** Every consumer must drain its RX interface independently of progress on its own TX interface. An endpoint that waits for its TX to complete before reading RX can deadlock against the memory adapter.

# 4. Packet and Flit Format

The first flit is the header. EOP is sideband and is authoritative for switching; the switch never reads LENGTH. LENGTH is checked by the memory adapter.

| Header field | Bits | Purpose |
|---|---|---|
| TYPE | 63:60 | Packet operation / message class |
| SRC_ID | 59:56 | 0–7 endpoints, 8 memory; **[v0.2]** stamped at ingress |
| DST_ID | 55:52 | 0–7 endpoints, 8 memory; **[v0.2]** 9–15 routed to SINK |
| LENGTH | 51:36 | Number of payload flits after the header; 0 is legal |
| TAG | 35:28 | Transaction identifier, echoed in memory responses |
| FLAGS | 27:24 | **[v0.2]** Error code in T_ERROR responses; otherwise reserved |
| RESERVED | 23:0 | Must transmit as zero |

| TYPE value | Meaning |
|---|---|
| 0x0 | DATA |
| 0x1 | MEM_READ_REQ |
| 0x2 | MEM_READ_RESP |
| 0x3 | MEM_WRITE_REQ |
| 0x4 | MEM_WRITE_RESP |
| 0xF | T_ERROR |

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

| Operation | Request (header LENGTH, payload) | Response |
|---|---|---|
| MEM_WRITE_REQ | LENGTH = 1 + n (n ≥ 1); p0 = address; p1..pn = data | MEM_WRITE_RESP, LENGTH 0, same TAG |
| MEM_READ_REQ | LENGTH = 2; p0 = address; p1[15:0] = n words | MEM_READ_RESP, LENGTH n, n data flits, same TAG |

**[v0.2] Errors.** On any violation the adapter drains to EOP and replies T_ERROR, LENGTH 0, same TAG, FLAGS = code. Writes commit as data flits arrive, so a write that fails its LENGTH check has already written the words it carried.

| FLAGS | Name | Condition |
|---|---|---|
| 0x1 | E_TYPE | TYPE other than MEM_READ_REQ / MEM_WRITE_REQ sent to memory |
| 0x2 | E_LEN | Observed payload flits ≠ LENGTH, header-only request, or illegal LENGTH |
| 0x3 | E_ALIGN | Address not a multiple of 8 |
| 0x4 | E_RANGE | Address, write burst or read count outside memory |

# 10. Clocking and Reset

All logic runs on one rising-edge clock. Reset is synchronous, active-low, with synchronized release at board level. Arbitration pointers, packet locks, route latches, FIFO state and adapter state return to idle. CDC is excluded from this baseline.

# 11. RTL Module Decomposition

| Module | Responsibility |
|---|---|
| skid_reg | **[v0.2.2]** 2-entry flop-based register slice, fully registered both ways |
| noc_pkg | Parameters, header layout, TYPE and error codes |
| rr_arbiter | N-way round robin, pointer committed on release |
| sync_fifo | Parameterized FWFT ready/valid FIFO |
| endpoint_port | TX/RX FIFOs, SRC stamping, stray-flit filtering |
| route_decode | Per-input destination latch, SINK mapping |
| output_port_ctrl | Per-output arbiter, lock-on-grant, release on EOP |
| noc_switch | 9x10 crossbar datapath and ready propagation |
| memory_adapter | Request decode, BRAM access, responses and errors |
| bram_sdp | Simple dual-port block RAM |
| noc_top | Endpoints + switch + memory + sink + status counters |
| ep_traffic, zed_top | FPGA self-test generator/checker and board wrapper |

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

| Version | WNS | Critical path |
|---|---|---|
| v0.2 | -6.466 ns | EP TX FIFO -> route decode -> arbiter -> mux -> memory adapter (65-bit checks) |
| v0.2.2 | -3.528 ns | route decode -> `stat_rx_pkts` 32-bit counter |
| v0.2.3 | -3.582 ns | input skid DST_ID -> route -> arbiter -> another input's ready |
| v0.3.0 | closes at 70 MHz | clock lowered; see below |

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

| Phase | Target |
|---|---|
| A | RTL simulation of arbiter, FIFO and one output |
| B | Crossbar simulation |
| C | Memory destination and BRAM |
| D | Vivado synthesis, timing and utilization |
| E | ZedBoard self-test: eight generators/checkers, LEDs, ILA on mark_debug nets |
| F | Optional AXI4 memory adapter to Zynq PS DDR |
| G | Optional CDC endpoint and multi-router/mesh evolution |

# 14. Design Parameters

| Parameter | Value |
|---|---|
| N_EP | 8 |
| N_IN / N_OUT | 9 / 10 |
| DATA_W / FLIT_W | 64 / 66 |
| DEST_W / TAG_W / LEN_W | 4 / 8 / 16 |
| FIFO_DEPTH | 16 flits (power of two, parameterized) |
| MEM_AW | 10 (1024 words) |
| ARBITRATION | Round robin, per output |
| LOCK_MODE | From first grant until accepted EOP |

# 15. Decisions Still Open

- Maximum legal packet length for application traffic (the fabric itself imposes none).
- Memory byte enables and burst limits beyond the 16-bit read count.
- CRC for off-chip or multi-router extensions.
- Latency and throughput targets beyond the 70 MHz clock.
- Credit-based flow control with registered ready, to lift the 73.6 MHz ceiling.
- QoS: weighted round robin, virtual channels or traffic classes.
- Whether the SINK should return T_ERROR to the source instead of silently dropping.

# 16. Build Order / Definition of Done

| Milestone | Definition of done | Status |
|---|---|---|
| P0 Protocol | Header, sideband, handshake, destination map and memory semantics frozen | Done (v0.2) |
| P1 Arbiter | Round-robin unit passes directed and contention tests | Done |
| P2 FIFO | Lossless FIFO passes full/empty/backpressure tests | Done |
| P3 Switch | Nine inputs contend for one output with locking | Done |
| P4 Crossbar | Independent output arbitration, simultaneous transfers | Done |
| P5 Endpoints | Eight endpoint wrappers integrated | Done |
| P6 Memory | BRAM read/write and error responses verified | Done |
| P7 System | Random traffic scoreboard passes with backpressure | Done |
| P8 FPGA | Vivado implementation closes timing; hardware self-test passes | Closes at 70 MHz (v0.3.0); board bring-up pending |

# 17. v0.2 Architectural Contract

**The core invariant:** an accepted flit is never dropped, duplicated, reordered within its packet, or interleaved with another packet on the same output, except flits deliberately discarded at ingress (strays) or at SINK (illegal DST_ID), which are counted. The flit offered on any output never changes while stalled. Arbitration is fair among continuously requesting inputs while the destination makes progress.

Any RTL change to packet format, ordering, locking or ready/valid semantics must first update this specification.
