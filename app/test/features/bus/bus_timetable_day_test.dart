import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/features/bus/widgets/bus_timetable_day.dart';

const _now = TimeOfDay(hour: 8, minute: 10);

BusServiceEntry _trip(String time, int serviceDay, {bool lowFloor = false}) =>
    BusServiceEntry(
      isTimetable: true,
      serviceDay: serviceDay,
      tripId: time,
      isLowFloor: lowFloor,
      departureTime: '$time:00',
    );

BusDailyTrip _dailyTrip(List<(int, String)> stops, {bool lowFloor = false}) =>
    BusDailyTrip(
      tripId: stops.first.$2,
      isLowFloor: lowFloor,
      stopTimes: [
        for (final (seq, time) in stops)
          BusStopTime(stopSequence: seq, departureTime: time, arrivalTime: ''),
      ],
    );

void main() {
  // Monday = bit 0, Sunday = bit 6.
  const monday = 1 << 0;
  const saturday = 1 << 5;

  test('weekday index maps Monday to 0 and Sunday to 6', () {
    expect(busWeekdayIndex(DateTime(2026, 7, 27)), 0); // a Monday
    expect(busWeekdayIndex(DateTime(2026, 8, 2)), 6); // the Sunday after
  });

  test('service days list only the days some entry runs', () {
    final days = busServiceDays([
      _trip('08:00', monday | saturday),
      const BusServiceEntry(isTimetable: false, serviceDay: saturday),
    ]);
    expect(days, {0, 5});
  });

  test('today reads the daily timetable, sorted, next departure marked', () {
    final board = busTimetableForDay(
      weekday: 0,
      schedules: [_trip('06:00', monday)],
      todayTrips: [
        _dailyTrip([(1, '09:00:00')]),
        _dailyTrip([(1, '08:15:00')], lowFloor: true),
        _dailyTrip([(1, '07:00:00')]),
      ],
      isToday: true,
      now: _now,
    );
    expect(board.departures.map((d) => d.time), ['07:00', '08:15', '09:00']);
    expect(board.departures.map((d) => d.isNext), [false, true, false]);
    expect(board.departures[1].lowFloor, isTrue);
  });

  test('daily trip departs from its lowest stop sequence, not list order', () {
    final board = busTimetableForDay(
      weekday: 0,
      schedules: const [],
      todayTrips: [
        _dailyTrip([(3, '08:40:00'), (1, '08:20:00')]),
      ],
      isToday: true,
      now: _now,
    );
    expect(board.departures.single.time, '08:20');
  });

  test('another weekday reads the weekly pattern and highlights nothing', () {
    final board = busTimetableForDay(
      weekday: 5,
      schedules: [
        _trip('06:00', monday),
        _trip('09:30', saturday),
        _trip('07:45', monday | saturday),
      ],
      todayTrips: [
        _dailyTrip([(1, '08:15:00')]),
      ],
      isToday: false,
      now: _now,
    );
    expect(board.departures.map((d) => d.time), ['07:45', '09:30']);
    expect(board.departures.every((d) => !d.isNext), isTrue);
  });

  test('a day the route does not run yields nothing to show', () {
    final board = busTimetableForDay(
      weekday: 6,
      schedules: [_trip('06:00', monday)],
      todayTrips: const [],
      isToday: false,
      now: _now,
    );
    expect(board.departures, isEmpty);
    expect(board.windows, isEmpty);
  });

  test('headway routes surface their window instead of departures', () {
    final board = busTimetableForDay(
      weekday: 0,
      schedules: const [
        BusServiceEntry(
          isTimetable: false,
          serviceDay: monday,
          startTime: '06:00',
          endTime: '22:00',
          minHeadwayMins: '15',
          maxHeadwayMins: '20',
        ),
      ],
      todayTrips: const [],
      isToday: true,
      now: _now,
    );
    expect(board.departures, isEmpty);
    expect(board.windows.single.start, '06:00');
    expect(board.windows.single.maxMins, '20');
  });
}
