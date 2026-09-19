---
title: "Mini-NoC Network Integration"
subtitle: "Ethernet / UDP Bridge Specification — Version 0.4 draft | ZedBoard Zynq-7020 | companion to Design Specification v0.3.0"
---

**Purpose.** Make the eight NoC endpoints and the memory endpoint reachable from a real IP network, so that the on-chip interconnect is addressable, forwardable and observable with ordinary network tools.

**Relationship to the design spec.** This document adds a layer above the packet interconnect. It changes nothing in Design Specification v0.3.0: flit format, locking, ordering, backpressure and error codes are unchanged. The bridge is a new endpoint-side component, not a change to the fabric.

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

| Address | DST_ID | Role |
|---|---|---|
| 192.168.1.10 | 0 | Endpoint 0 |
| 192.168.1.11 | 1 | Endpoint 1 |
| 192.168.1.12 | 2 | Endpoint 2 |
| 192.168.1.13 | 3 | Endpoint 3 |
| 192.168.1.14 | 4 | Endpoint 4 |
| 192.168.1.15 | 5 | Endpoint 5 |
| 192.168.1.16 | 6 | Endpoint 6 |
| 192.168.1.17 | 7 | Endpoint 7 |
| 192.168.1.18 | 8 | Shared memory |
| 192.168.1.1 | — | Host / gateway |

Subnet 192.168.1.0/24, static addressing, no DHCP. One MAC address answers ARP for all nine addresses.

**Forwarding table (normative).** The IP-to-DST_ID mapping is not hardcoded. `net_bridge` holds a 16-entry table in the PL, writable over AXI-Lite at runtime, each entry `{valid, ipv4_addr[31:0], dst_id[3:0]}`. A packet whose destination address misses the table is dropped and counted. Remapping an endpoint to a different address requires no rebuild; this is a forwarding plane, and demonstrating a live remap is a deliverable.

**Fallback.** If ARP for nine addresses proves impractical in lwIP, the fallback is one board address with UDP port 5000+N selecting the endpoint. The forwarding table then keys on port instead of address. This is a degradation of the demonstration, not of the datapath.

# 20. Encapsulation (stage 1 format)

The UDP payload is a NoC packet verbatim: the 64-bit header followed by payload words, each word big-endian on the wire. The bridge performs no header translation; it frames flits and asserts SOP/EOP.

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | NoC header word (TYPE, SRC_ID, DST_ID, LENGTH, TAG, FLAGS) |
| 8 | 8 x LENGTH | Payload words |

UDP destination port 5555 for encapsulated traffic. SRC_ID in the transmitted header is ignored and overwritten by `endpoint_port` as in design spec section 3; the bridge sets it to the DST_ID resolved for the sending host, so responses return to the correct endpoint.

**Constraint.** One UDP datagram carries exactly one NoC packet. A packet whose LENGTH exceeds the datagram is rejected with E_LEN.

# 21. Translation (stage 2 format)

Once encapsulation is proven, the bridge builds the NoC header from the IP/UDP headers instead of copying it:

| NoC field | Source |
|---|---|
| DST_ID | Forwarding-table lookup on destination IPv4 address |
| SRC_ID | Forwarding-table lookup on source IPv4 address, else the bridge's own ID |
| LENGTH | UDP payload length / 8, rejected if not a multiple of 8 |
| TYPE | UDP destination port: 5555 DATA, 5556 MEM_READ_REQ, 5557 MEM_WRITE_REQ |
| TAG | Low 8 bits of the UDP source port, echoed in responses for correlation |
| FLAGS | Zero on ingress; carries the error code on egress |

In this mode the host sends ordinary UDP datagrams containing only data, and the network layer determines the on-chip routing. This is the target format.

# 22. Error Mapping

The adapter's error codes (design spec section 9) become visible at the network layer. An error response is returned to the sender as a UDP datagram on the reply port with the encapsulated T_ERROR packet, FLAGS carrying the code.

| FLAGS | Name | Network-visible meaning |
|---|---|---|
| 0x1 | E_TYPE | Unsupported operation for that destination port |
| 0x2 | E_LEN | Datagram length disagrees with LENGTH, or not a multiple of 8 |
| 0x3 | E_ALIGN | Memory address not a multiple of 8 |
| 0x4 | E_RANGE | Memory address or burst outside the 1024-word region |

Two conditions are network-layer only and have no on-chip equivalent:

| Condition | Behaviour |
|---|---|
| Destination IP misses the forwarding table | Drop, increment `stat_fwd_miss` |
| Destination resolves to DST_ID 9-15 | Forwarded to the fabric, which sinks it (design spec section 5); counted by `stat_sink_pkts` |

The second is deliberate: it exercises the existing sink path from the network side, proving on hardware that illegal destinations are dropped rather than deadlocking an input.

# 23. Fragmentation

The fabric imposes no packet-length limit; LENGTH allows 65535 payload flits, or 512 kB. A 1500-byte MTU carries at most 184 payload words.

**Policy for v0.4:** no fragmentation. A NoC packet must fit one datagram; longer transfers are rejected with E_LEN. Fragmentation and reassembly, which would require reassembly buffers and a timeout in the bridge, are deferred. Jumbo frames are not assumed.

# 24. Verification

Each stage has one artifact that proves it, independent of the stage below.

| Stage | Proves | Artifact |
|---|---|---|
| N1 PS-PL bridge | Flits move between PS and NoC | Bare-metal C write/read loopback |
| N2 lwIP echo | GEM, PHY and IP config work | `ping` and UDP echo, no NoC involved |
| N3 Encapsulation | End-to-end path | Wireshark capture with the NoC dissector decoding TYPE/SRC/DST |
| N4 Forwarding | Address plan and table | `ping` to all nine addresses; live remap of one entry |
| N5 Error paths | Error codes surface on the wire | Scapy malformed-packet suite, one capture per code |
| N6 Routed hop | Board behaves as a host | Namespace router, ACL permitting endpoints 0-3 and denying 4-7 |

**Tooling.** A Wireshark Lua dissector (`net/noc_dissector.lua`) decodes the encapsulated format. A Scapy suite (`net/noc_scapy.py`) generates both valid traffic and each error case. A shell script (`net/netns_lab.sh`) builds the routed topology with `ip netns` and `nftables`; no commercial simulator is required. Cisco Packet Tracer cannot be used at all, as it has no path to physical interfaces.

# 25. Open Decisions

- Whether the memory endpoint should expose read/write as distinct UDP ports or as a TYPE field in an encapsulated header.
- Retry and timeout policy: UDP is lossy, the fabric is not. A dropped response currently looks identical to a lost request.
- Whether `stat_fwd_miss` and per-endpoint packet counters should be readable over AXI-Lite for host-side monitoring.
- AXI-DMA migration: at what stage the PS stops touching payload data.
