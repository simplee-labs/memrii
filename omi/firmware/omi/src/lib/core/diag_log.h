#ifndef DIAG_LOG_H
#define DIAG_LOG_H

/*
 * Retained-RAM diagnostic event ring. Aggregate drop counters say how many losses occurred; sequence, uptime
 * and context records preserve their order. Send records on 0x19B10063 and acknowledge on 0x19B10064 without SD
 * filesystem I/O.
 *
 * The 2 KB ring occupies the retained partition reserved by pm_static.yml. It survives reboot, crash and System
 * OFF, but not a flat battery. DIAG_BOOT distinguishes boot epochs; older records retain their original uptime
 * clock.
 *
 * CONFIG_OMI_DIAG_LOG compiles it out when disabled. The runtime toggle defaults off and is not persisted.
 * Enqueue is O(1), spinlock-protected and callable from any thread; it must never synchronously touch NAND and
 * inject latency into capture.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Event codes — APPEND-ONLY, never renumber (same discipline as the drop counters).
 * The app keeps a matching decode table; an unknown code renders generically so a
 * newer device against an older app still shows something. */
typedef enum {
    DIAG_RESERVED = 0,
    DIAG_EMPTY_BIN_ROTATION = 1,      /* arg1 = current_file_size (bytes in the empty bin) */
    DIAG_MARKER_WRITE_DROP = 2,       /* arg0 = marker header low16; arg1 = block_drops snapshot */
    DIAG_MARKER_PAUSE_GATE_SAVE = 3,  /* arg0 = marker header low16; arg1 = block len */
    DIAG_PRIORITY_RECORD_START = 4,   /* arg1 = session_id */
    DIAG_PRIORITY_RECORD_STOP = 5,    /* arg1 = session_id */
    DIAG_SESSION_END_MARKER_EMIT = 6, /* arg1 = session_id */
    DIAG_SD_BLOCK_DROP = 7,           /* arg1 = block_drops snapshot (audio block lost) */
    DIAG_CODEC_DROP = 8,              /* arg1 = codec ring-full drop count snapshot */
    DIAG_WRITE_BLOCKED = 9,           /* captured audio was discarded on its way to the card at a
                                       * stage that counts nothing, i.e. capture loss the 0x0062
                                       * counters cannot express.
                                       *   arg0 = diag_write_blocked_t (which stage)
                                       *   arg1 = stage-specific, see each reason
                                       * Rate-limited to one per second: these fire per dropped
                                       * frame, so unlimited they would evict all 128 slots in
                                       * ~13 s (reason 2, one per 100 ms mic buffer) or ~2.6 s
                                       * (reason 0, one per 20 ms Opus frame), taking the
                                       * priority-record and vad_level records that give the onset
                                       * its context with them. The onset is the diagnosis; the
                                       * repeat count is already in arg1. */
    DIAG_RING_IO_ERROR = 10,          /* reserved (not yet instrumented) */
    DIAG_BACKEND_MOUNT = 11,          /* reserved (not yet instrumented) */
    DIAG_BOND_STATE = 12,             /* arg0 = diag_bond_cause_t; arg1 = bond count AFTER the event */
    DIAG_ADV_START_FAIL = 13,         /* bt_le_adv_start() failed -- the radio is off the air.
                                       * arg0 = adv mode (0=fast 1=slow); arg1 = errno MAGNITUDE, i.e.
                                       * -(return of bt_le_adv_start), so 12 = ENOMEM. Positive. */
    DIAG_ADV_WATCHDOG_RESCUE = 14,    /* the watchdog restarted a radio it believed was off the
                                       * air. arg0 = adv mode (0=fast 1=slow). Replaces a 0x0062
                                       * counter: an approximate event log is still informative,
                                       * whereas an occasionally-wrong counter is worse than none. */
    DIAG_ADV_STOP_FAIL = 15,          /* bt_le_adv_stop() failed during a mode change, so the
                                       * interval could not be reconfigured. The old advertiser is
                                       * still up, so this is NOT an off-air event -- split from
                                       * code 13 so field diagnosis is not misled. arg0 = mode,
                                       * arg1 = errno magnitude. */
    DIAG_VAD_LEVEL = 16,              /* AAD input level over a 5 min peak-hold window -- the one
                                       * reading that separates "the mic is dead" from "the room is
                                       * quiet", which no counter or bin listing can.
                                       *   arg0 = window MAX avg-abs-amplitude (int16 units, sat 65535)
                                       *   arg1 = [window MIN u16 high 16][vad_threshold u16 low 16]
                                       * Emitted on a silent<->non-silent transition or hourly. A max
                                       * of 0 is digital silence from the part; a quiet room always
                                       * peaks above 0 even when nothing reaches the threshold. */
    DIAG_MIC_POWER_CYCLE = 17,        /*
                                       * Reserved, not emitted. Former post-update PDM_EN cycle; arg0 indicated
                                       * whether the rail cycled. Firmware leaves PDM_EN undriven. Keep this
                                       * append-only code and the app decoder for compatibility.
                                       */
    DIAG_MIC_STATE = 18,              /* The mic gate opened or closed capture, or a resume did not
                                       * produce audio. Exists because a parked mic emits NOTHING --
                                       * no DIAG_VAD_LEVEL windows close without frames -- so a gap
                                       * in the log is ambiguous between "mic off on purpose" and
                                       * "mic died" unless the transition itself is recorded.
                                       *   arg0 = diag_mic_state_t
                                       *   arg1 = the vad_threshold SNAPSHOT at the transition, not
                                       *          the cause. Do not read it as the gate reason: a
                                       *          resume driven by button pre-arm or a marker's
                                       *          force-wake happens while the threshold is still
                                       *          32769, so "resumed @32769" is normal and does NOT
                                       *          mean capture resumed into standby. */
    DIAG_IMU_POWER_STATE = 19,        /* LSM6DS3TR-C accel/gyro power state, read back from the part
                                       * rather than assumed. Nothing in the built firmware consumes
                                       * motion data (accel.c is not in CMakeLists.txt) — only the
                                       * 24-bit timestamp counter.
                                       * The build settles what this record was first added to hunt:
                                       * CONFIG_LSM6DSL_{GYRO,ACCEL}_ODR are both 0 and
                                       * lsm6dsl_init_chip() writes them into ODR_G/ODR_XL, so both
                                       * halves come up powered down and the feared free-running gyro
                                       * does not exist. The accel is then deliberately switched back
                                       * ON at 12.5 Hz — the part gates its timebase when both halves
                                       * are down, which would stop the timestamp counter and break
                                       * the System OFF time bridge — but in LOW-POWER mode, since
                                       * XL_HM_MODE resets to high-performance (~170 uA, and
                                       * ODR-independent) for samples nobody reads.
                                       * Healthy reading: CTRL2_G 0, CTRL1_XL 0x10, CTRL6_C 0x10.
                                       * arg0 = bit 15 IMU_PWR_READ_FAILED, bit 1 gyro attr_set
                                       *        returned non-zero, bit 0 accel likewise. Bit 15 is a
                                       *        separate bit and not a magic arg1 value on purpose:
                                       *        the all-good reading packs to arg1 == 0, which is
                                       *        exactly what a failed read would report.
                                       * arg1 = when bit 15 is CLEAR: [CTRL1_XL][CTRL2_G][CTRL6_C]
                                       *        [CTRL7_G], high byte first. ODR_XL/ODR_G are the top
                                       *        nibbles of the first two: 0 means powered down.
                                       *        XL_HM_MODE (CTRL6_C bit 4) and G_HM_MODE (CTRL7_G
                                       *        bit 7) are set when that part is in low-power rather
                                       *        than high-performance mode.
                                       *        When bit 15 is SET: [accel_rc u8][gyro_rc u8] in the
                                       *        low two bytes — the errnos, all the evidence there is
                                       *        when the bus will not answer.
                                       * Emitted only when the state changes (plus the first call after
                                       * boot), failures included: the producer runs on every VAD-sleep
                                       * transition as well as every time sync, so in auto mode an
                                       * undeduplicated failure would emit tens of FORCED records an
                                       * hour and evict the whole 128-slot ring. */
    DIAG_LINK_WEDGE_REBOOT = 20,      /*
                                       * The previous boot requested a BLE disconnect but never received its
                                       * callback. Report from flash on the following boot so retained-ring
                                       * survival is unnecessary.
                                       *
                                       * arg0 is the magnitude of bt_conn_disconnect errno: 0 accepted, 107
                                       * ENOTCONN (controller already dropped the link). arg1 is milliseconds
                                       * from request to reboot, including the silence wait.
                                       */
    DIAG_BOOT = 21,                   /* First record of every boot (oo-3.1.4). The ring survives
                                       * restarts, so records older than the newest DIAG_BOOT carry
                                       * an EARLIER boot's uptime and must not be mapped onto the
                                       * current boot's clock.
                                       *   arg0 = 1 if the previous boot's ring was adopted, 0 if
                                       *          not: retained RAM held no valid ring (first boot
                                       *          after a flash of older firmware, a flat battery),
                                       *          or the ring failed diag_log_init()'s checks. It
                                       *          describes the RING, not the whole retained slice —
                                       *          mute can survive while arg0 is 0.
                                       *   arg1 = hwinfo reset-cause bits for this boot */
} diag_event_code_t;

