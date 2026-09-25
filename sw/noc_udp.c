/* noc_udp.c -- UDP <-> NoC bridging (network stage N3) */
#include <string.h>

#include "lwip/udp.h"
#include "lwip/pbuf.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
#include "lwip/inet.h"
#include "xil_printf.h"

#include "noc_bridge.h"
#include "noc_udp.h"
#include "noc_alias.h"

#define MAX_FLITS 64                      /* 512 bytes: fits one MTU comfortably */

unsigned noc_udp_rx_datagrams, noc_udp_tx_datagrams;
unsigned noc_udp_bad_length, noc_udp_no_route, noc_udp_no_host, noc_udp_ctl_ops;

static struct udp_pcb *pcb, *raw_pcb, *ctl_pcb;
static const int raw_tag = 1;      /* non-NULL arg marks the header-routed port */

/* Where to send a reply from each endpoint: the host that last addressed it.
 * Indexed by DST_ID, so replies from memory (8) go to whoever wrote to it. */
/* A reply must look like it came from where the request was sent: same source
 * port and same source address. A host firewall tracks the flow and drops
 * anything else, so remember the pcb and the local address that was contacted,
 * not just the client. (Replying from the endpoint's own table address seemed
 * tidier, but it breaks the flow whenever the client addressed the board by a
 * different address; in N4, where the client does address the endpoint
 * directly, this rule gives the same result anyway.) */
static struct {
    ip_addr_t      ip;      /* client */
    u16_t          port;    /* client */
    ip_addr_t      local;   /* address the client sent to */
    struct udp_pcb *via;    /* port the request arrived on */
    int            valid;
} host_of[16];

static uint64_t be64(const u8_t *p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
    return v;
}

static void put_be64(u8_t *p, uint64_t v)
{
    for (int i = 7; i >= 0; i--) { p[i] = (u8_t)(v & 0xFF); v >>= 8; }
}

/* A datagram arrived. Its destination address picks the endpoint. */
static void noc_udp_recv(void *arg, struct udp_pcb *up, struct pbuf *p,
                         const ip_addr_t *addr, u16_t port)
{
    (void)up;
    int raw = (arg != NULL);          /* the port-5556 pcb registers arg = &raw_tag */
    if (p == NULL) return;

    /* The address the client actually used. For an alias address the stack has
     * already had the destination rewritten to the board's own address, so ask
     * the alias layer what the datagram was addressed to. */
    uint32_t dst_ip = noc_alias_current_dest();
    ip_addr_t dst_addr;
    IP4_ADDR(&dst_addr, (dst_ip >> 24) & 0xFF, (dst_ip >> 16) & 0xFF,
                        (dst_ip >> 8)  & 0xFF,  dst_ip        & 0xFF);
    const ip_addr_t *dst = &dst_addr;

    /* The payload must be a whole number of 64-bit flits, header included. */
    if (p->tot_len < 8 || (p->tot_len % 8) != 0 || p->tot_len > MAX_FLITS * 8) {
        noc_udp_bad_length++;
        pbuf_free(p);
        return;
    }

    /* Port 5555 routes by address: the table decides the endpoint, which is the
     * target behaviour. Until lwIP answers ARP for all nine addresses (N4), only
     * the board's own address resolves, so port 5556 is kept as a way in: it
     * honours the DST_ID already in the header and reaches any endpoint. */
    int dst_id = raw ? -2 : noc_fwd_probe(dst_ip);
    if (dst_id == -1) {
        noc_udp_no_route++;
        pbuf_free(p);
        return;
    }


    u8_t buf[MAX_FLITS * 8];
    pbuf_copy_partial(p, buf, p->tot_len, 0);
    unsigned flits = p->tot_len / 8;
    pbuf_free(p);

    uint64_t hdr = be64(buf);
    uint64_t pay[MAX_FLITS];
    for (unsigned k = 1; k < flits; k++) pay[k - 1] = be64(buf + 8 * k);

    /* Remember who to answer, keyed by the endpoint that will reply. */
    if (raw) dst_id = (int)((hdr >> 52) & 0xF);
    if (dst_id >= 0 && dst_id < 16) {
        host_of[dst_id].ip    = *addr;
        host_of[dst_id].port  = port;
        host_of[dst_id].local = *dst;
        host_of[dst_id].via   = raw ? raw_pcb : pcb;
        host_of[dst_id].valid = 1;
    }

    /* Push by IP (table rewrites DST_ID), or as-is in raw mode. */
    int ok = raw ? noc_send_pkt(hdr, pay, flits - 1)
                 : noc_send_pkt_ip(dst_ip, hdr, pay, flits - 1);
    if (ok == 0) noc_udp_rx_datagrams++;
}

