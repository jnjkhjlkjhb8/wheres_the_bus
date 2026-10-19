import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/track_card.dart';

JourneyLeg _buildLeg({
  required List<PlanPoint> stopLocations,
  String alightStop = '台北車站',
  String routeLabel = '299 往板橋',
}) => JourneyLeg(
  kind: JourneyLegKind.bus,
  routeLabel: routeLabel,
  boardStop: '起站',
  alightStop: alightStop,
  stopNames: const [],
  identity: const PlanIdentity.empty(),
  leadingWalkMinutes: 0,
  scheduledDeparture: null,
  scheduledArrival: null,
  boardLocation: const PlanPoint(lat: 0, lng: 0),
  stopLocations: stopLocations,
);

void main() {
  group('TrackCard.fromRidingLeg', () {
    test('computes stopsRemaining/progress/targetStopName from leg', () {
      final leg = _buildLeg(
        stopLocations: const [
          PlanPoint(lat: 1, lng: 1),
          PlanPoint(lat: 2, lng: 2),
          PlanPoint(lat: 3, lng: 3),
          PlanPoint(lat: 4, lng: 4),
          PlanPoint(lat: 5, lng: 5),
        ],
      );

      final card = TrackCard.fromRidingLeg(
        leg,
        nextStopIndex: 2,
        etaSeconds: 90,
      );

      expect(card.routeLabel, '299 往板橋');
      expect(card.plate, isNull);
      expect(card.targetStopName, '台北車站');
      expect(card.stopsRemaining, 3);
      expect(card.progress, closeTo(0.4, 1e-9));
      expect(card.etaSeconds, 90);
    });

    test('guards against divide-by-zero with empty stopLocations', () {
      final leg = _buildLeg(stopLocations: const []);

      final card = TrackCard.fromRidingLeg(leg, nextStopIndex: 0);

      expect(card.progress, 0.0);
      expect(card.stopsRemaining, 0);
      expect(card.etaSeconds, isNull);
    });

    test('clamps stopsRemaining and progress when nextStopIndex overruns', () {
      final leg = _buildLeg(
        stopLocations: const [
          PlanPoint(lat: 1, lng: 1),
          PlanPoint(lat: 2, lng: 2),
        ],
      );

      final card = TrackCard.fromRidingLeg(leg, nextStopIndex: 5);

      expect(card.stopsRemaining, 0);
      expect(card.progress, 1.0);
    });
  });
  group('TrackCard.fromRidingLeg boundaries', () {
    final five = _buildLeg(
      stopLocations: const [
        PlanPoint(lat: 1, lng: 1),
        PlanPoint(lat: 2, lng: 2),
        PlanPoint(lat: 3, lng: 3),
        PlanPoint(lat: 4, lng: 4),
        PlanPoint(lat: 5, lng: 5),
      ],
    );

    test('at the first stop every stop is still ahead', () {
      final card = TrackCard.fromRidingLeg(five, nextStopIndex: 0);
      expect(card.stopsRemaining, 5);
      expect(card.progress, 0.0);
    });

    test('at the last stop one stop remains', () {
      final card = TrackCard.fromRidingLeg(five, nextStopIndex: 4);
      expect(card.stopsRemaining, 1);
      expect(card.progress, closeTo(0.8, 1e-9));
    });

    test('exactly past the last stop nothing remains and progress is full', () {
      final card = TrackCard.fromRidingLeg(five, nextStopIndex: 5);
      expect(card.stopsRemaining, 0);
      expect(card.progress, 1.0);
    });

    test('a negative index is held at the start of the leg', () {
      final card = TrackCard.fromRidingLeg(five, nextStopIndex: -2);
      expect(card.stopsRemaining, 5);
      expect(card.progress, 0.0);
    });

    test('a riding card is never pinned', () {
      expect(TrackCard.fromRidingLeg(five, nextStopIndex: 1).plate, isNull);
    });
  });

  group('TrackCard.pinned', () {
    const base = TrackCard.pinned(
      routeLabel: '299',
      plate: 'ABC-123',
      targetStopName: '台北車站',
      stopsRemaining: 3,
      progress: 0.5,
      etaSeconds: 60,
    );

    test('keeps every supplied field', () {
      expect(base.routeLabel, '299');
      expect(base.plate, 'ABC-123');
      expect(base.targetStopName, '台北車站');
      expect(base.stopsRemaining, 3);
      expect(base.progress, 0.5);
      expect(base.etaSeconds, 60);
      expect(
        const TrackCard.pinned(
          routeLabel: '299',
          plate: 'ABC-123',
          targetStopName: '台北車站',
          stopsRemaining: 3,
          progress: 0.5,
        ).etaSeconds,
        isNull,
      );
    });

    test('every field takes part in equality', () {
      expect(base, base.copy());
      expect(base.hashCode, base.copy().hashCode);
      expect(base, isNot(base.copy(routeLabel: 'x')));
      expect(base, isNot(base.copy(plate: 'x')));
      expect(base, isNot(base.copy(targetStopName: 'x')));
      expect(base, isNot(base.copy(stopsRemaining: 4)));
      expect(base, isNot(base.copy(etaSeconds: 61)));
      expect(base, isNot(base.copy(progress: 0.6)));
    });
  });
}

extension on TrackCard {
  TrackCard copy({
    String? routeLabel,
    String? plate,
    String? targetStopName,
    int? stopsRemaining,
    int? etaSeconds,
    double? progress,
  }) => TrackCard.pinned(
    routeLabel: routeLabel ?? this.routeLabel,
    plate: plate ?? this.plate!,
    targetStopName: targetStopName ?? this.targetStopName,
    stopsRemaining: stopsRemaining ?? this.stopsRemaining,
    progress: progress ?? this.progress,
    etaSeconds: etaSeconds ?? this.etaSeconds,
  );
}
