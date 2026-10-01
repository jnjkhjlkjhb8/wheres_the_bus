import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';

void main() {
  AlightEvent? at(int? previous, int remaining, int lead) => alightEventFor(
    previousRemaining: previous,
    remaining: remaining,
    lead: lead,
  );

  group('lead 0 — 不提前提醒', () {
    test('only the alight buzz exists', () {
      expect(at(3, 2, 0), isNull);
      expect(at(2, 1, 0), AlightEvent.alight);
    });
  });

  group('lead above 0', () {
    test('the lead buzz lands where the 提前提醒站 is next', () {
      // lead 2 → the 提前提醒站 is two stops before the target, so it being the
      // next stop leaves three to go.
      expect(at(4, 3, 2), AlightEvent.lead);
      expect(at(3, 2, 2), isNull);
      expect(at(2, 1, 2), AlightEvent.alight);
    });

    test('lead 1 keeps the two buzzes on separate stops', () {
      expect(at(3, 2, 1), AlightEvent.lead);
      expect(at(2, 1, 1), AlightEvent.alight);
    });
  });

  group('only genuine crossings fire', () {
    test('a repeated reading is silent', () {
      expect(at(1, 1, 0), isNull);
      expect(at(2, 2, 1), isNull);
    });

    test('a feed flapping backwards is silent', () {
      // Re-entering the window from below is not a crossing: the buzz already
      // happened on the way down.
      expect(at(1, 2, 1), isNull);
    });

    test('the first frame of a session is silent', () {
      // Without a baseline there is no crossing — a session adopted already
      // inside a window must not buzz for something that happened before it
      // existed.
      expect(at(null, 1, 0), isNull);
    });

    test('a jump past both thresholds reports the alight buzz', () {
      // A stale feed catching up can skip the lead stop entirely. The long
      // buzz is the one that matters, so it wins rather than both being lost.
      expect(at(5, 1, 2), AlightEvent.alight);
    });
  });
}
