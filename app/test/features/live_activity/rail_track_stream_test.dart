import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/leg_eta_source.dart';

JourneyLeg _railLeg() => JourneyLeg(
  kind: JourneyLegKind.tra,
  routeLabel: '自強 123 往台中',
  boardStop: '台北',
  alightStop: '台中',
  stopNames: const [],
  identity: const PlanIdentity(
    routeType: 'tra',
    routeKey: '123',
    direction: '2026-07-20',
    departureStopKey: '',
    arrivalStopKey: '',
    supported: false,
  ),
  leadingWalkMinutes: 0,
  scheduledDeparture: null,
  scheduledArrival: null,
  boardLocation: const PlanPoint(lat: 0, lng: 0),
  stopLocations: const [],
  railSchedule: [
    RailStopSchedule(name: '台北', scheduledArrival: DateTime(2026, 7, 20, 8)),
    RailStopSchedule(name: '台中', scheduledArrival: DateTime(2026, 7, 20, 9)),
  ],
);

void main() {
  test('emits an initial frame, then re-emits when delay changes', () async {
    final delay = StreamController<Duration>();
    // Fixed clock at 08:30 (half-way), huge tick so the timer never fires.
    final frames = defaultRailTrackStream(
      _railLeg(),
      delaySource: delay.stream,
      tick: const Duration(hours: 1),
      now: () => DateTime(2026, 7, 20, 8, 30),
    );

    final seen = <RailTrackFrame>[];
    final sub = frames.listen(seen.add);

    await Future<void>.delayed(Duration.zero); // let the seeded frame land
    expect(seen.single.etaToAlight, const Duration(minutes: 30)); // delay 0

    delay.add(const Duration(minutes: 10)); // alight effective 09:10
    await Future<void>.delayed(Duration.zero);
    expect(seen.last.etaToAlight, const Duration(minutes: 40));

    await sub.cancel();
    await delay.close();
  });
}