/* Control plane: the forwarding table is reprogrammed from the network, so an
 * endpoint can be moved to a different address while traffic is running and
 * without rebuilding anything. Writing an entry also updates the set of
 * addresses this board answers ARP for, or the new address would never resolve. */
static void noc_ctl_recv(void *arg, struct udp_pcb *up, struct pbuf *p,
                         const ip_addr_t *addr, u16_t port)
{
    (void)arg; (void)up;
    if (p == NULL) return;
    if (p->tot_len < 12) { pbuf_free(p); return; }

    u8_t m[12];
    pbuf_copy_partial(p, m, 12, 0);
    pbuf_free(p);

    unsigned op    = m[0], idx = m[1] & 0xF, dst = m[2] & 0xF, valid = m[3];
    uint32_t ip    = ((uint32_t)m[4] << 24) | ((uint32_t)m[5] << 16) |
                     ((uint32_t)m[6] << 8)  |  (uint32_t)m[7];

    if (op == NOC_CTL_STATS) {
        /* Counters, so the host can prove a packet was dropped rather than
         * infer it from a timeout, and tell apart the three reasons: rejected
         * at the network layer, missed in the table, or refused by the fabric. */
        uint32_t c[7] = {
            noc_rd(NOC_TX_COUNT), noc_rd(NOC_RX_COUNT), noc_rd(NOC_TX_DROP),
            noc_rd(NOC_FWD_MISS), noc_udp_rx_datagrams, noc_udp_no_route,
            noc_udp_bad_length
        };
        struct pbuf *sp = pbuf_alloc(PBUF_TRANSPORT, 32, PBUF_RAM);
        if (sp == NULL) return;
        u8_t so[32];
        memset(so, 0, sizeof(so));
        so[0] = (u8_t)op;
        for (unsigned i = 0; i < 7; i++) {
            so[4 + i * 4] = (u8_t)(c[i] >> 24); so[5 + i * 4] = (u8_t)(c[i] >> 16);
            so[6 + i * 4] = (u8_t)(c[i] >> 8);  so[7 + i * 4] = (u8_t)c[i];
        }
        pbuf_take(sp, so, 32);
        udp_sendto(ctl_pcb, sp, addr, port);
        pbuf_free(sp);
        return;
    }

    if (op == NOC_CTL_WRITE) {
        /* Read the entry being replaced so its address stops being answered. */
        noc_wr(NOC_FWD_IDX, idx);
        uint32_t old_ip   = noc_rd(NOC_FWD_ENT_IP);
        uint32_t old_info = noc_rd(NOC_FWD_ENT_INFO);
        if ((old_info & FWD_HIT) && old_ip != 0) noc_alias_remove(old_ip);

        noc_fwd_set(idx, ip, dst, valid);
        if (valid) noc_alias_add(ip);
        noc_udp_ctl_ops++;
        xil_printf("ctl: entry %u -> %u.%u.%u.%u dst %u valid %u\r\n", idx,
                   (unsigned)(ip >> 24) & 0xFF, (unsigned)(ip >> 16) & 0xFF,
                   (unsigned)(ip >> 8) & 0xFF, (unsigned)ip & 0xFF, dst, valid);
    }

    /* Answer with the entry as hardware now holds it. */
    noc_wr(NOC_FWD_IDX, idx);
    uint32_t cur_ip   = noc_rd(NOC_FWD_ENT_IP);
    uint32_t cur_info = noc_rd(NOC_FWD_ENT_INFO);

    struct pbuf *r = pbuf_alloc(PBUF_TRANSPORT, 12, PBUF_RAM);
    if (r == NULL) return;
    u8_t o[12] = {
        (u8_t)op, (u8_t)idx, (u8_t)(cur_info & 0xF), (u8_t)((cur_info & FWD_HIT) ? 1 : 0),
        (u8_t)(cur_ip >> 24), (u8_t)(cur_ip >> 16), (u8_t)(cur_ip >> 8), (u8_t)cur_ip,
        (u8_t)(noc_rd(NOC_FWD_MISS) >> 24), (u8_t)(noc_rd(NOC_FWD_MISS) >> 16),
        (u8_t)(noc_rd(NOC_FWD_MISS) >> 8),  (u8_t)noc_rd(NOC_FWD_MISS)
    };
    pbuf_take(r, o, 12);
    udp_sendto(ctl_pcb, r, addr, port);
    pbuf_free(r);
}

