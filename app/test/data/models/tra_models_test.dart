import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

void main() {
  _traValueContracts();
  // What TDX lands for 桃園→臺北: one adult fare per train class, plus the
  // concession rows for the classes that publish them.
  const fares = [
    TraFare(ticketType: '成自', price: 99),
    TraFare(ticketType: '成莒', price: 76),
    TraFare(ticketType: '成復', price: 63),
    TraFare(ticketType: '成普', price: 31),
    TraFare(ticketType: '孩自', price: 50),
    TraFare(ticketType: '敬復', price: 32),
  ];

  test('prices each train class from its TDX train type name', () {
    int? full(String trainType) =>
        traFareFor(fares, trainType, FareType.full)?.price;
    // 區間車 is priced on the 復興 (成復) tier — the fare that used to be
    // misquoted as 99 because the pair's priciest row won.
    expect(full('區間'), 63);
    expect(full('區間快'), 63);
    expect(full('莒光(郵輪式列車)'), 76);
    expect(full('普快(專開列車)'), 31);
    // 太魯閣/普悠瑪/EMU3000 all bill at the 自強 fare.
    expect(full('自強(3000)(EMU3000 型電車)'), 99);
    expect(full('太魯閣(太魯閣)'), 99);
    expect(full('普悠瑪(普悠瑪)'), 99);
  });

  test('quotes the rider ticket type on the matching train class', () {
    // The concession is resolved on *both* axes at once: 敬老 on a 區間車 is
    // 敬復 (32), not the 敬老自強 fare and not the 全票區間 fare.
    final senior = traFareFor(fares, '區間', FareType.concession);
    expect(senior, (price: 32, matched: FareType.concession));

    final child = traFareFor(fares, '自強', FareType.child);
    expect(child, (price: 50, matched: FareType.child));
  });

  test('falls back to the full fare and says so', () {
    // The pair publishes no 孩童 fare on 區間車, so the rider sees the full
    // fare — reported as 全票 so the UI can never label 63 as a child fare.
    final child = traFareFor(fares, '區間', FareType.child);
    expect(child, (price: 63, matched: FareType.full));

    // TRA prices no student fare at all; students ride on 全票.
    final student = traFareFor(fares, '區間', FareType.student);
    expect(student, (price: 63, matched: FareType.full));
  });

  test('returns null when the pair has no fare for that class', () {
    expect(traFareFor(const [], '區間', FareType.full), isNull);
    // A zero price is missing data, not a free ride.
    expect(
      traFareFor(
        const [TraFare(ticketType: '成復', price: 0)],
        '區間',
        FareType.full,
      ),
      isNull,
    );
  });
}

void _traValueContracts() {
  test('TRA delay values distinguish the train and reported minutes', () {
    final delay = _delay();
    final equal = _delay();
    expect(identical(delay, equal), isFalse);
    expect(delay, equal);
    expect(delay.hashCode, equal.hashCode);
    final changed = [
      _delay(trainNo: '125'),
      _delay(delayMinutes: 4),
    ];
    for (final other in changed) {
      expect(delay, isNot(other));
    }
    expect({delay, equal, ...changed}, hasLength(3));
  });

  test('TRA stop values distinguish station, both times and stop order', () {
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

  test('TRA timetable equality retains trip, amenities and service state', () {
    final trip = _trip();
    final equal = _trip();
    expect(identical(trip, equal), isFalse);
    expect(trip, equal);
    expect(trip.hashCode, equal.hashCode);
    final changed = [
      _trip(trainNo: '125'),
      _trip(trainType: '莒光'),
      _trip(departureTime: '08:10'),
      _trip(arrivalTime: '10:10'),
      _trip(travelMinutes: 130),
      _trip(delayMinutes: 5),
      _trip(hasBike: false),
      _trip(hasDiningCar: false),
      _trip(isDisabledFriendly: false),
      _trip(hasBreastfeeding: false),
      _trip(remark: ''),
      _trip(runsDaily: false),
      _trip(isAddedService: false),
      _trip(isSuspended: false),
    ];
    for (final other in changed) {
      expect(trip, isNot(other));
    }
    expect({trip, equal, ...changed}, hasLength(15));
  });
}

TraDelayItem _delay({
  String trainNo = '123',
  int delayMinutes = 3,
}) => TraDelayItem(trainNo: trainNo, delayMinutes: delayMinutes);

TraStopTime _stop({
  String stationName = '臺北',
  String arrivalTime = '08:00',
  String departureTime = '08:05',
  int sequence = 2,
}) => TraStopTime(
  stationName: stationName,
  arrivalTime: arrivalTime,
  departureTime: departureTime,
  sequence: sequence,
);

TraTimetableItem _trip({
  String trainNo = '123',
  String trainType = '自強',
  String departureTime = '08:00',
  String arrivalTime = '10:00',
  int travelMinutes = 120,
  int delayMinutes = 3,
  bool hasBike = true,
  bool hasDiningCar = true,
  bool isDisabledFriendly = true,
  bool hasBreastfeeding = true,
  String remark = '加開公告',
  bool runsDaily = true,
  bool isAddedService = true,
  bool isSuspended = true,
}) => TraTimetableItem(
  trainNo: trainNo,
  trainType: trainType,
  departureTime: departureTime,
  arrivalTime: arrivalTime,
  travelMinutes: travelMinutes,
  delayMinutes: delayMinutes,
  hasBike: hasBike,
  hasDiningCar: hasDiningCar,
  isDisabledFriendly: isDisabledFriendly,
  hasBreastfeeding: hasBreastfeeding,
  remark: remark,
  runsDaily: runsDaily,
  isAddedService: isAddedService,
  isSuspended: isSuspended,
);
