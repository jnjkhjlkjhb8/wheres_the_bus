import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';

BusVehiclePosition _vehicle({
  String plate = 'ABC-123',
  double lat = 25.0,
  double lon = 121.5,
  int azimuth = 90,
  int dutyStatus = 0,
  int busStatus = 0,
  int gpsTimeUnix = 0,
}) => BusVehiclePosition(
  plate: plate,
  lat: lat,
  lon: lon,
  azimuth: azimuth,
  dutyStatus: dutyStatus,
  busStatus: busStatus,
  gpsTimeUnix: gpsTimeUnix,
);

BusStopEtaViewModel _eta({
  String stopUid = 'S1',
  int direction = 0,
  int sequence = 3,
  int estimateSeconds = 120,
  String nextBusTime = '',
  int stopStatus = 0,
  List<String> vehiclePlates = const ['ABC-123'],
  int arrivalUnix = 0,
  List<BusVehiclePosition> vehicles = const [],
  String plate = '',
  bool isLastBus = false,
}) => BusStopEtaViewModel(
  stopUid: stopUid,
  direction: direction,
  sequence: sequence,
  estimateSeconds: estimateSeconds,
  nextBusTime: nextBusTime,
  stopStatus: stopStatus,
  vehiclePlates: vehiclePlates,
  arrivalUnix: arrivalUnix,
  vehicles: vehicles,
  plate: plate,
  isLastBus: isLastBus,
);

BusStopArrival _arrival({int estimateSeconds = 120, int arrivalUnix = 0}) =>
    BusStopArrival(
      stationId: 'st',
      subRouteUid: 'sr',
      routeName: '299',
      destination: '板橋',
      estimateSeconds: estimateSeconds,
      arrivalUnix: arrivalUnix,
    );

void main() {
  // 2026-01-01T00:00:00Z, so arrivals are expressed as offsets from it.
  final now = DateTime.utc(2026);
  final nowUnix = now.millisecondsSinceEpoch ~/ 1000;

  group('BusVehiclePosition', () {
    test('every field takes part in equality', () {
      expect(_vehicle(), _vehicle());
      expect(_vehicle().hashCode, _vehicle().hashCode);
      for (final other in [
        _vehicle(plate: 'XYZ-999'),
        _vehicle(lat: 25.1),
        _vehicle(lon: 121.6),
        _vehicle(azimuth: 91),
        _vehicle(dutyStatus: 1),
        _vehicle(busStatus: 2),
        _vehicle(gpsTimeUnix: 1),
      ]) {
        expect(other, isNot(_vehicle()));
      }
    });
  });

  group('BusStopEtaViewModel', () {
    test('every field takes part in equality', () {
      expect(_eta(), _eta());
      expect(_eta().hashCode, _eta().hashCode);
      for (final other in [
        _eta(stopUid: 'S2'),
        _eta(direction: 1),
        _eta(sequence: 4),
        _eta(estimateSeconds: 121),
        _eta(nextBusTime: '10:00'),
        _eta(stopStatus: 1),
        _eta(vehiclePlates: const ['XYZ-999']),
        _eta(arrivalUnix: 1),
        _eta(vehicles: [_vehicle()]),
        _eta(plate: 'ABC-123'),
        _eta(isLastBus: true),
      ]) {
        expect(other, isNot(_eta()));
      }
    });

    group('decayed', () {
      test('without an absolute arrival it hands back the same estimate', () {
        for (final unix in [0, -1]) {
          final eta = _eta(arrivalUnix: unix);
          expect(eta.decayed(now), same(eta), reason: 'arrivalUnix $unix');
        }
      });

      test('counts down to the absolute arrival and stops at zero', () {
        final ahead = _eta(arrivalUnix: nowUnix + 90);
        expect(ahead.decayed(now).estimateSeconds, 90);
        final past = _eta(arrivalUnix: nowUnix - 30);
        expect(past.decayed(now).estimateSeconds, 0);
      });
    });
  });

  group('BusStopArrival.decayed', () {
    test('without an absolute arrival it hands back the same arrival', () {
      for (final unix in [0, -1]) {
        final arrival = _arrival(arrivalUnix: unix);
        expect(
          arrival.decayed(now),
          same(arrival),
          reason: 'arrivalUnix $unix',
        );
      }
    });

    test('counts down to the absolute arrival and stops at zero', () {
      expect(
        _arrival(arrivalUnix: nowUnix + 90).decayed(now).estimateSeconds,
        90,
      );
      expect(
        _arrival(arrivalUnix: nowUnix - 30).decayed(now).estimateSeconds,
        0,
      );
    });
  });
}
