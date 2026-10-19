import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';

void main() {
  const arrival = BusStopArrival(
    stationId: 's',
    subRouteUid: 'u',
    routeName: '307',
    destination: 'd',
    estimateSeconds: 60,
  );

  test('events without payload carry no props', () {
    expect(const BusStopStarted().props, isEmpty);
    expect(const BusStopRetryRequested().props, isEmpty);
  });

  test('BusStopArrivalsUpdated compares arrivals and kind', () {
    const updated = BusStopArrivalsUpdated([arrival]);
    expect(updated.kind, ArrivalFeedEmissionKind.source);
    expect(updated, const BusStopArrivalsUpdated([arrival]));
    expect(updated, isNot(const BusStopArrivalsUpdated([])));
    expect(
      updated,
      isNot(
        const BusStopArrivalsUpdated(
          [arrival],
          kind: ArrivalFeedEmissionKind.decay,
        ),
      ),
    );
  });

  test('BusStopStationSelected compares the station', () {
    expect(
      const BusStopStationSelected('a'),
      const BusStopStationSelected('a'),
    );
    expect(
      const BusStopStationSelected('a'),
      isNot(const BusStopStationSelected(null)),
    );
  });

  test('BusStopFailed compares the error', () {
    expect(
      const BusStopFailed(OfflineError()),
      const BusStopFailed(OfflineError()),
    );
    expect(
      const BusStopFailed(OfflineError()),
      isNot(const BusStopFailed(TimeoutError())),
    );
  });
}
