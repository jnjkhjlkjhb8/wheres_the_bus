import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/widgets/pinned_bus.dart';

BusStopEtaViewModel _eta(
  String uid, {
  required int direction,
  required int sequence,
  String plate = '',
}) => BusStopEtaViewModel(
  stopUid: uid,
  direction: direction,
  sequence: sequence,
  estimateSeconds: 0,
  nextBusTime: '',
  stopStatus: 0,
  // The whole route's fleet, identical on every stop — deliberately set on
  // every entry, since matching it is exactly the bug this guards.
  vehiclePlates: const ['KAA-1', 'OTHER'],
  plate: plate,
);

void main() {
  group('pinnedBusNextStopIndex', () {
    const order = ['A', 'B', 'C', 'D'];

    test('returns the lowest-order stop this vehicle is estimated at', () {
      final etas = [
        _eta('B', direction: 0, sequence: 2, plate: 'KAA-1'),
        _eta('C', direction: 0, sequence: 3, plate: 'KAA-1'),
      ];
      expect(
        pinnedBusNextStopIndex(
          etas: etas,
          stopUidsInOrder: order,
          direction: 0,
          plate: 'KAA-1',
        ),
        1, // 'B'
      );
    });

    test('ignores the other travel direction', () {
      final etas = [
        _eta('A', direction: 1, sequence: 1, plate: 'KAA-1'),
        _eta('C', direction: 0, sequence: 3, plate: 'KAA-1'),
      ];
      expect(
        pinnedBusNextStopIndex(
          etas: etas,
          stopUidsInOrder: order,
          direction: 0,
          plate: 'KAA-1',
        ),
        2, // 'C', not the direction-1 'A'
      );
    });

    test('returns null when no frame mentions the plate', () {
      final etas = [
        _eta('B', direction: 0, sequence: 2, plate: 'OTHER'),
      ];
      expect(
        pinnedBusNextStopIndex(
          etas: etas,
          stopUidsInOrder: order,
          direction: 0,
          plate: 'KAA-1',
        ),
        isNull,
      );
    });
  });

  group('firstAlightIndex / isAlightTarget', () {
    test('unknown position lets every stop be a target', () {
      expect(firstAlightIndex(null), 0);
      expect(isAlightTarget(0, null), isTrue);
      expect(isAlightTarget(5, null), isTrue);
    });

    test('stops before the bus are not targets', () {
      expect(firstAlightIndex(3), 3);
      expect(isAlightTarget(2, 3), isFalse);
      expect(isAlightTarget(3, 3), isTrue);
      expect(isAlightTarget(4, 3), isTrue);
    });
  });

  group('clampLeadStops', () {
    test('floors at zero stops', () {
      expect(clampLeadStops(0), 0);
      expect(clampLeadStops(-2), 0);
      expect(clampLeadStops(1), 1);
      expect(clampLeadStops(4), 4);
    });
  });
}
