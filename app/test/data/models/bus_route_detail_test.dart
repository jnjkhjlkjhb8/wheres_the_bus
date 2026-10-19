import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';

void main() {
  test('tripsForDirection returns only that direction', () {
    const detail = BusDailyTimetable(
      directions: {
        0: [
          BusDailyTrip(
            tripId: 'A',
            isLowFloor: true,
            stopTimes: [
              BusStopTime(
                stopSequence: 1,
                departureTime: '08:00',
                arrivalTime: '',
              ),
            ],
          ),
        ],
        1: [],
      },
    );
    expect(detail.tripsForDirection(0), hasLength(1));
    expect(detail.tripsForDirection(0).first.tripId, 'A');
    expect(detail.tripsForDirection(1), isEmpty);
    expect(detail.tripsForDirection(9), isEmpty); // missing direction
  });

  test('daily timetables compare direction keys and nested trip values', () {
    _expectValueContract(
      _timetable(
        directions: {
          0: [_trip()],
          1: [_trip(tripId: 'B')],
        },
      ),
      _timetable(
        directions: {
          1: [_trip(tripId: 'B')],
          0: [_trip()],
        },
      ),
      [
        _timetable(
          directions: {
            0: [_trip()],
            2: [_trip(tripId: 'B')],
          },
        ),
        _timetable(
          directions: {
            0: [_trip(tripId: 'C')],
            1: [_trip(tripId: 'B')],
          },
        ),
      ],
    );
  });

  test('daily trips compare identifier, accessibility and ordered stops', () {
    _expectValueContract(_trip(), _trip(), [
      _trip(tripId: 'B'),
      _trip(isLowFloor: true),
      _trip(stopTimes: [_stop(stopSequence: 2)]),
      _trip(
        stopTimes: [_stop(), _stop(stopSequence: 2), _stop(stopSequence: 3)],
      ),
      _trip(stopTimes: [_stop(stopSequence: 2), _stop()]),
    ]);
  });

  test('stop times compare sequence, departure and arrival', () {
    _expectValueContract(_stop(), _stop(), [
      _stop(stopSequence: 2),
      _stop(departureTime: '08:01:00'),
      _stop(arrivalTime: '07:58:00'),
    ]);
  });

  test('service entries compare every timetable and headway field', () {
    _expectValueContract(_entry(), _entry(), [
      _entry(isTimetable: false),
      _entry(serviceDay: 2),
      _entry(tripId: 'B'),
      _entry(isLowFloor: true),
      _entry(departureTime: '08:01:00'),
      _entry(startTime: '06:30:00'),
      _entry(endTime: '21:00:00'),
      _entry(minHeadwayMins: '11'),
      _entry(maxHeadwayMins: '21'),
    ]);
  });

  test('fare values compare pricing, free status and each raw payload', () {
    _expectValueContract(_fare(), _fare(), [
      _fare(pricingType: 2),
      _fare(isFreeBus: true),
      _fare(sectionFaresJson: '[16]'.codeUnits),
      _fare(stageFaresJson: '[21]'.codeUnits),
      _fare(odFaresJson: '[[31]]'.codeUnits),
    ]);
  });

  test('operator values compare name and both rider contact actions', () {
    _expectValueContract(_operator(), _operator(), [
      _operator(name: 'Transit B'),
      _operator(phone: '02-87654321'),
      _operator(url: 'https://other-operator.invalid'),
    ]);
  });
}

void _expectValueContract<T extends Object>(T value, T equal, List<T> changed) {
  expect(equal, isNot(same(value)));
  expect(equal, value);
  expect(value, equal);
  expect(equal.hashCode, value.hashCode);
  for (final other in changed) {
    expect(other, isNot(value));
    expect(value, isNot(other));
  }
  expect({value, equal, ...changed}, hasLength(changed.length + 1));
}

// Runtime fixture arguments prevent const identity from bypassing comparison.
BusDailyTimetable _timetable({
  required Map<int, List<BusDailyTrip>> directions,
}) => BusDailyTimetable(directions: directions);

BusDailyTrip _trip({
  String tripId = 'A',
  bool isLowFloor = false,
  List<BusStopTime>? stopTimes,
}) => BusDailyTrip(
  tripId: tripId,
  isLowFloor: isLowFloor,
  stopTimes: stopTimes ?? [_stop(), _stop(stopSequence: 2)],
);

BusStopTime _stop({
  int stopSequence = 1,
  String departureTime = '08:00:00',
  String arrivalTime = '07:59:00',
}) => BusStopTime(
  stopSequence: stopSequence,
  departureTime: departureTime,
  arrivalTime: arrivalTime,
);

BusServiceEntry _entry({
  bool isTimetable = true,
  int serviceDay = 1,
  String tripId = 'A',
  bool isLowFloor = false,
  String departureTime = '08:00:00',
  String startTime = '06:00:00',
  String endTime = '22:00:00',
  String minHeadwayMins = '10',
  String maxHeadwayMins = '20',
}) => BusServiceEntry(
  isTimetable: isTimetable,
  serviceDay: serviceDay,
  tripId: tripId,
  isLowFloor: isLowFloor,
  departureTime: departureTime,
  startTime: startTime,
  endTime: endTime,
  minHeadwayMins: minHeadwayMins,
  maxHeadwayMins: maxHeadwayMins,
);

BusFareInfo _fare({
  int pricingType = 1,
  bool isFreeBus = false,
  List<int>? sectionFaresJson,
  List<int>? stageFaresJson,
  List<int>? odFaresJson,
}) => BusFareInfo(
  pricingType: pricingType,
  isFreeBus: isFreeBus,
  sectionFaresJson: sectionFaresJson ?? '[15]'.codeUnits,
  stageFaresJson: stageFaresJson ?? '[20]'.codeUnits,
  odFaresJson: odFaresJson ?? '[[30]]'.codeUnits,
);

BusOperatorInfo _operator({
  String name = 'Transit A',
  String phone = '02-12345678',
  String url = 'https://operator.invalid',
}) => BusOperatorInfo(name: name, phone: phone, url: url);
