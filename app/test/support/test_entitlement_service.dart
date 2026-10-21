import 'package:omi/entitlements/entitlement_service.dart';

/// Simulated entitlements live only in the test tree, never in an application build.
class TestEntitlementService implements EntitlementService {
  TestEntitlementService({this.isPro = false});

  @override
  bool isPro;
}
