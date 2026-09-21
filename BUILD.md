# Build and status

## What exists

An 8-endpoint packet-switched interconnect with a shared-memory endpoint,
closing timing on a ZedBoard (xc7z020-1) and running on hardware, plus the
first stages of an IP network front end: a PS-to-fabric bridge and a hardware
forwarding table that maps IPv4 addresses to endpoints.

```
rtl/      noc_pkg, rr_arbiter, sync_fifo, skid_reg, bram_sdp, endpoint_port,
          route_decode, output_port_ctrl, noc_switch, memory_adapter, noc_top,
          axil_noc_bridge (AXI4-Lite <-> endpoint), fwd_table (IPv4 -> DST_ID)
tb/       tb_rr_arbiter, tb_sync_fifo, tb_noc_top (system scoreboard),
          tb_zed_selftest (board self-test), tb_n1_bridge (bridge + forwarding)
fpga/     ep_traffic (generator + checker), zed_top, zedboard.xdc, build.tcl  (track A)
          n1_top, n1.xdc, n1_bd.tcl                                          (track B)
sw/       noc_bridge.h/.c (bare-metal driver), n1_main.c (hardware acceptance test)
net/      noc_dissector.lua, noc_scapy.py, netns_lab.sh   (network tooling, not yet used)
scripts/  mutate.sh, spec_to_docx.js
docs/     design spec v0.3.0, network integration spec v0.4, P0 review
```

## Simulation

Needs Verilator >= 5.0 (developed on 5.020).

```
make lint                     # -Wall on zed_top, noc_top and n1_top
make unit                     # arbiter and FIFO
make sys DEPTH=16 SEED=3      # system scoreboard
make regress                  # depths 2/4/16/64 x seeds
make selftest                 # board self-test + fault injection
make n1                       # bridge + forwarding table, with generators running
make mutate                   # inject known bugs, confirm the benches catch them
make all
```

## Hardware

Two independent designs. Each script is complete on its own; run only the one you need.

### Track A: self-test bitstream (no processor)

```
cd <repo root>
vivado -mode batch -source fpga/build.tcl
```

Eight on-chip traffic generators and checkers, 100 MHz oscillator through an MMCM
to 70 MHz. SW0 enables traffic, SW1 adds random receive backpressure. LD0
heartbeat, LD1 pass, LD2 error (LD7:4 give the code), LD3 sink/framing moved.

After synthesis it prints `SKID PRESENT: 9 input slices` and `SOURCE DIR`. If
the count is 0, Vivado read an older `rtl/`.

### Track B: PS + bridge (N1 / N4)

```
cd <repo root>
vivado -mode batch -source fpga/n1_bd.tcl
```

Builds the block design (Zynq PS, bridge on endpoint 0, generators on 1-7),
bitstream and `build/n1/n1.xsa`. Check two lines in the output: `ADDRESS:` must
show `0x43C00000` (matching `NOC_BASE` in `sw/noc_bridge.h`), and `N1 WNS` must be
positive. The fabric clock is FCLK_CLK0 at 66.67 MHz.

Then in Vitis:

1. Platform component from `build/n1/n1.xsa`, standalone, `ps7_cortexa9_0`.
2. Application from the *Empty Application (C)* template; add the three `sw/` files.
3. UART on J14 at 115200 8N1. SW0 up.
4. Run. The launch config programs the device and runs `ps7_init`.

Expect `N1 PASS`. The fabric has no clock until the PS is initialised, so
programming the bitstream alone from Vivado leaves the LEDs dead; always launch
through Vitis.

### Two stale-build traps (each cost a debugging round)

**1. Vivado reading the wrong tree.** Relative paths resolve against the launch
directory. Three timing runs were byte-identical because Vivado kept compiling an
old checkout. Always `cd` to this repo root first.

