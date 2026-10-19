import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/availability_gauge.dart';

import '../../support/helpers/i18n.dart';

Future<void> _pump(
  WidgetTester tester,
  AvailabilityGauge gauge, {
  double width = 300,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      theme: AppTheme.light,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: gauge),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

CustomPaint _rack(WidgetTester tester) => tester.widget<CustomPaint>(
  find
      .descendant(
        of: find.byType(AvailabilityGauge),
        matching: find.byType(CustomPaint),
      )
      .first,
);

void main() {
  group('semantics', () {
    testWidgets('states total, bikes to borrow and docks to return', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const AvailabilityGauge(available: 9, docks: 11, capacity: 20),
      );
      expect(
        tester.getSemantics(find.byType(AvailabilityGauge)).label,
        zhStrings.bikeGaugeSemantics(20, 9, 11),
      );
      handle.dispose();
    });

    testWidgets('appends the status flag after a full-width comma', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const AvailabilityGauge(available: 0, docks: 20, capacity: 20),
      );
      expect(
        tester.getSemantics(find.byType(AvailabilityGauge)).label,
        '${zhStrings.bikeGaugeSemantics(20, 0, 20)}，${zhStrings.bikeNoBikes}',
      );
      handle.dispose();
    });
  });

  group('rack geometry', () {
    testWidgets('is 22 tall and as wide as its parent', (tester) async {
      await _pump(
        tester,
        const AvailabilityGauge(available: 5, docks: 15, capacity: 20),
      );
      expect(_rack(tester).size, const Size(300, 22));
    });

    testWidgets('keeps separate bays while each is at least 4 wide', (
      tester,
    ) async {
      // 10 bays of exactly 4 plus 9 gaps of 2.
      await _pump(
        tester,
        const AvailabilityGauge(available: 5, docks: 5, capacity: 10),
        width: 58,
      );
      final painter = _rack(tester).painter! as dynamic;
      expect(painter.slots, 10);
      expect(painter.gap, 2);
      expect(painter.radius, AppTheme.radiusSlot);
    });

    testWidgets('collapses into one stadium bar when a bay would be thinner', (
      tester,
    ) async {
      await _pump(
        tester,
        const AvailabilityGauge(available: 5, docks: 5, capacity: 10),
        width: 57,
      );
      final painter = _rack(tester).painter! as dynamic;
      expect(painter.slots, 1);
      expect(painter.gap, 0);
      expect(painter.radius, AppTheme.radiusStadium);
    });

    testWidgets('fills in proportion to the bikes available', (tester) async {
      await _pump(
        tester,
        const AvailabilityGauge(available: 3, docks: 7, capacity: 10),
      );
      expect((_rack(tester).painter! as dynamic).fraction, closeTo(0.3, 1e-9));
    });

    testWidgets('lays the bays out on an advance of width plus gap', (
      tester,
    ) async {
      await _pump(
        tester,
        const AvailabilityGauge(available: 0, docks: 3, capacity: 3),
        width: 100,
      );
      // advance (100 + 2) / 3 = 34, bay width 32.
      RRect bay(int i) => RRect.fromRectAndRadius(
        Rect.fromLTWH(i * 34.0, 0, 32, 22),
        const Radius.circular(AppTheme.radiusSlot),
      );
      expect(
        tester.renderObject(
          find
              .descendant(
                of: find.byType(AvailabilityGauge),
                matching: find.byType(CustomPaint),
              )
              .first,
        ),
        paints
          ..rrect(rrect: bay(0))
          ..rrect(rrect: bay(1))
          ..rrect(rrect: bay(2)),
      );
    });
  });

  testWidgets('the end counts keep their type sizes', (tester) async {
    await _pump(
      tester,
      const AvailabilityGauge(available: 9, docks: 11, capacity: 20),
    );
    final counts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(AvailabilityGauge),
            matching: find.byType(Text),
          ),
        )
        .firstWhere((t) => (t.textSpan as TextSpan?)?.children?.length == 2);
    final spans = (counts.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans[0].style?.fontSize, 28);
    expect(spans[0].style?.height, 1.15);
    expect(spans[1].style?.fontSize, 13);
  });
}
