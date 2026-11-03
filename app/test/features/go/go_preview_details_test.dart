import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import 'support/go_harness.dart';

const _p = PlanPoint(lat: 25, lng: 121);

PlanSection _leg(
  String type, {
  String from = '',
  String to = '',
  int seconds = 600,
  String color = '',
  String headsign = '',
  int stops = 0,
}) => PlanSection(
  type: type,
  travelSummary: PlanTravelSummary(duration: seconds, length: 0),
  departure: PlanPlace(name: from, type: '', location: _p, time: ''),
  arrival: PlanPlace(name: to, type: '', location: _p, time: ''),
  transport: PlanTransport(
    mode: type == 'transit' ? 'BUS' : '',
    name: type == 'transit' ? '307' : '',
    shortName: type == 'transit' ? '307' : '',
    longName: '',
    headsign: headsign,
    category: '',
    routeColor: color,
  ),
  intermediateStops: [
    for (var i = 0; i < stops; i++)
      const PlanStop(name: 's', location: _p, departureTime: ''),
  ],
);

class _Canvas implements Canvas {
  final lines = <(Offset, Offset, double)>[];
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint.strokeWidth));
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final harness = GoHarness()..install();
  final i18n = lookupAppI18n(const Locale('zh'));
  final scheme = AppTheme.light.colorScheme;

  PlanState preview(PlanRoute route) => PlanState(
    status: PlanStatus.success,
    result: PlanResult(routes: [route]),
    selectedRouteIndex: 0,
    previewing: true,
  );

  PlanRoute route(List<PlanSection> sections) => PlanRoute(
    travelTime: 1800,
    startTime: '2026-08-18T07:12:00',
    endTime: '2026-08-18T07:50:00',
    transfers: 0,
    totalFare: 30,
    sections: sections,
  );

  List<CustomPainter> connectors(WidgetTester tester) => [
    for (final paint in tester.widgetList<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size == const Size(24, double.infinity),
      ),
    ))
      paint.painter!,
  ];

  testWidgets('a walk leg names where it goes, skipping empty names', (
    tester,
  ) async {
    await harness.pump(
      tester,
      preview(
        route([
          _leg('walk', to: 'Named'),
          _leg('transit', from: 'Board', to: 'Alight', stops: 2, headsign: 'H'),
          _leg('walk'),
          _leg('transit', from: 'Next', to: 'End'),
          _leg('walk', to: ''),
        ]),
      ),
      destination: goTestDestination,
    );
    await tester.pump();
    expect(find.text(i18n.walkTo('Named')), findsOneWidget);
    expect(find.text(i18n.walkTo('Next')), findsOneWidget);
    expect(find.text(i18n.walkTo('目的地')), findsOneWidget);
    expect(find.text(i18n.rideStopsTowards(3, 'H')), findsOneWidget);
    expect(find.text(i18n.rideStops(1)), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('the header states both clocks in 15pt mono', (tester) async {
    await harness.pump(
      tester,
      preview(route([_leg('walk', to: 'X')])),
      destination: goTestDestination,
    );
    await tester.pump();
    expect(find.text(i18n.busDepart), findsOneWidget);
    expect(find.text(i18n.railColArrive), findsOneWidget);
    expect(tester.widget<Text>(find.text('07:12')).style!.fontSize, 15);
    expect(tester.widget<Text>(find.text('07:50')).style!.fontSize, 15);
    await harness.dispose(tester);
  });

  testWidgets('itinerary nodes: hollow rings per leg, a filled destination', (
    tester,
  ) async {
    await harness.pump(
      tester,
      preview(route([_leg('walk', to: 'X'), _leg('transit')])),
      destination: goTestDestination,
    );
    await tester.pump();
    BoxDecoration? decorationOf(double size) => tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (c) =>
              c.constraints?.maxWidth == size &&
              c.constraints?.maxHeight == size,
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .firstOrNull;
    expect(
      tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.maxWidth == 18)
          .length,
      2,
    );
    expect(decorationOf(20)!.color, scheme.onSurface);
    expect(decorationOf(7)!.color, Colors.white);
    final ring = decorationOf(18)!;
    expect(ring.color, scheme.surface);
    expect((ring.border! as Border).top.width, 2.5);
    await harness.dispose(tester);
  });

  testWidgets('the connector spine is 2.5 wide, solid or dashed', (
    tester,
  ) async {
    await harness.pump(
      tester,
      preview(route([_leg('walk', to: 'X'), _leg('transit')])),
      destination: goTestDestination,
    );
    await tester.pump();
    final painters = connectors(tester);
    expect(painters, hasLength(2));
    final dashed = _Canvas();
    painters[0].paint(dashed, const Size(24, 20));
    expect(dashed.lines, [
      (const Offset(12, 0), const Offset(12, 3), 2.5),
      (const Offset(12, 8), const Offset(12, 11), 2.5),
      (const Offset(12, 16), const Offset(12, 19), 2.5),
    ]);
    final tail = _Canvas();
    painters[0].paint(tail, const Size(24, 18));
    expect(tail.lines.last, (const Offset(12, 16), const Offset(12, 18), 2.5));
    final solid = _Canvas();
    painters[1].paint(solid, const Size(24, 20));
    expect(solid.lines, [(const Offset(12, 0), const Offset(12, 20), 2.5)]);
    await harness.dispose(tester);
  });

  testWidgets('connectors repaint when either colour or dash changes', (
    tester,
  ) async {
    final hex =
        '#${(scheme.outlineVariant.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    await harness.pump(
      tester,
      preview(
        route([
          _leg('walk', to: 'X'),
          _leg('walk', to: 'Y'),
          _leg('transit', color: hex),
          _leg('transit', color: '#00ff00'),
        ]),
      ),
      destination: goTestDestination,
    );
    await tester.pump();
    final p = connectors(tester);
    expect(p[0].shouldRepaint(p[1]), isFalse);
    expect(p[0].shouldRepaint(p[2]), isTrue);
    expect(p[2].shouldRepaint(p[3]), isTrue);
    expect(p[3].shouldRepaint(p[0]), isTrue);
    await harness.dispose(tester);
  });

  testWidgets('the footer clears the home indicator', (tester) async {
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetViewPadding);
    await harness.pump(
      tester,
      preview(route([_leg('walk', to: 'X')])),
      destination: goTestDestination,
    );
    await tester.pump();
    final footer = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.padding ==
              EdgeInsets.fromLTRB(
                AppTheme.space20,
                AppTheme.space12,
                AppTheme.space20,
                AppTheme.space12 + 34,
              ),
        );
    expect(footer, isNotNull);
    await harness.dispose(tester);
  });
}
