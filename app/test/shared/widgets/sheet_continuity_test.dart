import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

void main() {
  group('carriedFraction', () {
    test('returns the current height as a viewport fraction', () {
      expect(
        carriedFraction(
          offset: 300,
          viewportHeight: 1000,
          min: 0.25,
          max: 1,
          fallback: 0.5,
        ),
        0.3,
      );
    });

    test('clamps to the target sheet range (e.g. metro cap)', () {
      expect(
        carriedFraction(
          offset: 950,
          viewportHeight: 1000,
          min: 0.25,
          max: 0.85,
          fallback: 0.5,
        ),
        0.85,
      );
      expect(
        carriedFraction(
          offset: 100,
          viewportHeight: 1000,
          min: 0.25,
          max: 1,
          fallback: 0.5,
        ),
        0.25,
      );
    });

    test('falls back (clamped) when the sheet has no metrics yet', () {
      expect(
        carriedFraction(
          offset: 0,
          viewportHeight: 0,
          min: 0.25,
          max: 1,
          fallback: 0.5,
        ),
        0.5,
      );
      expect(
        carriedFraction(
          offset: 0,
          viewportHeight: 0,
          min: 0.25,
          max: 1,
          fallback: 0.1,
        ),
        0.25,
      );
    });
  });
}
