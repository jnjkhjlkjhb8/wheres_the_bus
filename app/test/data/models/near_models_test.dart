import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';

void main() {
  group('formatNearDistance', () {
    test('renders meters below 1000', () {
      expect(formatNearDistance(650), '650m');
      expect(formatNearDistance(0), '0m');
      expect(formatNearDistance(999), '999m');
    });

    test('renders kilometers with one decimal at or above 1000', () {
      expect(formatNearDistance(1000), '1.0km');
      expect(formatNearDistance(1200), '1.2km');
      expect(formatNearDistance(2549), '2.5km');
    });
  });

  test('displayDistance delegates to formatNearDistance', () {
    const s = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'a',
      stationName: '站A',
      lat: 0,
      lon: 0,
      walkingMinutes: 8,
      distanceMeters: 650,
    );
    expect(s.displayDistance, '650m');
  });

  test('routed defaults to true', () {
    const s = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'a',
      stationName: '站A',
      lat: 0,
      lon: 0,
      walkingMinutes: 8,
      distanceMeters: 650,
    );
    expect(s.routed, isTrue);
  });
  test('lineIds defaults to none', () {
    const s = NearStationViewModel(
      type: NearStationType.mrt,
      stationId: 'a',
      stationName: '站A',
      lat: 0,
      lon: 0,
      walkingMinutes: 1,
      distanceMeters: 1,
    );
    expect(s.lineIds, isEmpty);
    expect(s.walkingMinutes, 1);
    expect(s.distanceMeters, 1);
  });

  test('a station is identified by type, id and name alone', () {
    const base = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'a',
      stationName: '站A',
      lat: 1,
      lon: 2,
      walkingMinutes: 3,
      distanceMeters: 4,
    );
    const moved = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'a',
      stationName: '站A',
      lat: 9,
      lon: 8,
      walkingMinutes: 7,
      distanceMeters: 6,
      routed: false,
      lineIds: ['BL'],
    );
    expect(moved, base);
    expect(moved.hashCode, base.hashCode);
    const others = [
      NearStationViewModel(
        type: NearStationType.bike,
        stationId: 'a',
        stationName: '站A',
        lat: 1,
        lon: 2,
        walkingMinutes: 3,
        distanceMeters: 4,
      ),
      NearStationViewModel(
        type: NearStationType.bus,
        stationId: 'b',
        stationName: '站A',
        lat: 1,
        lon: 2,
        walkingMinutes: 3,
        distanceMeters: 4,
      ),
      NearStationViewModel(
        type: NearStationType.bus,
        stationId: 'a',
        stationName: '站B',
        lat: 1,
        lon: 2,
        walkingMinutes: 3,
        distanceMeters: 4,
      ),
    ];
    for (final other in others) {
      expect(other, isNot(base));
    }
  });

  test('a query is identified by position and radius', () {
    const base = NearQuery(lat: 25.0, lon: 121.5, radius: 500);
    expect(base, const NearQuery(lat: 25.0, lon: 121.5, radius: 500));
    expect(
      base.hashCode,
      const NearQuery(lat: 25.0, lon: 121.5, radius: 500).hashCode,
    );
    expect(base, isNot(const NearQuery(lat: 25.1, lon: 121.5, radius: 500)));
    expect(base, isNot(const NearQuery(lat: 25.0, lon: 121.6, radius: 500)));
    expect(base, isNot(const NearQuery(lat: 25.0, lon: 121.5, radius: 501)));
    expect(base.radius, 500);
  });

  test('the station types keep their declared order', () {
    expect(NearStationType.values.map((t) => t.name), [
      'bus',
      'bike',
      'mrt',
      'tra',
      'thsr',
    ]);
  });
}
