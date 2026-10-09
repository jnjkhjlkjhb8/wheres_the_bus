import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/bus_decoder.dart';
import 'package:wheres_the_bus/data/generated/bus.pb.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';

import '../../support/helpers/i18n.dart';

const BusDecoder _decoder = BusDecoder.instance;

/// Fixed clock so arrival-instant derivations are deterministic.
final DateTime _now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
int get _nowUnix => _now.millisecondsSinceEpoch ~/ 1000;

void main() {
  group('etaRemainingSeconds (shared decay derivation)', () {
    test('absolute instant derives vs now; ceil boundary 61s -> 2 min', () {
      final seconds = etaRemainingSeconds(
        arrivalUnix: _nowUnix + 61,
        serverEstimateSeconds: 999,
        now: _now,
      );
      expect(seconds, 61);
      expect(etaCeilMinutes(seconds), 2);
    });

    test('exact minute does not round up (60s -> 1 min)', () {
      expect(etaCeilMinutes(60), 1);
      expect(etaCeilMinutes(120), 2);
    });

    test('just-passed instant clamps to 0', () {
      final seconds = etaRemainingSeconds(
        arrivalUnix: _nowUnix - 5,
        serverEstimateSeconds: 999,
        now: _now,
      );
      expect(seconds, 0);
    });

    test('zero arrivalUnix falls back to server estimate', () {
      final seconds = etaRemainingSeconds(
        arrivalUnix: 0,
        serverEstimateSeconds: 180,
        now: _now,
      );
      expect(seconds, 180);
    });

    test('negative arrivalUnix falls back to server estimate', () {
      final seconds = etaRemainingSeconds(
        arrivalUnix: -1,
        serverEstimateSeconds: 42,
        now: _now,
      );
      expect(seconds, 42);
    });
  });

  group('decodeRouteEta', () {
    test('prefers absolute instant over server estimate', () {
      final arrival = Bus_RouteArrival(
        stops: [
          Bus_RouteEstimate(
            stopUid: 'S1',
            direction: 0,
            estimate: 999,
            stopSequence: 3,
            stopStatus: 0,
            nextBusTime: '',
            arrivalUnix: Int64(_nowUnix + 90),
          ),
        ],
      );
      final out = _decoder.decodeRouteEta(arrival, now: _now);
      expect(out, hasLength(1));
      expect(out.single.estimateSeconds, 90);
      expect(out.single.sequence, 3);
      expect(out.single.arrivalUnix, _nowUnix + 90);
    });

    test('falls back to server estimate when arrivalUnix is 0', () {
      final arrival = Bus_RouteArrival(
        stops: [
          Bus_RouteEstimate(stopUid: 'S1', estimate: 120),
        ],
      );
      final out = _decoder.decodeRouteEta(arrival, now: _now);
      expect(out.single.estimateSeconds, 120);
    });

    test('keeps only vehicles with a real position', () {
      final arrival = Bus_RouteArrival(
        stops: [
          Bus_RouteEstimate(
            stopUid: 'S1',
            buses: [
              Bus_position(
                plateNumb: 'AAA',
                positionLat: 25,
                positionLon: 121,
              ),
              Bus_position(plateNumb: 'BBB'), // no position -> dropped
            ],
          ),
        ],
      );
      final out = _decoder.decodeRouteEta(arrival, now: _now);
      expect(out.single.vehiclePlates, ['AAA', 'BBB']);
      expect(out.single.vehicles, hasLength(1));
      expect(out.single.vehicles.single.plate, 'AAA');
    });

    test('empty stops yields empty list', () {
      expect(_decoder.decodeRouteEta(Bus_RouteArrival(), now: _now), isEmpty);
    });
    test(
      'route ETA decoder carries the estimate plate onto the view model',
      () {
        final arrival = Bus_RouteArrival(
          subRouteUid: 'sub-1',
          stops: [
            Bus_RouteEstimate(
              stopUid: 'stop-7',
              direction: 0,
              stopSequence: 7,
              estimate: 240,
              stopStatus: 0,
              plateNumb: 'KKA-1288',
            ),
          ],
        );

        final decoded = BusDecoder.instance.decodeRouteEta(
          arrival,
          now: DateTime(2026, 7, 20),
        );

        expect(decoded.single.plate, 'KKA-1288');
      },
    );

    test('estimate plate defaults to empty when the server omits it', () {
      final arrival = Bus_RouteArrival(
        subRouteUid: 'sub-1',
        stops: [
          Bus_RouteEstimate(stopUid: 'stop-7', direction: 0, stopSequence: 7),
        ],
      );

      final decoded = BusDecoder.instance.decodeRouteEta(
        arrival,
        now: DateTime(2026, 7, 20),
      );

      expect(decoded.single.plate, '');
    });
  });

  group('decodeStationEta', () {
    Resp_Bus_station_eta respWith(List<Bus_StopEstimate> routes) =>
        Resp_Bus_station_eta(data: Bus_StationArrival(routes: routes));

    test('uses the server terminal name when present', () {
      final resp = respWith([
        Bus_StopEstimate(
          stopUid: 'S1',
          routeName: '5014',
          direction: 0,
          destination: '桃園後站',
          stopStatus: 0,
          estimate: 300,
        ),
      ]);
      final out = _decoder.decodeStationEta(resp, now: _now);
      expect(out.single.destination, '桃園後站');
    });

    test('derives minutes via ceil and falls back to 去程/返程 label', () {
      final resp = respWith([
        Bus_StopEstimate(
          stopUid: 'S1',
          routeName: '261',
          direction: 0,
          stopStatus: 0,
          arrivalUnix: Int64(_nowUnix + 61),
        ),
        Bus_StopEstimate(
          stopUid: 'S2',
          routeName: '261',
          direction: 1,
          stopStatus: 0,
          estimate: 300,
        ),
      ]);
      final out = _decoder.decodeStationEta(resp, now: _now);
      expect(out, hasLength(2));
      expect(out[0].destination, '去程');
      expect(out[0].minutes, 2); // 61s -> ceil -> 2
      expect(out[0].displayStatus, BusStopDisplayStatus.minutes);
      expect(out[1].destination, '返程');
      expect(out[1].minutes, 5); // 300s server estimate
    });

    test('stopStatus 1 with no estimate is 尚未發車, not arriving', () {
      final resp = respWith([
        Bus_StopEstimate(stopUid: 'S1', routeName: '9', stopStatus: 1),
      ]);
      final out = _decoder.decodeStationEta(resp, now: _now);
      expect(out.single.minutes, isNull);
      expect(out.single.isArriving, isFalse);
      expect(out.single.displayStatus, BusStopDisplayStatus.notDeparted);
      expect(out.single.displayLabelOf(zhStrings), '尚未發車');
    });

    test('stopStatus 1 with a predicted NextBusTime is a valid countdown, '
        'not a contradiction', () {
      final resp = respWith([
        Bus_StopEstimate(
          stopUid: 'S1',
          routeName: '9',
          stopStatus: 1,
          arrivalUnix: Int64(_nowUnix + 720),
        ),
      ]);
      final out = _decoder.decodeStationEta(resp, now: _now);
      expect(out.single.minutes, 12);
      expect(out.single.isArriving, isFalse);
      expect(out.single.displayStatus, BusStopDisplayStatus.minutes);
      expect(out.single.displayLabelOf(zhStrings), '12分');
    });

    test('stopStatus 0 with a passed instant reads 進站中', () {
      final resp = respWith([
        Bus_StopEstimate(
          stopUid: 'S1',
          routeName: '9',
          stopStatus: 0,
          arrivalUnix: Int64(_nowUnix - 10),
        ),
      ]);
      final out = _decoder.decodeStationEta(resp, now: _now);
      expect(out.single.minutes, isNull);
      expect(out.single.isArriving, isTrue);
      expect(out.single.displayStatus, BusStopDisplayStatus.arriving);
      expect(out.single.displayLabelOf(zhStrings), '進站中');
    });

    test('empty routes yields empty list', () {
      expect(_decoder.decodeStationEta(respWith(const []), now: _now), isEmpty);
    });

    test('carries IsLastBus and keeps it, with crowding, through decay', () {
      final resp = respWith([
        Bus_StopEstimate(
          stopUid: 'S1',
          routeName: '9999',
          direction: 0,
          stopStatus: 0,
          arrivalUnix: Int64(_nowUnix + 300),
          crowdLevel: BusCrowdLevel.BUS_CROWD_CROWDED,
          isLastBus: true,
        ),
      ]);
      final arrival = _decoder.decodeStationEta(resp, now: _now).single;
      expect(arrival.isLastBus, isTrue);
      final later = arrival.decayed(_now.add(const Duration(minutes: 1)));
      expect(later.estimateSeconds, 240);
      expect(later.isLastBus, isTrue);
      expect(later.crowdLevel, CrowdLevel.crowded);
    });
  });

  group('decodeStationMembers', () {
    test('maps member fields', () {
      final group = Bus_StationGroup(
        members: [
          Bus_StationGroupMember(
            stationUid: 'U1',
            stationId: 'I1',
            stationName: '銘傳大學',
            positionLat: 25.1,
            positionLon: 121.2,
          ),
        ],
      );
      final out = _decoder.decodeStationMembers(group);
      expect(out, hasLength(1));
      expect(out.single.stationUid, 'U1');
      expect(out.single.stationId, 'I1');
      expect(out.single.stationName, '銘傳大學');
      expect(out.single.lat, 25.1);
      expect(out.single.lon, 121.2);
    });

    test('empty members yields empty list', () {
      expect(_decoder.decodeStationMembers(Bus_StationGroup()), isEmpty);
    });
  });

  group('decodeStatic', () {
    test('maps both directions, headsigns, geometry and fare', () {
      final route = Bus_subroute(
        subRouteUID: 'SR1',
        routeName: '261',
        subRouteName: '261',
        city: 'Taipei',
        directions: [
          MapEntry(
            0,
            Direction(
              destinationStopName: '去程終點',
              geometry: 'GEO0',
              stops: [
                Bus_stop(stopUID: 'a', stopName: 'A', stopSequence: 1),
              ],
            ),
          ),
          MapEntry(
            1,
            Direction(destinationStopName: '返程終點', geometry: 'GEO1'),
          ),
        ],
        fare: Bus_Fare(isFreeBus: true, farePricingType: 2),
      );
      final vm = _decoder.decodeStatic(route);
      expect(vm.subRouteUid, 'SR1');
      expect(vm.headsignGo, '去程終點');
      expect(vm.headsignReturn, '返程終點');
      expect(vm.geometryGo, 'GEO0');
      expect(vm.geometryReturn, 'GEO1');
      expect(vm.stopsGo, hasLength(1));
      expect(vm.stopsGo.single.stopName, 'A');
      expect(vm.stopsReturn, isEmpty);
      expect(vm.fare, isNotNull);
      expect(vm.fare!.isFreeBus, isTrue);
      expect(vm.fare!.pricingType, 2);
    });

    test('missing directions default to empty stops/geometry', () {
      final vm = _decoder.decodeStatic(Bus_subroute(subRouteUID: 'SR2'));
      expect(vm.headsignGo, '');
      expect(vm.headsignReturn, '');
      expect(vm.stopsGo, isEmpty);
      expect(vm.stopsReturn, isEmpty);
      expect(vm.geometryGo, '');
      expect(vm.fare, isNull);
    });
  });

  group('decodeDaily', () {
    test('maps directions, trips and stop times', () {
      final proto = Bus_DailyTimetables(
        direction: [
          MapEntry(
            0,
            Bus_DirectionTimetable(
              dailyTimetables: [
                Bus_DailyTimetable(
                  tripID: 'T1',
                  isLowFloor: true,
                  stopTimes: [
                    Bus_StopTime(
                      stopSequence: 1,
                      departureTime: '08:00',
                      arrivalTime: '07:59',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
      final out = _decoder.decodeDaily(proto);
      final trips = out.tripsForDirection(0);
      expect(trips, hasLength(1));
      expect(trips.single.tripId, 'T1');
      expect(trips.single.isLowFloor, isTrue);
      expect(trips.single.stopTimes.single.departureTime, '08:00');
      expect(trips.single.stopTimes.single.arrivalTime, '07:59');
      expect(out.tripsForDirection(1), isEmpty);
    });

    test('empty direction map yields no trips', () {
      final out = _decoder.decodeDaily(Bus_DailyTimetables());
      expect(out.tripsForDirection(0), isEmpty);
    });
  });

  group('BusStopArrival.decayed', () {
    test('re-derives estimateSeconds and minutes from arrivalUnix', () {
      final arrival = BusStopArrival(
        stationId: 'S1',
        subRouteUid: 'SR1',
        routeName: '261',
        destination: '去程',
        estimateSeconds: 0,
        arrivalUnix: _nowUnix + 61,
      );
      final decayed = arrival.decayed(_now);
      expect(decayed.estimateSeconds, 61);
      expect(decayed.minutes, 2); // 61s -> ceil
      expect(decayed.displayStatus, BusStopDisplayStatus.minutes);
    });

    test('decayed() flips minutes -> 進站中 when the countdown reaches zero', () {
      final arrival = BusStopArrival(
        stationId: 'S1',
        subRouteUid: 'SR1',
        routeName: '262',
        destination: '去程',
        estimateSeconds: 90,
        arrivalUnix: _nowUnix + 90,
      );
      expect(arrival.displayStatus, BusStopDisplayStatus.minutes);
      final later = arrival.decayed(_now.add(const Duration(seconds: 120)));
      expect(later.minutes, isNull);
      expect(later.displayStatus, BusStopDisplayStatus.arriving);
      expect(later.displayLabelOf(zhStrings), '進站中');
    });

    test('leaves arrival unchanged when no absolute instant', () {
      const arrival = BusStopArrival(
        stationId: 'S1',
        subRouteUid: 'SR1',
        routeName: '261',
        destination: '去程',
        estimateSeconds: 240,
      );
      expect(identical(arrival.decayed(_now), arrival), isTrue);
    });
  });

  group('BusStopEtaViewModel.decayed', () {
    test('re-derives estimateSeconds from arrivalUnix', () {
      final vm = BusStopEtaViewModel(
        stopUid: 'S1',
        direction: 0,
        sequence: 1,
        estimateSeconds: 999,
        nextBusTime: '',
        stopStatus: 0,
        vehiclePlates: const [],
        arrivalUnix: _nowUnix + 61,
      );
      final decayed = vm.decayed(_now);
      expect(decayed.estimateSeconds, 61);
      expect(decayed.estimateMinutes, 2);
    });

    test('leaves estimate unchanged when no absolute instant', () {
      const vm = BusStopEtaViewModel(
        stopUid: 'S1',
        direction: 0,
        sequence: 1,
        estimateSeconds: 120,
        nextBusTime: '',
        stopStatus: 0,
        vehiclePlates: [],
      );
      expect(identical(vm.decayed(_now), vm), isTrue);
    });
  });
}
