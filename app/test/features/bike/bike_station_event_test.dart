import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_event.dart';

void main() {
  test('events without payload carry no props', () {
    expect(const BikeStationStarted().props, isEmpty);
    expect(const BikeStationEtaRecovered().props, isEmpty);
    expect(const BikeStationStarted(), const BikeStationStarted());
  });

  test('BikeStationEtaUpdated compares every count', () {
    const updated = BikeStationEtaUpdated(
      available: 1,
      returnDocks: 2,
      generalBikes: 3,
      electricBikes: 4,
    );
    expect(
      updated,
      const BikeStationEtaUpdated(
        available: 1,
        returnDocks: 2,
        generalBikes: 3,
        electricBikes: 4,
      ),
    );
    for (final other in const [
      BikeStationEtaUpdated(
        available: 9,
        returnDocks: 2,
        generalBikes: 3,
        electricBikes: 4,
      ),
      BikeStationEtaUpdated(
        available: 1,
        returnDocks: 9,
        generalBikes: 3,
        electricBikes: 4,
      ),
      BikeStationEtaUpdated(
        available: 1,
        returnDocks: 2,
        generalBikes: 9,
        electricBikes: 4,
      ),
      BikeStationEtaUpdated(
        available: 1,
        returnDocks: 2,
        generalBikes: 3,
        electricBikes: 9,
      ),
    ]) {
      expect(updated, isNot(other));
    }
  });

  test('BikeStationEtaFailed compares the error', () {
    expect(
      const BikeStationEtaFailed(OfflineError()),
      const BikeStationEtaFailed(OfflineError()),
    );
    expect(
      const BikeStationEtaFailed(OfflineError()),
      isNot(const BikeStationEtaFailed(TimeoutError())),
    );
  });
}
