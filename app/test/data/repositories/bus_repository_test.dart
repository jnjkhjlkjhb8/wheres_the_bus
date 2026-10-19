import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/generated/bus.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';

import '../../support/helpers/fake_grpc.dart';

void main() {
  _routeCacheAndStreamContracts();
  test('stationGroup builds the request and decodes members', () async {
    final station = _FakeBusStationClient(
      group: Bus_StationGroup(
        groupUid: 'G1',
        members: [
          Bus_StationGroupMember(
            stationUid: 'stop-1',
            stationId: 'sid-1',
            stationName: '台北車站',
            positionLat: 25,
            positionLon: 121,
          ),
        ],
      ),
    );
    final repo = BusRepository(stationClient: station);

    final members = await repo.stationGroup('G1');

    expect(station.groupRequest?.groupUid, 'G1');
    expect(members, hasLength(1));
    expect(members.single.stationUid, 'stop-1');
    expect(members.single.stationName, '台北車站');
  });

  test('stationGroup serves a re-visit from the memo, no second RPC', () async {
    final station = _FakeBusStationClient(
      group: Bus_StationGroup(groupUid: 'G1'),
    );
    final repo = BusRepository(stationClient: station);

    final first = await repo.stationGroup('G1');
    final second = await repo.stationGroup('G1');
    await repo.stationGroup('G2');

    expect(second, same(first));
    expect(station.groupCalls, 2);
  });

  test(
    'stationEta passes city + groupUid through and decodes the frame',
    () async {
      final station = _FakeBusStationClient(
        etaFrames: [Resp_Bus_station_eta()],
      );
      final repo = BusRepository(stationClient: station);

      final frames = await repo.stationEta('TPE', 'G1').toList();

      expect(station.etaRequest?.city, 'TPE');
      expect(station.etaRequest?.groupUid, 'G1');
      // A default (empty) frame decodes to an empty arrival list, no throw.
      expect(frames.single, isEmpty);
    },
  );
}

class _FakeBusStationClient implements Bus_Station_ServiceClient {
  _FakeBusStationClient({
    Bus_StationGroup? group,
    this.etaFrames = const [],
  }) : _group = group ?? Bus_StationGroup();

  final Bus_StationGroup _group;
  final List<Resp_Bus_station_eta> etaFrames;

  Bus_Ask_StationGroup? groupRequest;
  Bus_Ask_StationGroup? etaRequest;
  int groupCalls = 0;

  @override
  ResponseFuture<Bus_StationGroup> group(
    Bus_Ask_StationGroup request, {
    CallOptions? options,
  }) {
    groupRequest = request;
    groupCalls++;
    return FakeResponseFuture(Future.value(_group));
  }

