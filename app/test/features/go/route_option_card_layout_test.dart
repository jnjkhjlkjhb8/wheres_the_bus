import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

const _here = PlanPoint(lat: 25, lng: 121.5);
const _noTransport = PlanTransport(
  mode: '',
  name: '',
  shortName: '',
  longName: '',
  headsign: '',
  category: '',
  routeColor: '',
);

PlanSection _walk(String from, String to, int minutes) => PlanSection(
  type: 'pedestrian',
  travelSummary: PlanTravelSummary(duration: minutes * 60, length: 0),
  departure: PlanPlace(name: from, type: 'place', location: _here, time: ''),
  arrival: PlanPlace(name: to, type: 'place', location: _here, time: ''),
  transport: _noTransport,
  intermediateStops: const [],
);

/// A ride with real timestamps, so the gap before the next leg is computable.
PlanSection _ride({
  required String mode,
  required String line,
  required String departure,
  required String arrival,
  required int minutes,
}) => PlanSection(
  type: 'transit',
  travelSummary: PlanTravelSummary(duration: minutes * 60, length: 0),
  departure: PlanPlace(
    name: 'A',
    type: 'station',
    location: _here,
    time: departure,
  ),
  arrival: PlanPlace(
    name: 'B',
    type: 'station',
    location: _here,
    time: arrival,
  ),
  transport: PlanTransport(
    mode: mode,
    name: line,
    shortName: line,
    longName: '',
    headsign: '',
    category: '',
    routeColor: '',
  ),
  intermediateStops: const [],
);

/// 307 arrives 07:30, the metro leaves 07:38 — an eight-minute wait that no
/// section covers.
PlanRoute _route({int fare = 45}) => PlanRoute(
  travelTime: 38 * 60,
  startTime: '2026-08-18T07:12:00',
  endTime: '2026-08-18T07:50:00',
  transfers: 1,
  totalFare: fare,
  sections: [
    _walk('起點', '站牌', 4),
    _ride(
      mode: 'BUS',
      line: '307',
      departure: '2026-08-18T07:16:00',
      arrival: '2026-08-18T07:30:00',
      minutes: 14,
    ),
    _ride(
      mode: 'MRT',
      line: '板南線',
      departure: '2026-08-18T07:38:00',
      arrival: '2026-08-18T07:46:00',
      minutes: 8,
    ),
    _walk('捷運站', '目的地', 2),
  ],
);

Widget _host(Widget child, {double width = 352}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets('every leg reports its own minutes, waiting included', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        RouteOptionCard(
          route: _route(),
          highlighted: false,
          onTap: () {},
        ),
      ),
    );

    // Four legs and one transfer wait: 4, 14, 8, 2 walked/ridden, plus the
    // 8-minute gap between the bus arriving and the metro leaving.
    expect(find.text('4分'), findsOneWidget);
    expect(find.text('14分'), findsOneWidget);
    expect(find.text('2分'), findsOneWidget);
    // 8 appears twice — the metro ride and the wait before it — which is the
    // point: the wait is as long as the ride and used to be invisible.
    expect(find.text('8分'), findsNWidgets(2));
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.byIcon(Icons.directions_walk_rounded), findsNWidgets(2));
  });

  testWidgets('minutes show on an unhighlighted card too', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            RouteOptionCard(
              route: _route(),
              highlighted: true,
              onTap: () {},
            ),
            RouteOptionCard(
              route: _route(fare: 30),
              highlighted: false,
              onTap: () {},
            ),
          ],
        ),
      ),
    );

    // Once per card. Before this change only the highlighted card carried
    // per-leg durations, so the second card said nothing about its own legs.
    expect(find.text('14分'), findsNWidgets(2));
  });

  testWidgets('fare sits alone at the top right, above the leg strip', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        RouteOptionCard(
          route: _route(),
          highlighted: false,
          onTap: () {},
          onToggleSave: () {},
        ),
      ),
    );

    final fare = tester.getTopRight(find.text('45'));
    final duration = tester.getTopLeft(find.text('38'));
    final window = tester.getTopLeft(find.text('07:12'));
    final strip = tester.getTopLeft(find.byType(LegStrip));

    expect(
      fare.dx,
      greaterThan(duration.dx),
      reason: 'fare belongs on the right of the header',
    );
    expect(
      window.dy,
      greaterThan(duration.dy),
      reason: 'the journey window sits under the duration, not beside it',
    );
    expect(
      strip.dy,
      greaterThan(window.dy),
      reason: 'the leg strip follows the whole header block',
    );
  });

  testWidgets('no "fastest" badge, and no walking total in the footer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        RouteOptionCard(
          route: _route(),
          highlighted: true,
          onTap: () {},
        ),
      ),
    );

    final i18n = await AppI18n.delegate.load(const Locale('zh'));
    expect(find.text(i18n.goBadgeFastest), findsNothing);
    // Every walk already states its own minutes in the strip; the sum would
    // be the same fact twice.
    expect(find.text(i18n.walkMinutes(6)), findsNothing);
    expect(find.text(i18n.transfersCount(1)), findsOneWidget);
  });

  testWidgets('one-sided route clocks retain their direction semantics', (
    tester,
  ) async {
    for (final times in [('08:00', ''), ('', '09:00')]) {
      await tester.pumpWidget(
        _host(
          RouteOptionCard(
            route: PlanRoute(
              travelTime: 10,
              startTime: times.$1,
              endTime: times.$2,
              transfers: 0,
              sections: const [],
            ),
            highlighted: false,
            onTap: () {},
          ),
        ),
      );
      final time = times.$1.isEmpty ? times.$2 : times.$1;
      final text = tester.widget<Text>(find.text(time));
      expect(text.semanticsLabel, contains(time));
      expect(text.semanticsLabel, isNot(time));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  test('a line colour too pale to read is darkened, not replaced', () {
    const surface = AppTheme.surfacePressLight;

    // 環狀線 yellow: 1.3:1 against the chip, far under the 3:1 a 14px glyph
    // needs. It has to move.
    final yellow = legibleLineColor(AppTheme.mrtY, surface);
    expect(yellow, isNot(AppTheme.mrtY));
    expect(_contrast(yellow, surface), greaterThanOrEqualTo(3.0));
    // Still yellow: only lightness moved, so the line stays recognisable.
    expect(
      HSLColor.fromColor(yellow).hue,
      closeTo(HSLColor.fromColor(AppTheme.mrtY).hue, 1),
    );

    // 板南線 blue already clears the bar, so the card and the map agree on it.
    expect(legibleLineColor(AppTheme.mrtBL, surface), AppTheme.mrtBL);
  });

  test('the dark chip pushes dark lines the other way', () {
    const surface = AppTheme.surfaceHighlightDark;
    // 區間車 navy is the one that disappears on a dark chip.
    final navy = legibleLineColor(AppTheme.trainRangecar, surface);
    expect(navy, isNot(AppTheme.trainRangecar));
    expect(
      navy.computeLuminance(),
      greaterThan(AppTheme.trainRangecar.computeLuminance()),
      reason: 'a dark surface asks for a lighter line, not a darker one',
    );
    expect(_contrast(navy, surface), greaterThanOrEqualTo(3.0));
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
