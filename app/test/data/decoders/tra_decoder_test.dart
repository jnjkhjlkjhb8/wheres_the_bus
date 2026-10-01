import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/tra_decoder.dart';
import 'package:wheres_the_bus/data/generated/tra.pb.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

const TraDecoder _decoder = TraDecoder.instance;

/// Exercises the private `_parseTravelMinutes` (tra_decoder.dart:59-68)
/// indirectly through the public `decodeTimetable`, via a single-item
/// timetable that isolates the travelTime field under test.
int _travelMinutesFor(String travelTime) {
  final out = _decoder.decodeTimetable(
    tra_timetables(
      items: [tra_timetable(trainNo: 'T1', travelTime: travelTime)],
    ),
  );
  return out.single.travelMinutes;
}

void main() {
  group('_parseTravelMinutes via decodeTimetable', () {
    test("'1:30' is read as hours:minutes -> 90", () {
      expect(_travelMinutesFor('1:30'), 90);
    });

    test("'90分' strips the suffix and parses to 90", () {
      expect(_travelMinutesFor('90分'), 90);
    });

    test(
      "'1時30分' (hour+minute suffix form) is not parsed and falls back to 0",
      () {
        expect(_travelMinutesFor('1時30分'), 0);
      },
    );

    test('empty string does not throw and yields 0', () {
      expect(_travelMinutesFor(''), 0);
    });

    test("'N/A' does not throw and yields 0", () {
      expect(_travelMinutesFor('N/A'), 0);
    });
  });

  group('decodeTimetable', () {
    test('maps two items preserving order and fields', () {
      final out = _decoder.decodeTimetable(
        tra_timetables(
          items: [
            tra_timetable(
              trainNo: '123',
              trainTypeName: '自強',
              startingTime: '08:00',
              endingTime: '10:30',
              travelTime: '2:30',
              note: '',
            ),
            tra_timetable(
              trainNo: '456',
              trainTypeName: '莒光',
              startingTime: '09:15',
              endingTime: '12:00',
              travelTime: '165分',
              note: '假日行駛',
            ),
          ],
        ),
      );

      expect(out, hasLength(2));

      expect(out[0].trainNo, '123');
      expect(out[0].trainType, '自強');
      expect(out[0].departureTime, '08:00');
      expect(out[0].arrivalTime, '10:30');
      expect(out[0].travelMinutes, 150);
      expect(out[0].remark, '');

      expect(out[1].trainNo, '456');
      expect(out[1].trainType, '莒光');
      expect(out[1].departureTime, '09:15');
      expect(out[1].arrivalTime, '12:00');
      expect(out[1].travelMinutes, 165);
      expect(out[1].remark, '假日行駛');
    });

    test('empty timetable yields an empty list without throwing', () {
      expect(_decoder.decodeTimetable(tra_timetables()), isEmpty);
    });
  });

  group('mask bits via decodeTimetable', () {
    TraTimetableItem decodeWithMask(int mask) => _decoder
        .decodeTimetable(
          tra_timetables(
            items: [tra_timetable(trainNo: 'T1', mask: mask)],
          ),
        )
        .single;

    test('each bit lands on its own flag', () {
      expect(decodeWithMask(1 << 0).isDisabledFriendly, isTrue);
      expect(decodeWithMask(1 << 2).hasDiningCar, isTrue);
      expect(decodeWithMask(1 << 3).hasBike, isTrue);
      expect(decodeWithMask(1 << 4).hasBreastfeeding, isTrue);
      expect(decodeWithMask(1 << 5).runsDaily, isTrue);
      expect(decodeWithMask(1 << 6).isAddedService, isTrue);
      expect(decodeWithMask(1 << 7).isSuspended, isTrue);
    });

    test('bit 1 (行李服務) sets nothing — it has no icon and no UI', () {
      final item = decodeWithMask(1 << 1);
      expect(item.isDisabledFriendly, isFalse);
      expect(item.hasDiningCar, isFalse);
      expect(item.hasBike, isFalse);
      expect(item.hasBreastfeeding, isFalse);
      expect(item.runsDaily, isFalse);
      expect(item.isAddedService, isFalse);
      expect(item.isSuspended, isFalse);
    });

    test('a suspended train with amenities keeps both readings', () {
      // 133 = wheel | dining | suspended, the combination load_sink_test.go
      // pins on the Go side.
      final item = decodeWithMask(133);
      expect(item.isDisabledFriendly, isTrue);
      expect(item.hasDiningCar, isTrue);
      expect(item.isSuspended, isTrue);
      expect(item.hasBike, isFalse);
    });

    test('mask 0 leaves every flag clear', () {
      final item = decodeWithMask(0);
      expect(item.isDisabledFriendly, isFalse);
      expect(item.isSuspended, isFalse);
      expect(item.runsDaily, isFalse);
    });
  });

  group('decodeTimetableCard', () {
    test('carries station names, type, and the raw travel-time string', () {
      final view = _decoder.decodeTimetableCard(
        tra_timetable(
          trainNo: '123',
          trainTypeName: '自強',
          startingStationName: '臺北',
          endingStationName: '花蓮',
          startingTime: '08:00',
          endingTime: '10:30',
          travelTime: '2:30',
        ),
      );
      expect(view.trainNo, '123');
      expect(view.trainType, '自強');
      expect(view.originName, '臺北');
      expect(view.destinationName, '花蓮');
      expect(view.departureTime, '08:00');
      expect(view.arrivalTime, '10:30');
      // Kept verbatim, not parsed to minutes.
      expect(view.travelTime, '2:30');
    });
  });
}
