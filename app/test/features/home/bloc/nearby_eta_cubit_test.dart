import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_eta_cubit.dart';

import '../../../support/helpers/i18n.dart';

NearStationViewModel _station(
  String id, {
  NearStationType type = NearStationType.bus,
  String city = 'Taipei',
}) => NearStationViewModel(
  type: type,
  stationId: id,
  stationName: id,
  lat: 25,
  lon: 121,
  walkingMinutes: 1,
  distanceMeters: 10,
  city: city,
);

BusStopArrival _arrival(String route, int seconds, {int status = 0}) =>
    BusStopArrival(
      stationId: 'pole',
      subRouteUid: 'sub-$route',
      routeName: route,
      destination: '板橋',
      estimateSeconds: seconds,
      stopStatus: status,
    );

void main() {
  late _Repository repository;
  late ValueNotifier<bool> foreground;

  setUp(() {
    repository = _Repository();
    foreground = ValueNotifier(true);
  });
  tearDown(() async {
    await repository.frames.close();
    foreground.dispose();
  });

  NearbyEtaCubit mount() {
    final cubit = NearbyEtaCubit(
      i18n: zhStrings,
      repository: repository,
      settle: Duration.zero,
      foreground: foreground,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('asks for the nearest ten bus groups that name a city', () async {
    final cubit = mount()
      ..watch([
        _station('metro', type: NearStationType.mrt),
        _station('cityless', city: ''),
        for (var i = 0; i < 12; i++) _station('g$i'),
      ]);
    await settle();

    expect(repository.asked, hasLength(1));
    expect(repository.asked.single, [
      for (var i = 0; i < 10; i++) ('Taipei', 'g$i'),
    ]);
    // The same groups in another order are the same stream.
    cubit.watch([for (var i = 9; i >= 0; i--) _station('g$i')]);
    await settle();
    expect(repository.asked, hasLength(1));
  });

  test('keeps the two soonest timed arrivals per group', () async {
    final cubit = mount()..watch([_station('g')]);
    await settle();
    repository.frames.add({
      'g': [
        _arrival('9', 600),
        _arrival('B', 180),
        _arrival('A', 180),
        _arrival('ended', -1, status: 3),
      ],
    });
    await settle();

    expect([for (final a in cubit.state['g']!) a.display.label], ['A', 'B']);
  });

  test('a changed set waits for the list to settle', () async {
    final cubit = NearbyEtaCubit(
      i18n: zhStrings,
      repository: repository,
      settle: const Duration(milliseconds: 20),
      foreground: foreground,
    );
    addTearDown(cubit.close);
    cubit
      ..watch([_station('a')])
      ..watch([_station('b')]);
    await settle();
    expect(repository.asked, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(repository.asked.single, [('Taipei', 'b')]);
  });

  test('holds the stream while covered and reopens it after', () async {
    final cubit = mount()..watch([_station('g')]);
    await settle();
    cubit.setVisible(false);
    await settle();
    expect(repository.frames.hasListener, isFalse);

    cubit
      ..setVisible(false)
      ..setVisible(true);
    await settle();
    expect(repository.asked, hasLength(2));
    expect(repository.frames.hasListener, isTrue);
  });

  test('no bus groups opens no stream', () async {
    mount().watch([_station('metro', type: NearStationType.mrt)]);
    await settle();
    expect(repository.asked, isEmpty);
  });

  test('a server without the stream leaves the rows without times', () async {
    final cubit = mount()..watch([_station('g')]);
    await settle();
    repository.frames.add({
      'g': [_arrival('307', 180)],
    });
    await settle();
    expect(cubit.state, isNotEmpty);

    repository.frames.addError(const GrpcError.unimplemented());
    await settle();
    expect(cubit.state, isEmpty);
  });
}

class _Repository implements BusRepository {
  final frames =
      StreamController<Map<String, List<BusStopArrival>>>.broadcast();
  final asked = <List<(String, String)>>[];

  @override
  Stream<Map<String, List<BusStopArrival>>> stationEtas(
    List<(String, String)> groups,
  ) {
    asked.add(groups);
    return frames.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