/* arg0 values for DIAG_MIC_STATE. Appended-only, same discipline as the codes. */
typedef enum {
    DIAG_MIC_STATE_PARKED = 0,         /* capture stopped by the gate (manual standby) */
    DIAG_MIC_STATE_RESUMED = 1,        /* capture started by the gate */
    DIAG_MIC_STATE_RESUME_FAILED = 2,  /* dmic START failed twice; the mic is NOT running */
    DIAG_MIC_STATE_RESUMED_SILENT = 3, /* START succeeded but the first frames were digital zero --
                                        * a wedged part, which a quiet room cannot produce */
} diag_mic_state_t;

/* arg0 values for DIAG_WRITE_BLOCKED. Appended-only, same discipline as the codes. */
typedef enum {
    /*
     * An encoded Opus frame was dropped because the tx ring was full. The pusher must run at priority 6 above
     * the encoder at 7: a 0.8 s pre-roll burst can otherwise fill all 32 slots before the pusher gets scheduled
     * when time slicing is off.
     *
     * With that priority ordering, a nonzero count warrants investigating a blocked pusher or full SD queue.
     * arg1 is frames dropped here since boot.
     */
    DIAG_WRITE_BLOCKED_TX_RING_FULL = 0,

    /* Reserved, never emitted. Held for a stale sd_write_paused discarding plain-audio
     * blocks at the pause gate (process_write_data_req) while capture ran — a state the
     * aad.c re-check on vad_is_recording is meant to make unreachable. Instrumenting it
     * would mean counting inside that gate, which is deliberately silent because a paused
     * VAD forwards nothing, so healthily there is nothing there to count. Kept so the
     * numbering survives if that ever changes; do not reuse the value. */
    DIAG_WRITE_BLOCKED_STALE_PAUSE = 1,

    /*
     * Retired and never reusable. Firmware oo-3.1.1 and earlier emitted this when a live mic frame hit the full
     * pre-roll replay holding ring. Keep numbering stable for older device records; the ring was removed in
     * oo-3.1.3.
     *
     * vad_voiced_ms at offset 88 is measured upstream of these loss stages, so increasing capture duty does not
     * prove bytes reached the card. arg1 is live frames dropped since boot on those older versions.
     */
    DIAG_WRITE_BLOCKED_VAD_BACKLOG_FULL = 2,

    /* preroll_queue_flush() (oo-3.1.3 on) trimmed its burst because the encoder ring had
     * no room for the whole pre-roll, dropping the OLDEST frames — so a recording begins
     * with a shorter lead-in than the ring held.
     *
     * This needs its own reason because the trim happens BEFORE any push, which makes it
     * invisible to every counter downstream: codec_receive_pcm() is never called for the
     * trimmed frames, so codec_drops does not move, and nothing further along ever sees
     * audio that was never submitted. Reading "codec_drops == 0" as "the burst fits" is
     * the same shape of mistake as reading vad_voiced_ms as capture — a check that
     * structurally cannot express the failure it is being asked about.
     *
     * Should read zero. The burst runs only at the silence->speech transition, and a
     * sleeping VAD submits nothing, so the ring has been draining with no producer for at
     * least CONFIG_OMI_VAD_HOLD_MS; it is empty there by construction. A non-zero value
     * means the encoder thread was starved long enough to still hold >1 block at that
     * moment, which is a scheduling fault upstream of audio, not a VAD problem.
     * Disjoint from DIAG_CODEC_DROP by construction, and the burst loop's `- 1` is what
     * makes it so: a block the encoder REJECTS was submitted, so codec_receive_pcm()
     * counts that one and this does not. Every pre-roll frame is therefore accounted for
     * exactly once — delivered, counted there, or counted here. Keep it that way; folding
     * the rejected block in as well tallies it twice and contradicts "never submitted"
     * above.
     *   arg1 = pre-roll frames dropped this way since boot. Rate-limited to 1/s. */
    DIAG_WRITE_BLOCKED_PREROLL_TRIMMED = 3,
} diag_write_blocked_t;

