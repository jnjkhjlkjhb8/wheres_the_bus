import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/tra_stations.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/clock_dial.dart';
import 'package:wheres_the_bus/shared/widgets/station_display_field.dart';
import 'package:wheres_the_bus/shared/widgets/tra_station_picker.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('bus-tra-picker-');
    Hive.init(directory.path);
    await HiveStore.init(initBinding: () async {});
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  setUp(() => HiveStore.settings.delete('tra_hemisphere'));


  final north = TraStations.data['北部']!;
  final south = TraStations.data['南部']!;

  Future<List<String?>> open(
    WidgetTester tester, {
    bool reduced = false,
  }) async {
    final results = <String?>[];
    // The dialog is built under the Navigator's overlay, outside any
    // MediaQuery wrapped around `home`, so reduce-motion has to come from the
    // platform.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: reduced);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(800, 1000)),
          child: Scaffold(
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
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  // The picker fires its Hive write without awaiting it. Tapping inside
  // runAsync keeps the write on the real event loop; one started in the test's
  // fake-async zone is left half-done and blocks the box's write lock.
  Future<void> tapHemisphere(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  List<StationDisplayField> fields(WidgetTester tester) => tester
      .widgetList<StationDisplayField>(find.byType(StationDisplayField))
      .toList();

  ClockDial dial(WidgetTester tester) =>
      tester.widget<ClockDial>(find.byType(ClockDial));

  testWidgets('opens on 北部 showing its first region and station', (
    tester,
  ) async {
    await open(tester);
    final shown = fields(tester);
    expect(shown.map((f) => f.value), [north.keys.first, north.values.first.first]);
    expect(shown.map((f) => f.active), [true, false]);
    expect(dial(tester).items, north.keys.toList());
    expect(dial(tester).selectedIndex, 0);
  });

  testWidgets('a remembered 南部 reopens on the south', (tester) async {
    await tester.runAsync(() => HiveStore.setTraHemisphere('南部'));
    await open(tester);
    expect(dial(tester).items, south.keys.toList());
    expect(fields(tester).first.value, south.keys.first);
  });

  testWidgets('an unknown remembered half falls back to 北部', (tester) async {
    await tester.runAsync(() => HiveStore.setTraHemisphere('中部'));
    await open(tester);
    expect(dial(tester).items, north.keys.toList());
  });

  testWidgets('the dialog is titled, padded and rounded like the other modals', (
    tester,
  ) async {
    await open(tester);
    final scheme = Theme.of(tester.element(find.byType(Dialog))).colorScheme;
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, scheme.surfaceContainerHigh);
    expect(
      dialog.shape,
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusModal),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Padding &&
              w.padding ==
                  const EdgeInsets.fromLTRB(
                    AppTheme.space24,
                    AppTheme.space24,
                    AppTheme.space24,
                    AppTheme.space16,
                  ),
        ),
      ),
      findsOneWidget,
    );
    final title = tester.widget<Text>(find.text('選擇車站'));
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(title.style?.color, scheme.onSurfaceVariant);
    expect(title.style?.fontSize, AppTextStyles.bodyRegular.fontSize);
    final barrier = tester.widget<ModalBarrier>(find.byType(ModalBarrier).last);
    expect(barrier.semanticsLabel, '選擇車站');
  });

  testWidgets('the sections are spaced by token', (tester) async {
    await open(tester);
    final column = tester.widget<Column>(
      find.ancestor(of: find.byType(ClockDial), matching: find.byType(Column)).first,
    );
    expect(column.mainAxisSize, MainAxisSize.min);
    expect(column.crossAxisAlignment, CrossAxisAlignment.start);
    final gaps = column.children.whereType<SizedBox>().map((b) => b.height);
    expect(gaps, [AppTheme.space20, AppTheme.space24, AppTheme.space16]);
  });

  testWidgets('releasing the dial moves on to the station tile', (tester) async {
    await open(tester);
    final dialRect = tester.getCenter(find.byType(ClockDial));
    final gesture = await tester.startGesture(dialRect + const Offset(0, -104));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fields(tester).map((f) => f.active), [false, true]);
    expect(dial(tester).items, north.values.first);
  });

  testWidgets('the tiles switch the dial between regions and stations', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(StationDisplayField).last);
    await tester.pumpAndSettle();
    expect(dial(tester).items, north.values.first);
    expect(fields(tester).map((f) => f.active), [false, true]);
    await tester.tap(find.byType(StationDisplayField).first);
    await tester.pumpAndSettle();
    expect(dial(tester).items, north.keys.toList());
    expect(fields(tester).map((f) => f.active), [true, false]);
  });

  testWidgets('switching half resets the dial and remembers the choice', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(StationDisplayField).last);
    await tester.pumpAndSettle();
    await tapHemisphere(tester, '南部');
    expect(HiveStore.traHemisphere, '南部');
    expect(dial(tester).items, south.keys.toList());
    expect(dial(tester).selectedIndex, 0);
    expect(fields(tester).map((f) => f.value), [
      south.keys.first,
      south.values.first.first,
    ]);
    expect(fields(tester).map((f) => f.active), [true, false]);
    await tapHemisphere(tester, '北部');
    expect(HiveStore.traHemisphere, '北部');
    expect(dial(tester).items, north.keys.toList());
  });

  testWidgets('confirm hands back the shown station', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(results, [north.values.first.first]);
  });

  testWidgets('the footer buttons sit at the end, 8 apart', (tester) async {
    await open(tester);
    final cancel = tester.getRect(find.text('取消'));
    final confirm = tester.getRect(find.text('確定'));
    expect(confirm.left, greaterThan(cancel.right));
    final row = tester.widget<Row>(
      find.ancestor(of: find.text('取消'), matching: find.byType(Row)).first,
    );
    expect(row.mainAxisAlignment, MainAxisAlignment.end);
  });

  group('hemisphere toggle', () {
    testWidgets('stacks two 52 by 38 cells in an 8 radius outline', (
      tester,
    ) async {
      await open(tester);
      final scheme = Theme.of(tester.element(find.byType(Dialog))).colorScheme;
      final toggle = tester.widget<Container>(
        find.ancestor(of: find.text('北部'), matching: find.byType(Container)).last,
      );
      final decoration = toggle.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(8));
      expect(decoration.border, Border.all(color: scheme.outline));
      expect(toggle.clipBehavior, Clip.antiAlias);
      for (final label in ['北部', '南部']) {
        final cell = find.ancestor(of: find.text(label), matching: find.byType(SizedBox)).first;
        expect(tester.getSize(cell), const Size(52, 38));
      }
      final north = tester.widget<AnimatedContainer>(
        find.ancestor(of: find.text('北部'), matching: find.byType(AnimatedContainer)),
      );
      final south = tester.widget<AnimatedContainer>(
        find.ancestor(of: find.text('南部'), matching: find.byType(AnimatedContainer)),
      );
      expect(
        (north.decoration! as BoxDecoration).border,
        Border(bottom: BorderSide(color: scheme.outline)),
      );
      expect((south.decoration! as BoxDecoration).border, isNull);
      expect(north.curve, AppMotion.easeOut);
    });

    testWidgets('fades the active cell over the micro duration', (tester) async {
      await open(tester);
      final cell = tester.widget<AnimatedContainer>(
        find.ancestor(of: find.text('北部'), matching: find.byType(AnimatedContainer)),
      );
      expect(cell.duration, AppMotion.micro);
    });

    testWidgets('reduce motion makes the switch instant', (tester) async {
      await open(tester, reduced: true);
      final cell = tester.widget<AnimatedContainer>(
        find.ancestor(of: find.text('北部'), matching: find.byType(AnimatedContainer)),
      );
      expect(cell.duration, Duration.zero);
    });

    testWidgets('the active cell is tinted and bold-ish at 13 points', (
      tester,
    ) async {
      await open(tester);
      final scheme = Theme.of(tester.element(find.byType(Dialog))).colorScheme;
      final active = tester.widget<Text>(find.text('北部'));
      final idle = tester.widget<Text>(find.text('南部'));
      expect(active.style?.fontWeight, FontWeight.w600);
      expect(active.style?.fontSize, 13);
      expect(idle.style?.fontSize, 13);
      expect(active.style?.color, scheme.onTertiaryContainer);
      expect(idle.style?.color, scheme.onSurfaceVariant);
      final separator = tester.widget<Text>(find.text(':'));
      expect(separator.style?.fontWeight, FontWeight.w400);
      expect(separator.style?.color, scheme.onSurfaceVariant);
      final padding = tester.widget<Padding>(
        find.ancestor(of: find.text(':'), matching: find.byType(Padding)).first,
      );
      expect(
        padding.padding,
        const EdgeInsets.symmetric(horizontal: AppTheme.space6),
      );
    });
  });
}
