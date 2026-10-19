import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/core/location/nearest_within.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';

/// Taipei Main Station, give or take.
const _riderLat = 25.0478;
const _riderLon = 121.5170;

({double lat, double lon, String name}) _point(
  String name,
  double lat,
  double lon,
) => (lat: lat, lon: lon, name: name);

Position _fix({
  double accuracy = 8,
  Duration age = Duration.zero,
}) => Position(
  latitude: _riderLat,
  longitude: _riderLon,
  timestamp: DateTime.utc(2026, 8, 8, 12).subtract(age),
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

final _now = DateTime.utc(2026, 8, 8, 12);

void main() {
  group('nearestWithin', () {
    test('picks the closest point inside the radius', () {
      final near = _point('near', 25.0479, 121.5171);
      final far = _point('far', 25.0490, 121.5190);
      final result = nearestWithin(
        [far, near],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 300,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result?.name, 'near');
    });

    test('returns null when everything is beyond the radius', () {
      final result = nearestWithin(
        [_point('a', 25.0600, 121.5400)],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 200,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result, isNull);
    });

    test(
      'skips (0, 0) placeholders instead of treating them as a location',
      () {
        final result = nearestWithin(
          [_point('missing coords', 0, 0)],
          lat: _riderLat,
          lon: _riderLon,
          radiusMeters: 300,
          latOf: (p) => p.lat,
          lonOf: (p) => p.lon,
        );
        expect(result, isNull);
      },
    );

    test('the 10 m bus-pole radius separates the two sides of a road', () {
      // ~8 m north and ~30 m north of the rider.
      final thisSide = _point('this side', _riderLat + 0.00007, _riderLon);
      final acrossTheRoad = _point('across', _riderLat + 0.00027, _riderLon);
      final result = nearestWithin(
        [acrossTheRoad, thisSide],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 10,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result?.name, 'this side');
    });

    test('a point exactly on the radius is still a candidate', () {
      final edge = _point('edge', 25.0490, 121.5190);
      final radius = Geolocator.distanceBetween(
        _riderLat,
        _riderLon,
        edge.lat,
        edge.lon,
      );
      final result = nearestWithin(
        [edge],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: radius,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result?.name, 'edge');
    });

    test('keeps the first of two equidistant points', () {
      final first = _point('first', 25.0479, 121.5171);
      final second = _point('second', 25.0479, 121.5171);
      final result = nearestWithin(
        [first, second],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 300,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result?.name, 'first');
    });

    test('a zero latitude alone is a real location, not a placeholder', () {
      final equator = _point('equator', 0, _riderLon);
      final result = nearestWithin(
        [equator],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 2e7,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result?.name, 'equator');
    });

    test('a zero longitude alone is a real location, not a placeholder', () {
      final meridian = _point('meridian', _riderLat, 0);
      final result = nearestWithin(
        [meridian],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 2e7,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result?.name, 'meridian');
    });

    test('empty input is null, not an error', () {
      final result = nearestWithin(
        <({double lat, double lon, String name})>[],
        lat: _riderLat,
        lon: _riderLon,
        radiusMeters: 300,
        latOf: (p) => p.lat,
        lonOf: (p) => p.lon,
      );
      expect(result, isNull);
    });
  });

  group('usableAutoFocusFix', () {
    test('rejects a missing fix', () {
      expect(
        usableAutoFocusFix(null, maxAccuracyMeters: 300, now: _now),
        isFalse,
      );
    });

    test('rejects a fix whose own error exceeds the radius', () {
      expect(
        usableAutoFocusFix(
          _fix(accuracy: 400),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isFalse,
      );
    });

    test('rejects a stale fix', () {
      expect(
        usableAutoFocusFix(
          _fix(age: const Duration(hours: 3)),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isFalse,
      );
    });

    test('accepts a recent, accurate-enough fix', () {
      expect(
        usableAutoFocusFix(
          _fix(age: const Duration(minutes: 1)),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isTrue,
      );
    });

    test('accepts a fix exactly at the accuracy limit', () {
      expect(
        usableAutoFocusFix(
          _fix(accuracy: 300),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isTrue,
      );
    });

    test('rejects a fix with zero accuracy, which is not a measurement', () {
      expect(
        usableAutoFocusFix(
          _fix(accuracy: 0),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isFalse,
      );
    });

    test('accepts a fix exactly at the age limit', () {
      expect(
        usableAutoFocusFix(
          _fix(age: const Duration(minutes: 5)),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isTrue,
      );
    });

    test('rejects a fix one second past the age limit', () {
      expect(
        usableAutoFocusFix(
          _fix(age: const Duration(minutes: 5, seconds: 1)),
          maxAccuracyMeters: 300,
          now: _now,
        ),
        isFalse,
      );
    });

    test('the bus-pole gate accepts a 20 m fix a 10 m gate would reject', () {
      expect(
        usableAutoFocusFix(
          _fix(accuracy: 20),
          maxAccuracyMeters: 30,
          now: _now,
        ),
        isTrue,
      );
      expect(
        usableAutoFocusFix(
          _fix(accuracy: 20),
          maxAccuracyMeters: 10,
          now: _now,
        ),
        isFalse,
      );
    });
  });

  group('metroStationIdForName', () {
    test('resolves an interchange to its combined line-map id', () {
      // The nearby query answers per line; the line map keys interchanges by
      // both line codes, so the mapping has to go through the name.
      final id = metroStationIdForName('台北車站');
      expect(id, isNotNull);
      expect(id, contains('_'));
    });

    test('is null for a name the line map does not carry', () {
      expect(metroStationIdForName('不存在的站'), isNull);
    });
  });
}
