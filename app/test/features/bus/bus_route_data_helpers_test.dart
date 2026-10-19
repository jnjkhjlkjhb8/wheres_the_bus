import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';

BusRouteState _stateWithTrips(List<String> times, {int direction = 0}) =>
    BusRouteState(
      direction: direction,
      daily: BusDailyTimetable(
        directions: {
          direction: [
            for (final time in times)
              BusDailyTrip(
                tripId: time,
                isLowFloor: false,
                stopTimes: [
                  BusStopTime(
                    stopSequence: 1,
                    departureTime: '$time:00',
                    arrivalTime: '',
                  ),
                ],
              ),
          ],
        },
      ),
    );

// 06:00, 06:30, ... 20:30 (30 trips).
final _halfHourly = [
  for (var i = 0; i < 30; i++)
    '${(6 + i ~/ 2).toString().padLeft(2, '0')}:${i.isEven ? '00' : '30'}',
];

BusRouteViewModel _route({
  String headsignGo = '',
  String headsignReturn = '',
  List<BusStopModel> stopsGo = const [],
  List<BusStopModel> stopsReturn = const [],
}) => BusRouteViewModel(
  subRouteUid: 'u',
  routeName: '307',
  subRouteName: '307',
  departureStopName: 'A',
  destinationStopName: 'B',
  city: 'Taipei',
  headsignGo: headsignGo,
  headsignReturn: headsignReturn,
  stopsGo: stopsGo,
  stopsReturn: stopsReturn,
);

void main() {
  group('busRouteDepartures', () {
    test('keeps one past departure and marks the next', () {
      final rows = busRouteDepartures(
        _stateWithTrips(_halfHourly),
        const TimeOfDay(hour: 8, minute: 10),
      );
      expect(rows.first, (time: '08:00', isNext: false));
      expect(rows[1], (time: '08:30', isNext: true));
      expect(rows, hasLength(12));
      expect(rows.last.time, '13:30');
    });

    test('starts at the first row when nothing has departed yet', () {
      final rows = busRouteDepartures(
        _stateWithTrips(_halfHourly),
        const TimeOfDay(hour: 5, minute: 0),
      );
      expect(rows.first, (time: '06:00', isNext: true));
      expect(rows, hasLength(12));
    });

    test('clamps the window to the end of the day', () {
      final rows = busRouteDepartures(
        _stateWithTrips(_halfHourly),
        const TimeOfDay(hour: 20, minute: 10),
      );
      expect(rows.map((r) => r.time), ['20:00', '20:30']);
      expect(rows.map((r) => r.isNext), [false, true]);
    });

    test('shows the whole schedule unmarked once service is over', () {
      final rows = busRouteDepartures(
        _stateWithTrips(_halfHourly),
        const TimeOfDay(hour: 23, minute: 0),
      );
      expect(rows, hasLength(30));
      expect(rows.every((r) => !r.isNext), isTrue);
    });

    test('reads the trips of the direction on screen', () {
      final rows = busRouteDepartures(
        _stateWithTrips(['09:00'], direction: 1),
        const TimeOfDay(hour: 8, minute: 0),
      );
      expect(rows, [(time: '09:00', isNext: true)]);
      expect(
        busRouteDepartures(
          const BusRouteState(),
          const TimeOfDay(hour: 8, minute: 0),
        ),
        isEmpty,
      );
    });
  });

  group('busRouteHeadsign', () {
    test('prefers the headsign of the current direction', () {
      final route = _route(headsignGo: 'to B', headsignReturn: 'to A');
      expect(busRouteHeadsign(BusRouteState(route: route)), 'to B');
      expect(
        busRouteHeadsign(BusRouteState(route: route, direction: 1)),
        'to A',
      );
    });

    test('falls back to the last stop, then a dash', () {
      final route = _route(
        stopsGo: const [
          BusStopModel(stopUid: '1', stopName: 'first', sequence: 1),
          BusStopModel(stopUid: '2', stopName: 'last', sequence: 2),
        ],
      );
      expect(busRouteHeadsign(BusRouteState(route: route)), 'last');
      expect(busRouteHeadsign(const BusRouteState()), '-');
    });
  });
}
