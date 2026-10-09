import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';

RailTrainStop _s(String name, String arrive, String depart) =>
    RailTrainStop(name: name, arrive: arrive, depart: depart);

void main() {
  final stops = [
    _s('台北', '', '08:00'),
    _s('板橋', '08:20', '08:22'),
    _s('台中', '09:00', ''),
    _s('高雄', '10:30', ''),
  ];

  test('board→alight slice carries each stop time, arrival preferred', () {
    final sched = railTrackSchedule(
      stops,
      '2026-07-20',
      board: '板橋',
      alight: '台中',
    );
    expect(sched.map((e) => e.name).toList(), ['板橋', '台中']);
    expect(sched.first.scheduledArrival, DateTime(2026, 7, 20, 8, 20));
    expect(sched.last.scheduledArrival, DateTime(2026, 7, 20, 9));
  });

  test('board uses departure when its arrival is blank', () {
    final sched = railTrackSchedule(
      stops,
      '2026-07-20',
      board: '台北',
      alight: '板橋',
    );
    expect(sched.first.scheduledArrival, DateTime(2026, 7, 20, 8));
  });

  test('upstream or unknown alight yields empty (countdown fallback)', () {
    expect(
      railTrackSchedule(stops, '2026-07-20', board: '台中', alight: '板橋'),
      isEmpty,
    );
    expect(
      railTrackSchedule(stops, '2026-07-20', board: '板橋', alight: '嘉義'),
      isEmpty,
    );
  });
}
