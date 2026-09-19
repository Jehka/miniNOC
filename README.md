# Mini-NoC — 8-endpoint packet interconnect (spec v0.3.0)

Packet-switched interconnect: 8 bidirectional endpoints plus a shared-memory
endpoint, through a 9x10 crossbar. Per-output round-robin arbitration with
whole-packet locking and lossless ready/valid backpressure. SystemVerilog,
closing timing at 70 MHz on a ZedBoard (xc7z020-1).

```
EP0..EP7 TX FIFO --> [ 9x10 crossbar      ] --> EP0..EP7 RX FIFO
MEM responses    --> [ per-output RR +    ] --> MEM requests --> memory_adapter <--> BRAM
                     [ lock-on-grant      ] --> SINK (illegal DST_ID)
```

Track B extends this to a real IP network: each endpoint gets its own address,
reachable with ordinary tools, with a runtime-writable forwarding table in the
PL. See `docs/network_integration.md`.

| Document | Contents |
|---|---|
| `BUILD.md` | How to build and run, verification status, timing history |
| `PLAN.md` | What is done and what is next, both tracks |
| `docs/packet_noc_design_spec_v0_3_0.docx` | Design specification (source: `docs/spec_v0_2.md`) |
| `docs/network_integration.md` | Network integration spec: address plan, encapsulation, error mapping |
| `docs/p0_decisions.md` | Review of the v0.1 spec and the decisions taken |

## Status

| Milestone | State | Evidence |
|---|---|---|
| P0 Protocol | Frozen in v0.2 | `docs/p0_decisions.md`, spec sections 4-9 |
| P1 Arbiter | Pass | `tb_rr_arbiter`, N = 5, 8, 9: directed, rotation, packet-lock fairness, 20k random vs model, reset |
| P2 FIFO | Pass | `tb_sync_fifo`, DEPTH = 2, 16, 64: fill/drain, 20k random-stall scoreboard, stability, reset |
| P3 Switch | Pass | `tb_noc_top`: 8 inputs → one output, fairness bound incl. first-packet wait |
| P4 Crossbar | Pass | Permutation traffic drives all 8 outputs in the same cycle |
| P5 Endpoints | Pass | Any-to-any, header-only, packets longer than the FIFO |
| P6 Memory | Pass | Reference model; boundaries, zero-length read, all 4 error codes |
| P7 System | Pass | Random traffic + memory + illegal DST + stray flits + random stalls, counters, reset/recovery; FIFO depth 2/4/16/64 × seeds |
| P8 FPGA | Fixes applied, re-run pending | `tb_zed_selftest` passes and detects an injected bit flip. **First Vivado run: WNS -6.466 ns. Two fixes applied (see below); implementation not yet re-run.** |

Mutation testing (`make mutate`): 9/9 injected bugs caught, including the v0.1
lock-on-header-transfer rule (M1).

## Layout

```
rtl/      noc_pkg, rr_arbiter, sync_fifo, skid_reg, bram_sdp, endpoint_port,
          route_decode, output_port_ctrl, noc_switch, memory_adapter, noc_top
tb/       tb_rr_arbiter, tb_sync_fifo, tb_noc_top (system scoreboard), tb_zed_selftest
fpga/     ep_traffic (generator/checker), zed_top, zedboard.xdc, build.tcl
net/      noc_dissector.lua (Wireshark), noc_scapy.py (traffic + error suite),
          netns_lab.sh (routed hop + ACL lab)
scripts/  mutate.sh, spec_to_docx.js
docs/     design spec, network integration spec, P0 review
```

## Network tooling (track B)

```
wireshark -X lua_script:net/noc_dissector.lua          # decode NoC on the wire
sudo python3 net/noc_scapy.py --iface eth0 errors      # drive every error code
sudo ./net/netns_lab.sh up eth0 && sudo ./net/netns_lab.sh acl
```

## Running

Needs Verilator ≥ 5.0 (developed on 5.020).

```
make lint                     # -Wall, noc_top and zed_top
make unit                     # P1, P2
make sys DEPTH=16 SEED=3      # P3–P7 system test
make regress                  # depths 2/4/16/64 × seeds 1–3
make selftest                 # board self-test in simulation (+ fault injection)
make mutate                   # ~1 min per mutant
make all
```

## ZedBoard (P8)

```
vivado -mode batch -source fpga/build.tcl            # bitstream + timing/util reports in build/vivado
vivado -mode batch -source fpga/build.tcl -tclargs ila
```

