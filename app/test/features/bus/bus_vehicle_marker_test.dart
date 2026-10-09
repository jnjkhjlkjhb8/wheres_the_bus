import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/features/bus/widgets/bus_timeline_stops.dart';

/// A stop quoting a live countdown of [minutes].
TimelineStop _live(String name, int minutes) => TimelineStop(
  uid: name,
  name: name,
  primaryTime: '$minutes分',
  isLiveEta: true,
  etaMinutes: minutes,
);

/// A stop quoting a scheduled departure — no bus has left the terminal yet.
TimelineStop _scheduled(String name, String clock) =>
    TimelineStop(uid: name, name: name, primaryTime: clock);

void main() {
  group('busStopLabelIsLive', () {
    test('a not-yet-departed stop is never live, countdown or not', () {
      expect(
        busStopLabelIsLive(estimateSeconds: 0, stopStatus: 1),
        isFalse,
      );
      // The backend derives a countdown from the predicted NextBusTime, but
      // the label the rider sees is still the scheduled clock.
      expect(
        busStopLabelIsLive(estimateSeconds: 300, stopStatus: 1),
        isFalse,
      );
    });

    test('a bus at the stop is live even at zero seconds', () {
      expect(busStopLabelIsLive(estimateSeconds: 0, stopStatus: 0), isTrue);
    });

    test('a positive estimate is live', () {
      expect(busStopLabelIsLive(estimateSeconds: 120, stopStatus: 2), isTrue);
    });

    test('an ended service is not live', () {
      expect(busStopLabelIsLive(estimateSeconds: 0, stopStatus: 3), isFalse);
      expect(busStopLabelIsLive(estimateSeconds: 0, stopStatus: 4), isFalse);
    });
  });

  group('busVehicleMarkerIndices', () {
    test('marks where the live run begins', () {
      // The screenshot case: five stops still quoting a scheduled departure,
      // then the countdown starts — the bus is between 桃園郵局 and 永和市場.
      final stops = [
        _scheduled('桃園總站', '20:40'),
        _scheduled('聖保祿醫院', '20:40'),
        _scheduled('桃園郵局', '20:47'),
        _live('永和市場', 2),
        _live('中正三民路口', 3),
        _live('中正二街口', 4),
      ];
      expect(busVehicleMarkerIndices(stops), {3});
    });

    test('a countdown that drops is a second bus, not one bus', () {
      // No single vehicle reaches a later stop sooner; the stops behind are
      // quoting a following bus.
      final stops = [
        _live('A', 2),
        _live('B', 4),
        _live('C', 9),
        _live('D', 1),
        _live('E', 3),
      ];
      expect(busVehicleMarkerIndices(stops), {3});
    });

    test('one bus running clean marks nothing', () {
      final stops = [_live('A', 2), _live('B', 5), _live('C', 9)];
      expect(busVehicleMarkerIndices(stops), isEmpty);
    });

    test('an all-scheduled route marks nothing', () {
      final stops = [_scheduled('A', '20:40'), _scheduled('B', '20:45')];
      expect(busVehicleMarkerIndices(stops), isEmpty);
    });

    test('equal countdowns are still one bus', () {
      // Adjacent stops routinely round to the same minute; only a strict drop
      // implies a second vehicle.
      final stops = [_live('A', 9), _live('B', 9), _live('C', 11)];
      expect(busVehicleMarkerIndices(stops), isEmpty);
    });
  });
}
