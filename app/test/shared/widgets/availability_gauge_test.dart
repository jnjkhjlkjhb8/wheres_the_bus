import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/availability_gauge.dart';

void main() {
  Future<void> pump(WidgetTester tester, AvailabilityGauge gauge) =>
      tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,

          theme: AppTheme.light,
          home: Scaffold(
            body: Padding(padding: const EdgeInsets.all(16), child: gauge),
          ),
        ),
      );

  testWidgets(
    'no live frame yet renders a dash, never a confident zero (F27)',
    (tester) async {
      await pump(
        tester,
        const AvailabilityGauge(
          available: 0,
          docks: 0,
          capacity: 30,
          hasLiveData: false,
        ),
      );

      expect(find.textContaining('—'), findsNWidgets(2));
      expect(find.text('等待即時資料…'), findsOneWidget);
      expect(find.text('目前無車可借'), findsNothing);
    },
  );

  testWidgets('a confirmed zero says so, and only once', (tester) async {
    await pump(
      tester,
      const AvailabilityGauge(available: 0, docks: 20, capacity: 20),
    );

    expect(find.text('目前無車可借'), findsOneWidget);
    expect(find.text('車柱已滿，無法還車'), findsNothing);
  });

  testWidgets('a full rack blocks returns, not borrows', (tester) async {
    await pump(
      tester,
      const AvailabilityGauge(available: 20, docks: 0, capacity: 20),
    );

    expect(find.text('車柱已滿，無法還車'), findsOneWidget);
    expect(find.text('目前無車可借'), findsNothing);
  });

  testWidgets(
    'the low-bikes threshold scales with capacity: 3 bikes is scarce at a '
    '60-dock hub and unremarkable at a 20-dock station',
    (tester) async {
      await pump(
        tester,
        const AvailabilityGauge(available: 3, docks: 57, capacity: 60),
      );
      expect(find.text('車輛偏少'), findsOneWidget);

      await pump(
        tester,
        const AvailabilityGauge(available: 3, docks: 17, capacity: 20),
      );
      expect(find.text('車輛偏少'), findsNothing);
    },
  );

  testWidgets('a healthy station carries no flag at all', (tester) async {
    await pump(
      tester,
      const AvailabilityGauge(
        available: 12,
        docks: 18,
        capacity: 30,
        generalBikes: 8,
        electricBikes: 4,
      ),
    );

    expect(find.text('可借 · 一般 8 · 電輔 4'), findsOneWidget);
    expect(find.text('可還車位'), findsOneWidget);
    expect(find.text('車輛偏少'), findsNothing);
    expect(find.text('暫停服務'), findsNothing);
  });

  testWidgets(
    'a live-confirmed 0/0 is impossible for a station in service and is '
    'reported as such, not as "no bikes"',
    (tester) async {
      await pump(
        tester,
        const AvailabilityGauge(available: 0, docks: 0, capacity: 12),
      );

      expect(find.text('暫停服務'), findsOneWidget);
    },
  );

  testWidgets('a bike type with none of them is left out of the split', (
    tester,
  ) async {
    await pump(
      tester,
      const AvailabilityGauge(
        available: 5,
        docks: 7,
        capacity: 12,
        generalBikes: 5,
        electricBikes: 0,
      ),
    );

    expect(find.text('可借 · 一般 5'), findsOneWidget);
  });
}
