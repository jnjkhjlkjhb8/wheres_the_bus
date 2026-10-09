import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/leg_eta_source.dart';

List<RailStopSchedule> _sched() => [
  RailStopSchedule(name: '台北', scheduledArrival: DateTime(2026, 7, 20, 8)),
  RailStopSchedule(name: '板橋', scheduledArrival: DateTime(2026, 7, 20, 8, 20)),
  RailStopSchedule(name: '台中', scheduledArrival: DateTime(2026, 7, 20, 9)),
];

void main() {
  test('before departure: full segment, zero progress, next = board', () {
    final r = railProgress(
      _sched(),
      Duration.zero,
      DateTime(2026, 7, 20, 7, 50),
    );
    expect(r.remainingStops, 2);
    expect(r.progress, 0.0);
    expect(r.nextStop, '台北');
    expect(r.etaToAlight, const Duration(hours: 1, minutes: 10));
  });

  test('mid-run: decremented, partial progress, real next stop', () {
    // 08:30 — past 板橋 (08:20), heading to 台中.
    final r = railProgress(
      _sched(),
      Duration.zero,
      DateTime(2026, 7, 20, 8, 30),
    );
    expect(r.remainingStops, 1);
    expect(r.nextStop, '台中');
    expect(r.progress, closeTo(0.5, 0.001)); // 30 of 60 scheduled min
    expect(r.etaToAlight, const Duration(minutes: 30));
  });

  test('delay shifts both the boundary and the ETA', () {
    // +10 min delay: 板橋 now effectively 08:30, so at 08:25 it is NOT passed.
    final r = railProgress(
      _sched(),
      const Duration(minutes: 10),
      DateTime(2026, 7, 20, 8, 25),
    );
    expect(r.remainingStops, 2); // still before 板橋
    expect(r.nextStop, '板橋');
    // alight effective 09:10; eta = 45 min.
    expect(r.etaToAlight, const Duration(minutes: 45));
  });

  test('at/after alight: nothing left, full progress', () {
    final r = railProgress(
      _sched(),
      Duration.zero,
      DateTime(2026, 7, 20, 9, 5),
    );
    expect(r.remainingStops, 0);
    expect(r.progress, 1.0);
    expect(r.etaToAlight, Duration.zero);
    expect(r.nextStop, '台中');
  });

  test('single-stop segment is a no-op tracker', () {
    final one = [
      RailStopSchedule(name: '台中', scheduledArrival: DateTime(2026, 7, 20, 9)),
    ];
    final r = railProgress(one, Duration.zero, DateTime(2026, 7, 20, 8));
    expect(r.remainingStops, 0);
    expect(r.progress, 1.0);
    expect(r.nextStop, '台中');
  });
}
