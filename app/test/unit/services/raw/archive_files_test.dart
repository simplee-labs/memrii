import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('archive_files_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('the meta', () {
    Conversation read(Uint8List meta, {String name = 'recording_1789100000123.wav'}) {
      File('${root.path}/${name.split('.').first}.meta').writeAsBytesSync(meta);
      final audio = File('${root.path}/$name')..writeAsBytesSync(Uint8List(44));
      return Conversation.fromFile(audio);
    }

    test('today\'s reader reads every field', () {
      final c = read(buildMeta(
        totalSamples: 32000,
        peaks: Uint16List.fromList(List.generate(200, (i) => i)),
        sessionId: 7,
        startUptimeSeconds: 123,
        uploadKey: uploadKeyOf('aa:bb:cc:dd:ee:ff', 1789100000123, 'm4a'),
        forceSynced: true,
        capEnded: false,
        silero: true,
        manual: true,
        relativeBins: ['1789100000/1789100000_7.bin', '1789099000/1789099000_7.bin'],
      ));
      expect(c.duration, const Duration(seconds: 2));
      expect(c.sessionId, 7);
      expect(c.startUptimeMs, 123000);
      expect(c.uploadKey, 'AABBCC_recording_1789100000123.m4a');
      expect(c.forceSynced, isTrue);
      expect(c.capEnded, isFalse);
      expect(c.isSilero, isTrue);
      expect(c.recordedManual, isTrue);
      expect(c.clockCorrected, isFalse);
      expect(c.isCropped, isFalse);
      expect(c.relativeBins, ['1789099000/1789099000_7.bin', '1789100000/1789100000_7.bin']);
    });

    test('unknown mode and uptime stay unknown; a first-second start is not read as unknown', () {
      Uint8List meta({int? uptime, bool? manual}) => buildMeta(
            totalSamples: 320,
            peaks: Uint16List(200),
            sessionId: null,
            startUptimeSeconds: uptime,
            uploadKey: null,
            forceSynced: false,
            capEnded: true,
            silero: false,
            manual: manual,
            relativeBins: const [],
          );
      final c = read(meta());
      expect(c.recordedManual, isNull);
      expect(c.startUptimeMs, isNull);
      expect(c.capEnded, isTrue);
      expect(c.relativeBins, isEmpty);
      expect(read(meta(uptime: 0, manual: false)).startUptimeMs, 1000);
      expect(read(meta(uptime: 0, manual: false)).recordedManual, isFalse);
    });
  });

  test('a name\'s ms: the first all-digit part; markers and the discard list name none', () {
    expect(archiveNameMs('recording_123.wav'), 123);
    expect(archiveNameMs('recording_123_draft.wav'), 123);
    expect(archiveNameMs('unknown_123.meta'), 123);
    expect(archiveNameMs('recording_fs320_123.bin'), 123);
    expect(archiveNameMs('recording_123.meta.tmp'), 123);
    expect(archiveNameMs('recording_123_crop1.m4a'), 123);
    expect(archiveNameMs('marker_123.edl'), isNull);
    expect(archiveNameMs('discards.jsonl'), isNull);
  });

  group('reserving names', () {
    const start = 1789100000123;
    final date = localDateOf(start);

    void touch(String name, [String? day]) => File('${root.path}/${day ?? date}/$name').createSync(recursive: true);

    test('the start ms when free; else the first free ms across every stem', () async {
      final names = NameReserver(root.path);
      expect((await names.recording(start, derived: false)).stem, 'recording_$start');
      touch('recording_$start.m4a');
      touch('unknown_${start + 1}.meta');
      touch('recording_${start + 2}_draft.wav');
      touch('recording_fs320_${start + 3}.bin');
      touch('marker_${start + 4}.edl');
      final again = NameReserver(root.path);
      final n = await again.recording(start, derived: true);
      expect(n.stem, 'unknown_${start + 4}');
      expect(n.date, date);
      expect(n.sidecar, 'recording_fs320_${start + 4}.bin');
      // Reserved in this transaction: the next one is after it.
      expect((await again.recording(start, derived: false)).nameMs, start + 5);
    });

    test('one ms before midnight: the next day\'s folder is checked too, the true start\'s folder kept', () async {
      final d = DateTime(2026, 9, 11, 23, 59, 59, 999);
      final ms = d.millisecondsSinceEpoch;
      touch('recording_$ms.wav', localDateOf(ms));
      touch('recording_${ms + 1}.wav', localDateOf(ms + 1));
      final n = await NameReserver(root.path).recording(ms, derived: false);
      expect(n.nameMs, ms + 2);
      expect(n.date, localDateOf(ms));
    });

    test('an EDL takes marker_<ms>.edl, else marker_<ms>_<n>.edl', () async {
      touch('marker_55.edl');
      final names = NameReserver(root.path);
      expect(await names.edl(date, 55), 'marker_55_1.edl');
      expect(await names.edl(date, 55), 'marker_55_2.edl');
      expect(await names.edl(date, 56), 'marker_56.edl');
    });
  });

  test('a discard record: exact ranges per file, an id, today\'s fields', () {
    const a = RawFileKey(1789100000, 7), b = RawFileKey(1789100600, 7);
    const d = PlannedDiscard(
      sessionId: 7,
      closeType: CloseType.silence,
      closedAt: PlanPosition(b, 100),
      kind: DiscardKind.noiseSilenceSplit,
      spans: [FrameSpan(a, 3, 9), FrameSpan(b, 0, 2)],
      startMs: 10,
      endMs: 99,
      audioMs: 160,
      maxVoiceProb: 0.4,
    );
    final bytes = {
      a: [(100, 200), (300, 400)],
      b: [(36, 60)],
    };
    final id = discardIdOf(d, bytes);
    expect(id, '${a.rel}@100');
    final r = discardRecordOf(d, id, bytes);
    expect(r['reason'], 'noise_silence_split');
    expect(r['relativeBins'], [a.rel, b.rel]);
    expect(r['binRanges'], {
      a.rel: [
        [100, 200],
        [300, 400]
      ],
      b.rel: [
        [36, 60]
      ],
    });
    expect(r['audioMs'], 160);
  });
}
