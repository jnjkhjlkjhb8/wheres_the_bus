import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';

void main() {
  test('defaults describe the standard planner request', () {
    const options = PlanOptions();
    expect(options.top, 5);
    expect(options.transitModes, [3, 4, 5, 6, 7, 8, 9]);
    expect(options.transferBufferMinutes, 0);
    expect(options.firstMileMode, 0);
    expect(options.firstMileTime, 10);
    expect(options.lastMileMode, 0);
    expect(options.lastMileTime, 10);
    expect(options.maxTransfers, isNull);
    expect(options.avoidReservation, isFalse);
    expect(options.carryBike, isFalse);
    expect(options.wheelchair, isFalse);
    expect(options.walkSpeedCmPerSec, 0);
  });

  group('copyWith', () {
    const base = PlanOptions(
      top: 3,
      transitModes: [1, 2],
      transferBufferMinutes: 5,
      firstMileMode: 1,
      firstMileTime: 7,
      lastMileMode: 2,
      lastMileTime: 8,
      maxTransfers: 2,
      avoidReservation: true,
      carryBike: true,
      wheelchair: true,
      walkSpeedCmPerSec: 90,
    );

    test('without arguments it keeps every field', () {
      expect(base.copyWith(), base);
    });

    test('each argument replaces only its own field', () {
      expect(base.copyWith(top: 9).top, 9);
      expect(base.copyWith(transitModes: [8]).transitModes, [8]);
      expect(
        base.copyWith(transferBufferMinutes: 1).transferBufferMinutes,
        1,
      );
      expect(base.copyWith(firstMileMode: 3).firstMileMode, 3);
      expect(base.copyWith(firstMileTime: 4).firstMileTime, 4);
      expect(base.copyWith(lastMileMode: 3).lastMileMode, 3);
      expect(base.copyWith(lastMileTime: 4).lastMileTime, 4);
      expect(base.copyWith(maxTransfers: 0).maxTransfers, 0);
      expect(base.copyWith(avoidReservation: false).avoidReservation, isFalse);
      expect(base.copyWith(carryBike: false).carryBike, isFalse);
      expect(base.copyWith(wheelchair: false).wheelchair, isFalse);
      expect(base.copyWith(walkSpeedCmPerSec: 60).walkSpeedCmPerSec, 60);

      final changed = base.copyWith(top: 9);
      expect(changed.transitModes, [1, 2]);
      expect(changed.transferBufferMinutes, 5);
      expect(changed.firstMileMode, 1);
      expect(changed.firstMileTime, 7);
      expect(changed.lastMileMode, 2);
      expect(changed.lastMileTime, 8);
      expect(changed.maxTransfers, 2);
      expect(changed.avoidReservation, isTrue);
      expect(changed.carryBike, isTrue);
      expect(changed.wheelchair, isTrue);
      expect(changed.walkSpeedCmPerSec, 90);
    });

    test('clearMaxTransfers removes the ceiling and wins over a new value', () {
      expect(base.copyWith(clearMaxTransfers: true).maxTransfers, isNull);
      expect(
        base.copyWith(clearMaxTransfers: true, maxTransfers: 4).maxTransfers,
        isNull,
      );
      expect(base.copyWith(clearMaxTransfers: false).maxTransfers, 2);
    });
  });

  test('every field takes part in equality', () {
    const base = PlanOptions();
    expect(base, const PlanOptions());
    expect(base.hashCode, const PlanOptions().hashCode);
    final others = [
      base.copyWith(top: 6),
      base.copyWith(transitModes: [3]),
      base.copyWith(transferBufferMinutes: 16),
      base.copyWith(firstMileMode: 1),
      base.copyWith(firstMileTime: 11),
      base.copyWith(lastMileMode: 1),
      base.copyWith(lastMileTime: 11),
      base.copyWith(maxTransfers: 1),
      base.copyWith(avoidReservation: true),
      base.copyWith(carryBike: true),
      base.copyWith(wheelchair: true),
      base.copyWith(walkSpeedCmPerSec: 1),
    ];
    for (final other in others) {
      expect(other, isNot(base));
    }
  });
}
