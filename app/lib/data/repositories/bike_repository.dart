import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/generated/bike.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/bike_models.dart';

class BikeRepository {
  BikeRepository({Bike_ServiceClient? client}) : _client = client;

  static final BikeRepository instance = BikeRepository();

  final Bike_ServiceClient? _client;
  Bike_ServiceClient get _grpc => _client ?? GrpcClient.instance.bike;

  final _statics = <String, BikeStationInfo>{};

  Future<BikeStationInfo> stationStatic(String stationUid) async {
    final cached = _statics[stationUid];
    if (cached != null) return cached;
    final s = await _grpc.static(Bike_request(stationUID: stationUid));
    return _statics[stationUid] = BikeStationInfo(
      name: s.name,
      capacity: s.capacity,
      lat: double.tryParse(s.lat) ?? 0,
      lon: double.tryParse(s.lon) ?? 0,
    );
  }

  /// Server-streaming: emits decoded availability updates until cancelled.
  Stream<BikeAvailability> stationEta(String stationUid) =>
      _grpc.eta(Bike_request(stationUID: stationUid)).map((resp) {
        final e = resp.data;
        return BikeAvailability(
          generalBikes: e.generalBikes,
          electricBikes: e.electricBikes,
          returnDocks: e.availableReturnBikes,
        );
      });
}
