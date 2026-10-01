import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/decoders/bus_decoder.dart';
import 'package:wheres_the_bus/data/generated/bus.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/repositories/offline_cache.dart';

class BusRepository {
  BusRepository({
    Bus_Route_ServiceClient? routeClient,
    Bus_Station_ServiceClient? stationClient,
  }) : _routeClient = routeClient,
       _stationClient = stationClient;

  static final BusRepository instance = BusRepository();

  final Bus_Route_ServiceClient? _routeClient;
  Bus_Route_ServiceClient get _route =>
      _routeClient ?? GrpcClient.instance.busRoute;

  final Bus_Station_ServiceClient? _stationClient;
  Bus_Station_ServiceClient get _station =>
      _stationClient ?? GrpcClient.instance.busStation;

  Future<BusRouteViewModel> routeStatic(String subRouteUid) => offlineCached(
    key: 's:bus:static:$subRouteUid',
    maxAge: const Duration(days: 7),
    fetch: () async {
      final resp = await _route.static(
        Bus_Ask_Route(subRouteUID: subRouteUid),
      );
      return resp.data;
    },
    parse: Bus_subroute.fromBuffer,
    decode: BusDecoder.instance.decodeStatic,
  );

  Future<BusDailyTimetable> routeDaily(String subRouteUid) => offlineCached(
    key: 'd:${HiveStore.dateStamp(DateTime.now())}:bus:daily:$subRouteUid',
    fetch: () async {
      final resp = await _route.daily(Bus_Ask_Route(subRouteUID: subRouteUid));
      return resp.data;
    },
    parse: Bus_DailyTimetables.fromBuffer,
    decode: BusDecoder.instance.decodeDaily,
  );

  /// Server-streaming: emits decoded route ETAs until the stream is cancelled.
  Stream<List<BusStopEtaViewModel>> routeEta(String subRouteUid) => _route
      .eta(Bus_Ask_Route(subRouteUID: subRouteUid))
      .map((resp) => BusDecoder.instance.decodeRouteEta(resp.data));

  /// Server-streaming: emits decoded station-group ETAs until the stream is
  /// cancelled. [city] may be empty; the server resolves it from the group
  /// when omitted.
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) =>
      _station
          .eta(Bus_Ask_StationGroup(city: city, groupUid: groupUid))
          .map(BusDecoder.instance.decodeStationEta);

  final _stationGroups = <String, List<BusStationMember>>{};

  /// Resolves a station group's member stops as decoded domain types.
  Future<List<BusStationMember>> stationGroup(String groupUid) async {
    final cached = _stationGroups[groupUid];
    if (cached != null) return cached;
    return _stationGroups[groupUid] = await offlineCached(
      key: 's:bus:group:$groupUid',
      fetch: () => _station.group(Bus_Ask_StationGroup(groupUid: groupUid)),
      parse: Bus_StationGroup.fromBuffer,
      decode: BusDecoder.instance.decodeStationMembers,
    );
  }
}
