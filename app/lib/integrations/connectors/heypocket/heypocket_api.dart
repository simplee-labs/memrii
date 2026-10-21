import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/utils/logger.dart';
import 'package:path/path.dart' as p;

class HeyPocketService {
  static const _base = 'https://public.heypocketai.com/api/v1';

  /// Returns false only when the service rejects the key. An unavailable check
  /// throws, so callers can preserve a saved connection during an outage.
  static Future<bool> testConnection(String apiKey) async {
    if (apiKey.isEmpty) return false;
    final http.Response res;
    try {
      res = await http.get(Uri.parse('$_base/public/recordings'),
          headers: {'Authorization': 'Bearer $apiKey'}).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw const HeyPocketException(0, 'Connection timed out — check your network');
    } on SocketException {
      throw const HeyPocketException(0, 'No network connection');
    } catch (e) {
      throw const HeyPocketException(0, 'Connection failed');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return true;
    if (res.statusCode == 401 || res.statusCode == 403) return false;
    throw HeyPocketException(res.statusCode, 'Could not verify HeyPocket credentials (HTTP ${res.statusCode})');
  }

  static String _mimeType(String path) {
    if (path.endsWith('.wav')) return 'audio/wav';
    return 'audio/mp4';
  }

  static String _title(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return 'Recording – ${months[dt.month - 1]} ${dt.day}, ${dt.year} $h:$m $ampm';
  }

  /// RFC3339 timestamp preserving local timezone offset (e.g. 2024-03-16T19:23:00-07:00).
  static String _rfc3339(DateTime dt) {
    final offset = dt.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final base = dt.toIso8601String().split('.').first;
    return '$base$sign$hh:$mm';
  }

  /// Two-step upload:
  ///   1. POST /public/recordings/upload-url → extract upload_url from response data
  ///   2. PUT presigned URL streaming file bytes
  static Future<void> uploadRecording(String apiKey, IntegrationRecording rec) async {
    Logger.debug('HeyPocket: starting upload for ${p.basename(rec.audioPath)}');
    try {
      final contentType = _mimeType(rec.audioPath);

      // Step 1: get presigned URL
      final postRes = await http
          .post(
            Uri.parse('$_base/public/recordings/upload-url'),
            headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': _title(rec.startTime),
              'file_name': p.basename(rec.audioPath),
              'content_type': contentType,
              'duration': rec.duration.inSeconds,
              'recording_at': _rfc3339(rec.startTime),
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (postRes.statusCode != 200) {
        throw HeyPocketException(postRes.statusCode, _errorMessage(postRes.statusCode));
      }

      final body = jsonDecode(postRes.body);
      final data = body is Map ? body['data'] : null;
      final url = data is Map ? data['upload_url'] : null;
      if (url is! String || url.isEmpty) throw const HeyPocketException(500, 'Invalid upload URL');
      final uri = Uri.tryParse(url);
      if (uri == null) throw const HeyPocketException(500, 'Invalid upload URL');

      // Step 2: stream PUT file to presigned URL
      final fileLength = await rec.audioFile.length();
      final request = http.StreamedRequest('PUT', uri)
        ..headers['Content-Type'] = contentType
        ..contentLength = fileLength;

      Object? streamError;
      final pipeFuture = rec.audioFile.openRead().pipe(request.sink).catchError((e) {
        streamError = e;
        request.sink.close();
      });

      final streamedRes = await request.send();
      await pipeFuture.timeout(const Duration(seconds: 60));

      if (streamError != null) throw const HeyPocketException(0, 'File read failed during upload');
      if (streamedRes.statusCode != 200 && streamedRes.statusCode != 204) {
        throw HeyPocketException(streamedRes.statusCode, _errorMessage(streamedRes.statusCode));
      }
      Logger.debug('HeyPocket: upload success for ${p.basename(rec.audioPath)}');
    } on HeyPocketException catch (e) {
      Logger.error('HeyPocket: upload failed (code ${e.statusCode}): ${e.message}');
      rethrow;
    } on TimeoutException {
      Logger.error('HeyPocket: upload timed out');
      throw const HeyPocketException(0, 'Connection timed out — check your network');
    } on SocketException {
      Logger.error('HeyPocket: no network connection for upload');
      throw const HeyPocketException(0, 'No network connection');
    } catch (e) {
      // Malformed responses and ClientException can include a signed upload URL.
      Logger.error('HeyPocket: upload failed (${e.runtimeType})');
      throw const HeyPocketException(0, 'Upload failed');
    }
  }

  static String _errorMessage(int code) => switch (code) {
        400 => 'Bad request — check file format',
        401 => 'Unauthorized — check your API key',
        403 => 'Access denied — check your API key',
        _ => 'HeyPocket server error — try again later',
      };
}

class HeyPocketException implements Exception {
  final int statusCode;
  final String message;
  const HeyPocketException(this.statusCode, this.message);

  @override
  String toString() => 'HeyPocketException($statusCode): $message';
}
