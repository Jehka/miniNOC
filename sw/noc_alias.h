/* noc_alias.h -- one MAC, nine IP addresses (network stage N4)
 *
 * lwIP answers ARP only for its own netif address, and etharp.c offers no hook
 * to widen that. Rather than patch the BSP (which regeneration overwrites),
 * this wraps netif->input after xemac_add: frames are inspected before lwIP
 * sees them, and those addressed to an alias are handled here.
 *
 *   ARP request for an alias  -> reply with our MAC, so the host resolves it
 *   ICMP echo to an alias     -> reply in place, so ping works per endpoint
 *   UDP to an alias           -> destination rewritten to the netif address and
 *                                passed up; the original is kept for the app
 *   anything else             -> straight to lwIP, untouched
 *
 * This is a proxy-ARP arrangement: nine addresses, one MAC, one netif. It is
 * what a router or VM host presents, and `arp -a` on the peer shows exactly
 * that.
 */
#ifndef NOC_ALIAS_H
#define NOC_ALIAS_H

#include <stdint.h>
#include "lwip/netif.h"

/* Install the wrapper. Call once, after netif_set_up(). */
void noc_alias_init(struct netif *netif);

/* Register an address this board should answer for. The netif's own address
 * does not need registering. Returns 0 on success. */
int  noc_alias_add(uint32_t ipv4_host_order);

/* Stop answering for an address. Returns 0 if it was present. */
int  noc_alias_remove(uint32_t ipv4_host_order);

/* Destination address of the datagram currently being delivered, host order.
 * Valid inside a UDP receive callback; equals the netif address when the
 * datagram was not addressed to an alias. */
uint32_t noc_alias_current_dest(void);

extern unsigned noc_alias_arp_replies;    /* ARP requests answered for aliases */
extern unsigned noc_alias_pings;          /* ICMP echoes answered for aliases  */
extern unsigned noc_alias_udp_rewritten;  /* datagrams passed up to lwIP       */

#endif