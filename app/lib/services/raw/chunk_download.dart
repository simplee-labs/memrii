// One native transfer into a sealed chunk (RECORDINGS_PIPELINE_REDESIGN.md §1).
//
// The transfer writes a new part file starting where the sealed chunks end, and the part
// is sealed whatever way the transfer stops, keeping exactly the bytes the receiver
// accepted. Nothing already sealed is truncated or rewritten: a realignment that needs
// the Omi to resend earlier bytes gets them compared and skipped instead. Not switched on
// yet (see raw_chunks.dart).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/raw/raw_chunks.dart';

/// Starts the native transfer of a part: [appendOffset] is the logical offset of the
/// part's first byte, [overlap] the sealed bytes the Omi is asked to resend before it.
typedef NativeChunkTransfer = Future<StorageChunkResult> Function(int appendOffset, String partPath, Uint8List overlap);

/// The Omi resent bytes that differ from what the phone has sealed: its copy is not the
/// one the phone holds. Nothing more may be appended to this file.
class SourceMismatch implements Exception {
  final RawFileKey key;
  final int? offset;
  SourceMismatch(this.key, this.offset);
  @override
  String toString() => 'SourceMismatch: ${key.rel} differs from the Omi at byte $offset';
}

/// The Omi's file ends before the phone's sealed end, so the requested resend could not
/// all be compared. Mount recovery after a crash can shorten the Omi's newest closed
/// segment; the phone's longer copy stands (the file's lifecycle decides what follows).
class SourceShorter implements Exception {
  final RawFileKey key;
  final int? receivedEnd;
  SourceShorter(this.key, this.receivedEnd);
  @override
  String toString() => 'SourceShorter: the Omi\'s ${key.rel} ends at $receivedEnd';
}

class ChunkTransfer {
  /// The chunk sealed by this transfer, or null when it accepted nothing.
  final RawChunk? chunk;

  /// The logical file's length after sealing: where the next transfer resumes.
  final int sealedLength;

  const ChunkTransfer(this.chunk, this.sealedLength);
}

class ChunkDownloader {
  final RawChunkStore store;

  ChunkDownloader(this.store);

  /// One transfer per file at a time, across downloaders of the same store: the sealed
  /// length a transfer starts from must still be the file's end when it seals.
  static final Map<String, Future<void>> _running = {};

  /// The most a transfer may ask the Omi to resend: the realignment after a repeated
  /// integrity gap moves the start by about this much (SDCardWalSync.integrityRealignBytes).
  static const maxResend = 220;

  /// Downloads the rest of [key] after its sealed chunks. With [resend] > 0 the Omi is
  /// asked to start that many bytes earlier, so it cuts packets on different boundaries;
  /// those bytes are compared with the sealed copy and not written again.
  ///
  /// The part is sealed on success and on failure alike; a failure is then rethrown
  /// ([SourceMismatch] for resent bytes that differ, [SourceShorter] for a file that ends
  /// on the Omi before the sealed end, the platform error otherwise), and the next
  /// transfer resumes after whatever was sealed. Transfers of one file run one at a time.
  Future<ChunkTransfer> download(
    RawFileKey key, {
    required NativeChunkTransfer transfer,
    int resend = 0,
    int? advertisedLength,
  }) {
    if (resend < 0 || resend > maxResend) throw ArgumentError.value(resend, 'resend', 'must be 0..$maxResend');
    final slot = '${store.documentsPath}|${key.rel}';
    final previous = _running[slot] ?? Future<void>.value();
    final result = previous.then((_) => _download(key, transfer, resend, advertisedLength));
    final tail = result.then((_) {}, onError: (_) {});
    _running[slot] = tail;
    unawaited(tail.whenComplete(() {
      if (identical(_running[slot], tail)) _running.remove(slot);
    }));
    return result;
  }

  Future<ChunkTransfer> _download(
      RawFileKey key, NativeChunkTransfer transfer, int resend, int? advertisedLength) async {
    final sealed = await store.load(key);
    final appendOffset = sealed.length;
    final from = resend > appendOffset ? 0 : appendOffset - resend;
    final overlap = await sealed.read(from, appendOffset);
    final part = store.partFile(key, appendOffset);
    if (await part.exists()) {
      // Parts left by a crash are sealed by RawChunkStore.recover before any download.
      throw RawFileInconsistent('${key.rel}: an unsealed part is already at $appendOffset');
    }
    await part.parent.create(recursive: true);

    int acceptedEnd;
    bool echoed;
    Object? failure;
    StackTrace? failureTrace;
    try {
      final result = await transfer(appendOffset, part.path, overlap);
      acceptedEnd = result.acceptedEnd;
      echoed = result.echoedAck;
    } on PlatformException catch (e, st) {
      final details = e.details;
      final reported = details is Map ? details['acceptedEnd'] : null;
      // Without a reported end nothing in the part is known to be accepted.
      acceptedEnd = reported is int ? reported : appendOffset;
      echoed = details is Map && details['echoedAck'] == true;
      int? detail(String name) => details is Map && details[name] is int ? details[name] as int : null;
      failure = switch (e.code) {
        'storage-mismatch' => SourceMismatch(key, detail('offset')),
        'storage-short-source' => SourceShorter(key, detail('receivedEnd')),
        _ => e,
      };
      failureTrace = st;
    } catch (e, st) {
      acceptedEnd = appendOffset;
      echoed = false;
      failure = e;
      failureTrace = st;
    }

    final chunk = await store.seal(
      key,
      appendOffset: appendOffset,
      keepLength: acceptedEnd - appendOffset,
      provenance: echoed ? ChunkProvenance.echoed : ChunkProvenance.uncorrelated,
      advertisedLength: advertisedLength,
    );
    if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
    return ChunkTransfer(chunk, chunk?.end ?? appendOffset);
  }
}
