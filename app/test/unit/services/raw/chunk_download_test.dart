import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/raw/chunk_download.dart';
import 'package:omi/services/raw/raw_chunks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RawChunkStore store;
  late ChunkDownloader downloader;
  const key = RawFileKey(1789100000, 7);

  setUp(() {
    root = Directory.systemTemp.createTempSync('chunk_download_');
    store = RawChunkStore(root.path);
    downloader = ChunkDownloader(store);
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The Omi's copy of the file.
  final source = Uint8List.fromList([for (var i = 0; i < 300; i++) (i * 7) % 256]);

  /// A native transfer that writes [source] from the append offset up to [writeTo] into
  /// the part, then answers with [answer] (or throws [error]).
  NativeChunkTransfer native({
    required int writeTo,
    int? acceptedEnd,
    bool echoed = true,
    PlatformException? error,
    void Function(int appendOffset, Uint8List overlap)? onCall,
  }) =>
      (appendOffset, partPath, overlap) async {
        onCall?.call(appendOffset, overlap);
        await File(partPath).writeAsBytes(source.sublist(appendOffset, writeTo), flush: true);
        if (error != null) throw error;
        return StorageChunkResult(acceptedEnd: acceptedEnd ?? writeTo, echoedAck: echoed);
      };

  test('a complete transfer seals one echoed chunk holding the Omi\'s bytes', () async {
    final result = await downloader.download(key, transfer: native(writeTo: 300), advertisedLength: 300);
    expect(result.sealedLength, 300);
    final file = await store.load(key);
    expect(file.chunks.single.provenance, ChunkProvenance.echoed);
    expect(await file.read(0, 300), source);
    expect(file.advertisedLength, 300);
  });

  test('the next transfer resumes after the sealed chunks, as a continuation', () async {
    await downloader.download(key, transfer: native(writeTo: 120));
    int? askedAt;
    await downloader.download(key, transfer: native(writeTo: 300, onCall: (at, _) => askedAt = at));
    expect(askedAt, 120);
    final file = await store.load(key);
    expect(file.chunks.map((c) => c.offset), [0, 120]);
    expect(await file.read(0, 300), source);
  });

  test('a resend passes the sealed bytes it covers and rewrites nothing', () async {
    await downloader.download(key, transfer: native(writeTo: 120));
    Uint8List? overlap;
    await downloader.download(key, resend: 20, transfer: native(writeTo: 200, onCall: (_, o) => overlap = o));
    expect(overlap, source.sublist(100, 120));
    final file = await store.load(key);
    expect(file.chunks.map((c) => (c.offset, c.length)), [(0, 120), (120, 80)]);
    expect(await file.read(0, 200), source.sublist(0, 200));
  });

  test('a failed transfer seals exactly what the receiver accepted, then rethrows', () async {
    final failure = PlatformException(code: 'storage-integrity', message: 'gap', details: {
      'expectedOffset': 90,
      'acceptedEnd': 90,
      'echoedAck': true,
    });
    await expectLater(downloader.download(key, transfer: native(writeTo: 100, error: failure)), throwsA(same(failure)));
    final file = await store.load(key);
    expect(file.length, 90);
    expect(await file.read(0, 90), source.sublist(0, 90));
    expect(file.chunks.single.provenance, ChunkProvenance.echoed);
  });

  test('a failure that reports no accepted end keeps nothing from the part', () async {
    final failure = PlatformException(code: 'channel-error', message: 'lost');
    await expectLater(downloader.download(key, transfer: native(writeTo: 100, error: failure)), throwsA(same(failure)));
    expect((await store.load(key)).length, 0);
    expect(await store.partFile(key, 0).exists(), isFalse);
  });

  test('resent bytes that differ end the transfer as a source mismatch', () async {
    await downloader.download(key, transfer: native(writeTo: 120));
    final mismatch = PlatformException(code: 'storage-mismatch', message: 'differs', details: {
      'offset': 110,
      'acceptedEnd': 120,
      'echoedAck': true,
    });
    await expectLater(
      downloader.download(key, resend: 20, transfer: native(writeTo: 120, error: mismatch)),
      throwsA(isA<SourceMismatch>().having((e) => e.offset, 'offset', 110)),
    );
    expect((await store.load(key)).chunks.length, 1, reason: 'nothing more was sealed');
  });

  test('an ACK without the timestamp echo seals an uncorrelated chunk', () async {
    await downloader.download(key, transfer: native(writeTo: 50, echoed: false));
    expect((await store.load(key)).chunks.single.provenance, ChunkProvenance.uncorrelated);
  });

  test('a leftover part must be recovered before another transfer starts', () async {
    final part = store.partFile(key, 0);
    await part.parent.create(recursive: true);
    await part.writeAsBytes([1, 2, 3]);
    var called = false;
    await expectLater(
      downloader.download(key, transfer: (a, p, o) async {
        called = true;
        return StorageChunkResult(acceptedEnd: 0, echoedAck: true);
      }),
      throwsA(isA<RawFileInconsistent>()),
    );
    expect(called, isFalse);
  });

  test('a resend is limited to the realignment distance', () {
    expect(() => downloader.download(key, transfer: native(writeTo: 1), resend: 221), throwsArgumentError);
  });

  test('two transfers of one file run one after the other, never from the same end', () async {
    final starts = <int>[];
    final first = downloader.download(key, transfer: native(writeTo: 100, onCall: (at, _) => starts.add(at)));
    final second =
        ChunkDownloader(store).download(key, transfer: native(writeTo: 160, onCall: (at, _) => starts.add(at)));
    await Future.wait([first, second]);
    expect(starts, [0, 100]);
    final file = await store.load(key);
    expect(file.chunks.map((c) => (c.offset, c.length)), [(0, 100), (100, 60)]);
    expect(await file.read(0, 160), source.sublist(0, 160));
  });

  test('a file that ends on the Omi before the sealed end is reported as a shorter source', () async {
    await downloader.download(key, transfer: native(writeTo: 120));
    final short = PlatformException(code: 'storage-short-source', message: 'ends', details: {
      'receivedEnd': 110,
      'acceptedEnd': 120,
      'echoedAck': true,
    });
    await expectLater(
      downloader.download(key, resend: 20, transfer: native(writeTo: 120, error: short)),
      throwsA(isA<SourceShorter>().having((e) => e.receivedEnd, 'receivedEnd', 110)),
    );
    expect((await store.load(key)).length, 120, reason: 'the phone keeps its longer copy');
  });

  group('the Pigeon channel', () {
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.omi_pigeon.BleHostApi.downloadStorageChunk',
      BleHostApi.pigeonChannelCodec,
    );
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, null));

    test('sends the arguments in order and decodes the result', () async {
      List<Object?>? sent;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        channel,
        (message) async {
          sent = (message! as List).cast<Object?>();
          return [StorageChunkResult(acceptedEnd: 140, echoedAck: true)];
        },
      );
      final result =
          await BleHostApi().downloadStorageChunk('AA:BB', 3, 120, 1789100000, '/p', Uint8List.fromList([5, 6]));
      expect(sent!.sublist(0, 5), ['AA:BB', 3, 120, 1789100000, '/p']);
      expect(sent![5], [5, 6]);
      expect((result.acceptedEnd, result.echoedAck), (140, true));
    });

    test('a native failure arrives with its details', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        channel,
        (message) async => [
          'storage-mismatch',
          'differs',
          {'offset': 6, 'acceptedEnd': 8, 'echoedAck': false}
        ],
      );
      await expectLater(
        BleHostApi().downloadStorageChunk('AA:BB', 0, 8, 1, '/p', Uint8List(0)),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'storage-mismatch')
            .having((e) => e.details, 'details', {'offset': 6, 'acceptedEnd': 8, 'echoedAck': false})),
      );
    });
  });
}
