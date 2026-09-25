/* noc_alias.c -- ARP, ICMP and UDP for the endpoint addresses (stage N4) */
#include <string.h>

#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/etharp.h"
#include "lwip/inet_chksum.h"
#include "netif/ethernet.h"
#include "xil_printf.h"

#include "noc_alias.h"

#define MAX_ALIASES 16

#define ETH_HDR_LEN   14
#define ETHTYPE_ARP_  0x0806
#define ETHTYPE_IP_   0x0800
#define IP_PROTO_ICMP_ 1
#define IP_PROTO_UDP_  17

unsigned noc_alias_arp_replies, noc_alias_pings, noc_alias_udp_rewritten;

static struct netif *nif;
static netif_input_fn  lwip_input;          /* the real ethernet_input */
static uint32_t alias[MAX_ALIASES];
static unsigned n_alias;
static uint32_t current_dest;

static uint16_t rd16(const u8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t rd32(const u8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}
static void wr32(u8_t *p, uint32_t v)
{
    p[0] = (u8_t)(v >> 24); p[1] = (u8_t)(v >> 16);
    p[2] = (u8_t)(v >> 8);  p[3] = (u8_t)v;
}

static uint32_t own_ip(void)
{
    return lwip_ntohl(ip4_addr_get_u32(netif_ip4_addr(nif)));
}

static int is_alias(uint32_t ip)
{
    for (unsigned i = 0; i < n_alias; i++) if (alias[i] == ip) return 1;
    return 0;
}

int noc_alias_add(uint32_t ip)
{
    if (n_alias >= MAX_ALIASES) return -1;
    alias[n_alias++] = ip;
    return 0;
}

int noc_alias_remove(uint32_t ip)
{
    for (unsigned i = 0; i < n_alias; i++) {
        if (alias[i] == ip) {
            alias[i] = alias[--n_alias];        /* order does not matter */
            return 0;
        }
    }
    return -1;
}

uint32_t noc_alias_current_dest(void) { return current_dest; }

/* ---------------------------------------------------------------- ARP */
/* Answer "who has <alias>?" with our own MAC. Frame layout is fixed, so the
 * reply is built by hand rather than through etharp, which would insist the
 * address belongs to the netif. */
static void arp_reply(const u8_t *req)
{
    struct pbuf *p = pbuf_alloc(PBUF_RAW, 42, PBUF_RAM);
    if (p == NULL) return;
    u8_t *o = (u8_t *)p->payload;

    memcpy(o, req + 6, 6);                       /* dst MAC = requester      */
    memcpy(o + 6, nif->hwaddr, 6);               /* src MAC = ours           */
    o[12] = 0x08; o[13] = 0x06;                  /* ethertype ARP            */

    o[14] = 0x00; o[15] = 0x01;                  /* hardware type Ethernet   */
    o[16] = 0x08; o[17] = 0x00;                  /* protocol type IPv4       */
    o[18] = 6;    o[19] = 4;                     /* address lengths          */
    o[20] = 0x00; o[21] = 0x02;                  /* opcode reply             */

    memcpy(o + 22, nif->hwaddr, 6);              /* sender MAC = ours        */
    memcpy(o + 28, req + 38, 4);                 /* sender IP  = the target  */
    memcpy(o + 32, req + 22, 6);                 /* target MAC = requester   */
    memcpy(o + 38, req + 28, 4);                 /* target IP  = requester   */

    nif->linkoutput(nif, p);
    pbuf_free(p);
    noc_alias_arp_replies++;
}

/* --------------------------------------------------------------- ICMP */
/* Turn an echo request into a reply in place: swap the MAC and IP addresses,
 * change the type, and adjust the ICMP checksum incrementally. The IP header
 * checksum is unchanged because swapping addresses does not change their sum. */
static void icmp_echo_reply(u8_t *f, u16_t len)
{
    u8_t  *ip   = f + ETH_HDR_LEN;
    u8_t   ihl  = (u8_t)((ip[0] & 0x0F) * 4);
    u8_t  *icmp = ip + ihl;
    u8_t   mac[6];

    if (len < ETH_HDR_LEN + ihl + 8u) return;

    memcpy(mac, f, 6); memcpy(f, f + 6, 6); memcpy(f + 6, mac, 6);

    u32_t s = rd32(ip + 12), d = rd32(ip + 16);
    wr32(ip + 12, d); wr32(ip + 16, s);

    icmp[0] = 0;                                  /* echo request -> reply   */
    uint32_t ck = rd16(icmp + 2) + 0x0800;        /* type 8 -> 0, high byte  */
    if (ck > 0xFFFF) ck = (ck & 0xFFFF) + 1;
    icmp[2] = (u8_t)(ck >> 8); icmp[3] = (u8_t)ck;

    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
    if (p == NULL) return;
    memcpy(p->payload, f, len);
    nif->linkoutput(nif, p);
    pbuf_free(p);
    noc_alias_pings++;
}

/* ---------------------------------------------------------------- UDP */
/* lwIP drops IP packets not addressed to the netif, so rewrite the destination
 * to our own address and let the stack deliver normally. The original address
 * is kept for the application, which needs it to pick an endpoint. The UDP
 * checksum covers the destination address, so zero it: IPv4 permits that and
 * receivers skip the check. The IP header checksum is recomputed. */
static void udp_rewrite(u8_t *f)
{
    u8_t *ip  = f + ETH_HDR_LEN;
    u8_t  ihl = (u8_t)((ip[0] & 0x0F) * 4);
    u8_t *udp = ip + ihl;

    wr32(ip + 16, own_ip());
    ip[10] = 0; ip[11] = 0;
    u16_t ck = inet_chksum(ip, ihl);      /* already complemented, network order */
    memcpy(ip + 10, &ck, 2);

    udp[6] = 0; udp[7] = 0;                       /* checksum disabled       */
    noc_alias_udp_rewritten++;
}

/* ------------------------------------------------------------- wrapper */
static err_t noc_alias_input(struct pbuf *p, struct netif *n)
{
    u8_t *f = (u8_t *)p->payload;

    /* Only inspect frames held in one pbuf; anything else goes straight up. */
    if (p->len < ETH_HDR_LEN || p->len != p->tot_len) return lwip_input(p, n);

    uint16_t eth = rd16(f + 12);

    if (eth == ETHTYPE_ARP_ && p->len >= 42) {
        if (rd16(f + 20) == 1) {                          /* request */
            uint32_t target = rd32(f + 38);
            if (target != own_ip() && is_alias(target)) {
                arp_reply(f);
                pbuf_free(p);
                return ERR_OK;
            }
        }
        return lwip_input(p, n);
    }

    if (eth == ETHTYPE_IP_ && p->len >= ETH_HDR_LEN + 20) {
        u8_t    *ip   = f + ETH_HDR_LEN;
        u8_t     ihl  = (u8_t)((ip[0] & 0x0F) * 4);
        uint32_t dst  = rd32(ip + 16);
        u8_t     prot = ip[9];

        if (dst != own_ip() && is_alias(dst)) {
            if (prot == IP_PROTO_ICMP_ && p->len >= ETH_HDR_LEN + ihl + 8 &&
                ip[ihl] == 8) {                            /* echo request */
                icmp_echo_reply(f, p->len);
                pbuf_free(p);
                return ERR_OK;
            }
            if (prot == IP_PROTO_UDP_ && p->len >= ETH_HDR_LEN + ihl + 8) {
                current_dest = dst;                        /* for the app   */
                udp_rewrite(f);
                err_t e = lwip_input(p, n);
                current_dest = own_ip();
                return e;
            }
            pbuf_free(p);                                  /* nothing else  */
            return ERR_OK;
        }
        current_dest = dst;
    }

    return lwip_input(p, n);
}

void noc_alias_init(struct netif *netif)
{
    nif          = netif;
    lwip_input   = netif->input;
    netif->input = noc_alias_input;
    current_dest = own_ip();
    xil_printf("answering ARP for %u alias addresses on one MAC\r\n", n_alias);
}