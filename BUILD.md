# Build and status

## What exists

RTL, testbenches, an FPGA self-test harness and a Vivado flow for an 8-endpoint
packet interconnect with a shared-memory endpoint, closing timing at 70 MHz on
a ZedBoard (xc7z020-1).

```
rtl/      noc_pkg, rr_arbiter, sync_fifo, skid_reg, bram_sdp, endpoint_port,
          route_decode, output_port_ctrl, noc_switch, memory_adapter, noc_top
tb/       tb_rr_arbiter, tb_sync_fifo, tb_noc_top (system scoreboard), tb_zed_selftest
fpga/     ep_traffic (generator + checker), zed_top, zedboard.xdc, build.tcl
net/      noc_dissector.lua, noc_scapy.py, netns_lab.sh      (track B tooling)
scripts/  mutate.sh, spec_to_docx.js
docs/     design spec v0.3.0, network integration spec v0.4 draft, P0 review
```

## Running the simulations

Needs Verilator >= 5.0 (developed on 5.020).

```
make lint                     # -Wall, noc_top and zed_top
make unit                     # arbiter and FIFO
make sys DEPTH=16 SEED=3      # system scoreboard
make regress                  # depths 2/4/16/64 x seeds
make selftest                 # board self-test + fault injection
make mutate                   # inject known bugs, confirm the benches catch them
make all
```

## Building the bitstream

Run **from the repository root**, not from a parent directory:

```
cd <this directory>
vivado -mode batch -source fpga/build.tcl
vivado -mode batch -source fpga/build.tcl -tclargs ila     # with debug cores
```

After synthesis the script prints:

```
SKID PRESENT: 9 input slices
MEM SKID    : 1 cells
SOURCE DIR  : /path/it/actually/read
```

If either count is 0, Vivado read an older `rtl/` and the timing report from
that run describes the wrong netlist. This caused three wasted iterations;
check the line before reading any timing number.

Check `fpga/zedboard.xdc` bank 34/35 IOSTANDARD against the VADJ jumper (J18)
before programming. It is set to LVCMOS18.

## Verification status

| Item | Result |
|---|---|
| Lint, `-Wall`, both tops | Clean |
| Unit: arbiter (N = 5, 8, 9) | Pass |
| Unit: FIFO (depth 2, 16, 64) | Pass |
| System scoreboard, depths 2/4/16/64, multiple seeds | Pass |
| Board self-test in simulation | Pass, 72k packets, 250+ memory cycles/endpoint |
| Fault injection (single bit flip) | Detected |
| Mutation testing | 9 of 9 injected bugs caught |
| Vivado implementation | **Timing met at 70 MHz** |
| Hardware bring-up | **Not yet run** |

Utilization (includes the 8 self-test generators, not fabric-only):
7518 LUTs (14%), 750 LUTRAM, 4114 registers (3.9%), 2 BRAM.

## Timing history

Every number from a routed design, 100 MHz target unless stated.

| Version | WNS | Critical path | Fix |
|---|---|---|---|
| v0.2 | -6.466 ns | TX FIFO -> route -> arbiter -> mux -> memory adapter | 65-bit address arithmetic; unregistered adapter input |
| v0.2.1 | not measured | — | Narrowed checks to MEM_AW+2 bits; skid on memory request channel |
| v0.2.2 | -3.528 ns | route decode -> `stat_rx_pkts` 32-bit counter | Register slice on each switch input |
| v0.2.3 | -3.582 ns | input skid DST_ID -> route -> arbiter -> another input's ready | Pipelined the status counters |
| v0.3.0 | **met @ 70 MHz** | arbitration loop, 82% routing | Clock set to the measured maximum |

**The ceiling is 73.6 MHz** for this architecture on this part. The limit is the
arbitration loop: one input's DST_ID determines another input's ready, 82%
routing across 13 logic levels, so it is wire-dominated and removing logic
returns little. Lifting it requires credit-based flow control with registered
ready, which changes the flow-control contract in design spec section 3.

100 MHz was the ZedBoard oscillator frequency, never a requirement.

## What is next

See `PLAN.md`. Immediately: board bring-up (P9), then track B stage N1.