void noc_udp_service(void)
{
    uint64_t pkt[MAX_FLITS];
    uint32_t src_ip;
    int n, src_id;

    /* Nothing waiting: return immediately, this runs in the main loop. */
    if (!(noc_rd(NOC_STATUS) & ST_RX_AVAIL)) return;

    src_id = (int)(noc_rd(NOC_RX_SRC_INFO) & 0xF);
    src_ip = noc_rd(NOC_RX_SRC_IP);

    n = noc_recv_pkt(pkt, MAX_FLITS);
    if (n <= 0) return;

    if (!host_of[src_id].valid) {           /* nobody asked for this */
        noc_udp_no_host++;
        return;
    }

    struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)(n * 8), PBUF_RAM);
    if (p == NULL) return;

    u8_t out[MAX_FLITS * 8];
    for (int k = 0; k < n && k < MAX_FLITS; k++) put_be64(out + 8 * k, pkt[k]);
    pbuf_take(p, out, (u16_t)(n * 8));

    /* Reply from the endpoint's own address where the table knows one, so the
     * host sees which endpoint answered; otherwise from the board's address. */
    struct udp_pcb *via = host_of[src_id].via ? host_of[src_id].via : pcb;
    udp_sendto_if_src(via, p, &host_of[src_id].ip, host_of[src_id].port,
                      netif_default, &host_of[src_id].local);
    (void)src_ip;
    pbuf_free(p);
    noc_udp_tx_datagrams++;
}

void noc_udp_init_table(void)
{
    for (unsigned i = 0; i < FWD_ENTRIES; i++) noc_fwd_set(i, 0, 0, 0);
    for (unsigned n = 0; n < 8; n++)                       /* endpoints 0-7 */
        noc_fwd_set(n, IPV4(10, 10, 10, 10 + n), n, 1);
    noc_fwd_set(8, IPV4(10, 10, 10, 18), MEM_ID, 1);       /* shared memory */

    xil_printf("forwarding table:\r\n");
    for (unsigned n = 0; n < 9; n++)
        xil_printf("  10.10.10.%-3d -> endpoint %d\r\n", 10 + n,
                   (n == 8) ? MEM_ID : n);
}

int noc_udp_start(void)
{
    memset(host_of, 0, sizeof(host_of));

    pcb = udp_new();
    if (pcb == NULL) { xil_printf("udp_new failed\r\n"); return -1; }

    /* Bind to every local address so all nine endpoint addresses are served. */
    if (udp_bind(pcb, IP_ANY_TYPE, NOC_UDP_PORT) != ERR_OK) {
        xil_printf("udp_bind %d failed\r\n", NOC_UDP_PORT);
        return -1;
    }
    udp_recv(pcb, noc_udp_recv, NULL);

    raw_pcb = udp_new();
    if (raw_pcb == NULL || udp_bind(raw_pcb, IP_ANY_TYPE, NOC_UDP_PORT_RAW) != ERR_OK) {
        xil_printf("udp_bind %d failed\r\n", NOC_UDP_PORT_RAW);
        return -1;
    }
    udp_recv(raw_pcb, noc_udp_recv, (void *)&raw_tag);

    ctl_pcb = udp_new();
    if (ctl_pcb == NULL || udp_bind(ctl_pcb, IP_ANY_TYPE, NOC_UDP_PORT_CTL) != ERR_OK) {
        xil_printf("udp_bind %d failed\r\n", NOC_UDP_PORT_CTL);
        return -1;
    }
    udp_recv(ctl_pcb, noc_ctl_recv, NULL);

    xil_printf("NoC UDP bridge: %d routes by address, %d by header DST_ID, "
               "%d is the forwarding-table control port\r\n",
               NOC_UDP_PORT, NOC_UDP_PORT_RAW, NOC_UDP_PORT_CTL);
    return 0;
}

void noc_udp_print_counters(void)
{
    xil_printf("udp in %u  out %u | bad_len %u  no_route %u  no_host %u | "
               "fwd_miss %u  tx_drop %u\r\n",
               noc_udp_rx_datagrams, noc_udp_tx_datagrams, noc_udp_bad_length,
               noc_udp_no_route, noc_udp_no_host,
               (unsigned)noc_rd(NOC_FWD_MISS), (unsigned)noc_rd(NOC_TX_DROP));
}