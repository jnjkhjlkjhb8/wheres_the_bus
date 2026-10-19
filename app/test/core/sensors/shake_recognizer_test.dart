import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/sensors/shake_recognizer.dart';

/// Feeds [peaks] along the x axis, one every [step], and reports whether any
/// sample completed a shake.
bool _feed(
  ShakeRecognizer recognizer,
  List<double> peaks, {
  Duration step = const Duration(milliseconds: 80),
  Duration from = Duration.zero,
}) {
  var fired = false;
  var at = from;
  for (final x in peaks) {
    if (recognizer.add(x: x, y: 0, z: 0, at: at)) fired = true;
    at += step;
  }
  return fired;
}

/// Feeds full (x, y, z) peaks, 80 ms apart, to exercise each axis.
bool _feedVectors(
  ShakeRecognizer recognizer,
  List<(double, double, double)> peaks,
) {
  var fired = false;
  var at = Duration.zero;
  for (final (x, y, z) in peaks) {
    if (recognizer.add(x: x, y: y, z: z, at: at)) fired = true;
    at += const Duration(milliseconds: 80);
  }
  return fired;
}

void main() {
  test('a peak exactly at the threshold counts', () {
    expect(_feed(ShakeRecognizer(), [15, -15, 15, -15]), isTrue);
  });

  test('a projection exactly at half the threshold reverses the axis', () {
    final recognizer = ShakeRecognizer(requiredReversals: 1);
    expect(recognizer.add(x: 20, y: 0, z: 0, at: Duration.zero), isFalse);
    expect(
      recognizer.add(
        x: -7.49,
        y: 20,
        z: 0,
        at: const Duration(milliseconds: 80),
      ),
      isFalse,
    );
    expect(
      recognizer.add(
        x: -7.5,
        y: 20,
        z: 0,
        at: const Duration(milliseconds: 160),
      ),
      isTrue,
    );
  });

  test('the attempt includes a reversal exactly on the window boundary', () {
    final recognizer = ShakeRecognizer(requiredReversals: 1);
    expect(recognizer.add(x: 20, y: 0, z: 0, at: Duration.zero), isFalse);
    expect(
      recognizer.add(x: -20, y: 0, z: 0, at: const Duration(milliseconds: 700)),
      isTrue,
    );
  });

  test('reset clears a partial attempt while preserving the cooldown', () {
    final recognizer = ShakeRecognizer(requiredReversals: 1)
      ..add(x: 20, y: 0, z: 0, at: Duration.zero)
      ..reset();
    expect(
      recognizer.add(x: -20, y: 0, z: 0, at: const Duration(milliseconds: 40)),
      isFalse,
    );
    expect(
      recognizer.add(x: 20, y: 0, z: 0, at: const Duration(milliseconds: 80)),
      isTrue,
    );
    recognizer.reset();
    expect(
      _feed(recognizer, [20, -20], from: const Duration(milliseconds: 100)),
      isFalse,
    );
    expect(
      _feed(recognizer, [20, -20], from: const Duration(milliseconds: 3080)),
      isTrue,
    );
  });

  test('a tilted three-dimensional axis counts opposing peaks', () {
    final recognizer = ShakeRecognizer(requiredReversals: 1);
    expect(recognizer.add(x: -10, y: 10, z: -10, at: Duration.zero), isFalse);
    expect(
      recognizer.add(
        x: -10,
        y: 10,
        z: -10,
        at: const Duration(milliseconds: 40),
      ),
      isFalse,
    );
    expect(
      recognizer.add(
        x: 10,
        y: -10,
        z: 10,
        at: const Duration(milliseconds: 80),
      ),
      isTrue,
    );
  });

  test('a back-and-forth shake fires', () {
    expect(_feed(ShakeRecognizer(), [20, -20, 20, -20]), isTrue);
  });

  test('two legs are not enough', () {
    expect(_feed(ShakeRecognizer(), [20, -20, 20]), isFalse);
  });

  // The case the whole design is for: a phone on a bus over a rough surface
  // takes hard jolts, but they push it one way and let it settle.
  test('repeated jolts in one direction never fire', () {
    expect(_feed(ShakeRecognizer(), [22, 25, 21, 30, 24, 28]), isFalse);
  });

  test('gentle handling stays below the threshold', () {
    expect(_feed(ShakeRecognizer(), [8, -9, 8, -9, 8, -9]), isFalse);
  });

  // Reversals only count while an attempt is live, so unrelated jolts spaced
  // out over a ride cannot accumulate into a trigger.
  test('reversals spread past the window never accumulate', () {
    expect(
      _feed(
        ShakeRecognizer(),
        [20, -20, 20, -20, 20, -20],
        step: const Duration(milliseconds: 400),
      ),
      isFalse,
    );
  });

  test('one long shake asks once', () {
    final recognizer = ShakeRecognizer();
    expect(_feed(recognizer, [20, -20, 20, -20]), isTrue);
    expect(
      _feed(
        recognizer,
        [20, -20, 20, -20],
        from: const Duration(milliseconds: 320),
      ),
      isFalse,
    );
  });

  test('a fresh shake after the cooldown fires again', () {
    final recognizer = ShakeRecognizer();
    expect(_feed(recognizer, [20, -20, 20, -20]), isTrue);
    expect(
      _feed(recognizer, [20, -20, 20, -20], from: const Duration(seconds: 5)),
      isTrue,
    );
  });

  // Force arriving from a new direction is not the shake continuing; it is
  // a different event, and the first peak's axis is what every later one is
  // read against.
  test('peaks across the shake axis do not count as reversals', () {
    final recognizer = ShakeRecognizer();
    var at = Duration.zero;
    var fired = false;
    for (final sample in [
      (20.0, 0.0),
      (0.0, -20.0),
      (0.0, 20.0),
      (0.0, -20.0),
    ]) {
      if (recognizer.add(x: sample.$1, y: sample.$2, z: 0, at: at)) {
        fired = true;
      }
      at += const Duration(milliseconds: 80);
    }
    expect(fired, isFalse);
  });

  test('a shake along the y axis fires', () {
    expect(
      _feedVectors(ShakeRecognizer(), [
        (0.0, 20.0, 0.0),
        (0.0, -20.0, 0.0),
        (0.0, 20.0, 0.0),
        (0.0, -20.0, 0.0),
      ]),
      isTrue,
    );
  });

  test('a shake along the z axis fires', () {
    expect(
      _feedVectors(ShakeRecognizer(), [
        (0.0, 0.0, 20.0),
        (0.0, 0.0, -20.0),
        (0.0, 0.0, 20.0),
        (0.0, 0.0, -20.0),
      ]),
      isTrue,
    );
  });

  test('a same-side peak between reversals keeps the attempt alive', () {
    final recognizer = ShakeRecognizer(requiredReversals: 2);
    expect(_feed(recognizer, [20, -20, -20, 20]), isTrue);
  });

  test('a shake starting exactly when the cooldown ends fires', () {
    final recognizer = ShakeRecognizer();
    expect(_feed(recognizer, [20, -20, 20, -20]), isTrue);
    expect(
      _feed(
        recognizer,
        [20, -20, 20, -20],
        from: const Duration(milliseconds: 3240),
      ),
      isTrue,
    );
  });

  test('samples inside the cooldown never fire', () {
    final recognizer = ShakeRecognizer();
    expect(_feed(recognizer, [20, -20, 20, -20]), isTrue);
    expect(
      _feed(
        recognizer,
        [20, -20, 20, -20],
        from: const Duration(milliseconds: 2900),
      ),
      isFalse,
    );
  });
}
