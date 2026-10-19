import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
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
      ThemeData? theme,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: theme,
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

    testWidgets(
      'bus labels cover all cities, unknown feeds and empty department',
      (
        tester,
      ) async {
        final labels = {
          'NewTaipei': zhStrings.operatorBusNewTaipei,
          'Taoyuan': zhStrings.operatorBusTaoyuan,
          'Taichung': zhStrings.operatorBusTaichung,
          'Tainan': zhStrings.operatorBusTainan,
          'Kaohsiung': zhStrings.operatorBusKaohsiung,
          'unknown': zhStrings.modeBus,
        };
        for (final entry in labels.entries) {
          await pump(
            tester,
            AlertSource(AlertSourceKind.busAlert, entry.key),
            department: '',
          );
          expect(find.text(entry.value), findsOneWidget);
        }
      },
    );

    group('colors', () {
      final light = ThemeData(colorScheme: const ColorScheme.light());
      final dark = ThemeData(colorScheme: const ColorScheme.dark());

      Future<(Color?, Color?)> chipColors(
        WidgetTester tester,
        AlertSource source,
        ThemeData theme,
      ) async {
        await pump(tester, source, theme: theme);
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(AlertSourceChip),
            matching: find.byType(Container),
          ),
        );
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byType(AlertSourceChip),
            matching: find.byType(Text),
          ),
        );
        return ((box.decoration! as BoxDecoration).color, label.style?.color);
      }

      const bus = AlertSource(AlertSourceKind.busAlert, 'Taipei');
      const metro = AlertSource(AlertSourceKind.metro, 'TRTC');

      testWidgets('the Ink bus chip is dark with a white label in light', (
        tester,
      ) async {
        expect(
          await chipColors(tester, bus, light),
          (AppTheme.inkLight, Colors.white),
        );
      });

      testWidgets('the Ink bus chip swaps to the inverse surface in dark', (
        tester,
      ) async {
        expect(
          await chipColors(tester, bus, dark),
          (dark.colorScheme.inverseSurface, dark.colorScheme.onInverseSurface),
        );
      });

      testWidgets('an operator color stands on its own in both themes', (
        tester,
      ) async {
        for (final theme in [light, dark]) {
          expect(
            await chipColors(tester, metro, theme),
            (AppTheme.mrtBL, Colors.white),
          );
        }
      });

      testWidgets('an app notice is the Ink chip too', (tester) async {
        expect(
          await chipColors(
            tester,
            const AlertSource(AlertSourceKind.appNotice),
            dark,
          ),
          (dark.colorScheme.inverseSurface, dark.colorScheme.onInverseSurface),
        );
      });
    });
  });
}
