import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/features/settings/offline_bus_cities_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/haptic_log.dart';

bool _checked(WidgetTester tester, String city) => tester
    .widget<Visibility>(
      find.descendant(
        of: find.ancestor(of: find.text(city), matching: find.byType(Row)),
        matching: find.byType(Visibility),
      ),
    )
    .visible;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline-bus-cities-');
    Hive.init(dir.path);
    await Hive.openBox<dynamic>('settings');
  });
  tearDown(() async {
    await Hive.box<dynamic>('settings').close();
    await dir.delete(recursive: true);
  });

  testWidgets('toggling a city saves the choice and applies it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await HiveStore.setChosenOfflineBusCities(['Taipei']);
      // Keelung comes from inference, not from the rider.
      await HiveStore.setOfflineBusCities(['Keelung', 'Taipei']);
    });
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: OfflineBusCitiesScreen(refresh: () async => refreshes++),
      ),
    );

    final semantics = tester.ensureSemantics();
    final haptics = captureHaptics();
    expect(find.text('自動加入'), findsOneWidget);
    // The row's own label leads; its Text children are merged in after it.
    expect(find.bySemanticsLabel(RegExp('^基隆市, 自動加入')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^台中市')), findsOneWidget);
    semantics.dispose();
    expect(_checked(tester, '基隆市'), isTrue); // inferred only
    expect(_checked(tester, '台北市'), isTrue); // chosen only
    expect(_checked(tester, '台中市'), isFalse);

    await tester.runAsync(() async {
      await tester.tap(find.text('新北市'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(HiveStore.chosenOfflineBusCities, ['NewTaipei', 'Taipei']);
    expect(haptics, ['HapticFeedbackType.selectionClick']);

    await tester.runAsync(() async {
      await tester.tap(find.text('台北市'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(HiveStore.chosenOfflineBusCities, ['NewTaipei']);
    expect(refreshes, 2);
  });
}
