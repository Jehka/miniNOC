/* n3_main.c -- network stage N3: UDP datagrams in, NoC packets out
 *
 * Replaces main.c from the lwIP echo server template. Keep the template's
 * platform.c / platform_zynq.c / platform_config.h; delete echo.c. Add
 * noc_bridge.c and noc_udp.c.
 *
 * Direct cable, static addressing, no DHCP: set lwip220_dhcp false and
 * lwip220_lwip_dhcp_does_acd_check false in the BSP, or the build fails or the
 * board waits forever for a DHCP server that does not exist.
 *
 * Board 10.10.10.10, host 10.10.10.1. Endpoints answer on port 5555 by address
 * (once N4 makes the other addresses resolve) and on port 5556 by the DST_ID in
 * the packet header, which works today.
 */
#include "xparameters.h"
#include "netif/xadapter.h"
#include "platform.h"
#include "platform_config.h"
#include "xil_printf.h"

#include "lwip/init.h"
#include "lwip/inet.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"

#include "noc_bridge.h"
#include "noc_udp.h"
#include "noc_alias.h"

#if defined (__arm__) || defined (__aarch64__)
#include "xil_cache.h"
#endif

extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;

static struct netif server_netif;
struct netif *echo_netif;

static void print_ip(const char *msg, ip_addr_t *ip)
{
    xil_printf("%s%d.%d.%d.%d\r\n", msg,
               ip4_addr1(ip), ip4_addr2(ip), ip4_addr3(ip), ip4_addr4(ip));
}

int main(void)
{
    ip_addr_t ipaddr, netmask, gw;
    /* Locally administered MAC; must be unique on the segment. */
    unsigned char mac[6] = { 0x00, 0x0a, 0x35, 0x00, 0x01, 0x02 };

    echo_netif = &server_netif;

    init_platform();

    xil_printf("\r\n----- Mini-NoC UDP bridge (N3) -----\r\n");

    /* The bridge is reachable as soon as the PS is up; check it before the
     * network, so a hardware problem cannot look like a network problem. */
    uint32_t id = noc_rd(NOC_ID);
    if (id != NOC_ID_VALUE) {
        xil_printf("bridge ID %08x, expected %08x: wrong or stale bitstream\r\n",
                   (unsigned)id, (unsigned)NOC_ID_VALUE);
        return -1;
    }
    xil_printf("bridge ID ok (NOC2)\r\n");

    IP4_ADDR(&ipaddr,  10, 10, 10, 10);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gw,      10, 10, 10,  1);

    lwip_init();

    if (!xemac_add(echo_netif, &ipaddr, &netmask, &gw, mac, PLATFORM_EMAC_BASEADDR)) {
        xil_printf("error adding N/W interface\r\n");
        return -1;
    }
    netif_set_default(echo_netif);

#ifndef SDT
    platform_enable_interrupts();
#endif
    netif_set_up(echo_netif);

    print_ip("Board IP: ", &ipaddr);
    print_ip("Netmask : ", &netmask);
    print_ip("Gateway : ", &gw);

    noc_udp_init_table();

    /* One MAC, nine addresses: endpoints 0-7 at .10-.17, memory at .18.
     * The board's own address (.10) needs no alias entry. */
    for (unsigned n = 1; n <= 8; n++) noc_alias_add(IPV4(10, 10, 10, 10 + n));
    noc_alias_init(echo_netif);

    if (noc_udp_start() != 0) return -1;

    unsigned ticks = 0;
    while (1) {
        if (TcpFastTmrFlag) { tcp_fasttmr(); TcpFastTmrFlag = 0; }
        if (TcpSlowTmrFlag) { tcp_slowtmr(); TcpSlowTmrFlag = 0; }

        xemacif_input(echo_netif);      /* packets in from the wire  */
        noc_udp_service();              /* packets back from the NoC */

        if (++ticks >= 2000000) {       /* occasional progress line  */
            ticks = 0;
            noc_udp_print_counters();
            xil_printf("  alias: arp %u  ping %u  udp %u\r\n",
                       noc_alias_arp_replies, noc_alias_pings,
                       noc_alias_udp_rewritten);
        }
    }

    cleanup_platform();
    return 0;
}