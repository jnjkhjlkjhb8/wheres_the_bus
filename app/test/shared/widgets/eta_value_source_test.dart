import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    EtaStatus status, {
    EtaSource source = EtaSource.live,
    bool muted = false,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      theme: AppTheme.light,
      home: Scaffold(
        body: EtaValue(status: status, source: source, muted: muted),
      ),
    ),
  );

  Color? colorOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.color;
  ColorScheme scheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(EtaValue))).colorScheme;

  testWidgets('a live time carries no qualifier and keeps full ink', (
    tester,
  ) async {
    await pump(tester, const EtaMinutes(5));
    expect(find.text('預估'), findsNothing);
    expect(colorOf(tester, '5'), scheme(tester).onSurface);
  });

  for (final source in [EtaSource.scheduled, EtaSource.predicted]) {
    group('$source', () {
      testWidgets('minutes drop to secondary ink and say 預估', (tester) async {
        await pump(tester, const EtaMinutes(5), source: source);
        expect(find.text('預估'), findsOneWidget);
        expect(colorOf(tester, '5'), scheme(tester).onSurfaceVariant);
        expect(colorOf(tester, '預估'), scheme(tester).onSurfaceVariant);
      });

      testWidgets('minute+second countdown is secondary and qualified', (
        tester,
      ) async {
        await pump(tester, const EtaMinutesSeconds(3, 5), source: source);
        expect(find.text('預估'), findsOneWidget);
        expect(colorOf(tester, '3'), scheme(tester).onSurfaceVariant);
        expect(colorOf(tester, '05'), scheme(tester).onSurfaceVariant);
      });

      testWidgets('a clock is secondary and qualified', (tester) async {
        await pump(tester, const EtaLabel('08:30'), source: source);
        expect(find.text('預估'), findsOneWidget);
        expect(colorOf(tester, '08:30'), scheme(tester).onSurfaceVariant);
      });

      testWidgets('arriving and approaching never take their status colours', (
        tester,
      ) async {
        await pump(tester, const EtaArriving(), source: source);
        expect(colorOf(tester, '進站中'), scheme(tester).onSurfaceVariant);
        expect(find.text('預估'), findsOneWidget);
        await pump(tester, const EtaApproaching(), source: source);
        expect(colorOf(tester, '即將進站'), scheme(tester).onSurfaceVariant);
        expect(find.text('預估'), findsOneWidget);
      });

      testWidgets('service words, the dash and muted rows are not qualified', (
        tester,
      ) async {
        await pump(tester, const EtaLabel('尚未發車'), source: source);
        expect(find.text('預估'), findsNothing);
        await pump(tester, const EtaUnknown(), source: source);
        expect(find.text('預估'), findsNothing);
        await pump(
          tester,
          const EtaLabel('08:30'),
          source: source,
          muted: true,
        );
        expect(find.text('預估'), findsNothing);
      });
    });
  }

  testWidgets('the tile passes the source down from its display', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        theme: AppTheme.light,
        home: const Scaffold(
          body: EtaListTile(
            routeNo: '307',
            destination: '板橋',
            status: EtaMinutes(4),
            source: EtaSource.predicted,
          ),
        ),
      ),
    );
    expect(find.text('預估'), findsOneWidget);
  });

  testWidgets('fromDisplay forwards the display source', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        theme: AppTheme.light,
        home: Scaffold(
          body: EtaListTile.fromDisplay(
            const ArrivalDisplay(
              label: '307',
              destination: '板橋',
              status: EtaMinutes(4),
              rank: 6,
              source: EtaSource.scheduled,
            ),
          ),
        ),
      ),
    );
    expect(find.text('預估'), findsOneWidget);
  });
}