**2. Vitis platform holding an old XSA.** The platform keeps its own copy of the
hardware. Rebuilding the application picks up new C code but not new hardware, so
the board runs the old bitstream against new software. Symptom: new registers
read `0xDEADBEEF` (the bridge's unmapped-address value). After every Vivado
rebuild: platform component, *Switch XSA* to the new file, build platform, clean
and build application, run.

The bridge's ID register is bumped whenever its register map changes (currently
`0x4E4F4332`, "NOC2"). A stale bitstream then fails on the first line of
`n1_main.c` instead of confusingly further down.

Check the bank 34/35 IOSTANDARD in both XDC files against the VADJ jumper (J18).
It is set to LVCMOS18.

## Verification status

| Item                                                | Result                                                                 |
| --------------------------------------------------- | ---------------------------------------------------------------------- |
| Lint,`-Wall`, three tops                          | Clean                                                                  |
| Unit: arbiter (N = 5, 8, 9)                         | Pass                                                                   |
| Unit: FIFO (depth 2, 16, 64)                        | Pass                                                                   |
| System scoreboard, depths 2/4/16/64, multiple seeds | Pass                                                                   |
| Board self-test in simulation                       | Pass, 72k packets, 250+ memory cycles per endpoint                     |
| Fault injection (single bit flip)                   | Detected                                                               |
| Mutation testing                                    | 11 of 11 injected bugs caught (M10/M11 on the forwarding path)         |
| Vivado implementation, track A                      | **Timing met at 70 MHz**                                         |
| Hardware, track A self-test                         | **Pass** — zero errors, including SW1 randomized backpressure   |
| Bridge + forwarding, simulation (`make n1`)       | **Pass**                                                         |
| N1 bridge, hardware                                 | **Pass** — all checks, 1000-packet soak, 3.4 MB/s MMIO baseline |
| N4 forwarding table, hardware                       | **Pass** — route by IP, miss discard, live remap, invalidation  |

Utilization, track A (includes the 8 self-test generators, not fabric-only):
7518 LUTs (14%), 750 LUTRAM, 4114 registers (3.9%), 2 BRAM. The N1 design adds
about 600 registers for the forwarding table.

## Measured results

**MMIO throughput (N1, hardware).** 1000 x 32-flit loopbacks in 72.9 ms:
**3.4 MB/s each way**, about 285 ns per AXI-Lite access, eight accesses per flit
round trip. The fabric moves 64 bits per cycle, roughly 530 MB/s per port at
66.67 MHz, so MMIO uses under 1% of it. This is the baseline for N7 (DMA).

The loopback runs concurrently with generator traffic but is not contended:
generators never address endpoint 0. Memory requests do contend, since the
memory port is shared.

## Timing history

Every number from a routed design, 100 MHz target unless stated.

| Version | WNS                    | Critical path                                                  | Fix                                                              |
| ------- | ---------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------- |
| v0.2    | -6.466 ns              | TX FIFO -> route -> arbiter -> mux -> memory adapter           | 65-bit address arithmetic; unregistered adapter input            |
| v0.2.1  | not measured           | —                                                             | Narrowed checks to MEM_AW+2 bits; skid on memory request channel |
| v0.2.2  | -3.528 ns              | route decode ->`stat_rx_pkts` 32-bit counter                 | Register slice on each switch input                              |
| v0.2.3  | -3.582 ns              | input skid DST_ID -> route -> arbiter -> another input's ready | Pipelined the status counters                                    |
| v0.3.0  | **met @ 70 MHz** | arbitration loop, 82% routing                                  | Clock set to the measured maximum                                |

**The ceiling is 73.6 MHz** for this architecture on this part. The limit is the
arbitration loop: one input's DST_ID determines another input's ready, 82%
routing across 13 logic levels, so it is wire-dominated and removing logic
returns little. Lifting it requires credit-based flow control with registered
ready, which changes the flow-control contract in design spec section 3.

100 MHz was the ZedBoard oscillator frequency, never a requirement. Track B runs
at 66.67 MHz because the PS derives FCLK by integer division and exactly 70 MHz
is not available.

## Next

See `PLAN.md`. Without an Ethernet cable: test the Wireshark dissector on a saved
capture, and write the lwIP application for N3. With one: N2 onward.
