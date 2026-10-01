import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';
import 'package:wheres_the_bus/data/decoders/mrt_decoder.dart';
import 'package:wheres_the_bus/data/generated/mrt.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';

class MrtRepository {
  MrtRepository({Mrt_ServiceClient? client, LocalDb? localDb})
    : _client = client,
      _localDb = localDb;

  static final MrtRepository instance = MrtRepository();

  // Resolved lazily so tests that never touch the local DB can construct the
  // repository without initializing PowerSync.
  LocalDb? _localDb;
  LocalDb get _db => _localDb ??= PowerSyncService.instance;

  final Mrt_ServiceClient? _client;
  Mrt_ServiceClient get _grpc => _client ?? GrpcClient.instance.mrt;

  Stream<MetroLiveArrival> eta(String system, String stationId) => _grpc
      .eta(Ask_mrt(system: system, stationID: stationId))
      .map((resp) => MrtDecoder.instance.decodeEta(resp.data));

  Future<List<MetroScheduleEntry>> schedule(
    String system,
    String stationId,
  ) async {
    final ids = stationId.split('_');
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.getAll(
      'SELECT lineid, destinationstaionid, first_train_time, last_train_time '
      'FROM mrt_schedule WHERE system = ? AND station_id IN ($placeholders)',
      [system, ...ids],
    );
    return [for (final row in rows) MetroScheduleEntry.fromRow(row)];
  }

  Future<Map<String, JourneyInfo>> journeyMatrix(String stationId) async {
    final ids = stationId.split('_');
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.getAll(
      'SELECT to_station_id, fare_nt, half_fare_nt, travel_time_min '
      'FROM mrt_journey_matrix WHERE from_station_id IN ($placeholders)',
      ids,
    );
    return {
      for (final row in rows)
        row['to_station_id'] as String: JourneyInfo.fromRow(row),
    };
  }
}
