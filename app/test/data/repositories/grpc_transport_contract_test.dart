import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/generated/bike.pbgrpc.dart' as bike;
import 'package:wheres_the_bus/data/generated/maas.pbgrpc.dart' as maas;
import 'package:wheres_the_bus/data/generated/near.pbgrpc.dart' as nearby;
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/bike_repository.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';

import '../../support/helpers/fake_grpc.dart';

class FakeBike implements bike.Bike_ServiceClient {
  final staticIds = <String>[];
  String? etaId;
  @override
  ResponseFuture<bike.Bike_static> static(
    bike.Bike_request request, {
    CallOptions? options,
  }) {
    staticIds.add(request.stationUID);
    return FakeResponseFuture(
      Future.value(
        bike.Bike_static(
          name: 'Station',
          capacity: 20,
          lat: request.stationUID == 'invalid' ? 'invalid' : '25.1',
          lon: request.stationUID == 'invalid' ? '' : '121.2',
        ),
      ),
    );
  }

  @override
  ResponseStream<bike.Resp_Bike_eta> eta(
    bike.Bike_request request, {
    CallOptions? options,
  }) {
    etaId = request.stationUID;
    return FakeResponseStream(
      Stream.fromIterable([
        bike.Resp_Bike_eta(
          data: bike.Bike_eta(
            generalBikes: 4,
            electricBikes: 2,
            availableReturnBikes: 14,
          ),
        ),
        bike.Resp_Bike_eta(
          data: bike.Bike_eta(
            generalBikes: 3,
            electricBikes: 1,
            availableReturnBikes: 16,
          ),
        ),
      ]),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeNear implements nearby.Near_Station_ServiceClient {
  final requests = <nearby.Ask_Near>[];
  @override
  ResponseStream<nearby.resp_near> near(
    Stream<nearby.Ask_Near> input, {
    CallOptions? options,
  }) => FakeResponseStream(
    input.map((request) {
      requests.add(request);
      return nearby.resp_near();
    }),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeMaas implements maas.MaasServiceClient {
  maas.MaasPlanRequest? request;
  Object? failure;
  @override
  ResponseStream<maas.MaasPlanUpdate> planStream(
    maas.MaasPlanRequest request, {
    CallOptions? options,
  }) {
    this.request = request;
    final error = failure;
    return FakeResponseStream(
      error != null
          ? Stream.error(error)
          : Stream.fromIterable([
              maas.MaasPlanUpdate(
                plan: maas.MaasPlanResponse(nextPageCursor: 'next'),
              ),
              maas.MaasPlanUpdate(
                plan: maas.MaasPlanResponse(),
                complete: true,
              ),
            ]),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test(
    'bike statics cache per station and availability stays a live stream',
    () async {
      final client = FakeBike();
      final repo = BikeRepository(client: client);
      final first = await repo.stationStatic('station');
      expect(await repo.stationStatic('station'), same(first));
      expect(client.staticIds, ['station']);
      expect(first.name, 'Station');
      expect(first.capacity, 20);
      expect(first.lat, 25.1);
      expect(first.lon, 121.2);
      final invalid = await repo.stationStatic('invalid');
      expect(invalid.lat, 0);
      expect(invalid.lon, 0);
      final updates = await repo.stationEta('station').toList();
      expect(client.etaId, 'station');
      expect(updates.map((e) => e.generalBikes), [4, 3]);
      expect(updates.map((e) => e.electricBikes), [2, 1]);
      expect(updates.map((e) => e.returnDocks), [14, 16]);
    },
  );

  test(
    'near requests preserve coordinate updates and one-shot streams close',
    () async {
      final client = FakeNear();
      final repo = NearRepository(client: client);
      expect(
        await repo
            .near(
              Stream.fromIterable([
                const NearQuery(lat: 25, lon: 121, radius: 500),
                const NearQuery(lat: 26, lon: 122, radius: 1000),
              ]),
            )
            .toList(),
        [isEmpty, isEmpty],
      );
      expect(client.requests.map((r) => r.positionLat), [25, 26]);
      expect(client.requests.map((r) => r.positionLon), [121, 122]);
      expect(client.requests.map((r) => r.radius), [500, 1000]);
      expect(await repo.nearOnce(27, 123, 750).toList(), [isEmpty]);
      expect(client.requests.last.positionLat, 27);
      expect(client.requests.last.positionLon, 123);
      expect(client.requests.last.radius, 750);
    },
  );

  test(
    'plan streaming keeps paging and accessibility options on the wire',
    () async {
      final client = FakeMaas();
      final repo = MaasRepository(client: client);
      final updates = await repo
          .planStream(
            fromLat: 25,
            fromLon: 121,
            toLat: 26,
            toLon: 122,
            date: '2026-10-10',
            time: '08:00',
            arriveBy: true,
            pageCursor: 'earlier',
            legAlternatives: 2,
            options: const PlanOptions(
              gc: 1,
              top: 3,
              transitModes: [4],
              transferMin: 5,
              transferMax: 20,
              firstMileMode: 1,
              firstMileTime: 2,
              lastMileMode: 3,
              lastMileTime: 4,
              maxTransfers: 0,
              avoidReservation: true,
              carryBike: true,
              wheelchair: true,
              walkSpeedCmPerSec: 80,
            ),
          )
          .toList();
      expect(updates.map((u) => u.complete), [false, true]);
      expect(updates.first.result.nextPageCursor, 'next');
      final request = client.request!;
      expect(request.fromLat, 25);
      expect(request.fromLon, 121);
      expect(request.toLat, 26);
      expect(request.toLon, 122);
      expect(request.date, '2026-10-10');
      expect(request.time, '08:00');
      expect(request.arriveBy, isTrue);
      expect(request.gc, 1);
      expect(request.top, 3);
      expect(request.transitModes, [4]);
      expect(request.transferTimeMin, 5);
      expect(request.transferTimeMax, 20);
      expect(request.firstMileMode, 1);
      expect(request.firstMileTime, 2);
      expect(request.lastMileMode, 3);
      expect(request.lastMileTime, 4);
      expect(request.hasMaxTransfers(), isTrue);
      expect(request.maxTransfers, 0);
      expect(request.avoidReservation, isTrue);
      expect(request.carryBike, isTrue);
      expect(request.wheelchair, isTrue);
      expect(request.walkSpeedCmPerSec, 80);
      expect(request.pageCursor, 'earlier');
      expect(request.legAlternatives, 2);
      await repo
          .planStream(
            fromLat: 25,
            fromLon: 121,
            toLat: 26,
            toLon: 122,
            date: '2026-10-10',
            time: '09:00',
          )
          .toList();
      expect(client.request!.hasMaxTransfers(), isFalse);
    },
  );

  test(
    'planner transport failures map to rider-facing failure kinds',
    () async {
      final cases = <Object, PlanFailureKind>{
        const GrpcError.deadlineExceeded(): PlanFailureKind.timeout,
        const GrpcError.notFound(): PlanFailureKind.noRoute,
        const GrpcError.unavailable(): PlanFailureKind.unavailable,
        const GrpcError.resourceExhausted(): PlanFailureKind.unavailable,
        const GrpcError.invalidArgument(): PlanFailureKind.unknown,
        StateError('unexpected'): PlanFailureKind.unknown,
      };
      for (final entry in cases.entries) {
        final repo = MaasRepository(client: FakeMaas()..failure = entry.key);
        await expectLater(
          repo.planStream(
            fromLat: 1,
            fromLon: 2,
            toLat: 3,
            toLon: 4,
            date: 'date',
            time: 'time',
          ),
          emitsError(
            isA<PlanFailure>().having((e) => e.kind, 'kind', entry.value),
          ),
        );
      }
      expect(
        const PlanFailure(PlanFailureKind.timeout).toString(),
        'PlanFailure(timeout)',
      );
    },
  );
}
