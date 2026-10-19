import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';

void main() {
  const go = BusStopModel(stopUid: 'g', stopName: 'Go', sequence: 1);
  const back = BusStopModel(stopUid: 'r', stopName: 'Back', sequence: 1);
  const route = BusRouteViewModel(
    subRouteUid: 'u',
    routeName: '307',
    subRouteName: '307',
    departureStopName: 'A',
    destinationStopName: 'B',
    city: 'Taipei',
    headsignGo: 'to B',
    headsignReturn: 'to A',
    stopsGo: [go],
    stopsReturn: [back],
  );

  test('currentHeadsign follows direction', () {
    expect(const BusRouteState(route: route).currentHeadsign, 'to B');
    expect(
      const BusRouteState(route: route, direction: 1).currentHeadsign,
      'to A',
    );
    expect(const BusRouteState().currentHeadsign, '');
    expect(const BusRouteState(direction: 1).currentHeadsign, '');
  });

  test('currentStops follows direction', () {
    expect(const BusRouteState(route: route).currentStops, [go]);
    expect(const BusRouteState(route: route, direction: 1).currentStops, [
      back,
    ]);
    expect(const BusRouteState().currentStops, isEmpty);
    expect(const BusRouteState(direction: 1).currentStops, isEmpty);
  });

  test('starts loading with nothing else', () {
    const state = BusRouteState();
    expect(state.loading, isTrue);
    expect(state.direction, 0);
    expect(state.error, isNull);
    expect(state.etaMap, isEmpty);
    expect(state.reminders, isEmpty);
    expect(state.bufferSequences, isEmpty);
  });

  test('copyWith swaps exactly the field it is given', () {
    const base = BusRouteState();
    const eta = BusStopEtaViewModel(
      stopUid: 's',
      direction: 0,
      sequence: 1,
      estimateSeconds: 60,
      nextBusTime: '',
      stopStatus: 0,
      vehiclePlates: [],
    );
    const daily = BusDailyTimetable(directions: {0: []});
    const fare = BusFareInfo(
      pricingType: 1,
      isFreeBus: false,
      sectionFaresJson: [],
      stageFaresJson: [],
      odFaresJson: [],
    );
    final stamp = DateTime.utc(2030);
    final variants = [
      base.copyWith(route: route),
      base.copyWith(etaMap: {'s': eta}),
      base.copyWith(daily: daily),
      base.copyWith(fare: fare),
      base.copyWith(bufferSequences: {3}),
      base.copyWith(direction: 1),
      base.copyWith(reminders: {'s': 'p'}),
      base.copyWith(loading: false),
      base.copyWith(error: const OfflineError()),
      base.copyWith(updatedAt: stamp),
    ];
    for (final variant in variants) {
      expect(variant, isNot(base));
    }
    expect(variants[0].route, route);
    expect(variants[1].etaMap, {'s': eta});
    expect(variants[2].daily, daily);
    expect(variants[3].fare, fare);
    expect(variants[4].bufferSequences, {3});
    expect(variants[5].direction, 1);
    expect(variants[6].reminders, {'s': 'p'});
    expect(variants[7].loading, isFalse);
    expect(variants[8].error, isA<OfflineError>());
    expect(variants[9].updatedAt, stamp);

    final full = base.copyWith(
      route: route,
      etaMap: {'s': eta},
      daily: daily,
      fare: fare,
      bufferSequences: {3},
      direction: 1,
      reminders: {'s': 'p'},
      loading: false,
      error: const OfflineError(),
      updatedAt: stamp,
    );
    expect(full.copyWith(), full);
    final cleared = full.copyWith(clearError: true);
    expect(cleared.error, isNull);
    expect(cleared.route, route);
  });
}
