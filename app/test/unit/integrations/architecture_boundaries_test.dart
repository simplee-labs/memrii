import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins memrii's layer boundaries in the source itself, so a change that crosses one
/// fails here instead of surviving until someone notices in review.
///
/// - **Connectors consume normalized data.** Nothing under `lib/integrations/connectors/`
///   may import the capture/sync/processing internals — BLE, WAL, raw segments, VAD, the
///   recordings manager, clock anchors — or the recording layer's own model. A connector
///   gets an `IntegrationRecording` and nothing else.
/// - **Capture, device and recording code names no destination.** The code that records,
///   syncs, processes and files recordings asks the connector registry generic questions
///   ("does anyone want Opus frame sidecars?", "a recording moved") and never mentions
///   HeyPocket, Omi Cloud or Save to Folder by name.
/// - **Connectors stay behind the registry.** Outside `lib/integrations/`, only the
///   Integrations settings UI — per-destination configuration and its model — imports a connector.
///
/// Comments are ignored: explaining in prose which destination motivated a rule is fine.
void main() {
  // Tests run with app/ as the working directory.
  final lib = Directory('lib');

  Iterable<File> dartFiles(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

  String rel(File f) => f.path.replaceAll('\\', '/');

  /// Source with `//` comments removed (line and trailing), so prose never trips a rule.
  String code(File f) => f.readAsLinesSync().map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      }).join('\n');

  List<String> imports(File f) => RegExp(r'''^import\s+'([^']+)';''', multiLine: true)
      .allMatches(f.readAsStringSync())
      .map((m) => m.group(1)!)
      .toList();

  test('the library exists where this test expects it', () {
    expect(lib.existsSync(), isTrue, reason: 'run from app/');
    expect(Directory('lib/integrations/connectors').existsSync(), isTrue);
  });

  test('connectors import nothing from capture, sync, processing or the recording model', () {
    const forbidden = [
      'package:omi/services/wals',
      'package:omi/services/devices',
      'package:omi/services/bridges',
      'package:omi/services/vad',
      'package:omi/services/vad_audio_processor.dart',
      'package:omi/services/vad_batch_runner_channel.dart',
      'package:omi/services/recordings_manager.dart',
      'package:omi/services/recordings_isolate_worker.dart',
      'package:omi/services/device_clock_anchor.dart',
      'package:omi/services/discard_store.dart',
      'package:omi/services/frame_ref.dart',
      'package:omi/services/services.dart',
      'package:omi/providers/',
      'package:omi/gen/pigeon_communicator.g.dart',
      'package:omi/models/recordings/recordings_models.dart',
      // Capture policy is memrii's; a connector may only declare needsOpusFrameSidecar.
      'package:omi/capture/',
      'package:omi/entitlements/',
      'package:omi/integrations/automation/',
    ];
    final violations = <String>[];
    for (final f in dartFiles('lib/integrations/connectors')) {
      for (final imp in imports(f)) {
        if (forbidden.any(imp.startsWith)) violations.add('${rel(f)} imports $imp');
      }
    }
    expect(violations, isEmpty);
  });

  test('capture, device and recording code names no destination', () {
    final destinationNames = RegExp(r'\b(HeyPocket\w*|heypocket\w*|OmiCloud\w*|OmiApiClient|omiEnabled|omiSync\w*|'
        r'FolderExport\w*|folderExport\w*|OmiPassthrough\w*)\b');
    final guarded = [
      ...dartFiles('lib/services/devices'),
      ...dartFiles('lib/services/wals'),
      ...dartFiles('lib/services/vad'),
      File('lib/services/vad_audio_processor.dart'),
      File('lib/services/recordings_manager.dart'),
      File('lib/services/recordings_isolate_worker.dart'),
      File('lib/services/device_clock_anchor.dart'),
      File('lib/services/recording_sidecars.dart'),
      File('lib/services/services.dart'),
      File('lib/providers/device_provider.dart'),
      File('lib/main.dart'),
    ];
    final violations = <String>[];
    for (final f in guarded) {
      for (final m in destinationNames.allMatches(code(f))) {
        violations.add('${rel(f)}: ${m.group(0)}');
      }
    }
    expect(violations, isEmpty);
  });

  test('outside lib/integrations, only the Integrations settings UI imports a connector', () {
    const settingsUi = {
      'lib/pages/settings/integration_settings_page.dart',
      'lib/pages/settings/integration_settings_model.dart',
    };
    final violations = <String>[];
    for (final f in dartFiles('lib')) {
      final path = rel(f);
      if (path.startsWith('lib/integrations/') || settingsUi.contains(path)) continue;
      for (final imp in imports(f)) {
        if (imp.startsWith('package:omi/integrations/connectors/')) violations.add('$path imports $imp');
      }
    }
    expect(violations, isEmpty);
  });

  test('only the sharing policy can mint an AuthorizedUpload', () {
    // The private constructor makes this true for the compiler; this names the one file
    // allowed to contain it, so a second minting site is a visible, deliberate change.
    final minting = [
      for (final f in dartFiles('lib'))
        if (code(f).contains('AuthorizedUpload._(')) rel(f)
    ];
    expect(minting, ['lib/integrations/sharing/upload_authorization.dart']);
  });

  test('only the application integration owner constructs the production upload manager', () {
    final constructors = [
      for (final f in dartFiles('lib'))
        if (rel(f) != 'lib/integrations/integration_upload_manager.dart' &&
            RegExp(r'\bIntegrationUploadManager\s*\(').hasMatch(code(f)))
          rel(f),
    ];
    expect(constructors, ['lib/integrations/integration_coordinator.dart']);
    final services = code(File('lib/services/services.dart'));
    expect(services, contains('late final IntegrationCoordinator integrations'));
    expect(services, contains('IntegrationCoordinator.application('));
    expect(services, contains('integrations.dispose()'));
    final main = code(File('lib/main.dart'));
    final integrationStart = main.indexOf('integrations.start(waitForInitialDiscovery: false)');
    expect(integrationStart, greaterThanOrEqualTo(0),
        reason: 'archive discovery must not delay native readiness or UI');
    expect(integrationStart, lessThan(main.indexOf("invokeMethod('dartReady')")));
    expect(integrationStart, lessThan(main.indexOf('runApp(')));
    final controller = code(File('lib/pages/recordings/recordings_controller.dart'));
    expect(controller, contains('ServiceManager.instance().integrations'));
    expect(controller, isNot(contains('ConnectorRegistry.all(')));
    expect(controller, isNot(contains('_uploads.dispose(')));
    expect(controller, isNot(contains('_integrations.dispose(')));
  });

  test('connectors contain no entitlement decisions and every send requires a grant', () {
    final sendSignature = RegExp(r'Future<void>\s+send\s*\(\s*AuthorizedUpload\b');
    for (final f in [File('lib/integrations/connector.dart'), ...dartFiles('lib/integrations/connectors')]) {
      final source = code(f);
      expect(RegExp(r'\bisPro\b').hasMatch(source), isFalse, reason: rel(f));
      if (RegExp(r'Future<void>\s+send\s*\(').hasMatch(source)) {
        expect(sendSignature.hasMatch(source), isTrue, reason: '${rel(f)} must consume AuthorizedUpload');
      }
    }
    final authorization = code(File('lib/integrations/sharing/upload_authorization.dart'));
    expect(authorization, contains('final class AuthorizedUpload'));
    expect(RegExp(r'AuthorizedUpload\s*\(').hasMatch(authorization), isFalse, reason: 'no public grant constructor');
  });

  test('public application code has no built-in Pro toggle or private/test provider imports', () {
    for (final f in dartFiles('lib')) {
      expect(code(f), isNot(contains('developmentProOverride')), reason: rel(f));
      expect(code(f), isNot(contains('Development Pro override')), reason: rel(f));
      expect(
          imports(f).where((i) =>
              i.contains('/test/') || i.contains('test_entitlement_service.dart') || i.contains('local_development/')),
          isEmpty,
          reason: rel(f));
    }
  });

  test('automation does not import capture or wearable state', () {
    for (final f in dartFiles('lib/integrations/automation')) {
      expect(
          imports(f).where((i) =>
              i.startsWith('package:omi/providers/') ||
              i.startsWith('package:omi/services/') ||
              i.startsWith('package:omi/capture/')),
          isEmpty,
          reason: rel(f));
    }
    for (final dir in ['lib/services/devices', 'lib/services/wals', 'lib/services/vad', 'lib/capture']) {
      for (final f in dartFiles(dir)) {
        expect(
            imports(f).where((i) =>
                i.startsWith('package:omi/entitlements/') || i.startsWith('package:omi/integrations/automation/')),
            isEmpty,
            reason: rel(f));
      }
    }
  });
}
