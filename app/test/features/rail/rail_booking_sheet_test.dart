import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/rail/booking_launch.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_booking_sheet.dart';

void main() {
  group('traClassesFor', () {
    // Offering a class the train does not run is a booking the operator
    // rejects, so each option has to be earned by a fact about the train.
    test('offers only 一般訂票 for an ordinary train', () {
      expect(
        traClassesFor(trainType: '自強號', hasBikeService: false),
        [TraBookingClass.standard],
      );
    });

    test('adds 騰雲座艙 for 新自強 in any of its backend spellings', () {
      for (final label in ['新自強', '自強(EMU3000)', 'EMU3000', '自強3000']) {
        expect(
          traClassesFor(trainType: label, hasBikeService: false),
          [TraBookingClass.standard, TraBookingClass.tengyun],
          reason: '$label should read as 新自強',
        );
      }
    });

    test('adds 兩鐵 only when the train carries bicycles', () {
      expect(
        traClassesFor(trainType: '區間車', hasBikeService: true),
        [TraBookingClass.standard, TraBookingClass.bikeOnboard],
      );
    });

    test('offers both when a 新自強 also carries bicycles', () {
      expect(traClassesFor(trainType: '新自強', hasBikeService: true), [
        TraBookingClass.standard,
        TraBookingClass.tengyun,
        TraBookingClass.bikeOnboard,
      ]);
    });

    // The 車次查詢 path opens the detail screen without the timetable's service
    // marks, so an unknown train must not be offered 兩鐵 on a guess.
    test('an unknown train type falls back to 一般訂票 alone', () {
      expect(
        traClassesFor(trainType: '', hasBikeService: false),
        [TraBookingClass.standard],
      );
    });
  });
}
