import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/entitlements/entitlement_service.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/pages/settings/integration_settings_model.dart';
import 'package:omi/pages/settings/integrations_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../recordings/folder_export_integration_test.dart' show FakeFolder;
import '../../../support/test_entitlement_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesUtil prefs;
  final secure = <String, String>{};

  setUp(() async {
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        if (call.method == 'write') secure[args['key'] as String] = args['value'] as String;
        if (call.method == 'read') return secure[args['key'] as String];
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    FolderExportConnector.defaultBackend = FakeFolder();
  });

  tearDown(() {
    FolderExportConnector.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
  });

  Future<void> configure(IntegrationId id) async {
    switch (id) {
      case IntegrationId.heypocket:
        await prefs.setHeypocketApiKey('pk_test_configuration');
        prefs.heypocketEnabled = true;
      case IntegrationId.omiCloud:
        await prefs.setOmiRefreshToken('test-refresh');
        await prefs.setOmiFirebaseApiKey('test-api-key');
        await prefs.setOmiIdToken('test-id');
        prefs.omiTokenExpiry = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
        prefs.omiEnabled = true;
      case IntegrationId.folderExport:
        prefs.folderExportTreeUri = 'content://test-folder';
        prefs.folderExportLabel = 'My recordings';
        prefs.folderExportEnabled = true;
    }
  }

  Future<void> withClient(Future<void> Function() action) =>
      http.runWithClient(action, () => MockClient((_) async => http.Response('{}', 200)));

  Future<void> mount(WidgetTester tester, {Listenable? changes, void Function(String, {bool autoOnly})? cancel}) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(), home: IntegrationsPage(integrationChanges: changes, onCancelUploads: cancel)));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, IntegrationId id) async {
    await tester.tap(find.byKey(ValueKey(id.storageKey)));
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester, IntegrationId id) {
    final indicator = find.byWidgetPredicate((widget) => widget is IntegrationStatusIndicator && widget.id == id);
    return tester.widget<Tooltip>(find.descendant(of: indicator, matching: find.byType(Tooltip))).message!;
  }

  testWidgets('automation controls notify the owner with the newly saved values while settings stay open',
      (tester) async {
    ApplicationEntitlements.installLocalDevelopment(TestEntitlementService(isPro: true));
    addTearDown(() => ApplicationEntitlements.installLocalDevelopment(null));
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await configure(IntegrationId.heypocket);
    prefs.heypocketAutoUpload = true;
    final rules = AutomationSettings(prefs, 'heypocket');
    final observed = <String>[];
    await withClient(() async {
      await tester.pumpWidget(MaterialApp(home: IntegrationsPage(onAutomationChanged: () {
        observed.add('${rules.scope.name}|${rules.minimumSeconds}|${rules.wifiOnly}|${prefs.heypocketAutoUpload}');
      })));
      await tester.pumpAndSettle();
      await open(tester, IntegrationId.heypocket);
      await tester.tap(find.byType(DropdownButtonFormField<AutomaticRecordingScope>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Priority Recordings').last);
      await tester.pumpAndSettle();
      expect(observed.last, 'priority|0|false|true');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('300 seconds').last);
      await tester.pumpAndSettle();
      expect(observed.last, 'priority|300|false|true');
      await tester.ensureVisible(find.text('Wi-Fi only'));
      await tester.tap(find.text('Wi-Fi only'));
      await tester.pumpAndSettle();
      expect(observed.last, 'priority|300|true|true');
      await tester.ensureVisible(find.text('Auto-Upload'));
      await tester.tap(find.text('Auto-Upload'));
      await tester.pumpAndSettle();
      expect(observed.last, 'priority|300|true|false');
      expect(observed, hasLength(4));
      // Rebuilds are presentation only, and saved rules survive preference reload.
      await tester.pump();
      expect(observed, hasLength(4));
      await SharedPreferencesUtil.init();
      expect(rules.scope, AutomaticRecordingScope.priority);
      expect(rules.minimumSeconds, 300);
      expect(rules.wifiOnly, isTrue);
      expect(prefs.heypocketAutoUpload, isFalse);
    });
  });

  testWidgets('opening Omi settings offline preserves the enabled connection and automation rules', (tester) async {
    await configure(IntegrationId.omiCloud);
    prefs.omiAutoUpload = true;
    final rules = AutomationSettings(prefs, 'omi')
      ..scope = AutomaticRecordingScope.priority
      ..minimumSeconds = 60
      ..wifiOnly = true
      ..backfillIds = ['test-archive'];
    final cancelled = <String>[];
    await http.runWithClient(() async {
      await mount(tester, cancel: (name, {autoOnly = false}) => cancelled.add(name));
      expect(status(tester, IntegrationId.omiCloud), 'Enabled');
      await open(tester, IntegrationId.omiCloud);
      expect(prefs.omiEnabled, isTrue);
      expect(prefs.omiRefreshToken, 'test-refresh');
      expect(prefs.omiFirebaseApiKey, 'test-api-key');
      expect(prefs.omiAutoUpload, isTrue);
      expect(rules.scope, AutomaticRecordingScope.priority);
      expect(rules.minimumSeconds, 60);
      expect(rules.wifiOnly, isTrue);
      expect(rules.backfillIds, ['test-archive']);
      expect(cancelled, isEmpty);
    }, () => MockClient((_) async => throw const SocketException('Offline')));
  });

  for (final responseStatus in [429, 503]) {
    testWidgets('opening Omi settings during HTTP $responseStatus preserves the enabled connection', (tester) async {
      await configure(IntegrationId.omiCloud);
      final cancelled = <String>[];
      await http.runWithClient(() async {
        await mount(tester, cancel: (name, {autoOnly = false}) => cancelled.add(name));
        await open(tester, IntegrationId.omiCloud);
        expect(prefs.omiEnabled, isTrue);
        expect(cancelled, isEmpty);
      }, () => MockClient((_) async => http.Response('{}', responseStatus)));
    });
  }

  testWidgets('confirmed Omi credential rejection still disables the connection and cancels uploads', (tester) async {
    await configure(IntegrationId.omiCloud);
    final cancelled = <String>[];
    await http.runWithClient(() async {
      await mount(tester, cancel: (name, {autoOnly = false}) => cancelled.add(name));
      expect(status(tester, IntegrationId.omiCloud), 'Needs attention');
      expect(prefs.omiEnabled, isFalse);
      expect(cancelled, ['Omi Cloud']);
      expect(prefs.omiRefreshToken, 'test-refresh');
    }, () => MockClient((_) async => http.Response('{"error":{"message":"INVALID_REFRESH_TOKEN"}}', 400)));
  });

  testWidgets('an unavailable edited Omi credential check preserves the saved working connection', (tester) async {
    await configure(IntegrationId.omiCloud);
    final cancelled = <String>[];
    await withClient(() async {
      final model = IntegrationSettingsModel(
        checkOmi: (rt, _) async {
          if (rt == 'test-refresh') return true;
          throw const OmiSyncException('Connection unavailable');
        },
        onCancelUploads: (name, {autoOnly = false}) => cancelled.add(name),
      )..start();
      addTearDown(model.dispose);
      await tester.pumpAndSettle();
      model.omiRefreshTokenController.text = 'test-unsaved-refresh';
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(model.connection(IntegrationId.omiCloud), IntegrationConnectionState.error);
      expect(prefs.omiEnabled, isTrue);
      expect(prefs.omiRefreshToken, 'test-refresh');
      expect(prefs.omiFirebaseApiKey, 'test-api-key');
      expect(cancelled, isEmpty);
    });
  });

  testWidgets('compact list opens only the selected settings and returns without overflow', (tester) async {
    await mount(tester);
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(tester.widgetList<ListTile>(find.byType(ListTile)).map((row) => (row.title! as Text).data),
        ['Save to Folder', 'Omi Cloud (unofficial)', 'HeyPocket']);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(3));
    expect(find.text('Upload recordings to HeyPocket'), findsNothing);
    await open(tester, IntegrationId.heypocket);
    expect(find.text('HeyPocket'), findsOneWidget);
    expect(find.text('Omi Cloud (unofficial)'), findsNothing);
    expect(find.text('Save to Folder'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Auto-Upload'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('grey, yellow and green describe configuration and Enabled, not automation', (tester) async {
    await configure(IntegrationId.heypocket);
    prefs.heypocketEnabled = false;
    await configure(IntegrationId.folderExport);
    prefs.folderExportAutoUpload = false;
    await withClient(() async {
      await mount(tester);
      expect(status(tester, IntegrationId.omiCloud), 'Not configured');
      expect(status(tester, IntegrationId.heypocket), 'Disabled');
      expect(status(tester, IntegrationId.folderExport), 'Enabled');
      final model = tester.widget<IntegrationStatusIndicator>(find.byType(IntegrationStatusIndicator).first).model;
      expect(model.entitlements.isPro, isFalse);
    });
  });

  testWidgets('Edit hides disabled integrations, restores them and resets on reopening', (tester) async {
    await mount(tester);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('visibility-heypocket')));
    await tester.pumpAndSettle();
    expect(prefs.hiddenIntegrations, ['heypocket']);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('HeyPocket'), findsNothing);
    expect(find.text('Hidden integrations (1)'), findsOneWidget);
    await tester.tap(find.text('Hidden integrations (1)'));
    await tester.pumpAndSettle();
    expect(find.text('HeyPocket'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('visibility-heypocket')));
    await tester.pumpAndSettle();
    expect(prefs.hiddenIntegrations, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
  });

  testWidgets('all-hidden list always offers recovery', (tester) async {
    prefs.hiddenIntegrations = IntegrationId.values.map((id) => id.storageKey).toList();
    await mount(tester);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('No integrations shown'), findsOneWidget);
    await tester.tap(find.text('Hidden integrations (3)'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(3));
    await tester.tap(find.byKey(const ValueKey('visibility-omiCloud')));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Omi Cloud (unofficial)'), findsOneWidget);
    expect(find.text('Hidden integrations (2)'), findsOneWidget);
  });

  testWidgets('real drag reorders rows and ordering survives a new navigation session', (tester) async {
    await mount(tester);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.drag_handle).first));
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(find.byKey(const ValueKey('heypocket'))) + const Offset(-20, 40));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(prefs.integrationListOrder, ['omiCloud', 'heypocket', 'folderExport']);
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    expect(tester.widgetList<ListTile>(find.byType(ListTile)).map((row) => (row.title! as Text).data),
        ['Omi Cloud (unofficial)', 'HeyPocket', 'Save to Folder']);
  });

  testWidgets('enabled integration cannot be hidden; hidden integrations reappear when enabled', (tester) async {
    final changes = _IntegrationChanges();
    addTearDown(changes.dispose);
    await configure(IntegrationId.folderExport);
    prefs.hiddenIntegrations = ['heypocket'];
    await mount(tester, changes: changes);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final hide = tester.widget<IconButton>(find.byKey(const ValueKey('visibility-folderExport')));
    expect(hide.onPressed, isNull);
    expect(hide.tooltip, 'Turn off in settings to hide');
    await configure(IntegrationId.heypocket);
    changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(prefs.hiddenIntegrations, isEmpty);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('HeyPocket'), findsOneWidget);
  });

  testWidgets('hiding preserves connection and saved automation rules', (tester) async {
    await configure(IntegrationId.heypocket);
    prefs.heypocketEnabled = false;
    prefs.heypocketAutoUpload = true;
    final cutoff = prefs.heypocketKeySetAt;
    final rules = AutomationSettings(prefs, 'heypocket')
      ..scope = AutomaticRecordingScope.priority
      ..minimumSeconds = 60
      ..wifiOnly = true
      ..backfillIds = ['test-archive'];
    await withClient(() async {
      await mount(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility-heypocket')));
      await tester.pumpAndSettle();
      expect(prefs.heypocketApiKey, 'pk_test_configuration');
      expect(prefs.heypocketAutoUpload, isTrue);
      expect(prefs.heypocketKeySetAt, cutoff);
      expect(rules.scope, AutomaticRecordingScope.priority);
      expect(rules.minimumSeconds, 60);
      expect(rules.wifiOnly, isTrue);
      expect(rules.backfillIds, ['test-archive']);
    });
  });

  test('unknown and duplicate preference IDs are normalized without changing settings', () {
    prefs.integrationListOrder = ['heypocket', 'unknown', 'heypocket'];
    prefs.hiddenIntegrations = ['unknown', 'folderExport', 'folderExport'];
    final model = IntegrationSettingsModel()..start();
    addTearDown(model.dispose);
    expect(model.order, [IntegrationId.heypocket, IntegrationId.folderExport, IntegrationId.omiCloud]);
    expect(prefs.integrationListOrder, ['heypocket', 'folderExport', 'omiCloud']);
    expect(prefs.hiddenIntegrations, ['folderExport']);
  });

  for (final id in IntegrationId.values) {
    testWidgets('${id.title} disconnect requires confirmation and cancels before clearing configuration',
        (tester) async {
      await configure(id);
      final cancelled = <String>[];
      await withClient(() async {
        await mount(tester, cancel: (name, {bool autoOnly = false}) {
          expect(autoOnly, isFalse);
          expect(
              prefs.omiRefreshToken.isNotEmpty ||
                  prefs.heypocketApiKey.isNotEmpty ||
                  prefs.folderExportTreeUri.isNotEmpty,
              isTrue);
          cancelled.add(name);
        });
        await open(tester, id);
        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(cancelled, isEmpty);
        final model = tester.widget<IntegrationStatusIndicator>(find.byType(IntegrationStatusIndicator)).model;
        expect(model.hasConfiguration(id), isTrue);
        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
        await tester.pumpAndSettle();
        expect(cancelled, [id.connectorName]);
        expect(model.hasConfiguration(id), isFalse);
        expect(model.enabled(id), isFalse);
        expect(find.byIcon(Icons.delete_outline), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(status(tester, id), 'Not configured');
      });
    });
  }

  testWidgets('checking and red error statuses retain an accessible explanation', (tester) async {
    await configure(IntegrationId.heypocket);
    final gate = Completer<bool>();
    final model = IntegrationSettingsModel(checkHeyPocket: (_) => gate.future)..start();
    addTearDown(model.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AnimatedBuilder(
                animation: model,
                builder: (_, __) => IntegrationStatusIndicator(model: model, id: IntegrationId.heypocket)))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(status(tester, IntegrationId.heypocket), 'Checking');
    gate.complete(false);
    await tester.pumpAndSettle();
    expect(status(tester, IntegrationId.heypocket), 'Needs attention');
    expect(prefs.heypocketEnabled, isFalse);
  });

  testWidgets('unavailable folder shows red and can be disabled without removing its saved destination',
      (tester) async {
    await configure(IntegrationId.folderExport);
    FolderExportConnector.defaultBackend = FakeFolder()..access = false;
    await mount(tester);
    expect(status(tester, IntegrationId.folderExport), 'Needs attention');
    await open(tester, IntegrationId.folderExport);
    expect(find.textContaining('The app can no longer write to this folder'), findsOneWidget);
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.folderExportEnabled, isFalse);
    expect(prefs.folderExportTreeUri, 'content://test-folder');
  });

  testWidgets('runtime Enabled updates reach dots; leaving UI removes only its subscription', (tester) async {
    await configure(IntegrationId.folderExport);
    final changes = _IntegrationChanges();
    addTearDown(changes.dispose);
    await mount(tester, changes: changes);
    expect(changes.isObserved, isTrue);
    prefs.folderExportEnabled = false;
    changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(status(tester, IntegrationId.folderExport), 'Disabled');
    await open(tester, IntegrationId.folderExport);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(changes.isObserved, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(changes.isObserved, isFalse);
    changes.notifyListeners(); // the shared service remains usable
  });

  testWidgets('late HeyPocket validation cannot reconnect after disconnect', (tester) async {
    final gate = Completer<bool>();
    final model = IntegrationSettingsModel(checkHeyPocket: (_) => gate.future)..start();
    addTearDown(model.dispose);
    model.heypocketController.text = 'pk_test_delayed_validation';
    await tester.pump(const Duration(milliseconds: 900));
    expect(model.connection(IntegrationId.heypocket), IntegrationConnectionState.checking);
    await model.disconnect(IntegrationId.heypocket);
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(prefs.heypocketApiKey, isEmpty);
    expect(prefs.heypocketEnabled, isFalse);
    expect(model.connection(IntegrationId.heypocket), IntegrationConnectionState.idle);
  });

  testWidgets('late Omi login validation cannot restore authentication after disconnect', (tester) async {
    final gate = Completer<bool>();
    final model = IntegrationSettingsModel(checkOmi: (_, __) => gate.future)..start();
    addTearDown(model.dispose);
    final pending = model.acceptOmiLogin({'refreshToken': 'test-refresh', 'apiKey': 'test-api-key'});
    await model.disconnect(IntegrationId.omiCloud);
    gate.complete(true);
    await pending;
    expect(prefs.omiRefreshToken, isEmpty);
    expect(prefs.omiFirebaseApiKey, isEmpty);
    expect(prefs.omiEnabled, isFalse);
  });

  testWidgets('disconnect clears credentials after an already-started secure-storage save', (tester) async {
    final gate = Completer<void>();
    var saving = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        if (call.method == 'write') {
          final value = args['value'] as String;
          if (value.isNotEmpty) {
            saving = true;
            await gate.future;
          }
          secure[args['key'] as String] = value;
        }
        return null;
      },
    );
    final model = IntegrationSettingsModel(checkHeyPocket: (_) async => true)..start();
    addTearDown(model.dispose);
    model.heypocketController.text = 'pk_test_pending_storage';
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    expect(saving, isTrue);
    final disconnect = model.disconnect(IntegrationId.heypocket);
    gate.complete();
    await disconnect;
    expect(prefs.heypocketApiKey, isEmpty);
    expect(secure['heypocketApiKey'], isEmpty);
    expect(prefs.heypocketEnabled, isFalse);
  });

  testWidgets('an old launch check cannot disable a newly validated HeyPocket configuration', (tester) async {
    await configure(IntegrationId.heypocket);
    final oldCheck = Completer<bool>();
    final model = IntegrationSettingsModel(
        checkHeyPocket: (key) => key == 'pk_test_configuration' ? oldCheck.future : Future.value(true))
      ..start();
    addTearDown(model.dispose);
    model.heypocketController.text = 'pk_test_new_configuration';
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    oldCheck.complete(false);
    await tester.pumpAndSettle();
    expect(prefs.heypocketApiKey, 'pk_test_new_configuration');
    expect(prefs.heypocketEnabled, isTrue);
    expect(model.connection(IntegrationId.heypocket), IntegrationConnectionState.connected);
  });

  testWidgets('disposal discards validation results without writing credentials or notifying widgets', (tester) async {
    final gate = Completer<bool>();
    final model = IntegrationSettingsModel(checkHeyPocket: (_) => gate.future)..start();
    model.heypocketController.text = 'pk_test_disposed_validation';
    await tester.pump(const Duration(milliseconds: 900));
    model.dispose();
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(prefs.heypocketApiKey, isEmpty);
    expect(prefs.heypocketEnabled, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _IntegrationChanges extends ChangeNotifier {
  bool get isObserved => hasListeners;
}
