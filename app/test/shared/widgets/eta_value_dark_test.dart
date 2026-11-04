import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';

/// "進站中" and "即將進站" are the words a rider acts on; the light-surface
/// values measure about 3.2:1 on a dark sheet.
void main() {
  Future<Color?> colorOf(
    WidgetTester tester,
    EtaStatus status,
    String word, {
    required bool dark,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        theme: dark ? AppTheme.dark : AppTheme.light,
        home: Scaffold(body: EtaValue(status: status)),
      ),
    );
    return tester.widget<Text>(find.text(word)).style!.color;
  }

  testWidgets('arriving uses the light-surface green on a light theme', (
    tester,
  ) async {
    expect(
      await colorOf(tester, const EtaArriving(), '進站中', dark: false),
      AppTheme.statusArrivingText,
    );
  });

  testWidgets('arriving uses the lighter green on a dark theme', (
    tester,
  ) async {
    expect(
      await colorOf(tester, const EtaArriving(), '進站中', dark: true),
      AppTheme.statusArriving,
    );
  });

  testWidgets('approaching uses the light-surface orange on a light theme', (
    tester,
  ) async {
    expect(
      await colorOf(tester, const EtaApproaching(), '即將進站', dark: false),
      AppTheme.etaApproaching,
    );
  });

  testWidgets('approaching uses the lighter orange on a dark theme', (
    tester,
  ) async {
    expect(
      await colorOf(tester, const EtaApproaching(), '即將進站', dark: true),
      AppTheme.statusApproach,
    );
  });
}
