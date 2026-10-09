import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/thsr_decoder.dart';
import 'package:wheres_the_bus/data/generated/thsr.pb.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';

const ThsrDecoder _decoder = ThsrDecoder.instance;

/// The operator's own worked example: train 0117 南港 → 左營, calling at 台北,
/// 板橋 and 台中. Only 台北 is sold out (standard) / nearly sold out (business).
thsr_available_seats _example() => thsr_available_seats(
  trainNo: '0117',
  segments: [
    thsr_seat_segment(
      originStationId: '0990', // 南港
      destinationStationId: '1000',
      standardSeatStatus: 'O',
      businessSeatStatus: 'O',
    ),
    thsr_seat_segment(
      originStationId: '1000', // 台北
      destinationStationId: '1010',
      standardSeatStatus: 'X',
      businessSeatStatus: 'L',
    ),
    thsr_seat_segment(
      originStationId: '1010', // 板橋
      destinationStationId: '1040',
      standardSeatStatus: 'O',
      businessSeatStatus: 'O',
    ),
    thsr_seat_segment(
      originStationId: '1040', // 台中
      destinationStationId: '1070',
      standardSeatStatus: 'O',
      businessSeatStatus: 'O',
    ),
  ],
);

void main() {
  group('decodeSeatStatus', () {
    ThsrSeatStatus status(String from, String to, {bool business = false}) =>
        _decoder.decodeSeatStatus(
          _example(),
          fromStationId: from,
          toStationId: to,
          business: business,
        );

    test('a journey ending before the sold-out station is buyable', () {
      expect(status('0990', '1000'), ThsrSeatStatus.available);
    });

    test('a journey passing through the sold-out station is not', () {
      // 南港→板橋 and 南港→台中 both cross 台北, whose standard seats are gone.
      expect(status('0990', '1010'), ThsrSeatStatus.soldOut);
      expect(status('0990', '1040'), ThsrSeatStatus.soldOut);
      expect(status('1000', '1010'), ThsrSeatStatus.soldOut);
    });

    test('business class on the same journey is only limited', () {
      expect(status('0990', '1010', business: true), ThsrSeatStatus.limited);
    });

    test('journeys avoiding the sold-out station are unaffected', () {
      expect(status('1010', '1040'), ThsrSeatStatus.available);
      expect(status('1040', '1070'), ThsrSeatStatus.available);
      expect(status('1010', '1070'), ThsrSeatStatus.available);
    });

    test('stations this train does not pair yield unknown, never a seat', () {
      expect(status('9999', '1070'), ThsrSeatStatus.unknown);
      expect(status('0990', '9999'), ThsrSeatStatus.unknown);
      // Reversed: 台中 never precedes 台北 on this run.
      expect(status('1040', '1000'), ThsrSeatStatus.unknown);
      expect(status('0990', '0990'), ThsrSeatStatus.unknown);
    });

    test('an unrecognised status letter is unknown, not available', () {
      final seats = _example();
      seats.segments[0].standardSeatStatus = '?';
      expect(
        _decoder.decodeSeatStatus(
          seats,
          fromStationId: '0990',
          toStationId: '1000',
        ),
        ThsrSeatStatus.unknown,
      );
    });
  });

  group('decodeTimetableCard', () {
    test('fixes the type label to 高鐵 and preserves the rest verbatim', () {
      final view = _decoder.decodeTimetableCard(
        thsa_timetable(
          trainNo: '0821',
          startingStationName: '南港',
          endingStationName: '左營',
          startingTime: '09:00',
          endingTime: '10:36',
          travelTime: '1:36',
        ),
      );
      expect(view.trainNo, '0821');
      // THSR has a single service class; the wire carries no type name.
      expect(view.trainType, '高鐵');
      expect(view.originName, '南港');
      expect(view.destinationName, '左營');
      expect(view.departureTime, '09:00');
      expect(view.arrivalTime, '10:36');
      expect(view.travelTime, '1:36');
    });
  });
}
