import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

const _motis = PlannerCapabilities({
  'transitModes',
  'itineraryCount',
  'transferWindow',
  'firstLastMile',
  'pricePreference',
  'maxTransfers',
  'avoidReservation',
  'carryBike',
});

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(body: child),
);

Future<void> _openSheet(
  WidgetTester tester,
  PlanOptions initial,
  void Function(PlanOptions?) onResult,
) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _host(
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => onResult(
            await showOptionsSheet(
              context,
              current: initial,
              capabilities: _motis,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _apply(WidgetTester tester) async {
  await tester.tap(find.text('套用'));
  await tester.pumpAndSettle();
}

void main() {
  final i18n = lookupAppI18n(const Locale('zh'));

  testWidgets('the preference readout names the stance at each boundary', (
    tester,
  ) async {
    for (final (gc, label) in [
      (0.0, i18n.goPrefCheapest),
      (0.05, i18n.goPrefCheapest),
      (0.1, i18n.goPrefCheapest),
      (0.2, i18n.goPrefCheaperLeaning),
      (0.4, i18n.goPrefBalanced),
      (0.6, i18n.goPrefBalanced),
      (0.7, i18n.goPrefFasterLeaning),
      (0.9, i18n.goPrefFastest),
    ]) {
      await _openSheet(tester, PlanOptions(gc: gc), (_) {});
      // The end label repeats the extreme stances, so count them apart.
      final ends = (label == i18n.goPrefCheapest || label == i18n.goPrefFastest)
          ? 2
          : 1;
      expect(find.text(label), findsNWidgets(ends), reason: 'gc $gc');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('the sheet labels its sections and end stops', (tester) async {
    await _openSheet(tester, const PlanOptions(gc: 0.5), (_) {});
    for (final text in [
      i18n.goRouteOptions,
      i18n.goPrefRow,
      i18n.goPrefCheapest,
      i18n.goPrefFastest,
      i18n.goRouteCount,
      i18n.goZeroMinutes,
      i18n.goSixtyMinutes,
      i18n.goFirstMile,
      i18n.goLastMile,
      i18n.goAvoidReservation,
      i18n.goCarryBike,
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('套用'), findsOneWidget);
  });

  testWidgets('the sheet is capped at 85 percent of the screen', (
    tester,
  ) async {
    await _openSheet(tester, const PlanOptions(), (_) {});
    final capped = tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (c) => c.constraints?.maxHeight == 2400 * 0.85,
        );
    expect(capped, hasLength(1));
  });

  testWidgets('route count tops out at ten and mile times at sixty', (
    tester,
  ) async {
    PlanOptions? result;
    await _openSheet(
      tester,
      const PlanOptions(top: 9, firstMileTime: 59, lastMileTime: 60),
      (value) => result = value,
    );
    final plus = find.byIcon(Icons.add_rounded);
    await tester.tap(plus.at(0));
    await tester.pumpAndSettle();
    await tester.tap(plus.at(1));
    await tester.pumpAndSettle();
    await tester.tap(plus.at(2));
    await tester.pumpAndSettle();
    await _apply(tester);
    expect(
      (result!.top, result!.firstMileTime, result!.lastMileTime),
      (10, 60, 60),
    );
    PlanOptions? again;
    await _openSheet(
      tester,
      const PlanOptions(top: 10),
      (value) => again = value,
    );
    await tester.tap(find.byIcon(Icons.add_rounded).at(0));
    await tester.pumpAndSettle();
    await _apply(tester);
    expect(again!.top, 10);
  });

  testWidgets('the transfer window keeps its range through apply', (
    tester,
  ) async {
    PlanOptions? result;
    await _openSheet(
      tester,
      const PlanOptions(transferMin: 15, transferMax: 60),
      (value) => result = value,
    );
    expect(find.text(i18n.minutesRange(15, 60)), findsOneWidget);
    await _apply(tester);
    expect((result!.transferMin, result!.transferMax), (15, 60));
  });

  testWidgets('the skeleton stands in for a 32 minute, 30 dollar journey', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(PlanWaitingPanel(routeCount: 1, lastRoute: null, onCancel: () {})),
    );
    expect(find.text('32'), findsOneWidget);
    expect(find.text('24分'), findsOneWidget);
    expect(find.text('4分'), findsNWidgets(2));
    expect(find.textContaining('30'), findsWidgets);
    expect(find.byIcon(Icons.directions_bus_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('straight-line distance drops its decimal from ten km', (
    tester,
  ) async {
    for (final (meters, shown) in [
      (9949.0, '9.9'),
      (9960.0, '10.0'),
      (10000.0, '10'),
      (12400.0, '12'),
    ]) {
      await tester.pumpWidget(
        _host(
          PlanWaitingPanel(
            routeCount: 1,
            lastRoute: null,
            straightLineMeters: meters,
            onCancel: () {},
          ),
        ),
      );
      expect(find.text(shown), findsOneWidget, reason: '$meters');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
