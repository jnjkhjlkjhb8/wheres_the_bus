import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';

import '../../support/helpers/i18n.dart';

BusStopArrival _route(String sub, String name) => BusStopArrival(
  stationId: 'stop-1',
  subRouteUid: sub,
  routeName: name,
  destination: '板橋',
  estimateSeconds: -1,
  stopStatus: -1,
);

final _member = BusStationMember(
  stationUid: 'stop-1',
  stationId: 'sid-1',
  stationName: '台北車站',
  lat: 25,
  lon: 121,
  // Out of name order on purpose: every untimed row shares one rank.
  routes: [_route('sub-b', 'B'), _route('sub-a', 'A')],
);

void main() {
  late _LiveRepository repository;

  setUp(() => repository = _LiveRepository());
  tearDown(() => repository.live.close());

  BusStopBloc mount({Duration? liveWait}) {
    final bloc = BusStopBloc(
      i18n: zhStrings,
      stopId: 'group-1',
      repository: repository,
      liveWait: liveWait,
    );
    addTearDown(bloc.close);
    return bloc;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('lists the static routes before any live frame, by name', () async {
    final bloc = mount();
    await settle();

    expect(bloc.state.status, BusStopStatus.loaded);
    expect(bloc.state.arrivals, isEmpty);
    expect([for (final d in bloc.state.displays) d.display.label], ['A', 'B']);
    expect(bloc.state.arrivalsByStation['stop-1'], hasLength(2));
    expect(bloc.state.displays.first.display.status, isA<EtaUnknown>());
  });

  test('a live arrival replaces its static row and leads', () async {
    final bloc = mount();
    await settle();
    repository.live.add(const [
      BusStopArrival(
        stationId: 'stop-1',
        subRouteUid: 'sub-b',
        routeName: 'B',
        destination: '板橋',
        estimateSeconds: 180,
      ),
    ]);
    await settle();

    expect([for (final d in bloc.state.displays) d.display.label], ['B', 'A']);
    expect(bloc.state.displays.first.display.status, isA<EtaMinutes>());
  });

  test('says so once the wait for live data runs out', () async {
    final bloc = mount(liveWait: const Duration(milliseconds: 10));
    await settle();
    expect(bloc.state.liveWaitExpired, isTrue);

    bloc.add(const BusStopRetryRequested());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.liveWaitExpired, isFalse);
  });

  test('without a wait it never says so', () async {
    final bloc = mount();
    await settle();
    expect(bloc.state.liveWaitExpired, isFalse);
  });
}

/// Live stream stays open and silent until a test pushes a frame.
class _LiveRepository implements BusRepository {
  final live = StreamController<List<BusStopArrival>>.broadcast();

  @override
  Future<List<BusStationMember>> stationGroup(String groupUid) async => [
    _member,
  ];

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) =>
      live.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
