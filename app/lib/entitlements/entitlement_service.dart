/// Replace this provider when real entitlements exist; integrations need only this fact.
abstract interface class EntitlementService {
  bool get isPro;
}

/// The production provider remains Free until verified entitlements exist.
/// Debug mode, build flags and local preferences never authorize Pro here.
class LocalEntitlementService implements EntitlementService {
  const LocalEntitlementService();

  @override
  bool get isPro => false;
}

/// Shared startup composition for the automation policy and integration UI.
/// The public entry point installs nothing. A separate ignored entry point may
/// supply a private provider in Debug; no development authorization lives here.
final class ApplicationEntitlements {
  ApplicationEntitlements._();

  // The same compiler constants used by Flutter's kDebugMode. Keeping this
  // library independent of UI allows the actual guards to be tested in each mode.
  static const _compilerIsDebug = !bool.fromEnvironment('dart.vm.product') && !bool.fromEnvironment('dart.vm.profile');
  // Flutter permits overriding Profile mode defines for benchmarks. A mode
  // define alone must not make a build without Debug assertions accept a provider.
  static final _isDebugBuild = _compilerIsDebug && _hasDebugAssertions();
  static const EntitlementService _production = LocalEntitlementService();
  static EntitlementService? _localDevelopment;

  static EntitlementService get current => _isDebugBuild ? _localDevelopment ?? _production : _production;

  /// Call before the app starts. Null restores the production provider.
  /// Both installation and selection reject development providers outside Debug.
  static void installLocalDevelopment(EntitlementService? provider) {
    if (!_isDebugBuild) throw UnsupportedError('Local development entitlements require a Debug build.');
    _localDevelopment = provider;
  }

  static bool _hasDebugAssertions() {
    var enabled = false;
    assert(enabled = true);
    return enabled;
  }
}
