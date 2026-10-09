import 'package:wheres_the_bus/data/generated/near.pb.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';

class NearDecoder {
  const NearDecoder._();
  static const NearDecoder instance = NearDecoder._();

  /// Flattens a [resp_near] into a single list of view models, tagging each
  /// station with its transit mode. Covers bus, MRT, YouBike, TRA, and THSR.
  List<NearStationViewModel> decode(resp_near resp) {
    final out = <NearStationViewModel>[];
    for (final group in resp.nearBusStations.values) {
      for (final s in group.nearStations) {
        out.add(_vm(s, NearStationType.bus));
      }
    }
    for (final s in resp.nearMrtStations) {
      out.add(_vm(s, NearStationType.mrt));
    }
    for (final s in resp.nearBikeStations) {
      out.add(_vm(s, NearStationType.bike));
    }
    for (final s in resp.nearTraStations) {
      out.add(_vm(s, NearStationType.tra));
    }
    for (final s in resp.nearThsrStations) {
      out.add(_vm(s, NearStationType.thsr));
    }
    return out;
  }

  NearStationViewModel _vm(NearStation s, NearStationType type) =>
      NearStationViewModel(
        type: type,
        stationId: s.stationID,
        stationName: s.stationName,
        lat: s.positionLat,
        lon: s.positionLon,
        walkingMinutes: s.walk,
        distanceMeters: s.distance,
        routed: s.routed,
      );
}
