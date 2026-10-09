import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';

JourneyLeg _leg({List<RailStopSchedule> schedule = const []}) => JourneyLeg(
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
  railSchedule: schedule,
);

void main() {
  test('RailStopSchedule equality drives leg equality', () {
    final a = RailStopSchedule(
      name: '台北',
      scheduledArrival: DateTime(2026, 7, 20, 8),
    );
    final b = RailStopSchedule(
      name: '台北',
      scheduledArrival: DateTime(2026, 7, 20, 8),
    );
    expect(a, b);
    expect(_leg(schedule: [a]), _leg(schedule: [b]));
    expect(_leg(schedule: [a]) == _leg(), isFalse);
  });
}
