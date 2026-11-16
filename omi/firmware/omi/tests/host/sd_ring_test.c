/*
 * Host test for src/lib/core/sd_ring.c.
 *
 * Drives the real ring code over an in-memory "card" until it has wrapped several
 * times, rotating segments and syncing at irregular points, and checks after every
 * sync that each byte the ring claims as live ([tail, head)) reads back from the
 * card exactly as written. It then reads every listed segment back through the API.
 *
 * Usage: sd_ring_test [seed]
 */
#include <stdlib.h>
#include <string.h>

#include "lib/core/sd_ring.h"

int log_warn_count;

int64_t k_uptime_get(void)
{
    return 0;
}

/* A 300 KB ring: larger than the 40 KB append stage, small enough to wrap quickly. */
#define DATA_SECTORS 600u
#define TOTAL_SECTORS (RING_DATA_START_SECTOR + DATA_SECTORS)
static uint8_t disk[TOTAL_SECTORS * RING_SECTOR_SIZE];

int disk_access_read(const char *pdrv, uint8_t *buf, uint32_t start, uint32_t n)
{
    (void) pdrv;
    if (start + n > TOTAL_SECTORS) {
        return -1;
    }
    memcpy(buf, disk + (size_t) start * RING_SECTOR_SIZE, (size_t) n * RING_SECTOR_SIZE);
    return 0;
}

int disk_access_write(const char *pdrv, const uint8_t *buf, uint32_t start, uint32_t n)
{
    (void) pdrv;
    if (start + n > TOTAL_SECTORS) {
        return -1;
    }
    memcpy(disk + (size_t) start * RING_SECTOR_SIZE, buf, (size_t) n * RING_SECTOR_SIZE);
    return 0;
}

int disk_access_ioctl(const char *pdrv, uint8_t cmd, void *buff)
{
    (void) pdrv;
    (void) cmd;
    (void) buff;
    return 0;
}

uint32_t crc32_ieee(const uint8_t *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int k = 0; k < 8; k++) {
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
        }
    }
    return ~crc;
}

/* The byte appended at absolute offset `abs`; not periodic in 512 or the ring size. */
static uint8_t pattern(uint64_t abs)
{
    uint64_t x = abs * 0x9E3779B97F4A7C15ull;
    x ^= x >> 29;
    return (uint8_t) (x >> 17);
}

/* Bytes appended so far: the ring's head_abs, tracked independently. */
static uint64_t head;

/* Count bytes in [tail, head) that do not read back as written. */
static uint64_t check_live_region(uint64_t *first_bad)
{
    uint64_t ring_bytes = sd_ring_capacity_bytes();
    uint64_t tail = head - sd_ring_used_bytes();
    uint64_t bad = 0;
    for (uint64_t a = tail; a < head; a++) {
        uint8_t got = disk[(size_t) RING_DATA_START_SECTOR * RING_SECTOR_SIZE + (size_t) (a % ring_bytes)];
        if (got != pattern(a)) {
            if (bad == 0) {
                *first_bad = a - tail;
            }
            bad++;
        }
    }
    return bad;
}

int main(int argc, char **argv)
{
    static uint8_t stage[RING_STAGE_BYTES] __aligned(4);
    static uint8_t rbuf[400 * 1024];
    sd_ring_host_t host = {.stage = stage, .stage_bytes = sizeof(stage)};

    if (sd_ring_init(&host) != 0 || sd_ring_format(TOTAL_SECTORS) != 0) {
        puts("FAIL: ring setup");
        return 2;
    }

    srand(argc > 1 ? (unsigned) atoi(argv[1]) : 12345u);
    uint8_t block[440];
    uint64_t checks = 0, failing = 0, worst = 0, first_off = 0;
    int seg_ts = 1000;
    sd_ring_begin_segment(seg_ts++, 1);

    /* Six full traversals in 440 B blocks (the firmware's write size). */
    while (head < 6 * sd_ring_capacity_bytes()) {
        for (size_t i = 0; i < sizeof(block); i++) {
            block[i] = pattern(head + i);
        }
        if (sd_ring_append(block, sizeof(block)) != 0) {
            puts("FAIL: append");
            return 2;
        }
        head += sizeof(block);

        if (rand() % 40 == 0) {
            if (sd_ring_begin_segment(seg_ts++, 1) != 0) { /* syncs internally */
                puts("FAIL: begin_segment");
                return 2;
            }
        } else if (rand() % 7 == 0) {
            if (sd_ring_sync() != 0) {
                puts("FAIL: sync");
                return 2;
            }
        } else {
            continue;
        }

        uint64_t off = 0;
        uint64_t bad = check_live_region(&off);
        checks++;
        if (bad != 0) {
            if (failing == 0) {
                first_off = off;
            }
            failing++;
            if (bad > worst) {
                worst = bad;
            }
        }
    }

    int nseg = sd_ring_segment_count();
    int seg_bad = 0;
    for (int i = 0; i < nseg; i++) {
        ring_segment_t seg;
        sd_ring_get_segment(i, &seg);
        int n = sd_ring_read_segment(i, 0, rbuf, seg.length);
        if (n < 0) {
            seg_bad++;
            continue;
        }
        for (int k = 0; k < n; k++) {
            if (rbuf[k] != pattern(seg.start_abs + (uint64_t) k)) {
                seg_bad++;
                break;
            }
        }
    }

    printf("%s: %.1f traversals, keep-newest fired %d times; live-region checks %llu, failing %llu "
           "(worst %llu bytes, first at tail+%llu); segments %d, bad %d\n",
           (failing || seg_bad) ? "FAIL" : "PASS",
           (double) head / (double) sd_ring_capacity_bytes(),
           log_warn_count,
           (unsigned long long) checks,
           (unsigned long long) failing,
           (unsigned long long) worst,
           (unsigned long long) first_off,
           nseg,
           seg_bad);
    return (failing || seg_bad) ? 1 : 0;
}
