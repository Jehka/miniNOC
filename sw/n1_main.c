/* n1_main.c -- stage N1 acceptance test on hardware
 *
 * Mirrors tb/tb_n1_bridge.sv: ID, self-loopback, memory write/read-back, one
 * error path, an MMIO throughput measurement, then the forwarding table
 * (route by IP, miss discard, live remap, invalidation). Endpoints 1-7 keep running
 * their generators (SW0 up) the whole time, so every transfer crosses a
 * contended fabric.
 *
 * Vitis: standalone application on build/n1/n1.xsa with noc_bridge.h,
 * noc_bridge.c and this file. fpga/n1_bd.tcl pins the bridge at 0x43C00000,
 * which matches NOC_BASE in noc_bridge.h. Output on the UART at 115200.
 */
#include <stdio.h>
#include "xil_printf.h"
#include "noc_bridge.h"

/* Cortex-A9 global timer: 64-bit counter at CPU_CLK/2, fixed address on all
 * Zynq-7000 parts. Read directly so no BSP timer header is needed (the Vitis
 * 2025.2 SDT platform has no xtime_l.h). The ZedBoard preset runs the CPU at
 * 666.67 MHz, so the counter runs at 333.33 MHz; if xparameters.h shows a
 * different CPU clock, set GTIMER_HZ to half of it. */
#define GTIMER_LO    0xF8F00200u
#define GTIMER_HI    0xF8F00204u
#define GTIMER_CTRL  0xF8F00208u
#define GTIMER_HZ    333333333ull

static int fails;

