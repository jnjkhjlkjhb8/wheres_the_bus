import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
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

    await tester.tap(find.text('南部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('集集線'), findsNothing);
  });
}
