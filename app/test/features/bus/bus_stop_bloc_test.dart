import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';

import '../../support/helpers/i18n.dart';

void main() {
  test('loads members and arrivals from repository', () async {
    final repository = _FakeBusRepository(
      membersResult: const [
        BusStationMember(
          stationUid: 'stop-1',
          stationId: 'sid-1',
          stationName: '台北車站',
          lat: 25,
          lon: 121,
        ),
      ],
      arrivalsResult: const [
        BusStopArrival(
          stationId: 'stop-1',
          subRouteUid: 'sub-307',
          routeName: '307',
          destination: '板橋',
          estimateSeconds: 180,
        ),
      ],
    );
    final bloc = BusStopBloc(
      i18n: zhStrings,
      stopId: 'group-1',
      repository: repository,
    );
    addTearDown(bloc.close);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<BusStopState>()
            .having((s) => s.status, 'status', BusStopStatus.loaded)
            .having((s) => s.members, 'members', hasLength(1))
            .having((s) => s.arrivals, 'arrivals', hasLength(1)),
      ),
    );
  });

  test('derives sorted displays and per-stop grouping from arrivals', () async {
    final repository = _FakeBusRepository(
      membersResult: const [
        BusStationMember(
          stationUid: 'stop-1',
          stationId: 'stop-1',
          stationName: '台北車站',
          lat: 25,
          lon: 121,
        ),
        BusStationMember(
          stationUid: 'stop-2',
          stationId: 'stop-2',
          stationName: '公園',
          lat: 25,
          lon: 121,
        ),
      ],
      // Out of rank order on purpose (10 分, 2 分, 5 分) across two stops.
      arrivalsResult: const [
        BusStopArrival(
          stationId: 'stop-1',
          subRouteUid: 'sub-a',
          routeName: 'A',
          destination: '往東',
          estimateSeconds: 600,
        ),
        BusStopArrival(
          stationId: 'stop-1',
          subRouteUid: 'sub-b',
          routeName: 'B',
          destination: '往西',
          estimateSeconds: 120,
        ),
        BusStopArrival(
          stationId: 'stop-2',
          subRouteUid: 'sub-c',
          routeName: 'C',
          destination: '往南',
          estimateSeconds: 300,
        ),
      ],
    );
    final bloc = BusStopBloc(
      i18n: zhStrings,
      stopId: 'group-1',
      repository: repository,
    );
    addTearDown(bloc.close);

    final state = await bloc.stream.firstWhere(
      (s) => s.status == BusStopStatus.loaded && s.displays.isNotEmpty,
    );

    // Sorted soonest-first by rank (2 分, 5 分, 10 分).
    expect(
      state.displays.map((d) => d.subRouteUid).toList(),
      ['sub-b', 'sub-c', 'sub-a'],
    );
    // Grouped by member stop (arrival stationId keys the map).
    expect(
      state.arrivalsByStation['stop-1']!.map((d) => d.subRouteUid).toList(),
      ['sub-b', 'sub-a'],
    );
    expect(
      state.arrivalsByStation['stop-2']!.map((d) => d.subRouteUid).toList(),
      ['sub-c'],
    );
  });

  test('BusStopFailed sets AppError', () async {
    final bloc = BusStopBloc(
      i18n: zhStrings,
      stopId: 'group-1',
      repository: _FakeBusRepository(),
    );
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<BusStopState>()
            .having((s) => s.status, 'status', BusStopStatus.error)
            .having((s) => s.error, 'error', isA<OfflineError>()),
      ),
    );

    bloc.add(const BusStopFailed(OfflineError()));
    await next;
  });

  test('retry requests a fresh load', () async {
    final repository = _FakeBusRepository();
    final bloc = BusStopBloc(
      i18n: zhStrings,
      stopId: 'group-1',
      repository: repository,
    );
    addTearDown(bloc.close);

    await Future<void>.delayed(Duration.zero);
    bloc.add(const BusStopRetryRequested());
    await Future<void>.delayed(Duration.zero);

    expect(repository.groupCalls, greaterThanOrEqualTo(2));
  });

  test(
    'a decay re-emission updates the displayed countdown but leaves '
    'updatedAt untouched — only a source frame refreshes network '
    'freshness (F29)',
    () async {
      const first = BusStopArrival(
        stationId: 'stop-1',
        subRouteUid: 'sub-307',
        routeName: '307',
        destination: '板橋',
        estimateSeconds: 180,
      );
      const decayed = BusStopArrival(
        stationId: 'stop-1',
        subRouteUid: 'sub-307',
        routeName: '307',
        destination: '板橋',
        estimateSeconds: 120,
      );
      final repository = _FakeBusRepository(
        membersResult: const [
          BusStationMember(
            stationUid: 'stop-1',
            stationId: 'stop-1',
            stationName: '台北車站',
            lat: 25,
            lon: 121,
          ),
        ],
        arrivalsResult: const [first],
      );
      final bloc = BusStopBloc(
        i18n: zhStrings,
        stopId: 'group-1',
        repository: repository,
      );
      addTearDown(bloc.close);

      await bloc.stream.firstWhere(
        (s) => s.status == BusStopStatus.loaded && s.arrivals.isNotEmpty,
      );
      final sourceUpdatedAt = bloc.state.updatedAt;
      expect(sourceUpdatedAt, isNotNull);

      // A decay tick would re-derive the same list with a smaller estimate —
      // simulated directly here by dispatching a decay-kind event, since the
      // feed's own decay timer is exercised in arrival_feed_test.dart.
      bloc.add(
        const BusStopArrivalsUpdated(
          [decayed],
          kind: ArrivalFeedEmissionKind.decay,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.arrivals, [decayed]);
      expect(bloc.state.updatedAt, sourceUpdatedAt);
    },
  );

  test(
    'a decay re-emission does not clear an offline error — only source '
    'recovery does (F30)',
    () async {
      final repository = _FakeBusRepository(
        membersResult: const [
          BusStationMember(
            stationUid: 'stop-1',
            stationId: 'stop-1',
            stationName: '台北車站',
            lat: 25,
            lon: 121,
          ),
        ],
        arrivalsResult: const [
          BusStopArrival(
            stationId: 'stop-1',
            subRouteUid: 'sub-307',
            routeName: '307',
            destination: '板橋',
            estimateSeconds: 180,
          ),
        ],
      );
      final bloc = BusStopBloc(
        i18n: zhStrings,
        stopId: 'group-1',
        repository: repository,
      );
      addTearDown(bloc.close);

      await bloc.stream.firstWhere(
        (s) => s.status == BusStopStatus.loaded && s.arrivals.isNotEmpty,
      );
      bloc.add(const BusStopFailed(OfflineError()));
      await bloc.stream.firstWhere((s) => s.status == BusStopStatus.error);
      expect(bloc.state.error, isA<OfflineError>());

      bloc.add(
        const BusStopArrivalsUpdated(
          [
            BusStopArrival(
              stationId: 'stop-1',
              subRouteUid: 'sub-307',
              routeName: '307',
              destination: '板橋',
              estimateSeconds: 120,
            ),
          ],
          kind: ArrivalFeedEmissionKind.decay,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Values still refresh (the local countdown ticks visibly)...
      expect(bloc.state.arrivals.single.estimateSeconds, 120);
      // ...but the offline error a decay tick can't have fixed stays put.
      expect(bloc.state.error, isA<OfflineError>());
    },
  );

  test(
    'a source frame after an error clears it and refreshes updatedAt (F29, '
    'F30 — recovery only via a real source frame)',
    () async {
      final repository = _FakeBusRepository(
        membersResult: const [
          BusStationMember(
            stationUid: 'stop-1',
            stationId: 'stop-1',
            stationName: '台北車站',
            lat: 25,
            lon: 121,
          ),
        ],
        arrivalsResult: const [
          BusStopArrival(
            stationId: 'stop-1',
            subRouteUid: 'sub-307',
            routeName: '307',
            destination: '板橋',
            estimateSeconds: 180,
          ),
        ],
      );
      final bloc = BusStopBloc(
        i18n: zhStrings,
        stopId: 'group-1',
        repository: repository,
      );
      addTearDown(bloc.close);

      await bloc.stream.firstWhere(
        (s) => s.status == BusStopStatus.loaded && s.arrivals.isNotEmpty,
      );
      bloc.add(const BusStopFailed(OfflineError()));
      await bloc.stream.firstWhere((s) => s.status == BusStopStatus.error);

      bloc.add(
        const BusStopArrivalsUpdated(
          [
            BusStopArrival(
              stationId: 'stop-1',
              subRouteUid: 'sub-307',
              routeName: '307',
              destination: '板橋',
              estimateSeconds: 90,
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.error, isNull);
      expect(bloc.state.status, BusStopStatus.loaded);
      expect(bloc.state.updatedAt, isNotNull);
    },
  );

  test(
    'a station-group failure with a silent ETA stream settles instead of '
    'loading forever (F31)',
    () async {
      final repository = _FailingGroupBusRepository();
      final bloc = BusStopBloc(
        i18n: zhStrings,
        stopId: 'group-1',
        repository: repository,
      );
      addTearDown(bloc.close);

      final state = await bloc.stream.firstWhere(
        (s) => s.status != BusStopStatus.loading,
      );

      expect(state.status, isNot(BusStopStatus.loading));
      expect(state.error, isNotNull);
    },
  );
}

/// Station group fetch always throws; ETA stream never emits (silent) —
/// reproduces the partial-failure hang in F31.
class _FailingGroupBusRepository implements BusRepository {
  @override
  Future<List<BusStationMember>> stationGroup(String groupUid) async {
    throw StateError('station group unavailable');
  }

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class _FakeBusRepository implements BusRepository {
  _FakeBusRepository({
    this.membersResult = const [],
    this.arrivalsResult = const [],
  });

  final List<BusStationMember> membersResult;
  final List<BusStopArrival> arrivalsResult;
  int groupCalls = 0;

  @override
  Future<List<BusStationMember>> stationGroup(String groupUid) async {
    groupCalls++;
    return membersResult;
  }

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) async* {
    yield arrivalsResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
