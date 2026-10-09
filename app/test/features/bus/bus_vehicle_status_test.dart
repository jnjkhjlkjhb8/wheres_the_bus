import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/bus_vehicle_status.dart';

import '../../support/helpers/i18n.dart';

BusVehiclePosition _v({int duty = 0, int bus = 0, int gps = 0}) =>
    BusVehiclePosition(
      plate: 'AAA-1',
      lat: 25,
      lon: 121,
      azimuth: 0,
      dutyStatus: duty,
      busStatus: bus,
      gpsTimeUnix: gps,
    );

void main() {
  group('busVehicleStatus', () {
    test('normal driving reads as operating', () {
      final s = busVehicleStatus(zhStrings, _v());
      expect(s.label, '營運中');
      expect(s.tone, BusStatusTone.normal);
    });

    test('ending duty overrides the driving state', () {
      final s = busVehicleStatus(zhStrings, _v(duty: 2, bus: 3));
      expect(s.label, '收班中');
      expect(s.tone, BusStatusTone.muted);
    });

    test('breakdown is a warning', () {
      expect(
        busVehicleStatus(zhStrings, _v(bus: 2)).tone,
        BusStatusTone.warning,
      );
    });

    test('congestion is a notice', () {
      final s = busVehicleStatus(zhStrings, _v(bus: 3));
      expect(s.label, '塞車');
      expect(s.tone, BusStatusTone.notice);
    });

    test('unknown code falls back to operating', () {
      expect(busVehicleStatus(zhStrings, _v(bus: 255)).label, '營運中');
    });
  });

  group('busGpsAge', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1_000_000 * 1000);
    int at(int secondsAgo) => 1_000_000 - secondsAgo;

    test('missing fix reads as unlocated', () {
      final a = busGpsAge(zhStrings, 0, now);
      expect(a.text, '無定位');
      expect(a.stale, isTrue);
    });

    test('seconds are spelled out from the very first one', () {
      // No "剛剛" band at the front: the bubble ticks once a second, so a bucket
      // over the freshest part of a fix's life would read as a frozen clock.
      expect(busGpsAge(zhStrings, at(0), now).text, '0秒前');
      expect(busGpsAge(zhStrings, at(5), now).text, '5秒前');
      expect(busGpsAge(zhStrings, at(22), now).text, '22秒前');
      expect(busGpsAge(zhStrings, at(59), now).text, '59秒前');
    });

    test(
      'a fix ahead of the device clock clamps rather than going negative',
      () {
        // Clock skew, not time travel.
        expect(busGpsAge(zhStrings, at(-4), now).text, '0秒前');
      },
    );

    test('minutes take over at 60', () {
      expect(busGpsAge(zhStrings, at(60), now).text, '1分前');
      expect(busGpsAge(zhStrings, at(90), now).text, '1分前');
      expect(busGpsAge(zhStrings, at(120), now).text, '2分前');
      expect(busGpsAge(zhStrings, at(179), now).text, '2分前');
    });

    test('past 3 minutes is stale', () {
      final a = busGpsAge(zhStrings, at(200), now);
      expect(a.text, '定位延遲');
      expect(a.stale, isTrue);
    });
  });
}
