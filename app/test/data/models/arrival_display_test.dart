import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';

import '../../support/helpers/i18n.dart';

BusStopArrival _arrival({
  required int estimateSeconds,
  int stopStatus = 0,
  String nextBusTime = '',
  CrowdLevel crowdLevel = CrowdLevel.unknown,
  bool isLastBus = false,
}) => BusStopArrival(
  stationId: 'S',
  subRouteUid: 'R',
  routeName: '307',
  destination: '撫遠街',
  estimateSeconds: estimateSeconds,
  nextBusTime: nextBusTime,
  stopStatus: stopStatus,
  crowdLevel: crowdLevel,
  isLastBus: isLastBus,
);

ArrivalDisplay _display(
  int estimateSeconds, {
  int stopStatus = 0,
  String nextBusTime = '',
}) => ArrivalDisplay.fromBusStop(
  zhStrings,
  _arrival(
    estimateSeconds: estimateSeconds,
    stopStatus: stopStatus,
    nextBusTime: nextBusTime,
  ),
);

void main() {
  group('fromBusStop', () {
    test('copies the route, destination, crowd and last-bus flag', () {
      final display = ArrivalDisplay.fromBusStop(
        zhStrings,
        _arrival(
          estimateSeconds: 0,
          crowdLevel: CrowdLevel.crowded,
          isLastBus: true,
        ),
      );
      expect(display.label, '307');
      expect(display.destination, '撫遠街');
      expect(display.crowdLevel, CrowdLevel.crowded);
      expect(display.isLastBus, isTrue);
    });

    test('defaults to an unknown crowd and not the last bus', () {
      final display = _display(0);
      expect(display.crowdLevel, CrowdLevel.unknown);
      expect(display.isLastBus, isFalse);
      const plain = ArrivalDisplay(
        label: 'x',
        destination: 'y',
        status: EtaUnknown(),
        rank: 1,
      );
      expect(plain.crowdLevel, CrowdLevel.unknown);
      expect(plain.isLastBus, isFalse);
    });

    test('a live bus at zero is arriving and ranks first', () {
      final display = _display(0);
      expect(display.status, isA<EtaArriving>());
      expect(display.rank, 0);
    });

    test('under a minute is approaching, one rank behind arriving', () {
      for (final seconds in [1, 59]) {
        final display = _display(seconds);
        expect(display.status, isA<EtaApproaching>(), reason: '$seconds');
        expect(display.rank, 1);
      }
    });

    test('whole minutes round up and rank two behind their count', () {
      final a = _display(60);
      expect((a.status as EtaMinutes).value, 1);
      expect(a.rank, 3);
      final b = _display(61);
      expect((b.status as EtaMinutes).value, 2);
      expect(b.rank, 4);
      final c = _display(600);
      expect((c.status as EtaMinutes).value, 10);
      expect(c.rank, 12);
    });

    test('a not-yet-departed stop with a distant estimate shows its clock', () {
      final display = _display(3700, stopStatus: 1, nextBusTime: '8:05');
      expect((display.status as EtaLabel).text, '08:05');
      expect(display.rank, 62 + 2);
    });

    test(
      'a not-yet-departed stop shows its clock at rank 9999 with no estimate',
      () {
        final display = _display(0, stopStatus: 1, nextBusTime: '08:30');
        expect((display.status as EtaLabel).text, '08:30');
        expect(display.rank, 9999);
      },
    );

    test('a not-yet-departed stop without a clock says so', () {
      final display = _display(0, stopStatus: 1);
      expect((display.status as EtaLabel).text, zhStrings.etaNotDeparted);
      expect(display.rank, 9999);
    });

    test('traffic control and no service sit at 9999 with their label', () {
      final control = _display(0, stopStatus: 2);
      expect((control.status as EtaLabel).text, zhStrings.etaTrafficControl);
      expect(control.rank, 9999);
      final off = _display(0, stopStatus: 4);
      expect((off.status as EtaLabel).text, zhStrings.etaNotOperating);
      expect(off.rank, 9999);
    });

    test('the last bus having passed sinks below everything', () {
      final display = _display(0, stopStatus: 3);
      expect((display.status as EtaLabel).text, zhStrings.etaLastBusPassed);
      expect(display.rank, 10000);
    });

    test('a status the feed never defined is unknown at 9999', () {
      final display = _display(0, stopStatus: 9);
      expect(display.status, isA<EtaUnknown>());
      expect(display.rank, 9999);
    });
  });

  group('fromMetro', () {
    ArrivalDisplay metro(int seconds) => ArrivalDisplay.fromMetro(
      line: '板南線',
      destination: '南港展覽館',
      estimateSeconds: seconds,
    );

    test('carries the line and destination and ranks by seconds', () {
      final display = metro(225);
      expect(display.label, '板南線');
      expect(display.destination, '南港展覽館');
      expect(display.rank, 225);
      expect(display.crowdLevel, CrowdLevel.unknown);
      expect(display.isLastBus, isFalse);
    });

    test('zero or negative seconds read as arriving', () {
      for (final seconds in [0, -5]) {
        final display = metro(seconds);
        expect(display.status, isA<EtaArriving>(), reason: '$seconds');
        expect(display.rank, seconds);
      }
    });

    test('positive seconds split into minutes and seconds', () {
      for (final (seconds, m, s) in [
        (1, 0, 1),
        (59, 0, 59),
        (60, 1, 0),
        (225, 3, 45),
      ]) {
        final status = metro(seconds).status as EtaMinutesSeconds;
        expect((status.minutes, status.seconds), (m, s), reason: '$seconds');
      }
    });
  });

  test('only the first three ranks are coming soon', () {
    ArrivalDisplay at(int rank) => ArrivalDisplay(
      label: 'x',
      destination: 'y',
      status: EtaStatus.arriving(),
      rank: rank,
    );
    expect(at(-1).isComingSoon, isTrue);
    expect(at(3).isComingSoon, isTrue);
    expect(at(4).isComingSoon, isFalse);
  });
}
