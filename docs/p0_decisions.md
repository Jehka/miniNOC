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
