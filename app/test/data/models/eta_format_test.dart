import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';

import '../../support/helpers/i18n.dart';

void main() {
  group('etaRemainingSeconds', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    int nowUnix() => now.millisecondsSinceEpoch ~/ 1000;

    test('derives remaining seconds from a future absolute instant', () {
      expect(
        etaRemainingSeconds(
          arrivalUnix: nowUnix() + 90,
          serverEstimateSeconds: 999,
          now: now,
        ),
        90,
      );
    });

    test('a past absolute instant clamps to 0', () {
      expect(
        etaRemainingSeconds(
          arrivalUnix: nowUnix() - 90,
          serverEstimateSeconds: 999,
          now: now,
        ),
        0,
      );
    });

    // Documented contract (eta_format.dart:14-15): arrivalUnix == 0 means "no
    // absolute instant sent", so the server estimate passes through as-is --
    // even if it is stale. This is not re-validated against `now`.
    test('zero arrivalUnix returns serverEstimateSeconds unchanged', () {
      expect(
        etaRemainingSeconds(
          arrivalUnix: 0,
          serverEstimateSeconds: 45,
          now: now,
        ),
        45,
      );
    });
  });

  group('etaCeilMinutes', () {
    test('ceils partial minutes up', () {
      expect(etaCeilMinutes(1), 1);
      expect(etaCeilMinutes(59), 1);
      expect(etaCeilMinutes(60), 1);
      expect(etaCeilMinutes(61), 2);
      expect(etaCeilMinutes(120), 2);
    });

    test('non-positive seconds are zero', () {
      expect(etaCeilMinutes(0), 0);
      expect(etaCeilMinutes(-1), 0);
    });

    // Cross-mode consistency: bus (was ceil) and metro (was round) must now
    // agree for every input. 90s -> 2 min both ways; round() would give 2 as
    // well, but 30s must be 1 (ceil) not 0 (round) -- this is the guard.
    test('same seconds map to same minutes across modes (ceil, not round)', () {
      expect(etaCeilMinutes(30), 1); // round() would be 0 -- rejected
      expect(etaCeilMinutes(89), 2); // round() would be 1 -- rejected
    });
  });

  group('busStopDisplayStatus', () {
    test('arriving when stopStatus 0 and no estimate', () {
      expect(
        busStopDisplayStatus(estimateSeconds: 0, stopStatus: 0),
        BusStopDisplayStatus.arriving,
      );
    });
    test('departingSoon under a minute', () {
      expect(
        busStopDisplayStatus(estimateSeconds: 45, stopStatus: 0),
        BusStopDisplayStatus.departingSoon,
      );
    });
    test('minutes when estimate is a minute or more', () {
      expect(
        busStopDisplayStatus(estimateSeconds: 61, stopStatus: 0),
        BusStopDisplayStatus.minutes,
      );
    });
    // A not-yet-departed stop (status 1) with a predicted NextBusTime carries
    // a positive estimate the backend derived for exactly this countdown
    // (bus_eta.go gap fill); only a zero estimate falls back to 尚未發車.
    test('status 1 with a positive predicted estimate is a countdown', () {
      expect(
        busStopDisplayStatus(estimateSeconds: 300, stopStatus: 1),
        BusStopDisplayStatus.minutes,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 30, stopStatus: 1),
        BusStopDisplayStatus.departingSoon,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 0, stopStatus: 1),
        BusStopDisplayStatus.notDeparted,
      );
    });
    test('status 1 beyond the countdown cap falls back to notDeparted', () {
      expect(
        busStopDisplayStatus(
          estimateSeconds: busStopScheduledCountdownCap + 1,
          stopStatus: 1,
        ),
        BusStopDisplayStatus.notDeparted,
      );
      expect(
        busStopDisplayStatus(
          estimateSeconds: busStopScheduledCountdownCap,
          stopStatus: 1,
        ),
        BusStopDisplayStatus.minutes,
      );
    });
    test('status codes map exhaustively', () {
      expect(
        busStopDisplayStatus(estimateSeconds: -1, stopStatus: 1),
        BusStopDisplayStatus.notDeparted,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: -1, stopStatus: 2),
        BusStopDisplayStatus.trafficControl,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: -1, stopStatus: 3),
        BusStopDisplayStatus.lastBusPassed,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: -1, stopStatus: 4),
        BusStopDisplayStatus.notOperating,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: -1, stopStatus: 9),
        BusStopDisplayStatus.unknown,
      );
    });

    test('exact boundary matrix from the domain rule table', () {
      expect(
        busStopDisplayStatus(estimateSeconds: 0, stopStatus: 0),
        BusStopDisplayStatus.arriving,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 30, stopStatus: 0),
        BusStopDisplayStatus.departingSoon,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 300, stopStatus: 0),
        BusStopDisplayStatus.minutes,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 0, stopStatus: 1),
        BusStopDisplayStatus.notDeparted,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 0, stopStatus: 3),
        BusStopDisplayStatus.lastBusPassed,
      );
      expect(
        busStopDisplayStatus(estimateSeconds: 0, stopStatus: 99),
        BusStopDisplayStatus.unknown,
      );
    });
  });

  group('busStopDisplayLabel', () {
    test('minutes label uses ceil', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 61,
          stopStatus: 0,
          nextBusTime: '',
        ),
        '2分',
      );
    });
    test('arriving label', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 0,
          nextBusTime: '',
        ),
        '進站中',
      );
    });
    test('clock label parsed from nextBusTime', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: -1,
          stopStatus: 1,
          nextBusTime: '2026-06-18T08:15:00+08:00',
        ),
        '08:15',
      );
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: -1,
          stopStatus: 1,
          nextBusTime: '8:05:00',
        ),
        '08:05',
      );
    });

    test('status 1 (scheduled) shows the NextBusTime clock, not the '
        'derived countdown', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 300,
          stopStatus: 1,
          nextBusTime: '08:15',
        ),
        '08:15',
      );
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: '08:15',
        ),
        '08:15',
      );
    });

    test('clock label passes through an already-padded HH:MM', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: '23:30',
        ),
        '23:30',
      );
    });

    test('clock label left-pads a single-digit hour', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: '7:05',
        ),
        '07:05',
      );
    });

    test(
      'clock label on an RFC3339 string extracts the literal hour, '
      'not the timezone-converted local hour',
      () {
        expect(
          busStopDisplayLabel(
            i18n: zhStrings,
            estimateSeconds: 0,
            stopStatus: 1,
            nextBusTime: '2026-07-07T23:30:00+08:00',
          ),
          '23:30',
        );
      },
    );

    test('empty nextBusTime with no clock falls back to status label', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: '',
        ),
        '尚未發車',
      );
    });

    test('unparseable nextBusTime falls back to status label', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: 'garbage',
        ),
        '尚未發車',
      );
    });

    test('status label when no estimate and no clock', () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: -1,
          stopStatus: 3,
          nextBusTime: '',
        ),
        '末班已過',
      );
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: -1,
          stopStatus: 9,
          nextBusTime: '',
        ),
        isNull,
      );
    });
  });
}
