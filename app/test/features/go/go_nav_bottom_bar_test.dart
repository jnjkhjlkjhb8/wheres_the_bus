import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_event.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

import 'support/go_harness.dart';

const _p = PlanPoint(lat: 25, lng: 121);

PlanSection _leg(String type, String to) => PlanSection(
  type: type,
  travelSummary: const PlanTravelSummary(duration: 600, length: 0),
  departure: const PlanPlace(name: 'From', type: '', location: _p, time: ''),
  arrival: PlanPlace(name: to, type: '', location: _p, time: ''),
  transport: const PlanTransport(
    mode: '',
    name: '307',
    shortName: '307',
    longName: '',
    headsign: '',
    category: '',
    routeColor: '',
  ),
  intermediateStops: const [],
  identity: const PlanIdentity.empty(),
  walkSteps: const [],
);

PlanRoute _route({String endTime = '2026-08-18T14:52:00'}) => PlanRoute(
  travelTime: 1800,
  startTime: '',
  endTime: endTime,
  transfers: 1,
  sections: [
    _leg('walk', 'Stop A'),
    _leg('transit', 'Stop B'),
    _leg('walk', '壽山高中'),
  ],
);

void main() {
  final harness = GoHarness()..install();
  final i18n = lookupAppI18n(const Locale('zh'));

  Finder endControl() => find.byWidgetPredicate(
    (w) => w is Pressable && w.semanticLabel == i18n.goEndNavigation,
  );

  testWidgets('the bottom bar names the trip, its leg and the arrival', (
    tester,
  ) async {
    await harness.pump(
      tester,
      const PlanState(),
      trip: goTripOn(_route(), leg: 1),
    );
    await tester.pump();

    expect(find.byType(GoScreen), findsOneWidget);
    expect(find.text(i18n.towards('壽山高中')), findsOneWidget);
    expect(
      find.text(
        '${i18n.goLegProgress(2, 3)} · ${i18n.goArrivesAt('14:52')}',
      ),
      findsOneWidget,
    );
    // One way out, at the bottom, and none left beside the turn instruction.
    expect(endControl(), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(
      tester.getTopLeft(endControl()).dy,
      greaterThan(tester.view.physicalSize.height / 2),
    );
    await harness.dispose(tester);
  });

  testWidgets('without a planned arrival only the leg is stated', (
    tester,
  ) async {
    await harness.pump(
      tester,
      const PlanState(),
      trip: goTripOn(_route(endTime: '')),
    );
    await tester.pump();

    expect(find.text(i18n.goLegProgress(1, 3)), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('the end control ends the trip', (tester) async {
    await harness.pump(
      tester,
      const PlanState(),
      trip: goTripOn(_route()),
    );
    await tester.pump();

    await tester.tap(endControl());
    // Ending runs through the navigation coordinator asynchronously.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(harness.trip.events.last, isA<TripEnded>());
    await harness.dispose(tester);
  });
}
