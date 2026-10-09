import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';

void main() {
  const radius = 420.0;

  (double, double) frame(double t, {bool still = false}) =>
      scanRingFrameForTest(t: t, radius: radius, still: still);

  group('scan ring sweep', () {
    test('emerges from the location dot, not from nothing', () {
      final (r, _) = frame(0);
      expect(r, greaterThan(0));
      expect(r, lessThan(20));
    });

    test('lands on the queried radius', () {
      final (r, _) = frame(1);
      expect(r, closeTo(radius, 0.001));
    });

    test('only ever grows', () {
      var previous = 0.0;
      for (var i = 0; i <= 20; i++) {
        final (r, _) = frame(i / 20);
        expect(r, greaterThanOrEqualTo(previous));
        previous = r;
      }
    });

    test('fades up fast and leaves empty', () {
      final (_, start) = frame(0);
      final (_, early) = frame(0.03);
      final (_, end) = frame(1);
      expect(start, 0);
      // The eased curve puts the opacity peak within the first few percent of
      // real time; a slow fade-in reads as a camera flash catching up.
      expect(early, greaterThan(0.5));
      expect(end, closeTo(0, 0.001));
    });

    test('never paints above the peak opacity', () {
      for (var i = 0; i <= 40; i++) {
        final (_, alpha) = frame(i / 40);
        expect(alpha, lessThanOrEqualTo(0.55 + 0.001));
        expect(alpha, greaterThanOrEqualTo(-0.001));
      }
    });
  });

  group('scan ring, still variant', () {
    test('holds the queried radius the whole way — nothing travels', () {
      for (var i = 0; i <= 10; i++) {
        final (r, _) = frame(i / 10, still: true);
        expect(r, closeTo(radius, 0.001));
      }
    });

    test('breathes once: empty, peak at the midpoint, empty', () {
      final (_, start) = frame(0, still: true);
      final (_, middle) = frame(0.5, still: true);
      final (_, end) = frame(1, still: true);
      expect(start, closeTo(0, 0.001));
      expect(middle, closeTo(0.35, 0.001));
      expect(end, closeTo(0, 0.001));
    });

    test('stays quieter than the moving ring, since it lingers', () {
      final (_, stillPeak) = frame(0.5, still: true);
      final (_, movingPeak) = frame(0.03);
      expect(stillPeak, lessThan(movingPeak));
    });
  });
}
