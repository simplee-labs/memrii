import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_api.dart';
import 'package:omi/integrations/integration_recording.dart';

/// Answers the upload-URL request itself and sends the file PUT, for real, to [putUrl].
class _RoutingClient extends http.BaseClient {
  final Uri putUrl;
  final IOClient _inner = IOClient();
  _RoutingClient(this.putUrl);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST') {
      final body = utf8.encode(jsonEncode({
        'data': {'upload_url': putUrl.toString()}
      }));
      return http.StreamedResponse(Stream.value(body), 200);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  late Directory temp;
  late HttpServer server;
  late Duration idleLimit;
  late Duration responseLimit;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('heypocket_stall');
    idleLimit = HeyPocketService.uploadIdleLimit;
    responseLimit = HeyPocketService.uploadResponseLimit;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    HeyPocketService.uploadIdleLimit = idleLimit;
    HeyPocketService.uploadResponseLimit = responseLimit;
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  IntegrationRecording recording(int bytes) {
    final file = File('${temp.path}/recording_1789000000000.wav')..writeAsBytesSync(List<int>.filled(bytes, 7));
    return IntegrationRecording(
      id: 'k',
      audioPath: file.path,
      startTime: DateTime(2026, 9, 1, 10),
      duration: const Duration(seconds: 30),
    );
  }

  Future<void> upload(IntegrationRecording rec) => http.runWithClient(
        () => HeyPocketService.uploadRecording('key', rec),
        () => _RoutingClient(Uri.parse('http://${server.address.host}:${server.port}/put')),
      );

  Matcher timedOut() => throwsA(
      isA<HeyPocketException>().having((e) => e.message, 'message', 'Connection timed out — check your network'));

  test('a PUT whose connection stops taking the file fails at the idle limit', () async {
    HeyPocketService.uploadIdleLimit = const Duration(milliseconds: 500);
    HeyPocketService.uploadResponseLimit = const Duration(minutes: 1);
    server.listen((_) {}); // accepts, and never reads a byte: the socket fills and stops

    final watch = Stopwatch()..start();
    await expectLater(upload(recording(32 * 1024 * 1024)), timedOut());
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)),
        reason: 'the idle limit fired, not the minute-long response limit');
  });

  test('a PUT whose server never answers fails at the response limit', () async {
    HeyPocketService.uploadIdleLimit = const Duration(seconds: 30);
    HeyPocketService.uploadResponseLimit = const Duration(milliseconds: 500);
    server.listen((req) => req.drain<void>()); // takes the whole body, then says nothing

    await expectLater(upload(recording(4096)), timedOut());
  });

  test('a slow PUT that keeps moving is never cut off', () async {
    HeyPocketService.uploadIdleLimit = const Duration(seconds: 1);
    HeyPocketService.uploadResponseLimit = const Duration(seconds: 30);
    server.listen((req) async {
      // Read in small steps with pauses: slower overall than the idle limit, never idle for it.
      final sub = req.listen(null);
      sub.onData((_) {
        sub.pause();
        Future<void>.delayed(const Duration(milliseconds: 50), sub.resume);
      });
      await sub.asFuture<void>();
      req.response.statusCode = 200;
      await req.response.close();
    });

    await upload(recording(8 * 1024 * 1024));
  });
}