/* arg0 values for DIAG_BOND_STATE. Appended-only, same discipline as the codes. */
typedef enum {
    DIAG_BOND_CAUSE_BOOT_LOAD = 0, /* bonds loaded from settings at transport_start */
    DIAG_BOND_CAUSE_POST_DFU = 1,  /* wiped by the armed post-update unpair */
    DIAG_BOND_CAUSE_BUTTON = 2,    /* wiped by the 5-tap + hold gesture */
} diag_bond_cause_t;

/* 16-byte packed record. nRF5340 is little-endian, so the in-RAM layout IS the wire
 * layout — the drain memcpy's raw slot bytes with no per-field repacking. */
typedef struct __packed {
    uint32_t seq;       /* monotonic, assigned at enqueue; the ack/drain key */
    uint32_t uptime_ms; /* k_uptime_get_32() at the event */
    uint8_t code;       /* diag_event_code_t */
    uint8_t backend;    /* sd_get_active_backend(): 1 = ring (0 = the retired littlefs) */
    uint16_t arg0;      /* event-specific (see table above) */
    uint32_t arg1;      /* event-specific (see table above) */
} diag_event_t;

#define DIAG_LOG_RECORD_SIZE 16
#define DIAG_LOG_RING_DEPTH 128

/* 0x19B10063 drain header prepended to the record stream (little-endian):
 *   [u8  record_size = 16][u8 reserved][u16 record_count]
 *   [u32 dropped_count][u32 max_seq]
 * Total blob = DIAG_LOG_HEADER_SIZE + record_count * DIAG_LOG_RECORD_SIZE. */
