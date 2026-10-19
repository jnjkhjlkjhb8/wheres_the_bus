import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/tra_stations.dart';
import 'package:wheres_the_bus/shared/widgets/clock_dial.dart';
import 'package:wheres_the_bus/shared/widgets/tra_station_picker.dart';

Widget host() => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => showTRAStationPicker(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_tra_station_picker');
    await HiveStore.init(initBinding: () async {});
  });

  // The picker persists the half it was last opened on, and the Hive box
  // outlives the process — without this every run after the first would open
  // on whichever half the previous run's last test left behind.
  setUp(() => HiveStore.setTraHemisphere('北部'));

  testWidgets('releasing after picking a region advances to station select', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // '集集線' is a region label only — it is never a station name, so it is
    // present in region mode and absent once the dial switches to stations.
    expect(find.text('集集線'), findsOneWidget);

    // Press and hold on the dial keeps it in region mode — no dwell auto-
    // advance. Only lifting the finger (release) advances to station select.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ClockDial)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('集集線'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('集集線'), findsNothing);
  });

  testWidgets('reopens on the half last used', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // '集集線' is a 北部 region label, so its presence in region mode is the
    // proxy for which half the dial opened on.
    expect(find.text('集集線'), findsOneWidget);

    // The tap fires an unawaited Hive write. Run it on the real event loop: a
    // write started inside the test's fake-async zone is left half-done when
    // the test ends, and the box's write lock then blocks the next setUp.
    await tester.runAsync(() async {
      await tester.tap(find.text('南部'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('集集線'), findsNothing);
  });

  Future<void> openPicker(WidgetTester tester, List<String?> results) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    results.add(await showTRAStationPicker(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Offset sector(WidgetTester tester, int index, int count) {
    const radius = 256 / 2 - 24;
    final angle = -pi / 2 + index / count * 2 * pi;
    return tester.getCenter(find.byType(ClockDial)) +
        Offset(radius * cos(angle), radius * sin(angle));
  }

  testWidgets('a station picked in station mode is the one confirmed', (
    tester,
  ) async {
    final results = <String?>[];
    await openPicker(tester, results);

    // 基隆 has six stations; releasing on its sector opens the station dial.
    await tester.tapAt(sector(tester, 0, 7));
    await tester.pumpAndSettle();
    await tester.tapAt(sector(tester, 2, 6));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();

    expect(results, ['八堵']);
  });

  testWidgets('choosing a region resets the station to its first', (
    tester,
  ) async {
    final results = <String?>[];
    await openPicker(tester, results);

    await tester.tapAt(sector(tester, 1, TraStations.data['北部']!.length));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();

    expect(results, ['五堵']);
  });

  testWidgets('cancel returns nothing', (tester) async {
    final results = <String?>[];
    await openPicker(tester, results);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('the header separator and hemisphere cells keep their type', (
    tester,
  ) async {
    await openPicker(tester, []);
    expect(tester.widget<Text>(find.text(':')).style?.fontSize, 36);

    final north = tester.widget<Text>(find.text('北部'));
    final south = tester.widget<Text>(find.text('南部'));
    final cs = Theme.of(tester.element(find.text('北部'))).colorScheme;
    expect(north.style?.fontSize, 13);
    expect(north.style?.color, cs.onTertiaryContainer);
    expect(south.style?.color, cs.onSurfaceVariant);

    BoxDecoration cell(String label) =>
        tester
                .widget<AnimatedContainer>(
                  find.ancestor(
                    of: find.text(label),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(cell('北部').color, cs.tertiaryContainer);
    expect(cell('北部').border, isNotNull);
    expect(cell('南部').color, isNull);
    expect(cell('南部').border, isNull);
  });
}
