import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  const schedule = [
    MetroSchedule(
      line: 'BL',
      destination: '南港展覽館',
      firstTime: '06:02',
      lastTime: '00:37',
    ),
    MetroSchedule(
      line: 'BR',
      destination: '動物園',
      firstTime: '06:00',
      lastTime: '00:40',
    ),
  ];

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,

      theme: AppTheme.light,
      home: Scaffold(body: child),
    ),
  );

  group('metroServiceStatus', () {
    test('midday counts as running', () {
      final s = metroServiceStatus(schedule, DateTime(2026, 7, 12, 12));
      expect(s.state, MetroServiceState.running);
    });

    test('after the last past-midnight train counts as ended', () {
      // 00:50 is after every 00:3x/00:40 last train.
      final s = metroServiceStatus(schedule, DateTime(2026, 7, 12, 0, 50));
      expect(s.state, MetroServiceState.ended);
      expect(s.lastTrain, '00:40');
      expect(s.firstTrain, '06:00');
      expect(s.firstDestination, '動物園');
    });

    test('an evening time before midnight is still running', () {
      final s = metroServiceStatus(schedule, DateTime(2026, 7, 12, 23, 30));
      expect(s.state, MetroServiceState.running);
    });

    test('pre-dawn before the first train counts as before-first', () {
      final s = metroServiceStatus(schedule, DateTime(2026, 7, 12, 5));
      expect(s.state, MetroServiceState.beforeFirst);
    });
  });

  testWidgets('closed-service card renders when service has ended', (
    tester,
  ) async {
    await pump(
      tester,
      MetroArrivalsEmpty(schedule: schedule, now: DateTime(2026, 7, 12, 0, 50)),
    );

    expect(find.text('今日已收班'), findsOneWidget);
    expect(find.text('末班車已於 00:40 發出'), findsOneWidget);
    expect(find.text('06:00'), findsOneWidget);
    expect(find.text('明日首班 · 往 動物園'), findsOneWidget);
    // Not the old dead-end string.
    expect(find.text('此站目前沒有班次資訊'), findsNothing);
  });

  testWidgets(
    'running service with no live data reports a feed failure, not silence',
    (tester) async {
      await pump(
        tester,
        MetroArrivalsEmpty(schedule: schedule, now: DateTime(2026, 7, 12, 12)),
      );

      expect(find.text('收不到即時到站資料'), findsOneWidget);
      expect(find.text('目前無法取得資料，請聯絡開發者'), findsOneWidget);
      expect(find.text('今日已收班'), findsNothing);
      // Not the old dead-end string.
      expect(find.text('此站目前沒有班次資訊'), findsNothing);
    },
  );

  testWidgets('no schedule at all falls back to the running copy', (
    tester,
  ) async {
    await pump(tester, const MetroArrivalsEmpty(schedule: []));
    expect(find.text('收不到即時到站資料'), findsOneWidget);
  });

  testWidgets('retry action fires onRetry when tapped in the running branch', (
    tester,
  ) async {
    var tapped = false;
    await pump(
      tester,
      MetroArrivalsEmpty(
        schedule: schedule,
        now: DateTime(2026, 7, 12, 12),
        onRetry: () => tapped = true,
      ),
    );

    expect(find.text('重新載入'), findsOneWidget);
    await tester.tap(find.text('重新載入'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('no retry affordance renders in the ended branch', (
    tester,
  ) async {
    await pump(
      tester,
      MetroArrivalsEmpty(
        schedule: schedule,
        now: DateTime(2026, 7, 12, 0, 50),
        onRetry: () {},
      ),
    );

    expect(find.text('重新載入'), findsNothing);
  });
}