#define DIAG_LOG_HEADER_SIZE 12

#ifdef CONFIG_OMI_DIAG_LOG

/* Adopt the ring left in retained RAM by the previous boot if it is intact, otherwise
 * start empty; enabled = false either way. Returns true if records were kept. */
bool diag_log_init(void);
void diag_log_set_enabled(bool on); /* dev-tools toggle target (0x0064 enable bit) */
void diag_log_event(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1);

/* Same enqueue, but bypassing the runtime gate.
 *
 * The gate is volatile and starts closed at every boot; the app only opens it once
 * it has connected, which is seconds later. Any event emitted at boot therefore hits
 * a closed gate and is discarded — including DIAG_BOND_STATE, the single record that
 * says whether the device came up with its pairing keys. That made the one piece of
 * evidence for a post-update bond wipe structurally unreachable: the reboot that
 * produces the record is the same reboot that closes the gate that would keep it.
 *
 * Use this ONLY for events that (a) fire in the boot window and (b) cannot be
 * reconstructed later. The ring is already allocated, so unconditional records cost
 * RAM we have paid for. Everything periodic or high-rate must keep using
 * diag_log_event() so a disabled log stays one predictable branch.
 *
 * Note the gate governs CAPTURE, not readback: diag_log_drain() deliberately does
 * not consult it, so forced records are served to any app that reads 0x0063 even
 * while the log is disabled. That is the intent — a record nobody can read is the
 * problem this function was added to solve.
 *
 * Because of that, 0x0063/0x0064 are BT_GATT_PERM_*_ENCRYPT. They were plain READ/
 * WRITE until this function existed, which was fine when a disabled log was empty;
 * it stopped being fine the moment DIAG_BOND_STATE started landing on every boot
 * regardless, since transport_bond_count() then leaks pairing state to any peer
 * that can connect. Keep the encrypted permissions if you add more forced records. */
void diag_log_event_forced(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1);

/* Snapshot-based, byte-offset-addressable drain for GATT Long Read. The FIRST read
 * (offset 0) snapshots the ring boundary so records don't shift mid-transfer;
 * subsequent offsets serve the same snapshot. Writes up to `max` bytes of the blob
 * (header + packed records) starting at byte `offset`; returns bytes written. */
size_t diag_log_drain(uint8_t *out, size_t max, uint16_t offset);
void diag_log_ack(uint32_t through_seq); /* drop all records with seq <= through_seq */
uint32_t diag_log_dropped_count(void);   /* keep-newest overwrites since last ack */

#else /* !CONFIG_OMI_DIAG_LOG — no-op stubs so call sites compile with zero cost */

static inline bool diag_log_init(void)
{
    return false;
}
static inline void diag_log_set_enabled(bool on)
{
    (void) on;
}
static inline void diag_log_event(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1)
{
    (void) code;
    (void) backend;
    (void) arg0;
    (void) arg1;
}
static inline void diag_log_event_forced(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1)
{
    (void) code;
    (void) backend;
    (void) arg0;
    (void) arg1;
}
static inline size_t diag_log_drain(uint8_t *out, size_t max, uint16_t offset)
{
    (void) out;
    (void) max;
    (void) offset;
    return 0;
}
static inline void diag_log_ack(uint32_t through_seq)
{
    (void) through_seq;
}
static inline uint32_t diag_log_dropped_count(void)
{
    return 0;
}

#endif /* CONFIG_OMI_DIAG_LOG */

#endif // DIAG_LOG_H
