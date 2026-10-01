import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';

void main() {
  const base = AlightTrackContent(
    mode: AlightTrackMode.bus,
    phase: AlightTrackPhase.riding,
    vehicleLabel: '672',
    boardStation: 'A',
    targetStation: 'C',
    nextStation: 'B',
    hopCount: 6,
    currentIndex: 2,
    remainingStops: 4,
    leadStops: 2,
  );

  test('toArgs carries the vehicle identity when one is pinned', () {
    const pinned = AlightTrackContent(
      mode: AlightTrackMode.bus,
      phase: AlightTrackPhase.riding,
      vehicleLabel: '672',
      vehicleId: 'KKA-1288',
      boardStation: 'A',
      targetStation: 'C',
      nextStation: 'B',
      hopCount: 6,
      currentIndex: 2,
      remainingStops: 4,
      leadStops: 2,
    );

    final args = pinned.toArgs();

    expect(args['vehicleLabel'], '672');
    expect(args['vehicleId'], 'KKA-1288');
  });

  test('toArgs still declares vehicleId when no vehicle is pinned', () {
    final args = base.toArgs();

    expect(args.containsKey('vehicleId'), isTrue);
    expect(args['vehicleId'], isNull);
  });

  test('every mode and phase crosses the wire as its bare name', () {
    // The Kotlin and Swift sides switch on these strings; renaming an enum
    // value without renaming the platform branch would silently fall back to
    // the riding card.
    expect(
      AlightTrackMode.values.map((m) => m.name),
      ['bus', 'tra', 'thsr', 'metro'],
    );
    expect(
      AlightTrackPhase.values.map((p) => p.name),
      ['waiting', 'riding', 'approaching', 'arrived', 'lost'],
    );
  });

  test('toArgs carries the session id, and declares it when there is none', () {
    const metro = AlightTrackContent(
      mode: AlightTrackMode.metro,
      phase: AlightTrackPhase.riding,
      vehicleLabel: '板南線',
      boardStation: 'A',
      targetStation: 'C',
      nextStation: 'B',
      hopCount: 6,
      currentIndex: 2,
      remainingStops: 4,
      leadStops: 2,
      trackId: '3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f',
    );

    expect(metro.toArgs()['trackId'], '3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f');
    expect(base.toArgs().containsKey('trackId'), isTrue);
    expect(base.toArgs()['trackId'], isNull);
  });
}
