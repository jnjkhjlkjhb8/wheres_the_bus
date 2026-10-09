import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/near_decoder.dart';
import 'package:wheres_the_bus/data/generated/near.pb.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';

NearStation _station(String id, String name, {bool routed = true}) =>
    NearStation(
      stationID: id,
      stationName: name,
      positionLat: 25,
      positionLon: 121.5,
      walk: 5,
      distance: 400,
      routed: routed,
    );

void main() {
  group('NearDecoder.decode', () {
    test('flattens all five transit modes with correct types', () {
      final resp = resp_near(
        nearBusStations: {
          '站A': array_near(nearStations: [_station('bus1', '站A')]),
        }.entries,
        nearMrtStations: [_station('mrt1', '捷運站')],
        nearBikeStations: [_station('bike1', 'YouBike站')],
        nearTraStations: [_station('tra1', '台鐵站')],
        nearThsrStations: [_station('thsr1', '高鐵站')],
      );

      final out = NearDecoder.instance.decode(resp);

      final byType = {for (final s in out) s.type: s};
      expect(out.length, 5);
      expect(byType[NearStationType.bus]!.stationId, 'bus1');
      expect(byType[NearStationType.mrt]!.stationId, 'mrt1');
      expect(byType[NearStationType.bike]!.stationId, 'bike1');
      expect(byType[NearStationType.tra]!.stationId, 'tra1');
      expect(byType[NearStationType.thsr]!.stationId, 'thsr1');
    });

    test('maps every scalar field', () {
      final resp = resp_near(
        nearMrtStations: [_station('mrt1', '捷運站')],
      );

      final vm = NearDecoder.instance.decode(resp).single;

      expect(vm.stationId, 'mrt1');
      expect(vm.stationName, '捷運站');
      expect(vm.lat, 25);
      expect(vm.lon, 121.5);
      expect(vm.walkingMinutes, 5);
      expect(vm.distanceMeters, 400);
      expect(vm.routed, isTrue);
    });

    test('passes through the routed flag', () {
      final resp = resp_near(
        nearTraStations: [_station('tra1', '台鐵站', routed: false)],
        nearThsrStations: [_station('thsr1', '高鐵站')],
      );

      final out = NearDecoder.instance.decode(resp);
      final byType = {for (final s in out) s.type: s};

      expect(byType[NearStationType.tra]!.routed, isFalse);
      expect(byType[NearStationType.thsr]!.routed, isTrue);
    });

    test('expands multiple bus stations sharing a group name', () {
      final resp = resp_near(
        nearBusStations: {
          '站A': array_near(
            nearStations: [_station('bus1', '站A'), _station('bus2', '站A')],
          ),
        }.entries,
      );

      final out = NearDecoder.instance.decode(resp);
      expect(out.length, 2);
      expect(out.every((s) => s.type == NearStationType.bus), isTrue);
    });

    test('decodes an empty response to an empty list', () {
      expect(NearDecoder.instance.decode(resp_near()), isEmpty);
    });
  });
}
