import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bike_models.dart';

void main() {
  test('BikeAvailability sums general and electric into available', () {
    const a = BikeAvailability(
      generalBikes: 3,
      electricBikes: 2,
      returnDocks: 7,
    );
    expect(a.available, 5);
    expect(a.returnDocks, 7);
  });

  test('availability values compare by all counts and deduplicate in sets', () {
    final value = _availability(3, 2, 7);
    final equal = _availability(3, 2, 7);
    final changed = [
      _availability(4, 2, 7),
      _availability(3, 3, 7),
      _availability(3, 2, 8),
    ];

    expect(equal, isNot(same(value)));
    expect(equal, value);
    expect(value, equal);
    expect(equal.hashCode, value.hashCode);
    for (final other in changed) {
      expect(other, isNot(value));
      expect(value, isNot(other));
    }
    expect({value, equal, ...changed}, hasLength(4));
  });

  test('station values compare by all facts and deduplicate in sets', () {
    final value = _station('Station A', 20, 25.03, 121.56);
    final equal = _station('Station A', 20, 25.03, 121.56);
    final changed = [
      _station('Station B', 20, 25.03, 121.56),
      _station('Station A', 21, 25.03, 121.56),
      _station('Station A', 20, 25.04, 121.56),
      _station('Station A', 20, 25.03, 121.57),
    ];

    expect(equal, isNot(same(value)));
    expect(equal, value);
    expect(value, equal);
    expect(equal.hashCode, value.hashCode);
    for (final other in changed) {
      expect(other, isNot(value));
      expect(value, isNot(other));
    }
    expect({value, equal, ...changed}, hasLength(5));
  });
}

// Runtime arguments prevent const identities from bypassing value comparison.
BikeAvailability _availability(
  int generalBikes,
  int electricBikes,
  int docks,
) => BikeAvailability(
  generalBikes: generalBikes,
  electricBikes: electricBikes,
  returnDocks: docks,
);

BikeStationInfo _station(String name, int capacity, double lat, double lon) =>
    BikeStationInfo(name: name, capacity: capacity, lat: lat, lon: lon);
