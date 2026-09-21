/* noc_bridge.c -- flit and packet transfer over axil_noc_bridge */
#include "noc_bridge.h"

#define SPIN_LIMIT 1000000u

int noc_send_flit(int sop, int eop, uint64_t w)
{
    unsigned spins = 0;
    while (!(noc_rd(NOC_STATUS) & ST_TX_SPACE))
        if (++spins > SPIN_LIMIT) return -1;
    noc_wr(NOC_TX_LO, (uint32_t)w);
    noc_wr(NOC_TX_HI, (uint32_t)(w >> 32));
    noc_wr(NOC_TX_PUSH, (eop ? 2u : 0u) | (sop ? 1u : 0u));
    return 0;
}

int noc_recv_flit(int *sop, int *eop, uint64_t *w)
{
    unsigned spins = 0;
    uint32_t st;
    while (!((st = noc_rd(NOC_STATUS)) & ST_RX_AVAIL))
        if (++spins > SPIN_LIMIT) return -1;
    uint32_t lo = noc_rd(NOC_RX_LO);
    uint32_t hi = noc_rd(NOC_RX_HI);
    noc_wr(NOC_RX_POP, 1);
    *sop = !!(st & ST_RX_SOP);
    *eop = !!(st & ST_RX_EOP);
    *w   = ((uint64_t)hi << 32) | lo;
    return 0;
}

int noc_send_pkt(uint64_t hdr, const uint64_t *pay, unsigned n)
{
    if (noc_send_flit(1, n == 0, hdr)) return -1;
    for (unsigned k = 0; k < n; k++)
        if (noc_send_flit(0, k == n - 1, pay[k])) return -1;
    return 0;
}

int noc_recv_pkt(uint64_t *buf, unsigned max)
{
    int sop, eop;
    unsigned n = 0;
    uint64_t w;
    if (noc_recv_flit(&sop, &eop, &w) || !sop) return -1;
    buf[n++] = w;
    while (!eop) {
        if (noc_recv_flit(&sop, &eop, &w) || sop) return -1;
        if (n < max) buf[n] = w;
        n++;
    }
    return (int)n;
}

void noc_fwd_set(unsigned idx, uint32_t ip, unsigned dst, int valid)
{
    noc_wr(NOC_FWD_IDX, idx & 0xF);
    noc_wr(NOC_FWD_IP, ip);
    noc_wr(NOC_FWD_CTRL, ((dst & 0xF) << 8) | (valid ? 2u : 0u) | 1u);
}

int noc_fwd_probe(uint32_t ip)
{
    noc_wr(NOC_FWD_PROBE_IP, ip);
    uint32_t r = noc_rd(NOC_FWD_PROBE_RES);
    return (r & FWD_HIT) ? (int)(r & 0xF) : -1;
}

int noc_send_pkt_ip(uint32_t ip, uint64_t hdr, const uint64_t *pay, unsigned n)
{
    unsigned spins = 0;
    noc_wr(NOC_TX_DST_IP, ip);
    while (!(noc_rd(NOC_STATUS) & ST_TX_SPACE))
        if (++spins > SPIN_LIMIT) return -1;
    noc_wr(NOC_TX_LO, (uint32_t)hdr);
    noc_wr(NOC_TX_HI, (uint32_t)(hdr >> 32));
    noc_wr(NOC_TX_PUSH, PUSH_ROUTE | PUSH_SOP | (n == 0 ? PUSH_EOP : 0u));
    for (unsigned k = 0; k < n; k++)
        if (noc_send_flit(0, k == n - 1, pay[k])) return -1;
    return 0;
}

int noc_rx_src_ip(uint32_t *ip)
{
    unsigned spins = 0;
    while (!(noc_rd(NOC_STATUS) & ST_RX_AVAIL))
        if (++spins > SPIN_LIMIT) return -1;
    if (!(noc_rd(NOC_RX_SRC_INFO) & FWD_HIT)) return -1;
    *ip = noc_rd(NOC_RX_SRC_IP);
    return 0;
}

/* Wait long enough for a packet to cross the fabric, for miss checks. */
void noc_settle(void)
{
    for (volatile unsigned i = 0; i < 20000; i++) { }
}