import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:omi/utils/audio/sync_notification.dart';

/// The resting line of the one persistent notification — the surface a user reads all
/// day without opening the app, and the only one that can print a battery percentage
/// while the Omi is out of range. (The recordings page swaps the indicator for a
/// bluetooth icon when disconnected, and both routes into Device Settings are gated on
/// being connected.)
void main() {
  const int at = 1756500000000; // fixed instant; formatted in the local zone
  final String time = DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(at));

  String body({
    int lastStatusMs = at,
    bool skipped = false,
    bool partial = false,
    int batteryLevel = 87,
    bool? isConnected,
    int stuckFiles = 0,
    int stuckOverwriteMinutes = -1,
    bool storagePaused = false,
  }) =>
      SyncNotification.idleBodyText(
        lastStatusMs: lastStatusMs,
        skipped: skipped,
        partial: partial,
        batteryLevel: batteryLevel,
        isConnected: isConnected,
        stuckFiles: stuckFiles,
        stuckOverwriteMinutes: stuckOverwriteMinutes,
        storagePaused: storagePaused,
      );

  group('idle body text — battery freshness', () {
    test('a completed sync reached the device, so the reading stands', () {
      expect(body(), 'Last Sync: Complete • $time • 87% Battery');
    });

    test('a partial sync reached the device too', () {
      expect(body(partial: true), 'Last Sync: Partial • $time • 87% Battery');
    });

    // A file processing stopped waiting for no longer makes a sync partial; it is named
    // instead, for as long as it stays on the Omi.
    test('files that keep failing are named in place of Complete, never over Partial or Skipped', () {
      expect(body(stuckFiles: 1), 'Last Sync: 1 file stuck • $time • 87% Battery');
      expect(body(stuckFiles: 2), 'Last Sync: 2 files stuck • $time • 87% Battery');
      expect(body(stuckFiles: 1, partial: true), 'Last Sync: Partial • $time • 87% Battery');
      expect(body(stuckFiles: 1, skipped: true), 'Last Sync: Skipped • $time');
    });

    // Only a complete download deletes a stuck recording, so the Omi overwriting it once
    // it runs out of room is the one way it ends. Within a day of recording of that, the
    // line says so instead of the last sync.
    test('a stuck recording the Omi will soon overwrite takes over the line', () {
      expect(body(stuckFiles: 1, stuckOverwriteMinutes: 5 * 60 + 20),
          'Stuck recording on Omi • overwritten after ~5 h of recording');
      expect(body(stuckFiles: 2, stuckOverwriteMinutes: 40),
          '2 stuck recordings on Omi • overwritten after ~40 min of recording');
      expect(body(stuckFiles: 1, stuckOverwriteMinutes: 0),
          'Stuck recording on Omi • overwritten after ~1 min of recording');
      expect(body(stuckFiles: 1, stuckOverwriteMinutes: SyncNotification.stuckOverwriteWarnMinutes),
          'Last Sync: 1 file stuck • $time • 87% Battery',
          reason: 'a day or more away, the last sync keeps the line');
      expect(body(stuckFiles: 1), 'Last Sync: 1 file stuck • $time • 87% Battery', reason: 'unknown: no claim');
      expect(body(stuckFiles: 1, stuckOverwriteMinutes: 30, storagePaused: true),
          'Phone storage full • audio waiting to process');
    });

    test('a skipped sync never reached the device — no percentage', () {
      // The whole point: out of range for one cycle, then two, then a day. The stored
      // reading ages the entire time while this line would keep asserting it unchanged.
      expect(body(skipped: true), 'Last Sync: Skipped • $time');
    });

    test('but a live link still shows it, even with the skip flag set', () {
      // lastSyncSkipped stays true until the next sync COMPLETES, so a user who comes
      // back into range and reconnects would otherwise stare at a connected device with
      // its battery blanked.
      expect(body(skipped: true, isConnected: true), 'Last Sync: Skipped • $time • 87% Battery');
    });

    test('an unknown connection state is treated as not connected', () {
      // SyncNotification.idle() is also called with no connection argument at all
      // (recordings_controller). Assert less rather than more.
      expect(body(skipped: true, isConnected: null), 'Last Sync: Skipped • $time');
    });

    test('never-read battery is omitted regardless of outcome', () {
      expect(body(batteryLevel: -1), 'Last Sync: Complete • $time');
      expect(body(batteryLevel: -1, isConnected: true), 'Last Sync: Complete • $time');
    });

    test('a zero percent reading is a reading, not a missing one', () {
      expect(body(batteryLevel: 0), 'Last Sync: Complete • $time • 0% Battery');
    });
  });

  group('idle body text — no sync outcome yet', () {
    // One stable string, whatever the link is doing. The resting line reports work and
    // outcomes, never connection state: a "Connecting..." here was reachable on a fresh
    // install and could be left standing by a frozen isolate, and native's mirror
    // (OmiBleForegroundService.idleNotificationContent) has no view of the link on a
    // headless start, so any link-derived text would make the two renderers disagree.
    test('reads "Ready to sync" regardless of the link state', () {
      expect(body(lastStatusMs: 0), 'Ready to sync');
      expect(body(lastStatusMs: 0, isConnected: true), 'Ready to sync');
      expect(body(lastStatusMs: 0, isConnected: false), 'Ready to sync');
    });

    // isConnected survives as a parameter only to gate the battery clause, and that
    // clause is downstream of an outcome existing — so with none, it must not leak a
    // percentage into the line either.
    test('a live link does not conjure a battery reading with no outcome to attach it to', () {
      expect(body(lastStatusMs: 0, isConnected: true, batteryLevel: 87), 'Ready to sync');
    });
  });

  group('idle body text — phone storage', () {
    test('audio waiting on phone storage takes the line, with how much is waiting', () {
      expect(
        SyncNotification.idleBodyText(
          lastStatusMs: at,
          skipped: false,
          partial: false,
          batteryLevel: 87,
          storagePaused: true,
          storageWaitingMinutes: 42,
        ),
        'Phone storage full • 42 min of audio waiting',
      );
    });

    test('says so even before any sync outcome, or without a count', () {
      expect(
        SyncNotification.idleBodyText(
            lastStatusMs: 0, skipped: false, partial: false, batteryLevel: -1, storagePaused: true),
        'Phone storage full • audio waiting to process',
      );
    });
  });
}
