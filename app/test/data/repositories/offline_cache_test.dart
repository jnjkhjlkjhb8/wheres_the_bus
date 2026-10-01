import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/generated/bus.pbgrpc.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';

import '../../support/helpers/fake_grpc.dart';

void main() {
  setUp(() async {
    Hive.init('./.dart_tool/hive_test_offline_cache');
    await Hive.openBox<dynamic>('static_cache');
    await HiveStore.staticCache.clear();
  });

  tearDown(() async => Hive.box<dynamic>('static_cache').close());

  final group = Bus_StationGroup(
    groupUid: 'G1',
    members: [
      Bus_StationGroupMember(
        stationUid: 'stop-1',
        stationName: '台北車站',
        positionLat: 25,
        positionLon: 121,
      ),
    ],
  );

  final subRoute = Bus_subroute(subRouteUID: 'R1', routeName: '307');

  test('an unreachable server is served from the cached response', () async {
    final online = _FakeBusStationClient(group: group);
    await BusRepository(stationClient: online).stationGroup('G1');

    // A fresh repository, so the answer cannot come from the in-memory memo.
    final offline = _FakeBusStationClient(error: const GrpcError.unavailable());
    final members = await BusRepository(
      stationClient: offline,
    ).stationGroup('G1');

    expect(members.single.stationName, '台北車站');
  });

  test('a known-offline device is served from cache without an RPC', () async {
    final online = _FakeBusStationClient(group: group);
    await BusRepository(stationClient: online).stationGroup('G1');

    AppNetwork.online.value = false;
    addTearDown(AppNetwork.reset);
    // Would take the full unary deadline to fail if it were ever called.
    final offline = _FakeBusStationClient(error: const GrpcError.unavailable());
    final members = await BusRepository(
      stationClient: offline,
    ).stationGroup('G1');

    expect(members.single.stationName, '台北車站');
    expect(offline.calls, 0, reason: 'no doomed round-trip');
  });

  test('a known-offline device with nothing cached still hits the '
      'network for the real error', () async {
    AppNetwork.online.value = false;
    addTearDown(AppNetwork.reset);
    final offline = _FakeBusStationClient(error: const GrpcError.unavailable());

    await expectLater(
      BusRepository(stationClient: offline).stationGroup('G1'),
      throwsA(isA<GrpcError>()),
    );
    expect(offline.calls, 1);
  });

  test('a cache miss rethrows the network error', () async {
    final offline = _FakeBusStationClient(error: const GrpcError.unavailable());

    await expectLater(
      BusRepository(stationClient: offline).stationGroup('G1'),
      throwsA(isA<GrpcError>()),
    );
  });

  test(
    'undecodable bytes surface the network error, not a parse error',
    () async {
      // What a blob written by an incompatible build looks like. This path runs
      // when the rider is already offline, so it has to degrade to the error
      // they would have seen anyway rather than throw something nobody handles.
      await HiveStore.putStatic('s:bus:group:G1', const [1, 2, 3]);
      final offline = _FakeBusStationClient(
        error: const GrpcError.unavailable(),
      );

      await expectLater(
        BusRepository(stationClient: offline).stationGroup('G1'),
        throwsA(
          isA<GrpcError>().having(
            (e) => e.code,
            'code',
            StatusCode.unavailable,
          ),
        ),
      );
      // ...and the poisoned entry is dropped so it cannot fail twice.
      expect(HiveStore.getStatic('s:bus:group:G1'), isNull);
    },
  );

  test('a route opened before is served from Hive with no RPC', () async {
    final first = _FakeBusRouteClient(subRoute: subRoute);
    await BusRepository(routeClient: first).routeStatic('R1');

    // A fresh repository, so nothing can come from an in-memory memo.
    final second = _FakeBusRouteClient(subRoute: subRoute);
    final route = await BusRepository(routeClient: second).routeStatic('R1');

    expect(second.staticCalls, 0);
    expect(route.routeName, '307');
  });

  test('a route cached over 7 days ago is refetched', () async {
    final stale = DateTime.now().subtract(const Duration(days: 8));
    await HiveStore.staticCache.put('s:bus:static:R1', {
      'b': subRoute.writeToBuffer(),
      't': stale.millisecondsSinceEpoch,
    });

    final client = _FakeBusRouteClient(subRoute: subRoute);
    await BusRepository(routeClient: client).routeStatic('R1');

    expect(client.staticCalls, 1);
  });

  test('a definitive server answer is never overridden by the cache', () async {
    final online = _FakeBusStationClient(group: group);
    await BusRepository(stationClient: online).stationGroup('G1');

    // notFound means the backend replied. Serving a stale group here would
    // contradict an answer the server actually gave.
    final gone = _FakeBusStationClient(error: const GrpcError.notFound());
    await expectLater(
      BusRepository(stationClient: gone).stationGroup('G1'),
      throwsA(isA<GrpcError>()),
    );
  });
}

class _FakeBusRouteClient implements Bus_Route_ServiceClient {
  _FakeBusRouteClient({required this.subRoute});

  final Bus_subroute subRoute;
  int staticCalls = 0;

  @override
  ResponseFuture<Resp_Bus_static> static(
    Bus_Ask_Route request, {
    CallOptions? options,
  }) {
    staticCalls++;
    return FakeResponseFuture(Future.value(Resp_Bus_static(data: subRoute)));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class _FakeBusStationClient implements Bus_Station_ServiceClient {
  _FakeBusStationClient({Bus_StationGroup? group, this.error})
    : _group = group ?? Bus_StationGroup();

  final Bus_StationGroup _group;
  final GrpcError? error;
  int calls = 0;

  @override
  ResponseFuture<Bus_StationGroup> group(
    Bus_Ask_StationGroup request, {
    CallOptions? options,
  }) {
    calls++;
    final err = error;
    return FakeResponseFuture(
      err != null ? Future.error(err) : Future.value(_group),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