static uint64_t gtimer_now(void)
{
    uint32_t hi, lo, hi2;
    do {                                  /* re-read if the low word wrapped */
        hi  = Xil_In32(GTIMER_HI);
        lo  = Xil_In32(GTIMER_LO);
        hi2 = Xil_In32(GTIMER_HI);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static void check(const char *what, uint64_t got, uint64_t exp)
{
    if (got == exp) {
        xil_printf("  ok  %-32s %08x%08x\r\n", what, (unsigned)(got >> 32), (unsigned)got);
    } else {
        xil_printf("  FAIL %-31s got %08x%08x exp %08x%08x\r\n", what,
                   (unsigned)(got >> 32), (unsigned)got, (unsigned)(exp >> 32), (unsigned)exp);
        fails++;
    }
}

int main(void)
{
    uint64_t buf[64];
    int n;

    xil_printf("\r\n== Mini-NoC N1: PS <-> fabric over AXI-Lite ==\r\n");

    check("ID register", noc_rd(NOC_ID), NOC_ID_VALUE);

    /* 1. DATA loopback to self. SRC 9 is junk; endpoint_port must stamp it to 0. */
    const uint64_t lp[3] = { 0x1111222233334444ull, 0xAAAABBBBCCCCDDDDull, 0x0123456789ABCDEFull };
    noc_send_pkt(noc_hdr(T_DATA, 9, 0, 3, 0x5A, 0), lp, 3);
    n = noc_recv_pkt(buf, 64);
    check("loopback header (SRC stamped)", buf[0], noc_hdr(T_DATA, 0, 0, 3, 0x5A, 0));
    check("loopback flit count", (uint64_t)n, 4);
    for (int k = 0; k < 3; k++) check("loopback payload", buf[k + 1], lp[k]);

    /* 2. Memory write then read back, above the generators' region (word 512+). */
    uint64_t wr[5] = { 0x1000 };
    for (int k = 0; k < 4; k++) wr[k + 1] = 0xCAFE000000000000ull | (uint64_t)k;
    noc_send_pkt(noc_hdr(T_MEM_WRITE_REQ, 0, MEM_ID, 5, 0x21, 0), wr, 5);
    n = noc_recv_pkt(buf, 64);
    check("WRITE_RESP", buf[0], noc_hdr(T_MEM_WRITE_RESP, MEM_ID, 0, 0, 0x21, 0));

    const uint64_t rd[2] = { 0x1000, 4 };
    noc_send_pkt(noc_hdr(T_MEM_READ_REQ, 0, MEM_ID, 2, 0x22, 0), rd, 2);
    n = noc_recv_pkt(buf, 64);
    check("READ_RESP header", buf[0], noc_hdr(T_MEM_READ_RESP, MEM_ID, 0, 4, 0x22, 0));
    check("READ_RESP flit count", (uint64_t)n, 5);
    for (int k = 0; k < 4; k++) check("read-back word", buf[k + 1], wr[k + 1]);

    /* 3. Error path: misaligned address must come back as T_ERROR/E_ALIGN. */
    const uint64_t bad[2] = { 0x1003, 1 };
    noc_send_pkt(noc_hdr(T_MEM_READ_REQ, 0, MEM_ID, 2, 0x23, 0), bad, 2);
    n = noc_recv_pkt(buf, 64);
    check("E_ALIGN error response", buf[0], noc_hdr(T_ERROR, MEM_ID, 0, 0, 0x23, E_ALIGN));

    /* 4. Throughput: how fast MMIO moves flits. Sets the N7 baseline.
     * Every loopback is also checked, so this doubles as a soak test. */
    const uint64_t burst[31] = {0};
    unsigned rounds = 1000, bad_loops = 0;
    Xil_Out32(GTIMER_CTRL, Xil_In32(GTIMER_CTRL) | 1u);   /* ensure timer is running */
    uint64_t t0 = gtimer_now();
    for (unsigned r = 0; r < rounds; r++) {
        noc_send_pkt(noc_hdr(T_DATA, 0, 0, 31, r & 0xFF, 0), burst, 31);
        if (noc_recv_pkt(buf, 64) != 32) bad_loops++;
    }
    uint64_t t1 = gtimer_now();
    unsigned us     = (unsigned)((t1 - t0) * 1000000ull / GTIMER_HZ);
    unsigned kbytes = rounds * 32 * 8 / 1024;            /* 32 flits x 8 bytes, each way */
    if (us == 0) us = 1;                                  /* guard the division */
    xil_printf("  info %u x 32-flit loopbacks: %u us, %u KB each way, %u KB/s\r\n",
               rounds, us, kbytes, (unsigned)((uint64_t)kbytes * 1000000u / us));
    check("throughput loopbacks all 32 flits", bad_loops, 0);

    /* 5. Nothing dropped at the bridge. */
    check("TX_DROP", noc_rd(NOC_TX_DROP), 0);

    /* 6. Forwarding table (network stage N4, PL half). The network address plan,
     * running in hardware before any Ethernet exists. */
    xil_printf("  -- forwarding table --\r\n");
    for (unsigned i = 0; i < FWD_ENTRIES; i++) noc_fwd_set(i, 0, 0, 0);   /* clear */
    noc_fwd_set(0, IPV4(192,168,1,10), 0, 1);                           /* endpoint 0 */
    noc_fwd_set(1, IPV4(192,168,1,18), MEM_ID, 1);                      /* memory     */

    check("probe 192.168.1.18 -> dst 8", (uint64_t)noc_fwd_probe(IPV4(192,168,1,18)), 8);
    check("probe 192.168.1.99 -> miss",  (uint64_t)(noc_fwd_probe(IPV4(192,168,1,99)) < 0), 1);

    /* Route by IP. Header DST_ID is junk (0xF): hardware must rewrite it. */
    uint32_t src_ip = 0;
    const uint64_t one[1] = { 0x00C0FFEE00000001ull };
    noc_send_pkt_ip(IPV4(192,168,1,10), noc_hdr(T_DATA, 0, 0xF, 1, 0x61, 0), one, 1);
    noc_rx_src_ip(&src_ip);
    check("reply source IP 192.168.1.10", src_ip, IPV4(192,168,1,10));
    n = noc_recv_pkt(buf, 64);
    check("DST rewritten 0xF -> 0", buf[0], noc_hdr(T_DATA, 0, 0, 1, 0x61, 0));
    check("routed payload", buf[1], one[0]);

    const uint64_t mw[2] = { 0x1100, 0x123456789ABCDEF0ull };
    noc_send_pkt_ip(IPV4(192,168,1,18), noc_hdr(T_MEM_WRITE_REQ, 0, 0xF, 2, 0x62, 0), mw, 2);
    noc_rx_src_ip(&src_ip);
    check("memory reply source IP .18", src_ip, IPV4(192,168,1,18));
    noc_recv_pkt(buf, 64);
    check("WRITE_RESP via IP routing", buf[0], noc_hdr(T_MEM_WRITE_RESP, MEM_ID, 0, 0, 0x62, 0));

    /* Miss: a whole packet to an unknown address is discarded and counted once. */
    uint32_t miss0 = noc_rd(NOC_FWD_MISS), tx0 = noc_rd(NOC_TX_COUNT);
    const uint64_t two[2] = { 1, 2 };
    noc_send_pkt_ip(IPV4(192,168,1,99), noc_hdr(T_DATA, 0, 0, 2, 0x63, 0), two, 2);
    noc_settle();
    check("FWD_MISS +1 for unknown address", noc_rd(NOC_FWD_MISS) - miss0, 1);
    check("missed packet pushed no flits",  noc_rd(NOC_TX_COUNT) - tx0, 0);
    check("nothing delivered for the miss", (noc_rd(NOC_STATUS) & ST_RX_AVAIL) != 0, 0);

    /* Live remap: memory moves from .18 to .20, no rebuild. */
    noc_fwd_set(1, IPV4(192,168,1,20), MEM_ID, 1);
    const uint64_t rq[2] = { 0x1100, 1 };
    noc_send_pkt_ip(IPV4(192,168,1,18), noc_hdr(T_MEM_READ_REQ, 0, 0xF, 2, 0x65, 0), rq, 2);
    noc_settle();
    check("old address .18 now misses", noc_rd(NOC_FWD_MISS) - miss0, 2);
    noc_send_pkt_ip(IPV4(192,168,1,20), noc_hdr(T_MEM_READ_REQ, 0, 0xF, 2, 0x66, 0), rq, 2);
    noc_rx_src_ip(&src_ip);
    check("remapped reply source IP .20", src_ip, IPV4(192,168,1,20));
    noc_recv_pkt(buf, 64);
    check("read via new address .20", buf[1], mw[1]);

    /* Invalidate: traffic to a removed entry must miss, not route on stale state. */
    noc_fwd_set(1, IPV4(192,168,1,20), MEM_ID, 0);
    noc_send_pkt_ip(IPV4(192,168,1,20), noc_hdr(T_MEM_READ_REQ, 0, 0xF, 2, 0x67, 0), rq, 2);
    noc_settle();
    check("invalidated entry misses", noc_rd(NOC_FWD_MISS) - miss0, 3);

    xil_printf(fails ? "\r\nN1 FAIL (%d)\r\n" : "\r\nN1 PASS\r\n", fails);
    return fails;
}