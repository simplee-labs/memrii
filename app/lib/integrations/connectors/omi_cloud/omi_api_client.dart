import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:omi/models/recordings/recording_filename.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

class OmiSyncResult {
  final bool success;
  final String status;
  final List<String> newConversationIds;
  final List<String> updatedConversationIds;
  final int successfulSegments;
  final int failedSegments;
  final String? error;

  OmiSyncResult({
    required this.success,
    required this.status,
    this.newConversationIds = const [],
    this.updatedConversationIds = const [],
    this.successfulSegments = 0,
    this.failedSegments = 0,
    this.error,
  });

  List<String> get allConversationIds => {...newConversationIds, ...updatedConversationIds}.toList();

  @override
  String toString() =>
      'OmiSyncResult(success: $success, status: $status, new: ${newConversationIds.length}, updated: ${updatedConversationIds.length}, okSeg: $successfulSegments, failSeg: $failedSegments)';
}

/// Outcome of syncing one chunk, distinguishing a server *verdict* from the
/// client merely giving up waiting — the two used to be conflated, so a slow
/// (but still-running) job got abandoned and re-uploaded, deepening the backlog.
enum OmiJobStatus {
  /// Server finished the job (success or per-segment partial). Mark chunk synced.
  completed,

  /// Server ran the job and rejected it for a content/processing reason. The
  /// chunk needs a fresh upload to retry.
  failed,

  /// Server is overloaded or its gateway timed out — a 502/503/504 on submit, or
  /// a job whose failure is a transient backend-unavailable/gateway-timeout
  /// signal. NOT a content failure: the chunk re-uploads fresh, but only after an
  /// (exponential) backoff so we don't hammer a struggling backend.
  busy,

  /// Job is still `queued`/`processing`, or our poll budget elapsed while it was
  /// still alive. NOT a failure — keep the job id and reattach on the next run.
  pending,

  /// The job id no longer exists server-side (404). Re-upload fresh.
  gone,
}

class OmiJobOutcome {
  final OmiJobStatus status;

  /// The server job id, when one exists — persisted by the caller so a later
  /// run can reattach (poll) instead of re-uploading.
  final String? jobId;

  /// Parsed result when [status] is [OmiJobStatus.completed].
  final OmiSyncResult? result;

  /// Server-reported error when [status] is [OmiJobStatus.failed].
  final String? error;

  OmiJobOutcome(this.status, {this.jobId, this.result, this.error});
}

class OmiApiClient {
  static final _credentialLock = Mutex();
  static int _authGeneration = 0;
  static int get credentialGeneration => _authGeneration;
  // The server runs the full decode→VAD→Parakeet-STT pipeline on each uploaded
  // segment, so we split each bin into bounded chunks with sequential timestamps;
  // the server stitches consecutive timestamps back into one conversation. Each
  // chunk is uploaded in its own request, serialized (see buildSegments /
  // syncSegment), so the server only ever runs one Parakeet transcription at a
  // time — handing it many segments in one job made it fan them out in parallel
  // and 503 the STT backend.
  //
  // Two backend limits pull chunk size in opposite directions:
  //   1. Per-request transcribe timeout — the /v2/transcribe call sits behind a
  //      gateway that 504s if one segment's STT runs too long. A 5-min chunk was
  //      observed taking ~97 s of STT, close enough to the gateway limit to 504.
  //   2. Queue wait — jobs sit in `queued` waiting for a free Parakeet worker
  //      (seen at 4+ min), independent of chunk size, so more/smaller chunks add
  //      to the job count without shrinking each job's wait.
  // We bias toward (1): 3-min chunks keep each transcribe call well under the
  // gateway timeout, at the cost of a few more jobs. The queue-wait cost of those
  // extra jobs is bounded because chunks upload strictly serially with job-id
  // reattach (see [syncSegment]) — a slow job is polled, not abandoned and
  // re-queued, which would only deepen the backlog.
  static const int _chunkSeconds = 180; // 3 min per uploaded segment
  static const int _maxChunkFrames = _chunkSeconds * 50; // fs320 = 50 frames/s (20 ms each)

