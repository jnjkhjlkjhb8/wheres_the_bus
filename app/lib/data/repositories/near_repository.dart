import 'dart:async';

import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/decoders/near_decoder.dart';
import 'package:wheres_the_bus/data/generated/near.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';

// Nearby domain types live in data/models/near_models.dart; re-exported so
// feature callers keep resolving them through the repository.
export 'package:wheres_the_bus/data/models/near_models.dart'
    show NearQuery, NearStationType, NearStationViewModel;

class NearRepository {
  NearRepository({Near_Station_ServiceClient? client}) : _client = client;

  static final NearRepository instance = NearRepository();

  final Near_Station_ServiceClient? _client;
  Near_Station_ServiceClient get _grpc => _client ?? GrpcClient.instance.near;

  Stream<List<NearStationViewModel>> near(Stream<NearQuery> queries) {
    final requests = queries.map(
      (q) => Ask_Near(
        positionLat: q.lat,
        positionLon: q.lon,
        radius: q.radius,
      ),
    );
    return _grpc.near(requests).map(NearDecoder.instance.decode);
  }

  Stream<List<NearStationViewModel>> nearOnce(
    double lat,
    double lon,
    int radius,
  ) {
    final ctrl = StreamController<NearQuery>()
      ..add(NearQuery(lat: lat, lon: lon, radius: radius));
    unawaited(ctrl.close());
    return near(ctrl.stream);
  }
}
