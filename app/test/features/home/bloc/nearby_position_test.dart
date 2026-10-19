import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_bloc.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_event.dart';

class _Location extends GeolocatorPlatform {
  Completer<Position>? pending;
  bool denied = false;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      denied ? LocationPermission.deniedForever : LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      pending?.future ?? Future.value(fix);

  Position get fix => Position(
    latitude: 25,
    longitude: 121,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

class _Near extends NearRepository {
  final queries = <NearQuery>[];
  @override
  Stream<List<NearStationViewModel>> near(Stream<NearQuery> input) =>
      input.map((query) {
        queries.add(query);
        return const [
          NearStationViewModel(
            type: NearStationType.bus,
            stationId: 'S',
            stationName: 'Station',
            lat: 25,
            lon: 121,
            walkingMinutes: 1,
            distanceMeters: 30,
          ),
        ];
      });
}

void main() {
  late GeolocatorPlatform original;
  late _Location location;
  setUp(() {
    original = GeolocatorPlatform.instance;
    location = _Location();
    GeolocatorPlatform.instance = location;
  });
  tearDown(() => GeolocatorPlatform.instance = original);

  test('a query without a viewport uses the device position', () async {
    final repository = _Near();
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);
    bloc.add(const NearbyRequested(radius: 800));
    await bloc.stream.firstWhere((state) => state.stations.isNotEmpty);
    expect(repository.queries.single.lat, 25);
    expect(repository.queries.single.lon, 121);
    expect(repository.queries.single.radius, 800);
    expect(bloc.state.error, isNull);
  });

  test(
    'permission denial ends loading without sending an invented viewport',
    () async {
      location.denied = true;
      final repository = _Near();
      final bloc = NearbyBloc(repository: repository);
      addTearDown(bloc.close);
      bloc.add(const NearbyRequested(radius: 800));
      await bloc.stream.firstWhere((state) => state.error != null);
      expect(bloc.state.loading, false);
      expect(repository.queries, isEmpty);
    },
  );

  for (final fails in [false, true]) {
    test(
      'a newer viewport supersedes an in-flight GPS result (fails=$fails)',
      () async {
        location.pending = Completer<Position>();
        final repository = _Near();
        final bloc = NearbyBloc(repository: repository);
        addTearDown(bloc.close);
        bloc.add(const NearbyRequested(radius: 800));
        await pumpEventQueue();
        bloc.add(const NearbyRequested(radius: 400, lat: 24, lon: 120));
        await bloc.stream.firstWhere((state) => state.stations.isNotEmpty);
        if (fails) {
          location.pending!.completeError(StateError('stale GPS failure'));
        } else {
          location.pending!.complete(location.fix);
        }
        await pumpEventQueue();
        expect(repository.queries, hasLength(1));
        expect(repository.queries.single.lat, 24);
        expect(repository.queries.single.lon, 120);
        expect(bloc.state.loading, false);
        expect(bloc.state.error, isNull);
      },
    );
  }
}
