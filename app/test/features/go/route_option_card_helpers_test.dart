import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

const _here = PlanPoint(lat: 25, lng: 121.5);

PlanTransport _transport(String mode) => PlanTransport(
  mode: mode,
  name: 'L',
  shortName: 'L',
  longName: '',
  headsign: '',
  category: '',
  routeColor: '',
);

PlanSection _section(
  String type, {
  int seconds = 60,
  String from = '',
  String to = '',
  String departAt = '',
  String arriveAt = '',
  String mode = 'bus',
}) => PlanSection(
  type: type,
  travelSummary: PlanTravelSummary(duration: seconds, length: 0),
  departure: PlanPlace(
    name: from,
    type: 'place',
    location: _here,
    time: departAt,
  ),
  arrival: PlanPlace(name: to, type: 'place', location: _here, time: arriveAt),
  transport: _transport(mode),
  intermediateStops: const [],
);

PlanRoute _route(List<PlanSection> sections, {int travelTime = 600}) =>
    PlanRoute(
      travelTime: travelTime,
      startTime: '',
      endTime: '',
      transfers: 0,
      sections: sections,
    );

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(body: SizedBox(width: 352, child: child)),
);

void main() {
  test('route minutes are seconds above 600 and minutes at or below it', () {
    expect(routeMinutes(_route(const [], travelTime: 300)), 300);
    expect(routeMinutes(_route(const [], travelTime: 600)), 600);
    expect(routeMinutes(_route(const [], travelTime: 601)), 10);
    expect(routeMinutes(_route(const [], travelTime: 60000)), 999);
    expect(routeMinutes(_route(const [], travelTime: -5)), 0);
  });

  test('walk minutes add up every walk section and skip rides', () {
    final route = _route([
      _section('walk', seconds: 240),
      _section('transit', seconds: 600),
      _section('walk', seconds: 120),
    ]);
    expect(walkMinutes(route), 6);
  });

  test('a wait is the rounded gap between arrival and next departure', () {
    int wait(String arrive, String depart) => waitMinutesBefore([
      _section('transit', arriveAt: arrive),
      _section('transit', departAt: depart),
    ], 1);
    expect(wait('2026-08-18T07:30:00', '2026-08-18T07:30:29'), 0);
    expect(wait('2026-08-18T07:30:00', '2026-08-18T07:30:30'), 1);
    expect(wait('2026-08-18T07:30:00', '2026-08-18T07:38:00'), 8);
    expect(wait('2026-08-18T07:30:00', '2026-08-18T07:30:00'), 0);
    expect(wait('2026-08-18T07:30:00', '2026-08-18T07:20:00'), 0);
    expect(wait('', '2026-08-18T07:20:00'), 0);
    expect(waitMinutesBefore([_section('transit')], 0), 0);
  });

  group('endpoint names show only on a highlighted card with a name', () {
    Future<int> endpointCount(
      WidgetTester tester, {
      required bool highlighted,
      required String from,
      required String to,
    }) async {
      await tester.pumpWidget(
        _host(
          RouteOptionCard(
            route: _route([_section('walk', from: from, to: to)]),
            highlighted: highlighted,
            onTap: () {},
          ),
        ),
      );
      return find
          .descendant(
            of: find.byType(RouteOptionCard),
            matching: find.byType(Flexible),
          )
          .evaluate()
          .length;
    }

    testWidgets('each combination', (tester) async {
      final plain = await endpointCount(
        tester,
        highlighted: false,
        from: '',
        to: '',
      );
      expect(
        await endpointCount(tester, highlighted: false, from: 'O', to: 'D'),
        plain,
      );
      expect(find.text('O'), findsNothing);
      expect(
        await endpointCount(tester, highlighted: true, from: '', to: ''),
        plain,
      );
      expect(
        await endpointCount(tester, highlighted: true, from: 'O', to: ''),
        plain + 2,
      );
      expect(find.text('O'), findsOneWidget);
      expect(
        await endpointCount(tester, highlighted: true, from: '', to: 'D'),
        plain + 2,
      );
      expect(
        await endpointCount(tester, highlighted: true, from: 'O', to: 'D'),
        plain + 2,
      );
      expect(find.text('D'), findsWidgets);
    });
  });

  testWidgets('legs read as walk chips and ride pills with chevrons between', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        LegStrip(
          sections: [
            _section('pedestrian', seconds: 240),
            _section('transit', arriveAt: '2026-08-18T07:30:00', seconds: 840),
            _section(
              'transit',
              departAt: '2026-08-18T07:38:00',
              seconds: 480,
              mode: 'mrt',
            ),
            _section('pedestrian', seconds: 120),
          ],
        ),
      ),
    );
    expect(find.byIcon(Icons.directions_walk_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.directions_bus_rounded), findsOneWidget);
    expect(find.byIcon(Icons.directions_subway_rounded), findsOneWidget);
    expect(find.byIcon(Icons.directions_transit_rounded), findsNothing);
    // Three joins plus one before the 8-minute transfer wait; none trailing.
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(4));
  });
}
