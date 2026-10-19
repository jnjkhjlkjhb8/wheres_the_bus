import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';

ThsrTimetableItem _trip({
  String trainNo = '612',
  String departureTime = '23:40',
  String arrivalTime = '00:20',
  int travelMinutes = 40,
  int delayMinutes = 3,
  String remark = '臨時加開',
  ThsrSeatStatus seatStatus = ThsrSeatStatus.limited,
  bool isOvernight = true,
}) => ThsrTimetableItem(
  trainNo: trainNo,
  departureTime: departureTime,
  arrivalTime: arrivalTime,
  travelMinutes: travelMinutes,
  delayMinutes: delayMinutes,
  remark: remark,
  seatStatus: seatStatus,
  isOvernight: isOvernight,
);

ThsrStopTime _stop({
  String stationName = '臺北',
  String arrivalTime = '08:00',
  String departureTime = '08:05',
  int sequence = 2,
}) => ThsrStopTime(
  stationName: stationName,
  arrivalTime: arrivalTime,
  departureTime: departureTime,
  sequence: sequence,
);

void main() {
  test(
    'THSR trip values distinguish schedule, delay, seats and overnight state',
    () {
      final trip = _trip();
      final equal = _trip();
      expect(identical(trip, equal), isFalse);
      expect(trip, equal);
      expect(trip.hashCode, equal.hashCode);
      final changed = [
        _trip(trainNo: '614'),
        _trip(departureTime: '23:45'),
        _trip(arrivalTime: '00:25'),
        _trip(travelMinutes: 45),
        _trip(delayMinutes: 4),
        _trip(remark: ''),
        _trip(seatStatus: ThsrSeatStatus.soldOut),
        _trip(isOvernight: false),
      ];
      for (final other in changed) {
        expect(trip, isNot(other));
      }
      expect({trip, equal, ...changed}, hasLength(9));
    },
  );

  test('THSR stop values distinguish station, both times and stop order', () {
    final stop = _stop();
    final equal = _stop();
    expect(identical(stop, equal), isFalse);
    expect(stop, equal);
    expect(stop.hashCode, equal.hashCode);
    final changed = [
      _stop(stationName: '板橋'),
      _stop(arrivalTime: '08:01'),
      _stop(departureTime: '08:06'),
      _stop(sequence: 3),
    ];
    for (final other in changed) {
      expect(stop, isNot(other));
    }
    expect({stop, equal, ...changed}, hasLength(5));
  });

  test('rider quotes skip wrong cabins, classes and unavailable prices', () {
    const fares = [
      ThsrFare(fareClass: 2, price: 800),
      ThsrFare(fareClass: 1, cabinClass: 2, price: 1950),
      ThsrFare(fareClass: 1, cabinClass: 3, price: 1445),
      ThsrFare(fareClass: 1, price: 0),
      ThsrFare(fareClass: 1, price: -1),
      ThsrFare(fareClass: 9, cabinClass: 2, price: 975),
      ThsrFare(fareClass: 9, cabinClass: 3, price: 720),
      ThsrFare(fareClass: 9, price: 0),
      ThsrFare(fareClass: 9, price: -1),
      ThsrFare(fareClass: 1, price: 1),
      ThsrFare(fareClass: 9, price: 7),
    ];
    for (final rider in [FareType.full, FareType.student]) {
      expect(thsrFareFor(fares, rider), (price: 1, matched: FareType.full));
    }
    for (final rider in [FareType.child, FareType.concession]) {
      expect(thsrFareFor(fares, rider), (price: 7, matched: rider));
    }
  });

  test(
    'unavailable half fares fall back only to an available standard full fare',
    () {
      const unavailable = [
        ThsrFare(fareClass: 2, price: 80),
        ThsrFare(fareClass: 1, cabinClass: 2, price: 120),
        ThsrFare(fareClass: 1, price: 0),
        ThsrFare(fareClass: 9, cabinClass: 2, price: 60),
        ThsrFare(fareClass: 9, cabinClass: 3, price: 40),
        ThsrFare(fareClass: 9, price: 0),
        ThsrFare(fareClass: 9, price: -1),
      ];
      for (final rider in FareType.values) {
        expect(thsrFareFor(unavailable, rider), isNull);
      }
      const withFullFare = [
        ...unavailable,
        ThsrFare(fareClass: 1, price: 91),
      ];
      for (final rider in [FareType.child, FareType.concession]) {
        expect(
          thsrFareFor(withFullFare, rider),
          (price: 91, matched: FareType.full),
        );
      }
    },
  );
}
