import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';

JourneyLeg _leg(String label, {List<RailStopSchedule> rail = const []}) =>
    JourneyLeg(
      kind: JourneyLegKind.tra,
      routeLabel: label,
      boardStop: 'a',
      alightStop: 'b',
      stopNames: const [],
      identity: const PlanIdentity.empty(),
      leadingWalkMinutes: 0,
      scheduledDeparture: null,
      scheduledArrival: null,
      boardLocation: const PlanPoint(lat: 0, lng: 0),
      stopLocations: const [],
      railSchedule: rail,
    );

void main() {
  group('defaults', () {
    test('a fresh state is idle, empty and aboard', () {
      const state = JourneySessionState();
      expect(state.phase, JourneyPhase.idle);
      expect(state.legs, isEmpty);
      expect(state.legIndex, 0);
      expect(state.eta, isNull);
      expect(state.nextStopIndex, 0);
      expect(state.suggestBoarding, isFalse);
      expect(state.trackOnly, isFalse);
      expect(state.plate, isNull);
      expect(state.pinnedStopsRemaining, isNull);
      expect(state.railProgress, isNull);
      expect(state.railNextStop, isNull);
      expect(state.leadStops, 1);
      expect(state.railAboard, isTrue);
      expect(state.railDelay, Duration.zero);
      expect(state.currentLeg, isNull);
    });
  });

  group('leg position', () {
    test('currentLeg is the indexed leg and null past the end', () {
      final legs = [_leg('first'), _leg('second')];
      expect(JourneySessionState(legs: legs).currentLeg, legs[0]);
      expect(JourneySessionState(legs: legs, legIndex: 1).currentLeg, legs[1]);
      expect(JourneySessionState(legs: legs, legIndex: 2).currentLeg, isNull);
    });

    test('isLastLeg flips exactly on the final index', () {
      final legs = [_leg('first'), _leg('second'), _leg('third')];
      expect(JourneySessionState(legs: legs).isLastLeg, isFalse);
      expect(JourneySessionState(legs: legs, legIndex: 1).isLastLeg, isFalse);
      expect(JourneySessionState(legs: legs, legIndex: 2).isLastLeg, isTrue);
      expect(JourneySessionState(legs: legs, legIndex: 3).isLastLeg, isTrue);
      expect(const JourneySessionState().isLastLeg, isTrue);
      expect(JourneySessionState(legs: [_leg('only')]).isLastLeg, isTrue);
    });

    test('isRailTrack needs trackOnly and a leg with a rail schedule', () {
      final schedule = [
        RailStopSchedule(name: 's', scheduledArrival: DateTime(2026)),
      ];
      final railLeg = _leg('rail', rail: schedule);
      expect(
        JourneySessionState(legs: [railLeg], trackOnly: true).isRailTrack,
        isTrue,
      );
      expect(JourneySessionState(legs: [railLeg]).isRailTrack, isFalse);
      expect(
        JourneySessionState(legs: [_leg('bus')], trackOnly: true).isRailTrack,
        isFalse,
      );
      expect(const JourneySessionState(trackOnly: true).isRailTrack, isFalse);
    });
  });

  group('copyWith', () {
    final legs = [_leg('first')];
    final full = JourneySessionState(
      phase: JourneyPhase.riding,
      legs: legs,
      legIndex: 3,
      eta: const Duration(minutes: 4),
      nextStopIndex: 5,
      suggestBoarding: true,
      trackOnly: true,
      plate: 'ABC-123',
      pinnedStopsRemaining: 6,
      railProgress: 0.25,
      railNextStop: 'Banqiao',
      leadStops: 4,
      railAboard: false,
      railDelay: const Duration(minutes: 2),
    );

    test('without arguments it keeps every field', () {
      expect(full.copyWith(), full);
    });

    test('each argument replaces only its own field', () {
      final changes = <JourneySessionState>[
        full.copyWith(phase: JourneyPhase.done),
        full.copyWith(legs: [_leg('other')]),
        full.copyWith(legIndex: 0),
        full.copyWith(eta: const Duration(minutes: 9)),
        full.copyWith(nextStopIndex: 1),
        full.copyWith(suggestBoarding: false),
        full.copyWith(trackOnly: false),
        full.copyWith(plate: 'XYZ-9'),
        full.copyWith(pinnedStopsRemaining: 1),
        full.copyWith(railProgress: 0.75),
        full.copyWith(railNextStop: 'Taipei'),
        full.copyWith(leadStops: 2),
        full.copyWith(railAboard: true),
        full.copyWith(railDelay: Duration.zero),
      ];
      for (final changed in changes) {
        expect(changed, isNot(full));
      }
      expect(full.copyWith(phase: JourneyPhase.done).phase, JourneyPhase.done);
      expect(full.copyWith(phase: JourneyPhase.done).legIndex, 3);
      expect(full.copyWith(legIndex: 0).legIndex, 0);
      expect(full.copyWith(legIndex: 0).phase, JourneyPhase.riding);
      expect(full.copyWith(eta: const Duration(minutes: 9)).eta?.inMinutes, 9);
      expect(full.copyWith(plate: 'XYZ-9').plate, 'XYZ-9');
      expect(full.copyWith(leadStops: 2).leadStops, 2);
      expect(full.copyWith(railAboard: true).railAboard, isTrue);
      expect(full.copyWith(railDelay: Duration.zero).railDelay, Duration.zero);
      expect(full.copyWith(railProgress: 0.75).railProgress, 0.75);
      expect(full.copyWith(railNextStop: 'Taipei').railNextStop, 'Taipei');
      expect(full.copyWith(pinnedStopsRemaining: 1).pinnedStopsRemaining, 1);
      expect(full.copyWith(nextStopIndex: 1).nextStopIndex, 1);
      expect(full.copyWith(suggestBoarding: false).suggestBoarding, isFalse);
      expect(full.copyWith(trackOnly: false).trackOnly, isFalse);
    });

    test('clearEta drops the eta and wins over a new value', () {
      expect(full.copyWith(clearEta: true).eta, isNull);
      expect(
        full.copyWith(clearEta: true, eta: const Duration(minutes: 1)).eta,
        isNull,
      );
      expect(full.copyWith(clearEta: false).eta, const Duration(minutes: 4));
    });
  });

  group('equality', () {
    test('every field takes part in equality and hashing', () {
      final a = JourneySessionState(legs: [_leg('x')], plate: 'p');
      final b = JourneySessionState(legs: [_leg('x')], plate: 'p');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(plate: 'q')));
    });
  });
}
