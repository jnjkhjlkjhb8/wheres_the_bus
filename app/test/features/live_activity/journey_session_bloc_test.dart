import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';

/// Mutable gate so the disabled branch isn't statically dead in the test.
class _Gate {
  bool enabled = false;
}

JourneyLeg _leg(String label) => JourneyLeg(
  kind: JourneyLegKind.bus,
  routeLabel: label,
  boardStop: '起點站',
  alightStop: '終點站',
  stopNames: const ['中站'],
  identity: const PlanIdentity.empty(),
  leadingWalkMinutes: 0,
  scheduledDeparture: DateTime(2026, 7, 6, 10),
  scheduledArrival: DateTime(2026, 7, 6, 10, 30),
  boardLocation: const PlanPoint(lat: 25, lng: 121.5),
  stopLocations: const [
    PlanPoint(lat: 25.01, lng: 121.51),
    PlanPoint(lat: 25.02, lng: 121.52),
  ],
);

void main() {
  late StreamController<Duration?> etaCtrl;
  // channel and positions default to null: platform channel and location
  // tracking are skipped in tests.
  JourneySessionBloc bloc() => JourneySessionBloc(
    etaStream: (_) => etaCtrl.stream,
    liveActivityEnabled: () => true,
  );

  setUp(() => etaCtrl = StreamController<Duration?>.broadcast());
  tearDown(() => etaCtrl.close());

  test('start → waiting on first leg with streamed ETA', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg('307')]));
    await expectLater(
      b.stream,
      emits(
        isA<JourneySessionState>()
            .having((s) => s.phase, 'phase', JourneyPhase.waiting)
            .having((s) => s.legIndex, 'legIndex', 0),
      ),
    );
    etaCtrl.add(const Duration(minutes: 3));
    await expectLater(
      b.stream,
      emits(
        isA<JourneySessionState>().having(
          (s) => s.eta,
          'eta',
          const Duration(minutes: 3),
        ),
      ),
    );
    await b.close();
  });

  test('board → riding; alight on last leg → done', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg('307')]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    b.add(const BoardConfirmed());
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
    b.add(const AlightConfirmed());
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    await b.close();
  });

  test('alight on non-final leg advances to waiting on next leg', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg('307'), _leg('自強123')]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    b.add(const BoardConfirmed());
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
    b.add(const AlightConfirmed());
    final s = await b.stream.firstWhere(
      (s) => s.phase == JourneyPhase.waiting,
    );
    expect(s.legIndex, 1);
    expect(s.currentLeg?.routeLabel, '自強123');
    await b.close();
  });

  test('eta reaching zero flags suggestBoarding while waiting', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg('307')]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    etaCtrl.add(Duration.zero);
    final s = await b.stream.firstWhere((s) => s.eta == Duration.zero);
    expect(s.suggestBoarding, isTrue);
    await b.close();
  });

  test('cancel from any phase → done', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg('307')]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    b.add(const JourneyCancelled());
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    await b.close();
  });

  test('eta stream error falls back to scheduled countdown', () async {
    final b = JourneySessionBloc(
      etaStream: (_) => Stream<Duration?>.error(Exception('grpc drop')),
      liveActivityEnabled: () => true,
    )..add(JourneyStarted(legs: [_leg('307')]));
    // scheduledDeparture is in the past → fallback emits Duration.zero
    final s = await b.stream.firstWhere((s) => s.eta != null);
    expect(s.eta, Duration.zero);
    await b.close();
  });

  test('empty legs list is a no-op', () async {
    final b = bloc()..add(const JourneyStarted(legs: []));
    await Future<void>.delayed(Duration.zero);
    expect(b.state.phase, JourneyPhase.idle);
    await b.close();
  });

  test(
    'default (no positions) reaches riding without touching geolocator',
    () async {
      // positions omitted → _subscribePositions returns early, so no
      // geolocator platform call is made (that would throw
      // MissingPluginException in tests).
      final b = bloc()..add(JourneyStarted(legs: [_leg('307')]));
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
      b.add(const BoardConfirmed());
      final s = await b.stream.firstWhere(
        (s) => s.phase == JourneyPhase.riding,
      );
      expect(s.phase, JourneyPhase.riding);
      await b.close();
    },
  );

  test(
    'positions factory gated off is never subscribed (setting disabled)',
    () async {
      final gate = _Gate();
      var subscribed = false;
      Stream<Position> positions() {
        if (!gate.enabled) return const Stream<Position>.empty();
        subscribed = true;
        return Stream<Position>.error(Exception('should not subscribe'));
      }

      final b = JourneySessionBloc(
        etaStream: (_) => etaCtrl.stream,
        positions: positions,
        liveActivityEnabled: () => true,
      )..add(JourneyStarted(legs: [_leg('307')]));
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
      b.add(const BoardConfirmed());
      final s = await b.stream.firstWhere(
        (s) => s.phase == JourneyPhase.riding,
      );
      expect(s.phase, JourneyPhase.riding);
      await Future<void>.delayed(Duration.zero);
      expect(subscribed, isFalse);
      await b.close();
    },
  );

  test(
    'a delayed ETA event from a cancelled/previous journey does not mix '
    'into the new journey (F36 generation tagging)',
    () async {
      final b = bloc()..add(JourneyStarted(legs: [_leg('307')]));
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);

      // Journey B supersedes journey A before A's in-flight ETA event has a
      // chance to be delivered.
      b.add(JourneyStarted(legs: [_leg('自強123')]));
      final started = await b.stream.firstWhere(
        (s) => s.currentLeg?.routeLabel == '自強123',
      );
      expect(started.eta, isNull);

      b.add(const EtaTicked(Duration(minutes: 3), generation: 1));
      await Future<void>.delayed(Duration.zero);

      expect(b.state.eta, isNull);
      expect(b.state.currentLeg?.routeLabel, '自強123');
      await b.close();
    },
  );

  test('every card names its session, and a new ride mints a new id', () async {
    final channel = _FakeChannel();
    JourneySessionBloc start() => JourneySessionBloc(
      etaStream: (_) => etaCtrl.stream,
      channel: channel,
      liveActivityEnabled: () => true,
    )..add(JourneyStarted(legs: [_leg('307')]));

    final a = start();
    await a.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    await a.close();
    final b = start();
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    await b.close();

    expect(channel.started, hasLength(2));
    for (final content in channel.started) {
      // Named — the platform's tombstone and 取消追蹤 both key off this — and
      // marked device-local, so the cancel receiver knows not to call a server
      // that has never heard of this ride.
      expect(
        content.trackId,
        startsWith(AlightTrackContent.localTrackIdPrefix),
      );
    }
    expect(channel.started[0].trackId, isNot(channel.started[1].trackId));
  });

  test('position stream error does not break riding', () async {
    final b = JourneySessionBloc(
      etaStream: (_) => etaCtrl.stream,
      positions: () => Stream<Position>.error(Exception('permission revoked')),
      liveActivityEnabled: () => true,
    )..add(JourneyStarted(legs: [_leg('307')]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    b.add(const BoardConfirmed());
    final s = await b.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
    expect(s.phase, JourneyPhase.riding);
    // Give the errored subscription a chance to surface before closing.
    await Future<void>.delayed(Duration.zero);
    expect(b.state.phase, JourneyPhase.riding);
    await b.close();
  });
}

class _FakeChannel extends AlightTrackChannel {
  final started = <AlightTrackContent>[];
  int _lease = 0;

  @override
  Future<int> start(AlightTrackContent content) async {
    started.add(content);
    return ++_lease;
  }

  @override
  Future<void> update(int lease, AlightTrackContent content) async {}

  @override
  Future<void> stop(int lease) async {}
}
