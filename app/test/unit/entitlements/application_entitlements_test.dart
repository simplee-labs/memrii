import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/entitlements/entitlement_service.dart';

import '../../support/test_entitlement_service.dart';

void main() {
  tearDown(() => ApplicationEntitlements.installLocalDevelopment(null));

  test('startup composition uses production by default and only delegates to a supplied provider', () {
    expect(ApplicationEntitlements.current.isPro, isFalse);
    final provider = TestEntitlementService();
    ApplicationEntitlements.installLocalDevelopment(provider);
    expect(ApplicationEntitlements.current, same(provider));
    expect(ApplicationEntitlements.current.isPro, isFalse);
    provider.isPro = true;
    expect(ApplicationEntitlements.current.isPro, isTrue);
    expect(const LocalEntitlementService().isPro, isFalse);
    ApplicationEntitlements.installLocalDevelopment(null);
    expect(ApplicationEntitlements.current.isPro, isFalse);
  });

  final engine = File(Platform.resolvedExecutable);
  final dart = engine.uri.pathSegments.last.startsWith('dart')
      ? engine
      : File('${engine.parent.parent.parent.parent.path}/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}');

  for (final mode in [
    (name: 'Debug', defines: ['--enable-asserts'], allowsDevelopment: true),
    (
      name: 'Debug with obvious Pro flags',
      defines: ['--enable-asserts', '-DDEV_PRO=true', '-DPRO=true'],
      allowsDevelopment: true
    ),
    (name: 'Profile', defines: ['-Ddart.vm.profile=true', '-DDEV_PRO=true'], allowsDevelopment: false),
    (name: 'Release', defines: ['-Ddart.vm.product=true', '-DDEV_PRO=true'], allowsDevelopment: false),
    (
      name: 'Mode flags alone without Debug assertions',
      defines: ['-Ddart.vm.profile=false', '-Ddart.vm.product=false', '-DDEV_PRO=true'],
      allowsDevelopment: false
    ),
  ]) {
    test('${mode.name} stays Free by default and enforces development-provider installation', () async {
      expect(dart.existsSync(), isTrue, reason: 'Dart SDK must accompany the Flutter test engine');
      final result = await Process.run(dart.path, [
        ...mode.defines,
        '--packages=.dart_tool/package_config.json',
        'test/fixtures/entitlements/application_entitlements_probe.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final facts = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(facts['before'], isFalse, reason: 'Mode and defines never authorize Pro');
      expect(facts['production'], isFalse);
      expect(facts['installed'], mode.allowsDevelopment);
      expect(facts['after'], mode.allowsDevelopment);
    });
  }
}
