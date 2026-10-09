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
}
