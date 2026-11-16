/*
 * Host test for src/lib/core/retained.c.
 *
 * The first boot after an update that appends a field must keep what the previous
 * layout stored (mute, the diagnostic ring) rather than wipe it, and start the new
 * field clean; garbage must still be wiped; the Bluetooth retry mark must survive a
 * reboot (another retained_init() on the same memory).
 */
#include <string.h>

#include "lib/core/retained.h"

uint8_t fake_retained_region[4096] __attribute__((aligned(8)));
int log_warn_count;

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

/* The layout before the Bluetooth retry mark was appended, as that firmware wrote it. */
struct old_mute {
    uint8_t muted;
    uint8_t reserved[3];
    uint32_t since_utc_s;
    uint32_t crc;
};
struct old_layout {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    struct old_mute mute;
    struct retained_diag diag;
};

static int failures;

static void expect(int ok, const char *what)
{
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    failures += !ok;
}

int main(void)
{
    uint32_t since = 0;

    /* Leftover bytes where the appended field now sits must not read as a set mark. */
    memset(fake_retained_region, 0xA5, sizeof(fake_retained_region));
    struct old_layout *old = (struct old_layout *) fake_retained_region;
    old->magic = 0x4F4D4952u;
    old->version = 1;
    old->size = sizeof(struct old_layout);
    memset(&old->mute, 0, sizeof(old->mute));
    old->mute.muted = 1;
    old->mute.since_utc_s = 1234;
    old->mute.crc = crc32_ieee((const uint8_t *) &old->mute, offsetof(struct old_mute, crc));
    old->diag.count = 7;

    expect(retained_init(), "previous layout: kept, not wiped");
    expect(retained_mute_get(&since) && since == 1234, "previous layout: mute survives");
    expect(retained_diag()->count == 7, "previous layout: diagnostic ring survives");
    expect(!retained_bt_retry_used(), "previous layout: Bluetooth retry mark starts clear");

    retained_bt_retry_set(true);
    expect(retained_init() && retained_bt_retry_used(), "retry mark survives a reboot");
    retained_bt_retry_set(false);
    expect(retained_init() && !retained_bt_retry_used(), "cleared retry mark stays clear");
    expect(retained_mute_get(&since) && since == 1234, "mute still kept in the current layout");

    memset(fake_retained_region, 0x5A, sizeof(fake_retained_region));
    expect(!retained_init(), "garbage: wiped");
    expect(!retained_mute_get(NULL) && !retained_bt_retry_used(), "garbage: nothing reads as set");

    printf("%s: retained RAM\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
