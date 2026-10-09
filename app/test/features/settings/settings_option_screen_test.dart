import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/settings/settings_option_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

void main() {
  testWidgets('option row tap target is at least 44x44 (HIG minimum)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: SettingsOptionScreen(
          title: 'Test',
          options: ['A', 'B', 'C'],
          initialSelected: 'A',
        ),
      ),
    );

    for (final label in ['A', 'B', 'C']) {
      final row = find.widgetWithText(Pressable, label);
      expect(row, findsOneWidget);
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(44),
        reason: 'option row tap target must be >= 44 logical px tall',
      );
    }
  });
}
