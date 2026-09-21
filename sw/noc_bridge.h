/* noc_bridge.h -- bare-metal driver for axil_noc_bridge (network stage N1)
 *
 * Register map matches rtl/axil_noc_bridge.sv. A flit is 64 bits plus SOP/EOP:
 * push = TX_LO, TX_HI, TX_PUSH; receive = RX_LO, RX_HI, RX_POP.
 */
#ifndef NOC_BRIDGE_H
#define NOC_BRIDGE_H

#include <stdint.h>
#include "xil_io.h"

/* Set to the address Vivado assigns in the block design (Address Editor).
 * 0x43C00000 is the usual first M_AXI_GP0 peripheral address. */
#ifndef NOC_BASE
#define NOC_BASE 0x43C00000u
#endif

#define NOC_ID        0x00u
#define NOC_STATUS    0x04u
#define NOC_TX_LO     0x08u
#define NOC_TX_HI     0x0Cu
#define NOC_TX_PUSH   0x10u
#define NOC_RX_LO     0x14u
#define NOC_RX_HI     0x18u
#define NOC_RX_POP    0x1Cu
#define NOC_TX_COUNT  0x20u
#define NOC_RX_COUNT  0x24u
#define NOC_TX_DROP   0x28u

/* Forwarding table (N4): IPv4 address -> DST_ID, 16 entries */
#define NOC_FWD_MISS       0x2Cu
#define NOC_FWD_IDX        0x30u
#define NOC_FWD_IP         0x34u
#define NOC_FWD_CTRL       0x38u
#define NOC_FWD_ENT_IP     0x3Cu
#define NOC_FWD_ENT_INFO   0x40u
#define NOC_FWD_PROBE_IP   0x44u
#define NOC_FWD_PROBE_RES  0x48u
#define NOC_TX_DST_IP      0x4Cu
#define NOC_RX_SRC_IP      0x50u
#define NOC_RX_SRC_INFO    0x54u

#define PUSH_SOP      (1u << 0)
#define PUSH_EOP      (1u << 1)
#define PUSH_ROUTE    (1u << 2)      /* route by TX_DST_IP; only meaningful on SOP */
#define FWD_HIT       (1u << 31)
#define FWD_ENTRIES   16

#define IPV4(a,b,c,d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
                       ((uint32_t)(c) << 8)  |  (uint32_t)(d))

#define NOC_ID_VALUE  0x4E4F4332u        /* "NOC1" */

#define ST_TX_SPACE   (1u << 0)
#define ST_RX_AVAIL   (1u << 1)
#define ST_RX_SOP     (1u << 2)
#define ST_RX_EOP     (1u << 3)

/* TYPE field values (design spec section 4) */
enum { T_DATA = 0x0, T_MEM_READ_REQ = 0x1, T_MEM_READ_RESP = 0x2,
       T_MEM_WRITE_REQ = 0x3, T_MEM_WRITE_RESP = 0x4, T_ERROR = 0xF };
/* FLAGS in T_ERROR (design spec section 9) */
enum { E_NONE = 0, E_TYPE = 1, E_LEN = 2, E_ALIGN = 3, E_RANGE = 4 };

#define MEM_ID 8u

static inline uint32_t noc_rd(uint32_t off)             { return Xil_In32(NOC_BASE + off); }
static inline void     noc_wr(uint32_t off, uint32_t v) { Xil_Out32(NOC_BASE + off, v); }

static inline uint64_t noc_hdr(unsigned type, unsigned src, unsigned dst,
                               unsigned len, unsigned tag, unsigned flags)
{
    return ((uint64_t)(type  & 0xF)    << 60) | ((uint64_t)(src & 0xF) << 56) |
           ((uint64_t)(dst   & 0xF)    << 52) | ((uint64_t)(len & 0xFFFF) << 36) |
           ((uint64_t)(tag   & 0xFF)   << 28) | ((uint64_t)(flags & 0xF) << 24);
}

#define HDR_TYPE(h)  ((unsigned)((h) >> 60) & 0xF)
#define HDR_SRC(h)   ((unsigned)((h) >> 56) & 0xF)
#define HDR_DST(h)   ((unsigned)((h) >> 52) & 0xF)
#define HDR_LEN(h)   ((unsigned)((h) >> 36) & 0xFFFF)
#define HDR_TAG(h)   ((unsigned)((h) >> 28) & 0xFF)
#define HDR_FLAGS(h) ((unsigned)((h) >> 24) & 0xF)

/* Returns 0 on success, -1 on timeout. */
int  noc_send_flit(int sop, int eop, uint64_t w);
int  noc_recv_flit(int *sop, int *eop, uint64_t *w);
/* Whole packets. recv returns number of flits (header included), or -1. */
int  noc_send_pkt(uint64_t hdr, const uint64_t *pay, unsigned n);
int  noc_recv_pkt(uint64_t *buf, unsigned max);

/* Forwarding table. valid=0 removes the entry. */
void noc_fwd_set(unsigned idx, uint32_t ip, unsigned dst, int valid);
/* Returns dst_id on hit, -1 on miss. Does not touch traffic. */
int  noc_fwd_probe(uint32_t ip);
/* Send a packet addressed by IP: hardware looks up and rewrites DST_ID.
 * A miss discards the whole packet in hardware and counts FWD_MISS. */
int  noc_send_pkt_ip(uint32_t ip, uint64_t hdr, const uint64_t *pay, unsigned n);
/* Source address of the packet at the RX head (call before noc_recv_pkt).
 * Returns 0 and fills *ip on a reverse-lookup hit, -1 otherwise. */
int  noc_rx_src_ip(uint32_t *ip);
/* Short busy-wait so a dropped or in-flight packet has time to show up. */
void noc_settle(void);

#endif