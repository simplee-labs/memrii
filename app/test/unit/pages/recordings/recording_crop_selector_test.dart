import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/pages/recordings/recording_crop_selector.dart';

void main() {
  late ValueNotifier<(Duration, Duration)> range;
  late List<Duration> seeks;

  setUp(() {
    range = ValueNotifier((const Duration(seconds: 2), const Duration(seconds: 8)));
    seeks = [];
  });
  tearDown(() => range.dispose());

  Widget page({Duration total = const Duration(seconds: 10), bool enabled = true, double scale = 1}) => MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          appBar: AppBar(title: const Text('Crop recording')),
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ValueListenableBuilder(
                valueListenable: range,
                builder: (context, value, _) => RecordingCropSelector(
                  total: total,
                  start: value.$1,
                  end: value.$2,
                  enabled: enabled,
                  onChanged: (start, end) => range.value = (start, end),
                  onSeek: seeks.add,
                  waveformBuilder: (width) => SizedBox(
                    width: width,
                    height: 100,
                    child: const ColoredBox(color: Color(0xFF232323)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  void phone(WidgetTester tester, {double width = 390}) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  Finder control(String name) => find.byKey(ValueKey(name));

  testWidgets('full-range handles have large touch targets entirely on screen', (tester) async {
    phone(tester);
    range.value = (Duration.zero, const Duration(seconds: 10));
    await tester.pumpWidget(page());
    for (final name in ['crop-start-handle', 'crop-end-handle']) {
      final rect = tester.getRect(control(name));
      expect(rect.width, 48);
      expect(rect.height, 140);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
    }
    final start = tester.getRect(control('crop-start-handle'));
    // Grab the invisible margin beside the visible grip, as a finger often does.
    await tester.dragFrom(start.topLeft + Offset(2, start.height / 2), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(range.value.$1.inMilliseconds, greaterThan(0));
    expect(seeks, isEmpty, reason: 'grabbing a crop handle must not become a seek gesture');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an off-centre grab moves by the drag distance without jumping to the finger', (tester) async {
    phone(tester);
    await tester.pumpWidget(page());
    final start = tester.getRect(control('crop-start-handle'));
    final waveWidth = tester.getSize(find.byType(RecordingCropSelector)).width - 48;
    await tester.dragFrom(start.topLeft + Offset(1, start.height / 2), const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(range.value.$1.inMilliseconds, closeTo(2000 + 30 / waveWidth * 10000, 2));
    expect(range.value.$2, const Duration(seconds: 8));
    expect(seeks, isEmpty);
  });

  testWidgets('bounds clamp without crossing, and precision controls work when handles overlap', (tester) async {
    phone(tester);
    await tester.pumpWidget(page());
    await tester.drag(control('crop-start-handle'), const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(range.value.$1, const Duration(milliseconds: 7900));
    expect(range.value.$2, const Duration(seconds: 8));
    await tester.tap(control('crop-end-increase'));
    await tester.pump();
    expect(range.value.$2, const Duration(seconds: 9));
    await tester.drag(control('crop-end-handle'), const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(range.value.$2, const Duration(seconds: 10));
    expect(range.value.$1, const Duration(milliseconds: 7900));
  });

  testWidgets('one-second buttons adjust start and end separately with large targets', (tester) async {
    phone(tester);
    await tester.pumpWidget(page());
    for (final name in ['crop-start-increase', 'crop-end-decrease']) {
      final size = tester.getSize(control(name));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    await tester.tap(control('crop-start-increase'));
    await tester.pump();
    await tester.tap(control('crop-end-decrease'));
    await tester.pump();
    expect(range.value, (const Duration(seconds: 3), const Duration(seconds: 7)));
    expect(find.text('Selected 0:04'), findsOneWidget);
  });

  testWidgets('close handles separate vertically so each remains independently draggable', (tester) async {
    phone(tester);
    range.value = (const Duration(milliseconds: 7900), const Duration(seconds: 8));
    await tester.pumpWidget(page());
    final start = tester.getRect(control('crop-start-handle'));
    final end = tester.getRect(control('crop-end-handle'));
    expect(start.height, greaterThanOrEqualTo(48));
    expect(end.height, greaterThanOrEqualTo(48));
    expect(start.bottom, lessThanOrEqualTo(end.top));
    await tester.drag(control('crop-start-handle'), const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(range.value.$1.inMilliseconds, lessThan(7900));
    expect(range.value.$2, const Duration(seconds: 8));
    await tester.drag(control('crop-end-handle'), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(range.value.$2.inMilliseconds, greaterThan(8000));
    expect(seeks, isEmpty);
  });

  testWidgets('timestamps accept fractional seconds and reject invalid or crossed ranges', (tester) async {
    phone(tester);
    await tester.pumpWidget(page());
    await tester.tap(control('crop-start-time'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '00:03.125');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(range.value.$1, const Duration(milliseconds: 3125));
    await tester.tap(control('crop-end-time'));
    await tester.pumpAndSettle();
    for (final invalid in ['00:01', '00:60', 'Infinity', '1e309', '99999999999999999999999999:00']) {
      await tester.enterText(find.byType(TextField), invalid);
      await tester.tap(find.text('Set'));
      await tester.pump();
      expect(find.textContaining('Choose a time from'), findsOneWidget);
      expect(range.value.$2, const Duration(seconds: 8));
      expect(tester.takeException(), isNull);
    }
    await tester.enterText(find.byType(TextField), '00:09.250');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(range.value.$2, const Duration(milliseconds: 9250));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hour timestamps support precise cuts in long recordings', (tester) async {
    phone(tester);
    range.value = (const Duration(minutes: 20), const Duration(hours: 1));
    await tester.pumpWidget(page(total: const Duration(hours: 2)));
    await tester.tap(control('crop-end-time'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1:02:03.500');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(range.value.$2, const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500));
    expect(find.text('1:02:03.500'), findsOneWidget);
  });

  testWidgets('disabled controls cannot change a crop being saved, including accessibility actions', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(page(enabled: false));
    final before = range.value;
    await tester.drag(control('crop-start-handle'), const Offset(50, 0), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(range.value, before);
    expect(tester.widget<TextButton>(control('crop-start-increase')).onPressed, isNull);
    final data = tester.getSemantics(control('crop-start-handle')).getSemanticsData();
    expect(data.hasAction(ui.SemanticsAction.increase), isFalse);
    expect(data.hasAction(ui.SemanticsAction.decrease), isFalse);
    semantics.dispose();
  });

  testWidgets('controls fit a narrow phone with larger text', (tester) async {
    phone(tester, width: 320);
    await tester.pumpWidget(page(scale: 1.5));
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
