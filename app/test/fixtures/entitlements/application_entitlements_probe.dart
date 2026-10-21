import 'dart:convert';
import 'dart:io';

import 'package:omi/entitlements/entitlement_service.dart';

import '../../support/test_entitlement_service.dart';

// A console-only test probe, not an application entry point. It exercises the
// actual compiler-mode guards without depending on any private developer file.
void main() {
  final before = ApplicationEntitlements.current.isPro;
  var installed = false;
  try {
    ApplicationEntitlements.installLocalDevelopment(TestEntitlementService(isPro: true));
    installed = true;
  } on UnsupportedError {
    // Profile and Release must reject even an explicitly supplied test provider.
  }
  stdout.writeln(jsonEncode({
    'before': before,
    'installed': installed,
    'after': ApplicationEntitlements.current.isPro,
    'production': const LocalEntitlementService().isPro,
  }));
}
