/* noc_udp.h -- UDP <-> NoC bridging (network stage N3)
 *
 * A UDP datagram's payload is a NoC packet verbatim (network spec section 20):
 * the 64-bit header then payload words, big-endian. The datagram's *destination
 * address* selects the endpoint: the hardware forwarding table looks it up and
 * rewrites DST_ID, so the routing decision is made in the PL, not here.
 *
 * Replies are addressed by reverse lookup: a packet arriving from SRC_ID n is
 * sent back to whichever host last addressed the endpoint mapped to n.
 */
#ifndef NOC_UDP_H
#define NOC_UDP_H

#include "lwip/udp.h"

#define NOC_UDP_PORT     5555        /* route by destination address (target behaviour) */
#define NOC_UDP_PORT_RAW 5556        /* honour the DST_ID already in the header:
                                      * reaches an endpoint without relying on
                                      * its address resolving */
#define NOC_UDP_PORT_CTL 5557        /* control plane: read and write forwarding
                                      * table entries from the network */

/* Program the forwarding table: 10.10.10.10+n -> endpoint n, .18 -> memory. */
void noc_udp_init_table(void);

/* Bind the UDP port and install the receive callback. 0 on success. */
int  noc_udp_start(void);

/* Drain packets the fabric has returned and send them to the right host.
 * Call from the main loop, next to xemacif_input(). */
void noc_udp_service(void);

/* Counters, printed periodically so the console shows progress. */
extern unsigned noc_udp_rx_datagrams;   /* datagrams accepted from the network */
extern unsigned noc_udp_tx_datagrams;   /* datagrams sent back                 */
extern unsigned noc_udp_bad_length;     /* payload not a whole number of flits */
extern unsigned noc_udp_no_route;       /* destination address not in the table */
extern unsigned noc_udp_no_host;        /* reply with no host to send it to     */

void noc_udp_print_counters(void);

/* Control-plane message, 12 bytes, big-endian. A request is answered with the
 * entry as it stands in hardware afterwards, so the host sees what took effect.
 *
 *   op    0 read entry, 1 write entry
 *   idx   forwarding table entry, 0..15
 *   dst   DST_ID the address maps to (write only)
 *   valid 1 to install, 0 to remove (write only)
 *   ip    IPv4 address, big-endian (write only)
 */
#define NOC_CTL_READ  0u
#define NOC_CTL_WRITE 1u
#define NOC_CTL_STATS 2u     /* reply is 28 bytes: op, 3 pad, then seven u32:
                              * tx_count, rx_count, tx_drop, fwd_miss,
                              * udp_in, udp_no_route, udp_bad_length */

extern unsigned noc_udp_ctl_ops;

#endif