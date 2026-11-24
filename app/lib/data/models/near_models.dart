import 'package:equatable/equatable.dart';

enum NearStationType { bus, bike, mrt, tra, thsr }

/// Domain request for a nearby-station query. Mirrors only the fields callers
/// supply; the repository maps it to the wire type internally.
class NearQuery extends Equatable {
  const NearQuery({
    required this.lat,
    required this.lon,
    required this.radius,
  });

  /// WGS-84 coordinates.
  final double lat;
  final double lon;

  /// Search radius in metres.
  final int radius;

  @override
  List<Object?> get props => [lat, lon, radius];
}

class NearStationViewModel extends Equatable {
  const NearStationViewModel({
    required this.type,
    required this.stationId,
    required this.stationName,
    required this.lat,
    required this.lon,
    required this.walkingMinutes,
    required this.distanceMeters,
    this.routed = true,
    this.lineIds = const [],
    this.city = '',
    this.headsigns = const [],
  });

  final NearStationType type;
  final String stationId;
  final String stationName;
  final double lat;
  final double lon;
  final int walkingMinutes;
  final int distanceMeters;

  /// True when distance/walk time came from OSRM foot routing; false when it is
  /// a straight-line (geodesic) estimate.
  final bool routed;
  final List<String> lineIds;

  /// The station's city as the server names it (`Taipei`); keys its live
  /// data.
  final String city;

  /// Bus only: up to two terminals its routes run to, most routes first.
  final List<String> headsigns;

  String get displayDistance => formatNearDistance(distanceMeters);

  @override
  List<Object?> get props => [type, stationId, stationName];
}

/// Formats a distance in meters as `650m` below 1000 and `1.2km` (one decimal)
/// at or above 1000.
String formatNearDistance(int distanceMeters) {
  if (distanceMeters < 1000) return '${distanceMeters}m';
  return '${(distanceMeters / 1000).toStringAsFixed(1)}km';
}
