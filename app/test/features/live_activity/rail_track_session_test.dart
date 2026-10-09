import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/leg_eta_source.dart';

class _FakeChannel extends AlightTrackChannel {
  final contents = <AlightTrackContent>[];
  @override
  Future<int> start(AlightTrackContent c) async {
    contents.add(c);
    return 1;
  }

  @override
  Future<void> update(int lease, AlightTrackContent c) async => contents.add(c);
  @override
  Future<void> stop(int lease) async {}
}

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
    RailStopSchedule(
      name: '板橋',
      scheduledArrival: DateTime(2026, 7, 20, 8, 20),
    ),
    RailStopSchedule(name: '台中', scheduledArrival: DateTime(2026, 7, 20, 9)),
  ],
);

void main() {
  test(
    'rail track session pushes a riding card with 還剩 N 站 + progress',
    () async {
      final frames = StreamController<RailTrackFrame>.broadcast();
      final channel = _FakeChannel();
      final bloc = JourneySessionBloc(
        channel: channel,
        railTrackStream: (_) => frames.stream,
        liveActivityEnabled: () => true,
      )..add(JourneyStarted(trackOnly: true, legs: [_railLeg()]));

      await Future<void>.delayed(Duration.zero);

      frames.add((
        remainingStops: 1,
        etaToAlight: const Duration(minutes: 30),
        progress: 0.5,
        nextStop: '台中',
        aboard: true,
        etaToBoard: Duration.zero,
        delay: Duration.zero,
      ));
      await bloc.stream.firstWhere((s) => s.railProgress != null);

      expect(bloc.state.pinnedStopsRemaining, 1);
      expect(bloc.state.railProgress, 0.5);
      expect(bloc.state.railNextStop, '台中');
      expect(bloc.state.isRailTrack, isTrue);

      final last = channel.contents.last;
      // A rail track reads as aboard from the first frame: it counts stops,
      // never minutes-to-boarding.
      expect(last.phase, isNot(AlightTrackPhase.waiting));
      expect(last.mode, AlightTrackMode.tra);
      expect(last.remainingStops, 1);
      // Two hops 台北→板橋→台中, one of them travelled.
      expect(last.hopCount, 2);
      expect(last.currentIndex, 1);
      expect(last.nextStation, '台中');
      expect(last.targetStation, '台中');
      expect(last.vehicleId, isNull); // no pinned vehicle on a rail track

      await bloc.close();
      await frames.close();
    },
  );

  test(
    'a train that has not reached the platform reads as waiting, not riding',
    () async {
      final frames = StreamController<RailTrackFrame>.broadcast();
      final channel = _FakeChannel();
      final bloc = JourneySessionBloc(
        channel: channel,
        railTrackStream: (_) => frames.stream,
        liveActivityEnabled: () => true,
      )..add(JourneyStarted(trackOnly: true, legs: [_railLeg()]));

      await Future<void>.delayed(Duration.zero);

      frames.add((
        remainingStops: 2,
        etaToAlight: const Duration(minutes: 60),
        progress: 0,
        nextStop: '台北',
        aboard: false,
        etaToBoard: const Duration(minutes: 7),
        delay: const Duration(minutes: 5),
      ));
      await Future<void>.delayed(Duration.zero);

      final waiting = channel.contents.last;
      expect(waiting.phase, AlightTrackPhase.waiting);
      // Minutes to the train, not stops to the alight: the rider is standing
      // on a platform and the stop count would not move for the whole wait.
      expect(waiting.etaMinutes, 7);
      // The timetable and the slip travel separately so the card can name both.
      expect(waiting.scheduledDepartureMs, isNotNull);
      expect(waiting.delayMinutes, 5);

      // Train pulls in → the card switches to counting stops and drops the
      // timetable, which has nothing left to say.
      frames.add((
        remainingStops: 1,
        etaToAlight: const Duration(minutes: 30),
        progress: 0.5,
        nextStop: '台中',
        aboard: true,
        etaToBoard: Duration.zero,
        delay: const Duration(minutes: 5),
      ));
      await Future<void>.delayed(Duration.zero);

      final riding = channel.contents.last;
      expect(riding.phase, isNot(AlightTrackPhase.waiting));
      expect(riding.remainingStops, 1);
      expect(riding.scheduledDepartureMs, isNull);
      expect(riding.delayMinutes, 0);

      await bloc.close();
      await frames.close();
    },
  );
}
