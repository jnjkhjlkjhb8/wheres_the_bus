import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/features/alerts/view/alert_source_chip.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../../support/helpers/i18n.dart';

void main() {
  group('alertRelativeTime', () {
    final now = DateTime(2026, 7, 12, 10);

    test('under a minute reads 剛剛', () {
      expect(
        alertRelativeTime(
          zhStrings,
          now.subtract(const Duration(seconds: 30)),
          now,
        ),
        '剛剛',
      );
    });

    test('minutes bucket', () {
      expect(
        alertRelativeTime(
          zhStrings,
          now.subtract(const Duration(minutes: 5)),
          now,
        ),
        '5 分鐘前',
      );
    });

    test('hours bucket', () {
      expect(
        alertRelativeTime(
          zhStrings,
          now.subtract(const Duration(hours: 3)),
          now,
        ),
        '3 小時前',
      );
    });

    test('previous calendar day beyond 24h reads 昨天', () {
      expect(alertRelativeTime(zhStrings, DateTime(2026, 7, 11, 6), now), '昨天');
    });

    test('older dates read M/d', () {
      expect(alertRelativeTime(zhStrings, DateTime(2026, 7, 8, 9), now), '7/8');
    });
  });

  group('AlertSourceChip', () {
    Future<void> pump(
      WidgetTester tester,
      AlertSource? source, {
      String? department,
    }) => tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: Scaffold(
          body: AlertSourceChip(source: source, department: department),
        ),
      ),
    );

    testWidgets('maps a metro operator code to its label', (tester) async {
      await pump(tester, const AlertSource(AlertSourceKind.metro, 'TRTC'));
      expect(find.text('北捷'), findsOneWidget);
    });

    testWidgets('renders rail labels', (tester) async {
      await pump(tester, const AlertSource(AlertSourceKind.thsr));
      expect(find.text('高鐵'), findsOneWidget);
    });

    testWidgets('renders nothing for a null source', (tester) async {
      await pump(tester, null);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets(
      "a bus alert's real department name wins over the hardcoded city map",
      (tester) async {
        await pump(
          tester,
          const AlertSource(AlertSourceKind.busAlert, 'Taipei'),
          department: '臺北市公共運輸處',
        );
        expect(find.text('臺北市公共運輸處'), findsOneWidget);
        expect(find.text('北市公車'), findsNothing);
      },
    );

    testWidgets(
      'a department that is just an operator code (no CJK) falls back to '
      'the hardcoded city map',
      (tester) async {
        await pump(
          tester,
          const AlertSource(AlertSourceKind.busAlert, 'Taipei'),
          department: 'THB',
        );
        expect(find.text('北市公車'), findsOneWidget);
      },
    );

    testWidgets('no department falls back to the hardcoded city map', (
      tester,
    ) async {
      await pump(tester, const AlertSource(AlertSourceKind.busAlert, 'Taipei'));
      expect(find.text('北市公車'), findsOneWidget);
    });
  });
}