| Control | Function |
|---|---|
| SW0 | Traffic enable |
| SW1 | Random RX backpressure |
| BTNC | Reset |
| LD0 | Heartbeat (1 Hz; derived from the CLK_HZ parameter) |
| LD1 | PASS: no error, ≥1024 memory cycles, ≥100k packets |
| LD2 | Error (sticky) |
| LD3 | Sink/framing counter nonzero (should stay off) |
| LD7:4 | First error code, or rx-activity nibble |

Error codes: 1 sequence/ordering, 2 payload, 3 length/EOP, 4 wrong destination,
5 memory data, 6 unexpected response, 7 response watchdog, 8 framing.

Check `fpga/zedboard.xdc` bank 34/35 IOSTANDARD against your VADJ jumper (J18)
before programming.

### Timing history

First implementation run (Vivado 2025.2, 100 MHz): **WNS -6.466 ns**, 2116
failing endpoints. Every failing path ran from an endpoint TX FIFO through
route decode, the output-8 arbiter and the crossbar mux into the memory
adapter — 30 logic levels, 15-17 CARRY4.

Measured on xc7z020-1, 100 MHz target, routed:

| Version | WNS | Critical path |
|---|---|---|
| v0.2 | -6.466 ns | EP TX FIFO → route decode → arbiter → mux → memory adapter |
| v0.2.2 | -3.528 ns | route decode → `stat_rx_pkts` 32-bit counter |
| v0.2.3 | -3.582 ns | input skid DST_ID → route → arbiter → another input's ready |
| v0.3.0 | closes @ 70 MHz | clock lowered to the measured maximum |

Fix in v0.2.3:
- Status counters pipelined. The event condition fed a 32-bit carry chain in the
  same cycle it was computed; event bits and their population count are now
  registered first. Debug logic was setting the clock ceiling.

Fix in v0.2.2:
- Each switch input has a flop-based register slice (`rtl/skid_reg.sv`), so
  arbitration starts at a flip-flop instead of a FIFO LUTRAM read plus three LUT
  levels of route decode — about 3.5 ns of the failing path. No latency cost at
  full rate; all 8 outputs still transfer in the same cycle in P4.

Two fixes in v0.2.1:
- `noc_top` registers the switch-to-memory request channel (depth-2 skid FIFO),
  removing ~9.5 ns of arbitration delay from in front of the adapter.
- `memory_adapter` does address range and burst checks in MEM_AW+2 bits instead
  of 65, removing the carry chains.

Both verified in simulation (system tests at depths 2/4/16, seeds 1-3; board
self-test; memory mutants M6/M8 still caught). **No corrected bitstream has been produced yet.** The three timing reports so
far are all byte-identical (WNS -6.466, TNS -5981.686, 2116 endpoints) and all
show 65-bit `burst_end` carry chains and no `u_mem_req_skid`, so they are runs
of the pre-v0.2.1 sources. `fpga/build.tcl` uses relative paths and picks up
whatever `rtl/` sits under the launch directory. Verify with the SKID PRESENT
line it now prints after synthesis: zero means the old tree.

### Why 70 MHz

The final path is the arbitration loop: one input's DST_ID decides another
input's ready. At 82% routing over 13 logic levels it is wire-dominated, so
removing logic returns little. 12.989 ns of data path needs ~13.58 ns with skew
and uncertainty: **73.6 MHz is this architecture's ceiling on xc7z020-1.** The
fabric runs at 70 MHz from an MMCM (100 MHz in, VCO 700 MHz, /10) with ~0.7 ns
margin, and reset is held until lock.

Lifting it means credit-based flow control with registered ready, which changes
the flow-control contract — a v0.4 project, not a tuning pass. 100 MHz was only
ever the board oscillator frequency, not a requirement.

### Superseded notes

The remaining path will be datapath, and routing was already 73% of the
v0.2.2 path, so pipelining returns less than it did. Options in order:

A register slice on each switch output remains available if a future version
needs it, at one cycle of latency per packet and no throughput cost.

## Verilator 5.020 notes

The testbenches contain workarounds for three simulator issues:
- Local queues inside automatic tasks are not re-initialised per call, so they are cleared explicitly.
- Arrays of queues with a non-power-of-2 dimension generate invalid C++. The scoreboard uses a flat `[128][$]` array.
- Comments beginning `// Verilator` are parsed as metacomments.
