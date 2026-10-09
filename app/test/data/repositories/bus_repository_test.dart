import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/generated/bus.pbgrpc.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';

import '../../support/helpers/fake_grpc.dart';

void main() {
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