  static const _tokenUrl = 'https://securetoken.googleapis.com/v1/token';
  static const _syncUrlV2 = 'https://api.omi.me/v2/sync-local-files';
  static const _syncUrlV1 = 'https://api.omi.me/v1/sync-local-files';
  static const _speechProfileUrl = 'https://api.omi.me/v3/speech-profile';
  static const _conversationUrl = 'https://api.omi.me/v1/dev/user/conversations';

  static bool get isSignedIn {
    final prefs = SharedPreferencesUtil();
    return !prefs.omiCredentialsWriting && prefs.omiRefreshToken.isNotEmpty && prefs.omiFirebaseApiKey.isNotEmpty;
  }

  /// Saves a new sign-in without allowing a cached token or an older refresh
  /// request to carry over from the previous account. Settings revisions can
  /// cancel a save while secure storage is awaiting a platform response.
  static Future<bool> replaceCredentials({
    required String refreshToken,
    required String apiKey,
    String? idToken,
    int expiresIn = 3600,
    bool Function()? isCurrent,
  }) async {
    final prefs = SharedPreferencesUtil();
    bool current() => isCurrent?.call() ?? true;
    await _credentialLock.acquire();
    try {
      if (!current()) return false;
      final changed = prefs.omiRefreshToken != refreshToken || prefs.omiFirebaseApiKey != apiKey;
      if (!changed && idToken == null) return true;
      _authGeneration++;
      // Expire first: even a failed secure-storage write cannot leave the old
      // token eligible for reuse with the replacement credentials.
      await prefs.saveInt('omiTokenExpiry', 0);
      await prefs.setOmiIdToken('');
      if (!current()) return false;
      if (changed) {
        prefs.omiAuthUid = '';
        prefs.omiAuthEmail = '';
        prefs.omiHasSpeechProfile = false;
        prefs.omiSpeechProfileCheckedAtMs = 0;
        prefs.omiConnectedViaFallback = false;
      }
      await prefs.setOmiCredentials(refreshToken: refreshToken, apiKey: apiKey);
      if (!current()) return false;
      if (idToken != null && idToken.isNotEmpty) {
        await prefs.setOmiIdToken(idToken);
        if (!current()) return false;
        await prefs.saveInt('omiTokenExpiry', DateTime.now().millisecondsSinceEpoch + expiresIn * 1000);
      }
      return true;
    } finally {
      _credentialLock.release();
    }
  }

  static Future<void> signOut() async {
    final prefs = SharedPreferencesUtil();
    await _credentialLock.acquire();
    try {
      _authGeneration++;
      await prefs.saveInt('omiTokenExpiry', 0);
      await prefs.setOmiIdToken('');
      await prefs.setOmiCredentials(refreshToken: '', apiKey: '');
      prefs.omiEnabled = false;
      prefs.omiAuthUid = '';
      prefs.omiAuthEmail = '';
      prefs.omiHasSpeechProfile = false;
      prefs.omiSpeechProfileCheckedAtMs = 0;
      Logger.debug('OmiApiClient: Signed out, cleared tokens');
    } finally {
      _credentialLock.release();
    }
  }

