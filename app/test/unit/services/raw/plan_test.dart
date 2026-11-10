import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';

const t0 = 1789000000000;

FramesPiece frames(Bin b, int first, int end) => FramesPiece(FrameSpan(b.key, first, end));

void main() {
  group('a conversation', () {
    test('stays in progress until something closes it', () {
      final a = Bin(t0).frames(500, p: speech);
      final p = planOf([a.file()]);
      expect(p.items, isEmpty);
      expect(p.open.single.frameCount, 500);
      expect(p.open.single.startMs, t0);
    });

    test('Force closes it where it is, with everything it holds', () {
      final a = Bin(t0).frames(500, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.startMs, t0);
      expect(r.durationMs, 10000);
      expect(r.pieces, [frames(a, 0, 500)]);
      expect(r.closeType, CloseType.force);
      expect(r.silero, isTrue);
      expect(r.startUptimeSeconds, 100);
    });

    test('its start uptime is its first frame\'s, not the uptime after it', () {
      final a = Bin(t0, uptimeMs: 1999).frames(200, p: speech);
      expect(recordingsOf(planOf([a.file()], boundaries: [a.force])).single.startUptimeSeconds, 1);
    });

    test('a file whose header does not say its uptime has none, not the file before\'s', () {
      final a = Bin(t0, uptimeMs: 100000).frames(200, p: speech).stop();
      final b = Bin(t0 + 600000, header: false, uptimeMs: 200000).tap().frames(200, p: speech);
      final rs = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force]));
      expect(rs.last.startUptimeSeconds, isNull);
    });

    test('nor does a marker give it one: a resume carries only 32 bits', () {
      final a = Bin(t0, header: false, uptimeMs: 200000).frames(200, p: speech).resume(130000).frames(200, p: speech);
      final rs = recordingsOf(planOf([a.file()], boundaries: [a.force]));
      expect(rs.map((r) => r.startUptimeSeconds), [null, null]);
    });

    test('a Priority Recording\'s taps are placed at the audio before them', () {
      final a = Bin(t0).priority().frames(100, p: quiet);
      final tap = a.nextId;
      a.tap().frames(100, p: quiet).stop();
      final r = recordingsOf(planOf([a.file()])).single;
      expect(r.markers.last, PlannedMarker(tap, t0 + 2000, 2000, false));
    });

    test('undecodable frames stay in it, in place, as frames', () {
      final a = Bin(t0).frames(200, p: speech).frames(3, decoded: false).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.pieces, [frames(a, 0, 403)]);
      expect(r.durationMs, 403 * frameMs);
    });
  });

  group('silence', () {
    test('a silence run of the split length closes the conversation with its silence', () {
      final a = Bin(t0).frames(200, p: speech).frames(6000, p: quiet).frames(10, p: speech);
      final p = planOf([a.file()]);
      final r = recordingsOf(p).single;
      expect(r.pieces, [frames(a, 0, 6200)]);
      expect(r.closeType, CloseType.silence);
      expect(p.open.single.startMs, t0 + 6200 * frameMs, reason: 'the next one starts at its first frame');
    });

    test('silence alone is discarded as silence only', () {
      final a = Bin(t0).frames(6000, p: quiet);
      final d = discardsOf(planOf([a.file()])).single;
      expect(d.kind, DiscardKind.silenceOnly);
      expect(d.spans, [FrameSpan(a.key, 0, 6000)]);
      expect(d.audioMs, 120000);
    });

    test('too little speech before the silence is discarded as noise', () {
      final a = Bin(t0).frames(100, p: speech).frames(6000, p: quiet);
      final d = discardsOf(planOf([a.file()])).single;
      expect(d.kind, DiscardKind.noiseSilenceSplit);
      expect(d.maxVoiceProb, closeTo(speech, 1e-6));
    });

    test('manual mode never splits on silence', () {
      final a = Bin(t0).frames(20000, p: quiet);
      expect(planOf([a.file()], policy: manualPolicy).items, isEmpty);
    });
  });

  group('resume gaps', () {
    test('a gap over the split (less the firmware hold) starts a new conversation at the resume', () {
      final a = Bin(t0).frames(200, p: speech).resume(130000).frames(200, p: speech);
      final p = planOf([a.file()]);
      final r = recordingsOf(p).single;
      expect(r.pieces, [frames(a, 0, 200)]);
      expect(r.closeType, CloseType.resumeGap);
      expect(p.open.single.startMs, a.clockMs - 200 * frameMs);
    });

    test('the firmware hold counts: 115 s of gap is over a 120 s split', () {
      final a = Bin(t0).frames(200, p: speech).resume(115000).frames(200, p: speech);
      expect(recordingsOf(planOf([a.file()])).single.closeType, CloseType.resumeGap);
    });

    test('a shorter gap is kept as silence', () {
      final a = Bin(t0).frames(200, p: speech).resume(100000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.pieces, [frames(a, 0, 200), const SilencePiece(100000), frames(a, 200, 400)]);
      expect(r.durationMs, 108000);
    });

    test('a clock being set is neither silence nor a split', () {
      final a = Bin(t0).frames(200, p: speech).resume(3600000, clockSet: true).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.pieces, [frames(a, 0, 400)]);
    });

    test('a resume with no clock is dated by uptime', () {
      final a = Bin(t0).frames(200, p: speech).resume(100000, clockless: true).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.pieces, [frames(a, 0, 200), const SilencePiece(100000), frames(a, 200, 400)]);
    });

    test('too little speech before a split is discarded as noise', () {
      final a = Bin(t0).frames(100, p: speech).resume(130000).frames(10, p: speech);
      expect(discardsOf(planOf([a.file()])).single.kind, DiscardKind.noisePreSplit);
    });
  });

  group('between files', () {
    test('a gap under 10 s carries on without padding', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next(gapMs: 5000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
      expect(r.pieces, [frames(a, 0, 200), frames(b, 0, 200)]);
    });

    test('a gap of 10 s or more, under the split, is padded', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next(gapMs: 60000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
      expect(r.pieces, [frames(a, 0, 200), const SilencePiece(60000), frames(b, 0, 200)]);
    });

    test('a gap over the split closes the conversation', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next(gapMs: 200000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()])).single;
      expect(r.closeType, CloseType.fileGap);
      expect(r.pieces, [frames(a, 0, 200)]);
    });

    test('a trailing resume is not padded again by the gap to the next file', () {
      final a = Bin(t0).frames(200, p: speech).resume(30000);
      final b = a.next(gapMs: 20000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
      expect(r.pieces, [frames(a, 0, 200), const SilencePiece(30000), const SilencePiece(20000), frames(b, 0, 200)]);
      expect(r.durationMs, 58000);
    });

    test('a clock set across the 32-bit uptime wrap is still seen as the clock being set', () {
      const wrap = 0x100000000;
      final a = Bin(t0, uptimeMs: wrap - 3000).frames(100, p: speech).resume(2000).frames(100, p: speech);
      final b = Bin(a.clockMs + 3600000, uptimeMs: a.uptimeMs + 1000).frames(100, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
      expect(r.pieces.whereType<FramesPiece>().length, 3, reason: 'one recording, no gap split');
      expect(r.pieces.whereType<SilencePiece>().map((p) => p.ms), [2000]);
    });

    group('silence is counted from the last audio, in real time', () {
      // Auto mode splits on more than 110 s (120 s less the firmware hold).
      test('through two resumes with no audio between', () {
        final a = Bin(t0).frames(200, p: speech).resume(60000).resume(60000).frames(200, p: speech);
        final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).first;
        expect(r.closeType, CloseType.resumeGap);
        expect(r.pieces, [frames(a, 0, 200), const SilencePiece(60000)]);
      });

      test('across the gap to the next file', () {
        final a = Bin(t0).frames(200, p: speech);
        final b = a.next(gapMs: 50000).resume(70000).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force]));
        expect(rs.map((r) => r.closeType), [CloseType.resumeGap, CloseType.force]);
      });

      test('across a file with no audio', () {
        final a = Bin(t0).frames(200, p: speech);
        final h = a.next(gapMs: 60000);
        final b = h.next(gapMs: 60000).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file(), h.file(), b.file()], boundaries: [b.force]));
        expect(rs.map((r) => r.closeType), [CloseType.fileGap, CloseType.force]);
      });

      test('across the clock being set back, by the uptime that passed', () {
        final a = Bin(t0)
            .frames(200, p: speech)
            .resume(100000)
            .resume(-3600000, clockSet: true, elapsedMs: 2000)
            .resume(9000)
            .frames(200, p: speech);
        expect(recordingsOf(planOf([a.file()], boundaries: [a.force])).first.closeType, CloseType.resumeGap);
      });

      test('across the clock being set forward, to the millisecond', () {
        final a = Bin(t0)
            .frames(200, p: speech)
            .resume(100000)
            .resume(3600000, clockSet: true, elapsedMs: 2020)
            .resume(8000)
            .frames(200, p: speech);
        expect(recordingsOf(planOf([a.file()], boundaries: [a.force])).first.closeType, CloseType.resumeGap,
            reason: '110.02 s is over 110 s');
      });

      test('when the clock moved less than the time that passed', () {
        // 5 s by the clock, 120 s by uptime: the clock was set back. The 120 s that passed
        // split there, though the clock was set.
        final a = Bin(t0).frames(200, p: speech).resume(5000, clockSet: true, elapsedMs: 120000).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file()], boundaries: [a.force]));
        expect(rs.map((r) => r.closeType), [CloseType.resumeGap, CloseType.force]);
      });

      test('when the clock moved more than the time that passed', () {
        // 120 s by the clock, 6 s by uptime: the clock was set forward. No silence to split on.
        final a = Bin(t0).frames(200, p: speech).resume(120000, clockSet: true, elapsedMs: 6000).frames(200, p: speech);
        final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
        expect(r.pieces, [frames(a, 0, 400)], reason: 'no padding for a clock being set');
      });

      test('a clock set back that still moved on is not padded either', () {
        // 20 s by the clock, 60 s by uptime: set back 40 s. Under the split; no padding.
        final a = Bin(t0).frames(200, p: speech).resume(20000, clockSet: true, elapsedMs: 60000).frames(200, p: speech);
        final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
        expect(r.pieces, [frames(a, 0, 400)], reason: 'no padding for a clock being set');
      });

      test('across a long sleep at a resume', () {
        const days30 = 30 * 24 * 3600 * 1000;
        final a = Bin(t0).frames(200, p: speech).resume(days30).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file()], boundaries: [a.force]));
        expect(rs.map((r) => r.closeType), [CloseType.resumeGap, CloseType.force]);
      });

      test('across a long sleep between files', () {
        const days30 = 30 * 24 * 3600 * 1000;
        final a = Bin(t0).frames(200, p: speech);
        final b = a.next(gapMs: days30).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force]));
        expect(rs.map((r) => r.closeType), [CloseType.fileGap, CloseType.force]);
      });

      test('across the clock being set as the uptime wraps, by the uptime that passed', () {
        // An hour by the clock, 120 s by uptime, which wraps from 2^32 − 6 s to 114 s.
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 10000)
            .frames(200, p: speech)
            .resume(3600000, clockSet: true, elapsedMs: 120000)
            .frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file()], boundaries: [a.force]));
        expect(rs.map((r) => r.closeType), [CloseType.resumeGap, CloseType.force]);
      });

      test('not when a resume\'s uptime is a moment behind the computed end of the last frame', () {
        final a = Bin(t0).frames(200, p: speech).resume(0, clockSet: true, elapsedMs: -10).frames(200, p: speech);
        expect(recordingsOf(planOf([a.file()], boundaries: [a.force])).single.frameCount, 400);
      });

      test('a recording starting at a resume after a wrap has its full start uptime', () {
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 6000).frames(200, p: speech).resume(130000).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file()], boundaries: [a.force]));
        expect(rs.map((r) => r.startUptimeSeconds), [(wrap - 6000) ~/ 1000, (wrap + 128000) ~/ 1000]);
      });

      test('not across a pre-sync file, by its header\'s uptime, not its name\'s 32 bits', () {
        // The header says uptime 2^32 + 1,000 s; the name, 1,000 s. The next file starts as
        // this one's audio ends, by both clock and uptime.
        const wrap = 0x100000000;
        final a = Bin(0, keySeconds: 1000, uptimeMs: wrap + 1000000, headerUtcMs: 0).frames(200, p: speech);
        final b = Bin(t0, uptimeMs: a.uptimeMs).frames(200, p: speech);
        final r = recordingsOf(planOf([a.file(firstSealedAtMs: t0 - 4000), b.file()], boundaries: [b.force])).single;
        expect(r.pieces, [frames(a, 0, 200), frames(b, 0, 200)]);
      });

      test('not across pre-sync files sealed a whole wrap apart, by their headers\' uptimes', () {
        // The phone sealed them 2^32 + 4 s apart; the headers show the audio running on.
        const wrap = 0x100000000;
        final a = Bin(0, keySeconds: 1000, uptimeMs: 1000000, headerUtcMs: 0).frames(201, p: speech);
        final b = Bin(0, keySeconds: 1004, uptimeMs: 1004020, headerUtcMs: 0).frames(200, p: speech);
        final files = [a.file(firstSealedAtMs: t0), b.file(firstSealedAtMs: t0 + wrap + 4000)];
        final r = recordingsOf(planOf(files, boundaries: [b.force])).single;
        expect(r.pieces, [frames(a, 0, 201), frames(b, 0, 200)]);
      });

      test('not by a pre-sync name, which after a wrap runs on from before it', () {
        // The header is lost; the name, bumped past the last one, says 1 s after it began. The
        // only clock, the phone's, says 130 s after its audio ended.
        final a = Bin(0, keySeconds: 4294960, uptimeMs: 4294960000, headerUtcMs: 0).frames(200, p: speech);
        final b = Bin(0, keySeconds: 4294961, header: false).frames(200, p: speech);
        final files = [a.file(firstSealedAtMs: t0), b.file(firstSealedAtMs: t0 + 4000 + 130000)];
        final rs = recordingsOf(planOf(files, boundaries: [b.force]));
        expect(rs.map((r) => r.closeType), [CloseType.fileGap, CloseType.force]);
      });

      test('not when the next header is a moment behind the end of the audio, whatever the clock', () {
        // 10 ms behind by the headers; an hour on by the clock, which was set.
        final a = Bin(t0).frames(200, p: speech);
        final b = a.next(gapMs: 3600000, uptimeMs: a.uptimeMs - 10).frames(200, p: speech);
        final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
        expect(r.pieces, [frames(a, 0, 200), frames(b, 0, 200)]);
      });

      test('by the uptime when the clock agrees: a resume\'s clock is in whole seconds', () {
        // 110 s by the clock, 110.5 s by uptime: over the 110 s split.
        final a =
            Bin(t0).frames(200, p: speech).resume(110000, clockSet: true, elapsedMs: 110500).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file()], boundaries: [a.force]));
        expect(rs.map((r) => r.closeType), [CloseType.resumeGap, CloseType.force]);
      });

      test('not across a resume\'s 32-bit uptime at the end of a file, just after a wrap', () {
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 6000).frames(200, p: speech).resume(3000);
        expect(a.uptimeMs, wrap + 1000, reason: 'the resume carries uptime 1 s');
        final b = a.next().frames(200, p: speech);
        final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
        expect(r.pieces, [frames(a, 0, 200), const SilencePiece(3000), frames(b, 0, 200)]);
      });

      test('not across a resume\'s 32-bit uptime just after a wrap, with audio after it', () {
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 6000).frames(200, p: speech).resume(3000).frames(200, p: speech);
        final b = a.next().frames(200, p: speech);
        final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
        expect(r.pieces, [frames(a, 0, 200), const SilencePiece(3000), frames(a, 200, 400), frames(b, 0, 200)]);
      });

      test('a Priority Recording is padded across files after its 32-bit start, just after a wrap', () {
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 2000).frames(200, p: speech).priority().frames(200, p: quiet);
        final b = a.next(gapMs: 12000).frames(200, p: quiet).stop();
        final r = recordingsOf(planOf([a.file(), b.file()])).last;
        expect(r.pieces, [frames(a, 200, 400), const SilencePiece(12000), frames(b, 0, 200)]);
        expect(r.startUptimeSeconds, (wrap + 2000) ~/ 1000);
      });

      test('between files when the clock moved less than the time that passed', () {
        final a = Bin(t0).frames(200, p: speech);
        final b = Bin(a.clockMs + 5000, uptimeMs: a.uptimeMs + 120000).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force]));
        expect(rs.map((r) => r.closeType), [CloseType.fileGap, CloseType.force]);
      });

      test('between files whose header says no uptime (0), by the clock', () {
        final a = Bin(t0).frames(200, p: speech);
        final b = Bin(a.clockMs + 130000, uptimeMs: 0).frames(200, p: speech);
        final rs = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force]));
        expect(rs.map((r) => r.closeType), [CloseType.fileGap, CloseType.force]);
      });

      test('into a stale Priority Recording, even across a clock being set', () {
        // An hour by the clock, 20 s by uptime: 20 s of real silence shows the stop was lost.
        final a = Bin(t0)
            .priority()
            .frames(200, p: quiet)
            .resume(3600000, clockSet: true, elapsedMs: 20000)
            .frames(10, p: quiet);
        expect(recordingsOf(planOf([a.file()])).single.closeType, CloseType.priorityStale);
      });

      test('when the uptime wraps to exactly zero', () {
        // A resume carries uptime's low 32 bits; here they are 0, which is an uptime.
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 5000)
            .frames(200, p: speech)
            .resume(3600000, clockSet: true, elapsedMs: 1000)
            .frames(200, p: speech)
            .stop();
        expect(a.uptimeMs - 4000 - 1000, wrap - 1000, reason: 'the resume is at uptime 2^32');
        expect(recordingsOf(planOf([a.file()])).single.pieces, [frames(a, 0, 400)]);
      });

      test('from where the stream was, not from a coalesced resume', () {
        // Without Silero, three tiny resume splits: the third coalesces (no re-anchor). The next
        // file starts a second after it: 131 s after the last audio.
        final a = Bin(t0);
        for (var i = 0; i < 3; i++) {
          a.frames(10).resume(130000);
        }
        final b = Bin(a.clockMs + 1000, uptimeMs: a.uptimeMs + 1000).frames(10);
        final p = planOf([a.file(hasVad: false), b.file(hasVad: false)], boundaries: [b.force]);
        expect(recordingsOf(p).map((r) => r.closeType).last, CloseType.force);
        expect(recordingsOf(p).map((r) => r.closeType), contains(CloseType.fileGap));
      });

      test('after a coalesced resume, time and uptime run on together: a short gap after it is padded', () {
        // The third tiny split coalesces; 10 frames later a 20 s resume is no clock set.
        final a = Bin(t0);
        for (var i = 0; i < 3; i++) {
          a.frames(10).resume(130000);
        }
        a.frames(10).resume(20000).frames(10);
        final r = recordingsOf(planOf([a.file(hasVad: false)], boundaries: [a.force])).last;
        expect(r.pieces.whereType<SilencePiece>(), hasLength(1));
      });

      test('a priority start without a clock is dated by the uptime it says, as a resume is', () {
        // Before time sync: 4 s of audio, a 60 s sleep, the start, and its resume 1 s later.
        final a = Bin(0, keySeconds: 1000, uptimeMs: 1000000, headerUtcMs: 0).frames(200, p: speech);
        a.priority(atMs: 0, uptimeMs: a.uptimeMs + 60000).resume(61000, clockless: true).frames(200, p: quiet).stop();
        final r = recordingsOf(planOf([a.file(firstSealedAtMs: t0)])).last;
        expect(r.startMs, t0 + 4000 + 61000);
      });

      test('a clockless resume after a priority start is dated from the start', () {
        final a = Bin(t0).frames(200, p: speech).priority().resume(1000, clockless: true).frames(200, p: quiet).stop();
        final r = recordingsOf(planOf([a.file()])).last;
        expect(r.startMs, t0 + 5000);
      });

      test('a clockless resume after a priority start at the wrap (uptime 0) too', () {
        const wrap = 0x100000000;
        final a = Bin(t0, uptimeMs: wrap - 4000).frames(200, p: speech);
        expect(a.uptimeMs, wrap, reason: 'the start carries uptime 0');
        a.priority().resume(1000, clockless: true).frames(200, p: quiet).stop();
        expect(recordingsOf(planOf([a.file()])).last.startMs, t0 + 5000);
      });

      test('from a priority start, which is dated after the audio before it', () {
        // The start wakes the Omi 4 s after its last audio; its resume comes 107 s after the
        // start (111 s after the audio): under the 110 s split, counted from the start.
        final a = Bin(t0).frames(200, p: speech);
        final start = a.nextId;
        a.priority(atMs: a.clockMs + 4000, uptimeMs: a.uptimeMs + 4000).resume(111000).frames(200, p: quiet).stop();
        final p = planOf([a.file()]);
        expect(orphansOf(p), isEmpty);
        final r = recordingsOf(p).last;
        expect(r.closeType, CloseType.stop);
        expect(r.markers.single.id, start);
      });
    });

    test('a clock set by a resume at the end of a file does not split it from the next', () {
      final a = Bin(t0).frames(200, p: speech).resume(3600000, clockSet: true);
      final b = a.next().frames(200, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
      expect(r.pieces, [frames(a, 0, 200), frames(b, 0, 200)]);
    });

    test('without uptimes, a gap between files is taken as it is', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = Bin(a.clockMs + 200000, header: false).frames(200, p: speech);
      expect(recordingsOf(planOf([a.file(), b.file()])).single.closeType, CloseType.fileGap);
    });

    test('without an uptime, a resume gap is taken as it is, not as the clock being set', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = Bin(t0 + 600000, header: false).frames(200, p: speech).resume(130000).frames(200, p: speech);
      final rs = recordingsOf(planOf([a.file(), b.file()], boundaries: [a.force, b.force]));
      expect(rs.map((r) => r.closeType), [CloseType.force, CloseType.resumeGap, CloseType.force]);
    });

    test('a gap that is the clock being set is not padded', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next(gapMs: 3600000, uptimeMs: a.uptimeMs + 1000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file(), b.file()], boundaries: [b.force])).single;
      expect(r.pieces, [frames(a, 0, 200), frames(b, 0, 200)]);
    });

    test('a new session ends the last one', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next(gapMs: 1000, session: 8, uptimeMs: 5000).frames(200, p: speech);
      final p = planOf([a.file(), b.file()]);
      final r = recordingsOf(p).single;
      expect(r.sessionId, 7);
      expect(r.closeType, CloseType.sessionEnd);
      expect(p.open.single.sessionId, 8);
    });
  });

  group('taps', () {
    test('a tap is placed at the audio before it', () {
      final a = Bin(t0).frames(100, p: speech);
      final tap = a.nextId;
      a.tap().frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.markers, [PlannedMarker(tap, t0 + 2000, 2000, false)]);
    });

    test('a tap that opens a conversation is at its start', () {
      final a = Bin(t0);
      final tap = a.nextId;
      a.tap().frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.markers, [PlannedMarker(tap, t0, 0, false)]);
      expect(r.startMs, t0);
    });

    test('a tap with no audio around it is an orphan', () {
      final a = Bin(t0);
      final tap = a.nextId;
      a.tap().stop();
      final p = planOf([a.file()]);
      expect(orphansOf(p).single, PlannedMarker(tap, t0, 0, false));
      expect(recordingsOf(p), isEmpty);
    });

    test('its window makes the audio after it speech, so the conversation is kept', () {
      // 50 s of frames count as speech, then 120 s of silence closes it.
      final a = Bin(t0).tap().frames(10000, p: quiet);
      final r = recordingsOf(planOf([a.file()])).single;
      expect(r.pieces, [frames(a, 0, 2502 + 6000)]);
      expect(r.closeType, CloseType.silence);
      expect(r.markers, hasLength(1));
    });

    test('a resume inside its window does not split; one after it does', () {
      // Manual mode, where any gap splits.
      final a = Bin(t0).frames(200, p: speech).tap().frames(10, p: speech).resume(30000).frames(10, p: speech);
      expect(planOf([a.file()], policy: manualPolicy).items, isEmpty, reason: 'within 50 s of the tap');
      final b = Bin(t0).frames(200, p: speech).tap().frames(10, p: speech).resume(130000).frames(10, p: speech);
      expect(recordingsOf(planOf([b.file()], policy: manualPolicy)).single.closeType, CloseType.resumeGap);
    });

    test('a tapped conversation with no speech at a silence split is a discard that keeps its tap', () {
      // Deferred (today's behaviour): quiet audio. A 30 s split; the tap's own clock is 2
      // minutes behind the audio, so its window has passed by the audio's time.
      const policy = PlanPolicy(
          vadEnabled: true,
          speechThreshold: 0.5,
          silenceSplitMs: 30000,
          minSpeechMs: 3000,
          maxChunkMs: 1 << 62,
          manual: false);
      final a = Bin(t0).frames(50, p: quiet);
      final tap = a.nextId;
      a.tap(atMs: a.clockMs - 120000).frames(1600, p: quiet);
      final p = planOf([a.file()], policy: policy, boundaries: [a.force]);
      expect(discardsOf(p).first.orphans.single.id, tap);
    });

    test('a conversation with a tap is kept however little speech it has', () {
      final a = Bin(t0).tap().frames(50, p: quiet);
      expect(recordingsOf(planOf([a.file()], boundaries: [a.force])).single.frameCount, 50);
    });

    test('a conversation starting after the window is not protected by it', () {
      // The first frame after the gap still counts as speech (the frame before it was in
      // the window), but the conversation itself started outside it.
      final a = Bin(t0).frames(200, p: speech).tap().frames(10, p: speech).resume(130000).frames(100, p: quiet);
      a.resume(130000).frames(10);
      final p = planOf([a.file()]);
      expect(recordingsOf(p).single.frameCount, 210);
      expect(discardsOf(p).single.kind, DiscardKind.noisePreSplit);
    });

    test('a tap with no clock, or one far from the audio, takes the audio time', () {
      final a = Bin(t0).frames(100, p: speech).tap(atMs: 0).frames(100, p: speech);
      expect(recordingsOf(planOf([a.file()], boundaries: [a.force])).single.markers.single.markerMs, t0 + 2000);
      final b = Bin(t0).frames(100, p: speech).tap(atMs: t0 + 2000 + 120000).frames(100, p: speech);
      expect(recordingsOf(planOf([b.file()], boundaries: [b.force])).single.markers.single.markerMs, t0 + 2000);
    });
  });

  group('stop', () {
    test('closes the conversation and keeps it, however little speech it has', () {
      final a = Bin(t0).frames(20, p: quiet).stop();
      final r = recordingsOf(planOf([a.file()])).single;
      expect(r.closeType, CloseType.stop);
      expect(r.pieces, [frames(a, 0, 20)]);
    });

    test('frames after it, until a resume, are discarded as after-stop', () {
      final a = Bin(t0).frames(200, p: speech).stop().frames(2).resume(60000).frames(200, p: speech);
      final p = planOf([a.file()], boundaries: [a.force]);
      final d = discardsOf(p).single;
      expect(d.kind, DiscardKind.afterStop);
      expect(d.spans, [FrameSpan(a.key, 200, 202)]);
      expect(d.closeType, CloseType.latchEnd);
      expect(recordingsOf(p).map((r) => r.pieces), [
        [frames(a, 0, 200)],
        [frames(a, 202, 402)],
      ]);
    });
  });

  group('Priority Recording', () {
    test('closes what was open, and is one recording of speech until its stop', () {
      final a = Bin(t0).frames(200, p: speech);
      final start = a.nextId;
      a.priority().frames(10000, p: quiet).stop();
      final rs = recordingsOf(planOf([a.file()]));
      expect(rs.map((r) => r.closeType), [CloseType.priorityStart, CloseType.stop]);
      expect(rs[1].pieces, [frames(a, 200, 10200)]);
      expect(rs[1].markers, [PlannedMarker(start, t0 + 4000, 0, true)]);
    });

    test('started and stopped with no audio is a priority orphan', () {
      final a = Bin(t0);
      final start = a.nextId;
      a.priority().stop();
      expect(orphansOf(planOf([a.file()])).single, PlannedMarker(start, t0, 0, true));
    });

    test('a lost stop is made up at the safety cap, measured in the audio', () {
      // Cap 1 min + 2 min grace = 9000 frames.
      final a = Bin(t0).priority().frames(10000, p: quiet);
      final p = planOf([a.file()], capMinutes: 1);
      final r = recordingsOf(p).single;
      expect(r.closeType, CloseType.priorityCap);
      expect(r.pieces, [frames(a, 0, 9000)]);
      expect(p.open.single.inPriority, isFalse);
    });

    test('the cap is the one in force when it started', () {
      final a = Bin(t0).priority().frames(10000, p: quiet);
      final p = plan(PlanInput(
        files: [a.file()],
        policies: const PolicyHistory(autoPolicy),
        caps: CapHistory([(atMs: 0, minutes: 1), (atMs: t0 + 1000, minutes: 0)]),
      ));
      expect(recordingsOf(p).single.closeType, CloseType.priorityCap);
    });

    test('a long resume gap inside it shows the stop was lost', () {
      final a = Bin(t0).priority().frames(100, p: quiet).resume(20000).frames(100, p: quiet);
      final r = recordingsOf(planOf([a.file()])).single;
      expect(r.closeType, CloseType.priorityStale);
      expect(r.pieces, [frames(a, 0, 100)]);
    });

    test('the resume that wakes the Omi for the start is not that evidence', () {
      final a = Bin(t0).priority().resume(20000).frames(100, p: quiet);
      expect(planOf([a.file()]).items, isEmpty);
      expect(planOf([a.file()]).open.single.inPriority, isTrue);
    });

    test('nor is the clock being set', () {
      final a = Bin(t0).priority().frames(100, p: quiet).resume(3600000, clockSet: true).frames(100, p: quiet);
      expect(planOf([a.file()]).items, isEmpty);
    });

    group('its cap counts device time, as the firmware\'s timer does', () {
      test('not a clock set forward past it between files', () {
        // 10 minutes of audio, then a header a day on by the clock, the uptime running on.
        final a = Bin(t0).priority().frames(30000, p: quiet);
        final b = a.next(gapMs: 86400000, uptimeMs: a.uptimeMs).frames(200, p: quiet).stop();
        final r = recordingsOf(planOf([a.file(), b.file()])).single;
        expect(r.closeType, CloseType.stop);
        expect(r.frameCount, 30200);
      });

      test('nor the phone\'s date for a file the Omi could not date', () {
        // The start has the Omi's clock; the phone sealed the file a day later.
        final a = Bin(0, keySeconds: 1000, header: false, uptimeMs: 1000000)
            .priority(atMs: t0, uptimeMs: 1000000)
            .frames(200, p: quiet)
            .stop();
        final p = planOf([a.file(firstSealedAtMs: t0 + 86400000)]);
        expect(orphansOf(p), isEmpty);
        expect(recordingsOf(p).single.frameCount, 200);
      });

      test('the uptime asleep within the span counts', () {
        // A 1-minute cap (3 minutes with grace): 164 s of audio, and 40 s asleep in 10 s naps.
        final a = Bin(t0).priority().frames(7500, p: quiet);
        for (var i = 0; i < 4; i++) {
          a.resume(10000).frames(50, p: quiet);
        }
        a.frames(500, p: quiet).stop();
        final p = planOf([a.file()], capMinutes: 1);
        expect(recordingsOf(p).map((r) => r.closeType), contains(CloseType.priorityCap));
      });

      test('each span counts from its own start', () {
        // A 1-minute cap (3 minutes with grace): spans of 150 s and 100 s.
        final a = Bin(t0).priority().frames(7500, p: quiet).stop().resume(1000);
        a.priority().frames(5000, p: quiet).stop();
        final p = planOf([a.file()], capMinutes: 1);
        expect(recordingsOf(p).map((r) => r.closeType), [CloseType.stop, CloseType.stop]);
      });

      test('before time sync, a shorter cap set since does not cut it', () {
        // Ten minutes recorded under a 120-minute cap; the cap set to 1 minute a day later;
        // the phone sealed the file the day after.
        final a = Bin(0, keySeconds: 1000, uptimeMs: 1000000, headerUtcMs: 0)
            .priority(atMs: 0)
            .frames(30000, p: quiet)
            .stop();
        final caps = CapHistory([(atMs: 0, minutes: 120), (atMs: t0 + 86400000, minutes: 1)]);
        final r = recordingsOf(planOf([a.file(firstSealedAtMs: t0 + 2 * 86400000)], caps: caps)).single;
        expect(r.closeType, CloseType.stop);
        expect(r.frameCount, 30000);
      });

      test('nor a clock set back at a resume', () {
        // A 1-minute cap (3 minutes with grace): 150 s of audio, a 10 s nap while the clock is
        // set back 60 s, then 40 s more: 200 s of device time, 140 s by the clock.
        final a = Bin(t0)
            .priority()
            .frames(7500, p: quiet)
            .resume(-50000, clockSet: true, elapsedMs: 10000)
            .frames(2000, p: quiet)
            .stop();
        final rs = recordingsOf(planOf([a.file()], capMinutes: 1));
        expect(rs.first.closeType, CloseType.priorityCap);
      });

      test('and a clock set back does not hold it off', () {
        // A 1-minute cap (3 minutes with its grace): 150 s of audio, then 40 s asleep while
        // the clock is set back 60 s. By the clock, the next file's 20 s end before the cap.
        final a = Bin(t0).priority().frames(7500, p: quiet);
        final b = a.next(gapMs: -20000, uptimeMs: a.uptimeMs + 40000).frames(1000, p: quiet);
        final p = planOf([a.file(), b.file()], capMinutes: 1);
        final r = recordingsOf(p).single;
        expect(r.closeType, CloseType.priorityCap);
        expect(r.pieces, [frames(a, 0, 7500)]);
      });
    });

    test('a Force inside it closes its recording, which is kept however short', () {
      final a = Bin(t0).priority().frames(50, p: quiet);
      final cut = a.length;
      a.frames(200, p: quiet).stop();
      final p = planOf([a.file()], boundaries: [PlanBoundary(BoundaryKind.force, a.key, cut)]);
      expect(recordingsOf(p).map((r) => r.frameCount), [50, 200]);
      expect(discardsOf(p), isEmpty);
    });

    test('ends with its session', () {
      final a = Bin(t0).priority().frames(200, p: quiet);
      final b = a.next(gapMs: 1000, session: 8, uptimeMs: 5000).frames(6000, p: quiet);
      final p = planOf([a.file(), b.file()]);
      expect(recordingsOf(p).single.closeType, CloseType.sessionEnd);
      expect(discardsOf(p).single.kind, DiscardKind.silenceOnly, reason: 'the new session is not force-captured');
    });
  });

  group('mute', () {
    test('mute on closes and keeps what was open; mute off makes the interval a muted discard', () {
      final a = Bin(t0).frames(20, p: quiet);
      final on = a.nextId;
      a.muteOn().muteOff(atMs: t0 + 60000);
      final p = planOf([a.file()]);
      expect(recordingsOf(p).single.closeType, CloseType.muteOn);
      final d = discardsOf(p).single;
      expect(d.kind, DiscardKind.muted);
      expect([d.startMs, d.endMs, d.muteOn], [t0 + 400, t0 + 60000, on]);
    });

    test('frames written while muted close with the interval, as one item', () {
      final a = Bin(t0);
      final on = a.nextId;
      a.muteOn().frames(100).muteOff().resume(30000).frames(10, p: speech);
      final d = discardsOf(planOf([a.file()])).single;
      expect(d.kind, DiscardKind.muted);
      expect([d.muteOn, d.startMs, d.endMs, d.audioMs], [on, t0, t0 + 2000, 2000]);
      expect(d.spans, [FrameSpan(a.key, 0, 100)]);
    });

    test('a new session ends the interval at its start', () {
      final a = Bin(t0).frames(10, p: speech).muteOn();
      final b = a.next(gapMs: 30000, session: 8, uptimeMs: 5000).frames(10, p: speech);
      final d = discardsOf(planOf([a.file(), b.file()])).single;
      expect(d.endMs, t0 + 200 + 30000);
      expect(d.closeType, CloseType.sessionEnd);
    });

    test('mute on ends a tap window', () {
      final a = Bin(t0).tap().frames(10, p: speech).muteOn().muteOff().resume(1000).frames(6000, p: quiet);
      expect(discardsOf(planOf([a.file()])).single.kind, DiscardKind.silenceOnly);
    });
  });

  group('without Silero', () {
    test('every frame is speech, so nothing is discarded as noise', () {
      final a = Bin(t0).frames(10, p: quiet).resume(130000).frames(10);
      final r = recordingsOf(planOf([a.file(hasVad: false)])).single;
      expect(r.silero, isFalse);
      expect(r.pieces, [frames(a, 0, 10)]);
    });

    test('a run of tiny resume splits coalesces until the next boundary', () {
      final a = Bin(t0);
      for (var i = 0; i < 6; i++) {
        a.frames(10).resume(2000);
      }
      a.frames(10).stop().resume(2000).frames(10).resume(2000).frames(10);
      final p = planOf([a.file()], policy: manualPolicy, boundaries: [a.force]);
      expect(recordingsOf(p).map((r) => r.closeType), [
        CloseType.resumeGap,
        CloseType.resumeGap,
        CloseType.stop,
        CloseType.resumeGap,
        CloseType.force,
      ]);
      expect(recordingsOf(p)[2].frameCount, 50, reason: 'the third tiny split on coalesces');
    });
  });

  group('length', () {
    test('the length cap cuts and carries on', () {
      final a = Bin(t0).frames(4000, p: speech);
      const capped = PlanPolicy(
          vadEnabled: true, speechThreshold: 0.5, silenceSplitMs: 120000, minSpeechMs: 3000, maxChunkMs: 60000);
      final p = planOf([a.file()], policy: capped);
      expect(recordingsOf(p).single.pieces, [frames(a, 0, 3000)]);
      expect(recordingsOf(p).single.closeType, CloseType.cap);
      expect(p.open.single.frameCount, 1000);
    });

    test('no recording is longer than a day; the rest is the next part', () {
      final a = Bin(t0);
      for (var i = 0; i < 900; i++) {
        a.frames(1).resume(100000);
      }
      a.frames(1);
      final rs = recordingsOf(planOf([a.file(hasVad: false)], boundaries: [a.force]));
      expect(rs.first.closeType, CloseType.dayLimit);
      expect(rs.first.durationMs, lessThan(dayLimitMs));
      expect(rs.fold<int>(0, (n, r) => n + r.frameCount), 901);
    });

    test('the day limit cuts at the frame that reaches it', () {
      final a = Bin(t0);
      for (var i = 0; i < 863; i++) {
        a.frames(1).resume(100000);
      }
      a.frames(1).resume(98000).frames(200);
      final rs = recordingsOf(planOf([a.file(hasVad: false)], boundaries: [a.force]));
      expect(rs.first.closeType, CloseType.dayLimit);
      expect(rs.first.durationMs, dayLimitMs);
      expect(rs.first.pieces.last, isA<FramesPiece>());
    });
  });

  group('policy', () {
    test('each file is cut by the policy it was recorded under; a change closes', () {
      final a = Bin(t0).frames(6000, p: quiet);
      final b = a.next().frames(6000, p: quiet);
      final history = PolicyHistory(autoPolicy, [(atUtcSeconds: b.key.timerStart, before: manualPolicy)]);
      final p = planOf([a.file(), b.file()], policies: history);
      final r = recordingsOf(p).single;
      expect(r.closeType, CloseType.policy);
      expect(r.manual, isTrue);
      expect(discardsOf(p).single.kind, DiscardKind.silenceOnly);
    });

    test('a file cut without Silero next to one cut with it is a change of rules too', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(200, p: speech);
      final p = planOf([a.file(), b.file(hasVad: false)], boundaries: [b.force]);
      expect(recordingsOf(p).map((r) => (r.closeType, r.silero)), [(CloseType.policy, true), (CloseType.force, false)]);
    });

    test('a file the Omi could not date predates every switch', () {
      expect(
          const PolicyHistory(autoPolicy, [(atUtcSeconds: 1700000000, before: manualPolicy)])
              .forFile(const RawFileKey(5000, 7)),
          manualPolicy);
    });
  });

  group('walls and late audio', () {
    test('a published tap still forces the late audio around it to be kept', () {
      // A arrives after B's tap was published as an orphan: the tap still counts.
      final a = Bin(t0).frames(50, p: quiet);
      final b = a.next().tap().resume(130000).frames(10, p: speech);
      final published = planOf([b.file()], missing: [a.key], waived: {a.key});
      final late = planOf([a.file(), b.file()], owned: ownershipOf(published.items));
      final r = recordingsOf(late).single;
      expect(r.pieces, [frames(a, 0, 50)]);
      expect(r.markers, isEmpty, reason: 'the tap is listed once, by its orphan record');
    });

    test('a published tap opens no conversation of its own', () {
      // The tap closes A's recording; B's quiet audio after it is not the tap's.
      final a = Bin(t0).frames(200, p: speech).tap();
      final b = a.next(gapMs: 200000).frames(100, p: quiet).resume(130000).frames(10);
      final full = planOf([a.file(), b.file()]);
      expect(full.items.map((i) => i.closeType), [CloseType.fileGap, CloseType.resumeGap]);
      final again = planOf([a.file(), b.file()], owned: ownershipOf([full.items.first]));
      expect(again.items, full.items.skip(1));
      expect(discardsOf(again).single.kind, DiscardKind.noisePreSplit);
    });

    group('a receipt is walked as its card would be, everything owned', () {
      /// B is published while A is missing and given up on; then A arrives.
      (Plan, Plan) cardAndReceipt(Bin a, Bin b) {
        final published = planOf([b.file()], missing: [a.key], waived: {a.key}, boundaries: [b.force]);
        final owned = ownershipOf(published.items);
        expect(releasable(b.file(), owned), isTrue);
        return (planOf([a.file(), b.file()], owned: owned), planOf([a.file(), b.receipt()], owned: owned));
      }

      test('its leading tap still forces the audio before it to be kept', () {
        final a = Bin(t0).frames(50, p: quiet);
        final (card, receipt) = cardAndReceipt(a, a.next().tap().resume(130000).frames(200, p: speech));
        expect(receipt.items, card.items);
        expect(recordingsOf(receipt).single.pieces, [frames(a, 0, 50)]);
      });

      test('the gap to it is padded as before its card was released', () {
        final a = Bin(t0).frames(200, p: speech);
        final (card, receipt) = cardAndReceipt(a, a.next(gapMs: 20000).frames(200, p: speech));
        expect(receipt.items, card.items);
        expect(recordingsOf(receipt).single.durationMs, 24000);
      });

      test('a muted interval crossing it is still one item', () {
        final a = Bin(t0).frames(200, p: speech);
        final on = a.nextId;
        a.muteOn().frames(2);
        final (card, receipt) = cardAndReceipt(a, a.next().muteOff().resume(30000).frames(200, p: speech));
        expect(receipt.items, card.items);
        final muted = discardsOf(receipt).where((d) => d.kind == DiscardKind.muted).single;
        expect([
          muted.muteOn,
          muted.spans
        ], [
          on,
          [FrameSpan(a.key, 200, 202)]
        ]);
      });

      test('a file of markers only is no wall', () {
        // B holds a tap and a stop and no audio; its tap was published as an orphan.
        final a = Bin(t0).frames(50, p: quiet);
        final b = a.next().tap().stop();
        final c = b.next().resume(5000).frames(200, p: speech);
        final owned = ownershipOf(planOf([b.file()], missing: [a.key], waived: {a.key}).items);
        expect(releasable(b.file(), owned), isTrue);
        final receipt = planOf([a.file(), b.receipt(), c.file()], owned: owned, boundaries: [c.force]);
        expect(receipt.items, planOf([a.file(), b.file(), c.file()], owned: owned, boundaries: [c.force]).items);
        expect(recordingsOf(receipt).first.closeType, CloseType.stop,
            reason: "A runs on to B's stop, forced by its tap");
      });

      test('a file the Omi could not date keeps the date the phone first sealed it at', () {
        // Before the clock was set: names count uptime, markers carry no date.
        final a = Bin(0, header: false, keySeconds: 5000).frames(200, p: speech).muteOn(atMs: 0);
        final b = Bin(0, header: false, keySeconds: 5300).muteOff(atMs: 0).resume(5000).frames(200, p: speech);
        final aFile = a.file(firstSealedAtMs: t0);
        final bFile = b.file(firstSealedAtMs: t0 + 300000);
        final owned = ownershipOf(planOf([aFile]).items);
        expect(releasable(aFile, owned), isTrue);
        final card = planOf([aFile, bFile], owned: owned, boundaries: [b.force]);
        final receipt = planOf([receiptOf(aFile), bFile], owned: owned, boundaries: [b.force]);
        expect(receipt.items, card.items);
        expect(discardsOf(receipt).single.startMs, t0 + 4000, reason: 'the mute is dated from A');
      });

      test('it keeps whether its card had VAD: the flood guard depends on it', () {
        // B, cut without Silero, ends in a flood of tiny resume splits that C carries on.
        final a = Bin(t0).frames(200, p: speech);
        final b = a.next();
        for (var i = 0; i < 3; i++) {
          b.frames(10).resume(130000);
        }
        b.frames(10);
        final c = b.next().frames(10).resume(130000).frames(10);
        final owned = ownershipOf(
            planOf([b.file(hasVad: false)], missing: [a.key], waived: {a.key}, boundaries: [b.force]).items);
        Plan withB(PlanFile bFile) =>
            planOf([a.file(), bFile, c.file(hasVad: false)], owned: owned, boundaries: [c.force]);
        final card = withB(b.file(hasVad: false));
        expect(withB(b.receipt(hasVad: false)).items, card.items);
        expect(recordingsOf(card).last.frameCount, 20, reason: "C's resume coalesces");
        expect(withB(b.receipt(hasVad: true)).items, isNot(card.items), reason: 'the scenario depends on it');
      });
    });

    test('a released file is known from its receipt: not a hole, and its markers still count', () {
      final a = Bin(t0).frames(200, p: speech).stop();
      // No Force here: one would waive A whether or not its receipt counted.
      final b = a.next().frames(20).resume(5000).frames(200, p: speech).resume(130000).frames(10);
      final aPlan = planOf([a.file()]);
      final p = planOf([a.receipt(), b.file()], owned: ownershipOf(aPlan.items));
      expect(p.stoppedAt, isEmpty);
      expect(discardsOf(p).single.kind, DiscardKind.afterStop, reason: "A's stop latches B's first frames");
      expect(recordingsOf(p).single.pieces, [frames(b, 20, 220)]);
    });

    test('publishing what closed leaves the rest of the plan as it was', () {
      final a = Bin(t0).frames(200, p: speech).resume(130000).frames(300, p: speech).resume(130000).frames(10);
      final full = planOf([a.file()]);
      final rest = planOf([a.file()], owned: ownershipOf([full.items.first]));
      expect(rest.items, full.items.skip(1));
      expect(rest.open.single.frameCount, full.open.single.frameCount);
    });

    test('a file arriving before what is not yet published joins in place', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(200, p: speech);
      final c = b.next().frames(200, p: speech);
      final before = planOf([a.file(), c.file()], missing: [b.key]);
      expect(before.items, isEmpty);
      expect(before.stoppedAt.values.single, PlanPosition(b.key, -1));
      expect(
          before.describe(),
          allOf(startsWith('0 recording(s), 0 discard(s)'), contains('open from'),
              contains('waits for a hole at ${b.key.stem}@-1')),
          reason: 'the debug log line');
      final after = planOf([a.file(), b.file(), c.file()], boundaries: [c.force]);
      expect(recordingsOf(after).single.pieces, [frames(a, 0, 200), frames(b, 0, 200), frames(c, 0, 200)]);
      expect(after.describe(), startsWith('1 recording(s) ['));
    });

    test('given up on, a file is a wall; arriving later between published audio, it is an island', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(200, p: speech);
      final c = b.next().frames(200, p: speech);
      final given = planOf([a.file(), c.file()], missing: [b.key], waived: {b.key}, boundaries: [c.force]);
      expect(recordingsOf(given).map((r) => r.closeType), [CloseType.wall, CloseType.force]);
      final island = planOf([a.file(), b.file(), c.file()], owned: ownershipOf(given.items), boundaries: [c.force]);
      final r = recordingsOf(island).single;
      expect(r.pieces, [frames(b, 0, 200)]);
      expect(r.closeType, CloseType.wall);
    });

    test('a set-aside file is a wall, but its markers still govern its neighbours', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(50, p: speech).stop();
      final c = b.next().frames(30, p: speech);
      final p = planOf([a.file(), b.file(setAside: true), c.file()], boundaries: [c.force]);
      expect(recordingsOf(p).single.closeType, CloseType.wall);
      final d = discardsOf(p).single;
      expect(d.kind, DiscardKind.afterStop);
      expect(d.spans, [FrameSpan(c.key, 0, 30)]);
    });
  });

  group('holes', () {
    test('Force inside a file without its card waives only what came before it', () {
      final a = Bin(t0).frames(200, p: speech);
      final force = a.force;
      a.stop();
      final b = a.next().frames(200, p: speech);
      final p = planOf([a.file(withAudio: false), b.file()], boundaries: [force]);
      expect(p.stoppedAt[7], PlanPosition(a.key, force.offset), reason: 'the stop after Force is not read');
      expect(p.items, isEmpty);
    });

    test('which sessions ended is the Omi\'s evidence, not the order of the files\' dates', () {
      final a = Bin(t0 + 7200000).frames(200, p: speech);
      final hole = a.next(gapMs: 1000);
      final beyond = Bin(t0, keySeconds: hole.key.timerStart + 100).frames(10); // a corrected clock
      final other = Bin(t0 + 3600000, session: 8).frames(200, p: speech);
      const ended = {8: null};
      final without = planOf([a.file(), other.file()], missing: [hole.key], endedSessions: ended);
      final withBeyond = planOf([a.file(), beyond.file(), other.file()], missing: [hole.key], endedSessions: ended);
      expect(withBeyond.items, without.items);
      expect(recordingsOf(without).single.sessionId, 8);
    });

    test('rebuild end closes what is open and waives the holes before it, as Force does', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(200, p: speech);
      final p =
          planOf([b.file()], missing: [a.key], boundaries: [PlanBoundary(BoundaryKind.rebuildEnd, b.key, b.length)]);
      expect(recordingsOf(p).single.closeType, CloseType.rebuildEnd);
      expect(p.stoppedAt, isEmpty);
    });

    test('a session is read only up to a file still on the Omi; other sessions go on', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(200, p: speech).resume(130000).frames(10, p: speech);
      final other = Bin(t0 + 3600000, session: 9).frames(200, p: speech).resume(130000).frames(10);
      final p = planOf([b.file(), other.file()], missing: [a.key]);
      expect(p.stoppedAt[7], PlanPosition(a.key, -1));
      expect(recordingsOf(p).single.sessionId, 9);
    });

    test('the unread rest of a file still arriving is a hole', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = Bin(t0 + 3600000, session: 9).frames(10);
      final p = planOf([a.file(lifecycle: SourceLifecycle.receiving), b.file()]);
      expect(p.items, isEmpty, reason: 'its session cannot end: more of it may come');
      expect(p.stoppedAt[7], PlanPosition(a.key, a.length));
    });

    test('a file here without its card is a hole', () {
      final a = Bin(t0).frames(200, p: speech).resume(130000).frames(10);
      final p = planOf([a.file(withAudio: false)]);
      expect(p.items, isEmpty);
      expect(p.stoppedAt[7], PlanPosition(a.key, -1));
    });

    test('Force waives the holes before it and closes at its end', () {
      final a = Bin(t0).frames(200, p: speech);
      final b = a.next().frames(200, p: speech);
      final p = planOf([b.file()], missing: [a.key], boundaries: [b.force]);
      expect(recordingsOf(p).single.closeType, CloseType.force);
      expect(p.stoppedAt, isEmpty);
    });

    test('Force on a file still arriving closes what is open, and its rest comes after', () {
      final a = Bin(t0).frames(200, p: speech);
      final force = a.force;
      a.frames(100, p: speech);
      final p = planOf([a.file(lifecycle: SourceLifecycle.receiving)], boundaries: [force]);
      expect(recordingsOf(p).single.pieces, [frames(a, 0, 200)]);
      expect(p.stoppedAt[7], PlanPosition(a.key, a.length));
      expect(p.open.single.frameCount, 100);
    });
  });

  test('a file the Omi could not date is dated by when it was first sealed', () {
    final a = Bin(0, header: false, keySeconds: 5000).frames(200, p: speech);
    final r = recordingsOf(planOf([a.file(firstSealedAtMs: t0)], boundaries: [a.force])).single;
    expect(r.startMs, t0);
    expect(r.derivedTime, isTrue);
  });

  // Each differs from today's processor on purpose (RECORDINGS_PIPELINE_REDESIGN.md §10);
  // the equivalence test keeps its timelines clear of them.
  group('changed on purpose', () {
    test('a recording starts at its first frame, not at a tap before it', () {
      // The tap wakes the Omi; its resume comes 5 s later.
      final a = Bin(t0).frames(200, p: speech).stop();
      final tap = a.nextId;
      a.tap().resume(5000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).last;
      expect(r.startMs, t0 + 9000);
      expect(r.markers.single, PlannedMarker(tap, t0 + 4000, 0, false));
    });

    test('a new session is a boundary even inside a tap window', () {
      final a = Bin(t0).frames(200, p: speech).tap().frames(10, p: speech);
      final b = a.next(gapMs: 20000, session: 8, uptimeMs: 5000).frames(200, p: speech);
      final p = planOf([a.file(), b.file()], boundaries: [b.force]);
      expect(recordingsOf(p).map((r) => r.sessionId), [7, 8]);
    });

    test('a tap after a resume is dated where it is, not before the gap', () {
      final a = Bin(t0).frames(200, p: speech).resume(130000);
      final tap = a.nextId;
      a.tap().frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).last;
      expect(r.markers.single, PlannedMarker(tap, t0 + 134000, 0, false));
      expect(r.startMs, t0 + 134000);
    });

    test('a second resume with no audio between pads only its own time', () {
      final a = Bin(t0).frames(200, p: speech).resume(30000).resume(30000).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.pieces, [frames(a, 0, 200), const SilencePiece(30000), const SilencePiece(30000), frames(a, 200, 400)]);
      expect(r.durationMs, a.clockMs - t0);
    });

    test('a clockless resume after another is dated from that one', () {
      final a = Bin(t0).frames(200, p: speech).resume(30000).resume(30000, clockless: true).frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).single;
      expect(r.durationMs, a.clockMs - t0);
    });

    test('frames after a stop take their time', () {
      final a = Bin(t0).frames(200, p: speech).stop().frames(50).tap().frames(200, p: speech);
      final r = recordingsOf(planOf([a.file()], boundaries: [a.force])).last;
      expect(r.startMs, t0 + 250 * frameMs);
    });

    test('a second mute-on while muted keeps the interval the first one opened', () {
      final a = Bin(t0);
      final first = a.nextId;
      a.muteOn().muteOn(atMs: t0 + 5000).muteOff(atMs: t0 + 9000);
      final d = discardsOf(planOf([a.file()])).single;
      expect([d.muteOn, d.startMs, d.endMs], [first, t0, t0 + 9000]);
    });

    test('a conversation starting inside a tap window is kept, whatever closed the one before', () {
      // The priority cap (1 min + 2 min grace) falls 20 ms before the window ends.
      final a = Bin(t0).priority().frames(6501, p: quiet).tap().frames(2500, p: quiet).frames(100, p: quiet);
      final p = planOf([a.file()], capMinutes: 1, boundaries: [a.force]);
      expect(recordingsOf(p).map((r) => r.closeType), [CloseType.priorityCap, CloseType.force]);
    });

    test('a tap left as an orphan still protects the audio after it', () {
      final a = Bin(t0).frames(200, p: speech).stop().resume(2000);
      final force = a.force;
      a.tap();
      final tapAt = a.length;
      final b = Bin(t0 + 6000).frames(100, p: quiet);
      final orphaned = planOf([a.file()], boundaries: [PlanBoundary(BoundaryKind.force, a.key, tapAt)]);
      expect(orphansOf(orphaned), hasLength(1));
      final later = planOf([a.file(), b.file()],
          owned: ownershipOf(orphaned.items), boundaries: [PlanBoundary(BoundaryKind.force, a.key, tapAt), b.force]);
      expect(recordingsOf(later).single.pieces, [frames(b, 0, 100)], reason: 'kept, though it is all quiet');
      expect(force.offset, lessThan(tapAt));
    });

    test('Priority Recording: a long resume gap closes a span opened in this very plan', () {
      // Today only a span restored from an earlier run could close this way.
      final a = Bin(t0).priority().frames(200, p: quiet).resume(60000).frames(10, p: quiet);
      expect(recordingsOf(planOf([a.file()])).single.closeType, CloseType.priorityStale);
    });
  });
}
