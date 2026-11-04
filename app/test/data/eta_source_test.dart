import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/bus_decoder.dart';
import 'package:wheres_the_bus/data/generated/bus.pb.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';

import '../support/helpers/i18n.dart';

final DateTime _now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
int get _nowUnix => _now.millisecondsSinceEpoch ~/ 1000;

BusStopArrival _arrival(
  int seconds, {
  int stopStatus = 0,
  EtaSource source = EtaSource.live,
}) => BusStopArrival(
  stationId: 'S',
  subRouteUid: 'R',
  routeName: '307',
  destination: '板橋',
  estimateSeconds: seconds,
  stopStatus: stopStatus,
  source: source,
);

void main() {
  group('wire source decoding', () {
    test('only SCHEDULED and PREDICTED leave live', () {
      expect(
        etaSourceOf(BusEstimateSource.BUS_ESTIMATE_SOURCE_UNSPECIFIED),
        EtaSource.live,
      );
      expect(
        etaSourceOf(BusEstimateSource.BUS_ESTIMATE_SOURCE_LIVE),
        EtaSource.live,
      );
      expect(
        etaSourceOf(BusEstimateSource.BUS_ESTIMATE_SOURCE_SCHEDULED),
        EtaSource.scheduled,
      );
      expect(
        etaSourceOf(BusEstimateSource.BUS_ESTIMATE_SOURCE_PREDICTED),
        EtaSource.predicted,
      );
    });

    test('a frame without the field decodes exactly as before', () {
      final out = BusDecoder.instance.decodeRouteEta(
        Bus_RouteArrival(
          stops: [Bus_RouteEstimate(stopUid: 'S1', estimate: 60)],
        ),
        now: _now,
      );
      expect(out.single.source, EtaSource.live);
    });

    test('route estimates carry the source into the view model', () {
      final out = BusDecoder.instance.decodeRouteEta(
        Bus_RouteArrival(
          stops: [
            Bus_RouteEstimate(
              stopUid: 'S1',
              estimateSource: BusEstimateSource.BUS_ESTIMATE_SOURCE_PREDICTED,
            ),
          ],
        ),
        now: _now,
      );
      expect(out.single.source, EtaSource.predicted);
      expect(
        out.single.copyWith(estimateSeconds: 5).source,
        EtaSource.predicted,
      );
    });

    test('station estimates carry the source through decay', () {
      final resp = Resp_Bus_station_eta(
        data: Bus_StationArrival(
          routes: [
            Bus_StopEstimate(
              stopUid: 'S1',
              stopStatus: 1,
              arrivalUnix: Int64(_nowUnix + 600),
              estimateSource: BusEstimateSource.BUS_ESTIMATE_SOURCE_SCHEDULED,
            ),
          ],
        ),
      );
      final arrival = BusDecoder.instance
          .decodeStationEta(resp, now: _now)
          .single;
      expect(arrival.source, EtaSource.scheduled);
      expect(arrival.decayed(_now).source, EtaSource.scheduled);
    });

    test('source takes part in equality', () {
      expect(
        _arrival(120) == _arrival(120, source: EtaSource.predicted),
        isFalse,
      );
    });
  });

  group('ArrivalDisplay for a non-live time', () {
    test('a live countdown keeps arriving / approaching / minutes', () {
      expect(
        ArrivalDisplay.fromBusStop(zhStrings, _arrival(0)).status,
        isA<EtaArriving>(),
      );
      expect(
        ArrivalDisplay.fromBusStop(zhStrings, _arrival(30)).status,
        isA<EtaApproaching>(),
      );
    });

    for (final source in [EtaSource.scheduled, EtaSource.predicted]) {
      test('$source never reads 進站中 or 即將進站', () {
        for (final seconds in [0, 30]) {
          final d = ArrivalDisplay.fromBusStop(
            zhStrings,
            _arrival(seconds, source: source),
          );
          expect(d.status, isA<EtaMinutes>(), reason: '$seconds');
          expect((d.status as EtaMinutes).value, 1);
          expect(d.source, source);
          expect(d.isComingSoon, isFalse);
        }
      });

      test('$source minutes stay a countdown but never highlight', () {
        final d = ArrivalDisplay.fromBusStop(
          zhStrings,
          _arrival(120, stopStatus: 1, source: source),
        );
        expect((d.status as EtaMinutes).value, 2);
        expect(d.rank, 4);
        expect(d.isComingSoon, isFalse);
      });
    }

    test('a live row at rank 3 still highlights', () {
      const d = ArrivalDisplay(
        label: 'x',
        destination: 'y',
        status: EtaArriving(),
        rank: 3,
      );
      expect(d.isComingSoon, isTrue);
      expect(d.source, EtaSource.live);
    });
  });
}