  /// Refreshes the Firebase ID token if it expires within 60 seconds.
  /// No-op if the token is still valid. Throws [OmiSyncException] on failure.
  static Future<void> refreshTokenIfNeeded() async {
    final prefs = SharedPreferencesUtil();
    final now = DateTime.now().millisecondsSinceEpoch;
    final int authGeneration;
    final String refreshToken;
    final String apiKey;
    await _credentialLock.acquire();
    try {
      final remainingMs = prefs.omiTokenExpiry - now;
      if (remainingMs > 60 * 1000) {
        Logger.debug('OmiApiClient: Token still valid, expires in ${(remainingMs / 1000).round()}s');
        return;
      }
      authGeneration = _authGeneration;
      refreshToken = prefs.omiRefreshToken;
      apiKey = prefs.omiFirebaseApiKey;
    } finally {
      _credentialLock.release();
    }
    if (refreshToken.isEmpty || apiKey.isEmpty) {
      Logger.error('OmiApiClient: refreshToken empty=${refreshToken.isEmpty}, apiKey empty=${apiKey.isEmpty}');
      throw const OmiSyncException('Omi credentials not configured');
    }

    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$_tokenUrl?key=${Uri.encodeComponent(apiKey)}'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'grant_type=refresh_token&refresh_token=${Uri.encodeComponent(refreshToken)}',
          )
          .timeout(const Duration(seconds: 10));
    } on SocketException {
      throw const OmiSyncException('No network connection');
    } on http.ClientException {
      // ClientException can contain the request URI, including its Firebase key.
      throw const OmiSyncException('Token refresh connection failed');
    } on TimeoutException {
      throw const OmiSyncException('Token refresh timed out');
    }
    late int expiresIn;
    await _credentialLock.acquire();
    try {
      if (_authGeneration != authGeneration ||
          prefs.omiRefreshToken != refreshToken ||
          prefs.omiFirebaseApiKey != apiKey) {
        throw const OmiSyncException('Sign-in changed during token refresh');
      }
      if (res.statusCode != 200) {
        Logger.error('OmiApiClient: Token refresh HTTP ${res.statusCode}');
        throw OmiSyncException('Token refresh failed (${res.statusCode})', isAuthError: _isCredentialRejection(res));
      }
      final body = _responseObject(res.body);
      final idToken = body['id_token'] as String?;
      expiresIn = int.tryParse(body['expires_in']?.toString() ?? '') ?? 3600;
      if (idToken == null || idToken.isEmpty) {
        throw const OmiSyncException('Token refresh returned no id_token');
      }
      await prefs.setOmiIdToken(idToken);
      prefs.omiTokenExpiry = now + expiresIn * 1000;

      // Google can rotate the refresh token on each exchange — persist the new one.
      final newRefreshToken = body['refresh_token'] as String?;
      if (newRefreshToken != null && newRefreshToken.isNotEmpty && newRefreshToken != refreshToken) {
        await prefs.setOmiCredentials(refreshToken: newRefreshToken, apiKey: apiKey, isTokenRefresh: true);
      }
    } finally {
      _credentialLock.release();
    }

    Logger.debug('OmiApiClient: Token refreshed, expires in ${expiresIn}s');
  }

  static Future<String> _idTokenForRequest({int? expectedGeneration}) async {
    final prefs = SharedPreferencesUtil();
    while (true) {
      final generation = _authGeneration;
      if (expectedGeneration != null && generation != expectedGeneration) {
        throw const OmiSyncException('Sign-in changed during upload');
      }
      await refreshTokenIfNeeded();
      await _credentialLock.acquire();
      try {
        // A replacement may have won the lock after the refresh. Fetch its token
        // next instead of reading a partially saved sign-in or the old cache.
        if (_authGeneration != generation) continue;
        final token = await prefs.omiIdToken;
        if (token.isEmpty) throw const OmiSyncException('No Omi ID token available');
        return token;
      } finally {
        _credentialLock.release();
      }
    }
  }

  /// Reads [binFile] and prepares its upload segments in the official device
  /// format `audio_<mac>_opus_fs320_16000_1_fs320_<ts_sec>.bin`: length-prefixed
  /// Opus frames (app-side marker frames stripped), split into ≤[_chunkSeconds]
  /// chunks with sequential timestamps the server stitches back into one
  /// conversation. Returns one (filename, bytes) entry per segment; empty if the
  /// bin holds no Opus frames. Callers upload these one at a time via
  /// [syncSegment] so the server never runs Parakeet on them in parallel.
  static Future<List<(String, Uint8List)>> buildSegments(File binFile) async {
    final chunks = await _readOpusFrameChunks(binFile);
    if (chunks.isEmpty) {
      Logger.error('OmiApiClient: No Opus frames found in ${binFile.path}');
      return const [];
    }

    final mac = _deviceMacForFilename();
    final baseTs = _baseTsSeconds(binFile);
    final latestSafe = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 30;

    final segments = <(String, Uint8List)>[];
    for (var j = 0; j < chunks.length; j++) {
      // Sequential per-chunk timestamps so the server orders/stitches them back
      // into one conversation. Clamp defensively so a chunk never lands in the
      // future (recordings are finalized after the fact, so this rarely fires).
      var ts = baseTs + j * _chunkSeconds;
      if (ts > latestSafe) ts = latestSafe;
      segments.add(('audio_${mac}_opus_fs320_16000_1_fs320_$ts.bin', chunks[j]));
    }
    Logger.debug('OmiApiClient: ${binFile.uri.pathSegments.last} → ${segments.length} segment(s) of ≤$_chunkSeconds s');
    return segments;
  }

  /// Syncs ONE chunk and reports the [OmiJobOutcome]. Callers serialize calls, so
  /// the server runs at most one Parakeet transcription at a time — handing it
  /// many segments at once made it fan them out in parallel and 503 the STT
  /// backend.
  ///
  /// If [existingJobId] is given, the chunk's prior job is **reattached** (polled)
  /// instead of re-uploaded. Outcomes: `completed` (mark synced); `failed`/`gone`
  /// (a real verdict — re-upload fresh); `pending` (job still alive — keep the id
  /// and reattach next time, don't enqueue a duplicate); `busy` (server 503/502/504
  /// or a transient transcription 503 — re-upload, but only after a backoff so a
  /// struggling backend isn't hammered).
  ///
  /// Throws [OmiSyncException] on auth/transport/HTTP error (incl. not signed in).
  static Future<OmiJobOutcome> syncSegment((String, Uint8List) segment,
      {String? existingJobId, bool Function()? isCancelled}) async {
    if (!isSignedIn) throw const OmiSyncException('Not signed in');
    final generation = _authGeneration;
    bool cancelled() => (isCancelled?.call() ?? false) || generation != _authGeneration;
    OmiJobOutcome stopped() => OmiJobOutcome(OmiJobStatus.pending, jobId: existingJobId);
    if (cancelled()) return stopped();

    final token = await _idTokenForRequest(expectedGeneration: generation);
    if (cancelled()) return stopped();
    final headers = {'Authorization': 'Bearer $token'};

    // Reattach path: poll the outstanding job rather than re-uploading. Jobs live
    // under the URL they were submitted to; we default to v2 (the normal path) —
    // if it was a rare v1 fallback, v2 returns 404 → `gone` → a fresh upload below
    // re-discovers the right endpoint.
    if (existingJobId != null) {
      Logger.debug('Omi Cloud: reattaching to job $existingJobId for ${segment.$1}');
      final outcome = await _pollJob(_syncUrlV2, existingJobId, 0, isCancelled: cancelled, generation: generation);
      if (outcome.status != OmiJobStatus.gone) return outcome;
      Logger.debug('Omi Cloud: job $existingJobId gone — re-uploading ${segment.$1}');
    }

    if (cancelled()) return stopped();

    Logger.debug('Omi Cloud: uploading segment ${segment.$1}');
    var res = await _doUploadBytes(_syncUrlV2, [segment], headers);
    var usedUrl = _syncUrlV2;

    if (res.statusCode == 404 || res.statusCode == 405) {
      if (cancelled()) return stopped();
      Logger.debug('OmiApiClient: v2 not found (${res.statusCode}), falling back to v1');
      res = await _doUploadBytes(_syncUrlV1, [segment], headers);
      usedUrl = _syncUrlV1;
    }

    final responseBody = res.body;
    Logger.debug('OmiApiClient: Upload response ${res.statusCode}');

    // Server overloaded — back off and retry later rather than failing/hammering.
    if (_isBusyStatus(res.statusCode)) {
      Logger.debug('Omi Cloud: server busy on submit (${res.statusCode}) for ${segment.$1}');
      return OmiJobOutcome(OmiJobStatus.busy, error: 'Server busy (${res.statusCode})');
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final isAuth = res.statusCode == 401 || res.statusCode == 403;
      throw OmiSyncException('Sync upload failed (${res.statusCode})', isAuthError: isAuth);
    }

    if (res.statusCode == 202) {
      final json = _responseObject(responseBody);
      final jobId = json['job_id'] as String?;
      final pollAfterMs = (json['poll_after_ms'] as int?) ?? 3000;
      if (jobId != null) {
        return await _pollJob(usedUrl, jobId, pollAfterMs, isCancelled: cancelled, generation: generation);
      }
    }

    // Synchronous (non-202) result.
    final result = _parseSyncResult(res.statusCode, responseBody);
    if (result.success) {
      Logger.debug('Omi Cloud: upload success');
      return OmiJobOutcome(OmiJobStatus.completed, result: result);
    }
    Logger.error('Omi Cloud: upload failed: ${result.status}');
    return OmiJobOutcome(OmiJobStatus.failed, error: result.error ?? result.status);
  }

  static String _deviceMacForFilename() {
    final raw = SharedPreferencesUtil().btDevice.id;
    final cleaned = raw.replaceAll(':', '').replaceAll('-', '').toLowerCase();
    // Fallback so an empty/unknown MAC still produces a parseable filename.
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  /// Base segment timestamp (epoch seconds) from "recording_fs320_<ms>.bin",
  /// clamped to the server's accepted window (>= 2024-01-01, <= now - 30 s).
  /// Per-chunk timestamps are derived by adding [_chunkSeconds] × chunkIndex.
  static int _baseTsSeconds(File binFile) {
    final parsed = RecordingFilename.timestamp(binFile.path) ?? 0;
    var tsSeconds = parsed > 1000000000000 ? parsed ~/ 1000 : parsed;

    const minValidSeconds = 1704067200;
    final latestSafe = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 30;
    final safeFloor = latestSafe > minValidSeconds ? latestSafe : minValidSeconds;
    if (tsSeconds < minValidSeconds) tsSeconds = safeFloor;
    if (tsSeconds > latestSafe) tsSeconds = latestSafe;

    return tsSeconds;
  }

  /// Reads a .bin and returns its length-prefixed Opus frames split into chunks of
  /// at most [_maxChunkFrames] frames (≈ [_chunkSeconds] of audio), so each chunk
  /// becomes a separate server segment that stays under the Parakeet STT timeout.
  /// App-side marker frames (0xFFFFFFF8/F9/FA/FB/FC/FD/FE) and zero/sentinel slots are skipped.
  static Future<List<Uint8List>> _readOpusFrameChunks(File binFile) async {
    final bytes = await binFile.readAsBytes();
    final byteData = ByteData.sublistView(bytes);
    final chunks = <Uint8List>[];
    var current = BytesBuilder();
    int framesInChunk = 0;

    int offset = 0;
    int frameCount = 0;
    int skippedMarkers = 0;
    bool desynced = false;
    while (offset + 4 <= bytes.length) {
      final frameLength = byteData.getUint32(offset, Endian.little);

      if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
        offset += 4;
        continue;
      }
      if (frameLength == 0xFFFFFFFB) {
        offset += 36;
        skippedMarkers++;
        continue;
      }
      if (frameLength == 0xFFFFFFFE) {
        offset += 20;
        skippedMarkers++;
        continue;
      }
      if (frameLength == 0xFFFFFFFD) {
        offset += 16;
        skippedMarkers++;
        continue;
      }
      // 20-byte markers: priority-start (0xFFFFFFF8), mute-off (0xFFFFFFF9),
      // mute-on (0xFFFFFFFA), session-end (0xFFFFFFFC). Without this they fall
      // into the +4 catch-all below and desync the stream by 16 bytes.
      if (frameLength == 0xFFFFFFF8 ||
          frameLength == 0xFFFFFFF9 ||
          frameLength == 0xFFFFFFFA ||
          frameLength == 0xFFFFFFFC) {
        offset += 20;
        skippedMarkers++;
        continue;
      }
      if (frameLength > 0xFFFF00) {
        offset += 4;
        skippedMarkers++;
        continue;
      }

      if (offset + 4 + frameLength > bytes.length) {
        desynced = true;
        break;
      }

      current.add(Uint8List.sublistView(bytes, offset, offset + 4 + frameLength));
      offset += 4 + frameLength;
      frameCount++;
      framesInChunk++;

      if (framesInChunk >= _maxChunkFrames) {
        chunks.add(current.takeBytes());
        current = BytesBuilder();
        framesInChunk = 0;
      }
    }
    if (current.length > 0) chunks.add(current.takeBytes());

    // Each Opus frame is 20 ms (fs320 @ 16 kHz), so duration ≈ frames × 20 ms.
    final estMs = frameCount * 20;
    Logger.debug(
      'OmiApiClient: _readOpusFrameChunks ${binFile.uri.pathSegments.last}: '
      '$frameCount frames (~${(estMs / 60000).toStringAsFixed(1)} min) → ${chunks.length} chunk(s), '
      'markers skipped: $skippedMarkers, trailing bytes after last frame: ${bytes.length - offset}'
      '${desynced ? ' [DESYNC: stopped early at offset $offset of ${bytes.length}]' : ''}',
    );

    return chunks;
  }

  @visibleForTesting
  static Future<List<Uint8List>> readOpusFrameChunksForTest(File binFile) => _readOpusFrameChunks(binFile);

  static Future<http.Response> _doUploadBytes(
    String url,
    List<(String filename, Uint8List bytes)> files,
    Map<String, String> headers,
  ) async {
    final request = http.MultipartRequest('POST', Uri.parse(url))..headers.addAll(headers);
    for (final (filename, bytes) in files) {
      request.files.add(http.MultipartFile.fromBytes(
        'files',
        bytes,
        filename: filename,
        contentType: MediaType('application', 'octet-stream'),
      ));
    }

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 120));
      return http.Response.fromStream(streamed);
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }
  }

  /// Polls a single job until the server renders a verdict or the budget elapses.
  /// Each chunk is its own one-segment job, so the budget is a fixed ~4 min (80
  /// polls × ~3 s). Crucially, budget-elapse returns [OmiJobStatus.pending] — the
  /// job is still alive server-side, so the caller reattaches next run instead of
  /// abandoning and re-uploading it (which would only add to the queue backlog
  /// that made it slow in the first place). A 404 returns [OmiJobStatus.gone].
  static Future<OmiJobOutcome> _pollJob(String baseUrl, String jobId, int initialDelayMs,
      {bool Function()? isCancelled, required int generation}) async {
    if (isCancelled?.call() ?? false) return OmiJobOutcome(OmiJobStatus.pending, jobId: jobId);
    await Future.delayed(Duration(milliseconds: initialDelayMs));

    const maxAttempts = 80; // ~4 min at ~3 s/poll
    var delayMs = 3000;
    for (var i = 0; i < maxAttempts; i++) {
      // User disabled the integration / its auto-upload mid-poll. The job is
      // still alive server-side, so stop as `pending` (keep the job id) and let a
      // later run reattach rather than abandoning and re-uploading it.
      if (isCancelled?.call() ?? false) {
        Logger.debug('OmiApiClient: Job $jobId poll cancelled — leaving for reattach');
        return OmiJobOutcome(OmiJobStatus.pending, jobId: jobId);
      }
      final token = await _idTokenForRequest(expectedGeneration: generation);
      if (isCancelled?.call() ?? false) return OmiJobOutcome(OmiJobStatus.pending, jobId: jobId);

      final headers = {'Authorization': 'Bearer $token'};

      final http.Response res;
      try {
        res = await http.get(Uri.parse('$baseUrl/$jobId'), headers: headers).timeout(const Duration(seconds: 15));
      } on SocketException {
        throw const OmiSyncException('No network connection');
      }

      Logger.debug('OmiApiClient: Job $jobId poll ${res.statusCode}');

      if (res.statusCode == 401 || res.statusCode == 403) {
        throw OmiSyncException('Job poll auth error (${res.statusCode})', isAuthError: true);
      }

      if (res.statusCode == 404) {
        return OmiJobOutcome(OmiJobStatus.gone, jobId: jobId);
      }

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final bodyJson = _responseObject(res.body);
        final status = bodyJson['status'] as String?;
        if (status == 'completed' || status == 'partial_failure') {
          return OmiJobOutcome(OmiJobStatus.completed,
              jobId: jobId, result: _parseSyncResult(res.statusCode, res.body));
        }
        if (status == 'failed') {
          final err = (bodyJson['error'] ?? bodyJson['message'] ?? 'unknown error').toString();
          // A job that failed only because the transcription backend was
          // unavailable or its gateway timed out (a 503, or a 502/504) is
          // transient — treat it as busy (back off + re-upload later), not a
          // content failure.
          final transient = _looksTransient(err) ? OmiJobStatus.busy : OmiJobStatus.failed;
          return OmiJobOutcome(transient, jobId: jobId, error: err);
        }
        delayMs = (bodyJson['poll_after_ms'] as int?) ?? delayMs;
      }

      if (isCancelled?.call() ?? false) return OmiJobOutcome(OmiJobStatus.pending, jobId: jobId);
      await Future.delayed(Duration(milliseconds: delayMs));
    }

    // Budget elapsed but the job is still queued/processing — reattach next run.
    Logger.debug('OmiApiClient: Job $jobId still running after poll budget — leaving for reattach');
    return OmiJobOutcome(OmiJobStatus.pending, jobId: jobId);
  }

  /// 5xx gateway/overload statuses the server returns when it can't take work
  /// right now — retryable after a backoff rather than a hard failure.
  static bool _isBusyStatus(int code) => code == 503 || code == 502 || code == 504;

  /// A malformed response must not escape as a FormatException containing raw credentials.
  static Map<String, dynamic> _responseObject(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw const OmiSyncException('Invalid server response');
    }
  }

  /// Whether a failed-job error message is a transient backend/gateway signal —
  /// a transcription 503, a 502/504 gateway timeout, or a plain request timeout —
  /// rather than a real content/processing failure. These re-upload after a
  /// backoff instead of spending the give-up budget. A 504 here arrives embedded
  /// in a `status: failed` body on a 200 poll, so it bypasses the HTTP-status
  /// [_isBusyStatus] check and must be caught by string match.
  static bool _looksTransient(String error) {
    final e = error.toLowerCase();
    return e.contains('503') ||
        e.contains('502') ||
        e.contains('504') ||
        e.contains('gateway timeout') ||
        e.contains('gateway time-out') ||
        e.contains('bad gateway') ||
        e.contains('service unavailable') ||
        e.contains('temporarily unavailable') ||
        e.contains('timed out');
  }

  static OmiSyncResult _parseSyncResult(int httpStatus, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final status = json['status']?.toString() ?? 'completed';
      final success = httpStatus >= 200 && httpStatus < 300 && status != 'failed';

      List<String> parseIds(dynamic val) {
        if (val is List) return val.map((e) => e.toString()).toList();
        return [];
      }

      return OmiSyncResult(
        success: success,
        status: status,
        newConversationIds: parseIds(json['new_memories']),
        updatedConversationIds: parseIds(json['updated_memories']),
        successfulSegments: json['successful_segments'] as int? ?? 0,
        failedSegments: json['failed_segments'] as int? ?? 0,
      );
    } catch (e) {
      return OmiSyncResult(
        success: httpStatus >= 200 && httpStatus < 300,
        status: 'parse_error',
        error: 'Invalid server response',
      );
    }
  }

  /// Verifies a conversation was actually created on the server and checks its metadata.
  static Future<void> traceSyncResult(OmiSyncResult result, {bool Function()? isCancelled}) async {
    if (!result.success || result.allConversationIds.isEmpty) return;
    final generation = _authGeneration;

    try {
      final token = await _idTokenForRequest(expectedGeneration: generation);
      final headers = {'Authorization': 'Bearer $token'};

      for (final id in result.allConversationIds.take(3)) {
        if ((isCancelled?.call() ?? false) || generation != _authGeneration) return;
        final res = await http
            .get(
              Uri.parse('$_conversationUrl/${Uri.encodeComponent(id)}?include_transcript=true'),
              headers: headers,
            )
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200) {
          final json = _responseObject(res.body);
          final segs = (json['transcript_segments'] as List?) ?? const [];
          final title = (json['structured'] as Map?)?['title'] ?? 'No Title';
          final discarded = json['discarded'] == true;

          // Span the transcript actually covers. Each segment has `start`/`end`
          // in seconds; min(start)..max(end) tells us whether the cloud stopped
          // early (genuine truncation) or scattered speech across the full file.
          double? firstStart;
          double? lastEnd;
          for (final s in segs) {
            if (s is! Map) continue;
            final start = (s['start'] as num?)?.toDouble();
            final end = (s['end'] as num?)?.toDouble();
            if (start != null && (firstStart == null || start < firstStart)) firstStart = start;
            if (end != null && (lastEnd == null || end > lastEnd)) lastEnd = end;
          }
          final spanStr = (firstStart != null && lastEnd != null)
              ? 'span ${(firstStart / 60).toStringAsFixed(1)}–${(lastEnd / 60).toStringAsFixed(1)} min'
              : 'span unknown';
          Logger.debug(
            'OmiApiClient: Trace result for $id: "$title", segments: ${segs.length}, '
            '$spanStr, discarded: $discarded',
          );
        } else {
          Logger.error('OmiApiClient: Trace failed for $id (HTTP ${res.statusCode})');
        }
      }
    } catch (e) {
      Logger.error('OmiApiClient: Trace error (${e.runtimeType})');
    }
  }

  /// Refreshes the user's speech profile status from the server.
  static Future<bool?> refreshSpeechProfileStatus() async {
    if (!isSignedIn) return null;
    final generation = _authGeneration;

    try {
      final token = await _idTokenForRequest(expectedGeneration: generation);
      final res = await http.get(
        Uri.parse(_speechProfileUrl),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        Logger.error('OmiApiClient: Speech profile check HTTP ${res.statusCode}');
        return null;
      }

      final body = _responseObject(res.body);
      final hasProfile = body['has_profile'] == true;

      if (generation != _authGeneration) return null;
      final prefs = SharedPreferencesUtil();
      prefs.omiHasSpeechProfile = hasProfile;
      prefs.omiSpeechProfileCheckedAtMs = DateTime.now().millisecondsSinceEpoch;

      Logger.debug('OmiApiClient: Speech profile checked: $hasProfile');
      return hasProfile;
    } catch (e) {
      Logger.error('OmiApiClient: Speech profile check error (${e.runtimeType})');
      return null;
    }
  }

  /// Verifies credentials by attempting a token refresh with the supplied values.
  /// Does not read from or write to saved preferences, so callers can test
  /// unsaved credentials without overwriting the working ones.
  /// Returns false only for missing or rejected credentials. Throws when the
  /// check is unavailable, so a temporary outage cannot disable a saved connection.
  static Future<bool> testConnection({
    required String refreshToken,
    required String apiKey,
  }) async {
    if (refreshToken.isEmpty || apiKey.isEmpty) return false;
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$_tokenUrl?key=${Uri.encodeComponent(apiKey)}'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'grant_type=refresh_token&refresh_token=${Uri.encodeComponent(refreshToken)}',
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Client exceptions can include the URL (and API key); never forward them.
      throw const OmiSyncException('Could not verify Omi credentials — check your connection');
    }
    if (res.statusCode == 200) return true;
    if (_isCredentialRejection(res)) return false;
    throw OmiSyncException('Could not verify Omi credentials (HTTP ${res.statusCode})');
  }

  static bool _isCredentialRejection(http.Response res) {
    if (res.statusCode == 401) return true;
    if (res.statusCode == 400 || res.statusCode == 403) {
      final error = _responseObject(res.body)['error'];
      final message = error is Map ? error['message'] : null;
      // https://firebase.google.com/docs/reference/rest/auth#section-refresh-token
      const rejectedCredentials = {
        'TOKEN_EXPIRED',
        'USER_DISABLED',
        'USER_NOT_FOUND',
        'INVALID_REFRESH_TOKEN',
        'MISSING_REFRESH_TOKEN',
        'PROJECT_NUMBER_MISMATCH',
        'API_KEY_INVALID',
        'API key not valid. Please pass a valid API key.',
      };
      if (message is String && rejectedCredentials.contains(message)) return true;
    }
    return false;
  }
}

class OmiSyncException implements Exception {
  final String message;
  final bool isAuthError;
  const OmiSyncException(this.message, {this.isAuthError = false});
  @override
  String toString() => 'OmiSyncException: $message';
}