  @override
  ResponseStream<Resp_Bus_station_eta> eta(
    Bus_Ask_StationGroup request, {
    CallOptions? options,
  }) {
    etaRequest = request;
    return FakeResponseStream(Stream.fromIterable(etaFrames));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

void _routeCacheAndStreamContracts() {
  test(
    'daily timetable survives an offline revisit until a later date prune',
    () async {
      expect(HiveStore.staticCacheReady, isFalse);
      final directory = await Directory.systemTemp.createTemp(
        'bus-daily-cache-',
      );
      final previousOnline = AppNetwork.online.value;
      Box<dynamic>? ownedCache;
      try {
        Hive.init(directory.path);
        ownedCache = await Hive.openBox<dynamic>('static_cache');
        final message = Bus_DailyTimetables(
          subRouteUID: 'R-daily',
          direction: [
            MapEntry(
              1,
              Bus_DirectionTimetable(
                dailyTimetables: [
                  Bus_DailyTimetable(
                    tripID: 'trip-back',
                    isLowFloor: true,
                    stopTimes: [
                      Bus_StopTime(
                        stopSequence: 4,
                        arrivalTime: '09:10',
                        departureTime: '09:11',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
        const expected = BusDailyTimetable(
          directions: {
            1: [
              BusDailyTrip(
                tripId: 'trip-back',
                isLowFloor: true,
                stopTimes: [
                  BusStopTime(
                    stopSequence: 4,
                    arrivalTime: '09:10',
                    departureTime: '09:11',
                  ),
                ],
              ),
            ],
          },
        );
        var observedSameDay = false;
        for (var attempt = 0; attempt < 3; attempt++) {
          await ownedCache.clear();
          final before = DateTime.now();
          await HiveStore.pruneStaticCache(
            now: before,
            buildNumber: () async => 'daily-contract-build',
            staticVersion: () async => 'daily-contract-version',
          );
          AppNetwork.online.value = true;
          final online = _ContractBusRouteClient(dailyData: message);
          final first = await BusRepository(
            routeClient: online,
          ).routeDaily('R-daily');
          await ownedCache.flush();
          expect(first, expected);
          expect(online.dailyRequest?.subRouteUID, 'R-daily');
          expect(online.dailyCalls, 1);
          if (!_sameCalendarDay(before, DateTime.now())) continue;
          AppNetwork.online.value = false;
          const unavailable = GrpcError.unavailable('owned offline fixture');
          final offline = _ContractBusRouteClient(dailyError: unavailable);
          BusDailyTimetable revisit;
          try {
            revisit = await BusRepository(
              routeClient: offline,
            ).routeDaily('R-daily');
          } on GrpcError catch (error) {
            if (identical(error, unavailable) &&
                !_sameCalendarDay(before, DateTime.now())) {
              continue;
            }
            rethrow;
          }
          if (!_sameCalendarDay(before, DateTime.now())) continue;
          expect(revisit, expected);
          expect(offline.dailyCalls, 0);
          await HiveStore.pruneStaticCache(
            now: before.add(const Duration(days: 2)),
            buildNumber: () async => 'daily-contract-build',
            staticVersion: () async => 'daily-contract-version',
          );
          await expectLater(
            BusRepository(routeClient: offline).routeDaily('R-daily'),
            throwsA(same(unavailable)),
          );
          expect(offline.dailyCalls, 1);
          observedSameDay = true;
          break;
        }
        expect(
          observedSameDay,
          isTrue,
          reason: 'bounded attempts require an unchanged calendar date',
        );
      } finally {
        AppNetwork.online.value = previousOnline;
        try {
          if (ownedCache != null) await ownedCache.close();
        } finally {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test(
    'route ETA delivers decoded frames then the original server error and done',
    () async {
      final source = StreamController<Resp_Bus_eta>(sync: true);
      final client = _ContractBusRouteClient(etaSource: source.stream);
      final error = StateError('owned route stream failure');
      final observed = expectLater(
        BusRepository(routeClient: client).routeEta('R-live'),
        emitsInOrder([
          [
            const BusStopEtaViewModel(
              stopUid: 'stop-a',
              direction: 1,
              sequence: 2,
              estimateSeconds: 75,
              nextBusTime: '10:00',
              stopStatus: 0,
              vehiclePlates: [],
            ),
          ],
          <BusStopEtaViewModel>[],
          emitsError(same(error)),
          emitsDone,
        ]),
      )..ignore();
      try {
        expect(client.etaRequest?.subRouteUID, 'R-live');
        source
          ..add(
            Resp_Bus_eta(
              data: Bus_RouteArrival(
                stops: [
                  Bus_RouteEstimate(
                    stopUid: 'stop-a',
                    direction: 1,
                    stopSequence: 2,
                    estimate: 75,
                    nextBusTime: '10:00',
                    stopStatus: 0,
                  ),
                ],
              ),
            ),
          )
          ..add(Resp_Bus_eta())
          ..addError(error);
        await source.close();
        await observed;
      } finally {
        try {
          if (!source.isClosed) await source.close();
        } finally {
          await observed;
        }
      }
    },
  );

  test(
    'cancelling the route ETA subscription cancels its source '
    'and stops delivery',
    () async {
      final cancelled = Completer<void>();
      var cancelCalls = 0;
      final source = StreamController<Resp_Bus_eta>.broadcast(
        sync: true,
        onCancel: () {
          cancelCalls++;
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      final client = _ContractBusRouteClient(etaSource: source.stream);
      final frames = <List<BusStopEtaViewModel>>[];
      final subscription = BusRepository(
        routeClient: client,
      ).routeEta('R-cancel').listen(frames.add);
      try {
        expect(client.etaRequest?.subRouteUID, 'R-cancel');
        expect(source.hasListener, isTrue);
        source.add(Resp_Bus_eta());
        expect(frames, [<BusStopEtaViewModel>[]]);
        await subscription.cancel();
        expect(cancelled.isCompleted, isTrue);
        await cancelled.future;
        expect(cancelCalls, 1);
        expect(source.hasListener, isFalse);
        source.add(
          Resp_Bus_eta(
            data: Bus_RouteArrival(
              stops: [Bus_RouteEstimate(stopUid: 'after-cancel')],
            ),
          ),
        );
        expect(frames, [<BusStopEtaViewModel>[]]);
      } finally {
        try {
          await subscription.cancel();
        } finally {
          await source.close();
        }
      }
    },
  );
}

bool _sameCalendarDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

class _ContractBusRouteClient implements Bus_Route_ServiceClient {
  _ContractBusRouteClient({
    this.dailyData,
    this.dailyError,
    this.etaSource = const Stream<Resp_Bus_eta>.empty(),
  });

  final Bus_DailyTimetables? dailyData;
  final Object? dailyError;
  final Stream<Resp_Bus_eta> etaSource;
  Bus_Ask_Route? dailyRequest;
  Bus_Ask_Route? etaRequest;
  int dailyCalls = 0;

  @override
  ResponseFuture<Resp_Bus_daily_timetable> daily(
    Bus_Ask_Route request, {
    CallOptions? options,
  }) {
    dailyRequest = request;
    dailyCalls++;
    final error = dailyError;
    return FakeResponseFuture(
      error == null
          ? Future.value(Resp_Bus_daily_timetable(data: dailyData))
          : Future<Resp_Bus_daily_timetable>.error(error),
    );
  }

  @override
  ResponseStream<Resp_Bus_eta> eta(
    Bus_Ask_Route request, {
    CallOptions? options,
  }) {
    etaRequest = request;
    return FakeResponseStream(etaSource);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
