import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

PlanPlace _place(String name) => PlanPlace(
  name: name,
  type: '',
  location: const PlanPoint(lat: 0, lng: 0),
  time: '2026-07-11T08:00:00',
);

PlanSection _walk({required String from, required String to}) => PlanSection(
  type: 'walk',
  travelSummary: const PlanTravelSummary(duration: 600, length: 0),
  departure: _place(from),
  arrival: _place(to),
  transport: const PlanTransport(
    mode: 'walk',
    name: '',
    shortName: '',
    longName: '',
    headsign: '',
    category: '',
    routeColor: '',
  ),
  intermediateStops: const [],
);

Widget _card({required String from, required String to}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(
    body: RouteOptionCard(
      route: PlanRoute(
        travelTime: 600,
        startTime: '2026-07-11T08:00:00',
        endTime: '2026-07-11T08:10:00',
        transfers: 0,
        sections: [_walk(from: from, to: to)],
      ),
      highlighted: true,
      onTap: () {},
    ),
  ),
);

void main() {
  group('endpointLabel', () {
    test('swaps the router sentinel, ignoring case', () {
      expect(RouteOptionCard.endpointLabel('START', 'START', '出發地'), '出發地');
      expect(RouteOptionCard.endpointLabel('start', 'START', '出發地'), '出發地');
    });

    test('keeps a real place name', () {
      expect(RouteOptionCard.endpointLabel('臺北101', 'END', '目的地'), '臺北101');
    });

    test('does not mistake the other sentinel for this one', () {
      expect(RouteOptionCard.endpointLabel('END', 'START', '出發地'), 'END');
    });
  });

  testWidgets('highlighted card shows localized names for START and END', (
    tester,
  ) async {
    await tester.pumpWidget(_card(from: 'START', to: 'END'));

    expect(find.text('出發地'), findsOneWidget);
    expect(find.text('目的地'), findsOneWidget);
    expect(find.text('START'), findsNothing);
    expect(find.text('END'), findsNothing);
  });

  testWidgets('highlighted card keeps real place names', (tester) async {
    await tester.pumpWidget(_card(from: '台北車站', to: '臺北101'));

    expect(find.text('台北車站'), findsOneWidget);
    expect(find.text('臺北101'), findsOneWidget);
  });
}
