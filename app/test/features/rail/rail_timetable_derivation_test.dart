import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';
import 'package:wheres_the_bus/features/rail/rail_timetable_derivation.dart';

RailTrainStop _stop(String name, String arrive, [String? depart]) =>
    RailTrainStop(name: name, arrive: arrive, depart: depart ?? arrive);

void main() {
  // 區間車 1258, 苗栗 → 竹北. One-minute dwells except 新竹, which holds two.
  final stops = [
    _stop('苗栗', '', '18:08'),
    _stop('豐富', '18:12', '18:13'),
    _stop('造橋', '18:17', '18:18'),
    _stop('竹南', '18:23', '18:24'),
    _stop('新竹', '18:42', '18:44'),
    _stop('竹北', '18:50', ''),
  ];
  const date = '2026-07-19';

  group('railPositionIndex', () {
    test('is null before the run starts', () {
      expect(
        railPositionIndex(stops, date, 0, DateTime(2026, 7, 19, 17, 30)),
        isNull,
      );
    });

    test('is the last stop already called at, mid-run', () {
      // 18:20 — past 造橋 (18:17), not yet 竹南 (18:23).
      expect(
        railPositionIndex(stops, date, 0, DateTime(2026, 7, 19, 18, 20)),
        2,
      );
    });

    test('a live delay holds the train back a stop', () {
      // Same clock, 5 minutes late: 造橋's effective arrival is 18:22, so the
      // train has only reached 豐富.
      expect(
        railPositionIndex(stops, date, 5, DateTime(2026, 7, 19, 18, 20)),
        1,
      );
    });

    test('is null once the run has terminated', () {
      expect(
        railPositionIndex(stops, date, 0, DateTime(2026, 7, 19, 19, 30)),
        isNull,
      );
    });

    test('is null when a time cannot be parsed', () {
      expect(
        railPositionIndex(
          [_stop('壞掉', 'nope')],
          date,
          0,
          DateTime(2026, 7, 19, 18, 20),
        ),
        isNull,
      );
    });
  });

  group('elapsedMinutes', () {
    test('accumulates from the boarding stop', () {
      expect(elapsedMinutes(date, stops[3], stops[5]), 27);
    });

    test('is null for a pair in the wrong order', () {
      expect(elapsedMinutes(date, stops[5], stops[3]), isNull);
    });
  });

  group('dwellMinutes', () {
    test('is 1 at an ordinary TRA stop — the value not worth printing', () {
      expect(dwellMinutes(stops[1]), 1);
    });

    test('is the real wait where the train actually holds', () {
      expect(dwellMinutes(stops[4]), 2);
    });

    test('is 0 at an endpoint with only one time', () {
      expect(dwellMinutes(stops[0]), 0);
      expect(dwellMinutes(stops[5]), 0);
    });
  });

  test('sameStation folds the 臺/台 spelling split', () {
    expect(sameStation('臺北', '台北'), isTrue);
    expect(sameStation('臺中', '台南'), isFalse);
  });
}
