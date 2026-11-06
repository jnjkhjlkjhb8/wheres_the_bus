import 'dart:convert';

import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';
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
    LocalDb? localDb,
  }) : _routeClient = routeClient,
       _stationClient = stationClient,
       _localDb = localDb;

  static final BusRepository instance = BusRepository();

  final Bus_Route_ServiceClient? _routeClient;
  Bus_Route_ServiceClient get _route =>
      _routeClient ?? GrpcClient.instance.busRoute;

  final Bus_Station_ServiceClient? _stationClient;
  Bus_Station_ServiceClient get _station =>
      _stationClient ?? GrpcClient.instance.busStation;

  // Resolved lazily so online-only tests need no PowerSync.
  final LocalDb? _localDb;
  LocalDb get _db => _localDb ?? PowerSyncService.instance;

  /// The full route from the router or the Hive cache (ADR-0017), else, on an
  /// unreachable server, the slim per-city copy (ADR-0029): stops only, with
  /// no geometry, schedules, fare or operators.
  Future<BusRouteViewModel> routeStatic(String subRouteUid) async {
    try {
      return await _cachedRouteStatic(subRouteUid);
    } on Object catch (e, stack) {
      final local = await _offlineRoute(AppError.from(e), subRouteUid);
      if (local == null) Error.throwWithStackTrace(e, stack);
      return local;
    }
  }

  Future<BusRouteViewModel?> _offlineRoute(AppError error, String uid) async {
    if (error is! OfflineError && error is! TimeoutError) return null;
    return _localRoute(uid);
  }

  /// A missing table or a malformed row is a miss; the caller rethrows the
  /// original error.
  Future<BusRouteViewModel?> _localRoute(String uid) async {
    try {
      final rows = await _db.getAll(
        'SELECT * FROM bus_route_offline WHERE id = ?',
        [uid],
      );
      return rows.isEmpty ? null : offlineRouteFromRow(uid, rows.first);
    } on Object {
      return null;
    }
  }

  Future<BusRouteViewModel> _cachedRouteStatic(String subRouteUid) =>
      offlineCached(
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

/// Decodes a `bus_route_offline` row. Throws on a malformed stop list.
BusRouteViewModel offlineRouteFromRow(String uid, Map<String, dynamic> row) =>
    BusRouteViewModel(
      subRouteUid: uid,
      routeName: row['route_name'] as String,
      subRouteName: row['sub_route_name'] as String,
      departureStopName: row['depart'] as String,
      destinationStopName: row['destin'] as String,
      city: row['city'] as String,
      headsignGo: row['headsign_go'] as String,
      headsignReturn: row['headsign_return'] as String,
      stopsGo: _offlineStops(row['stops_go'] as String),
      stopsReturn: _offlineStops(row['stops_return'] as String),
    );

/// `[stop_uid, stop_name, sequence, lat, lon]` per stop, as mrtsync writes.
List<BusStopModel> _offlineStops(String json) => [
  for (final s in jsonDecode(json) as List)
    if (s case [
      final String uid,
      final String name,
      final int sequence,
      final num lat,
      final num lon,
    ])
      BusStopModel(
        stopUid: uid,
        stopName: name,
        sequence: sequence,
        lat: lat.toDouble(),
        lon: lon.toDouble(),
      )
    else
      throw FormatException('bad offline stop', s),
];
