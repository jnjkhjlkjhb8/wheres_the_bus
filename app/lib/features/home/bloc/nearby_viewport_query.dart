import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show Size;
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Backend hard cap on the nearby-station search radius — must track
/// `maxNearbyRadius` in services/router/nearby.go. A query beyond this is
/// rejected outright, so the client clamps before ever sending it.
const kNearbyMaxRadiusMeters = 5000;

/// Floor so a fully collapsed/zero-size viewport still asks for a sensible
/// area rather than a near-zero radius.
const kNearbyMinRadiusMeters = 100;

const _earthRadiusMeters = 6371000.0;

/// Great-circle distance between [a] and [b], in metres.
double haversineMeters(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// Search radius, in whole metres, spanning [center] to the farthest corner
/// of [bounds] — so a query covers everything currently on screen — clamped
/// to the backend's accepted range.
int nearbyRadiusForViewport({
  required LatLng center,
  required LatLngBounds bounds,
}) {
  final corners = [
    bounds.northeast,
    bounds.southwest,
    LatLng(bounds.northeast.latitude, bounds.southwest.longitude),
    LatLng(bounds.southwest.latitude, bounds.northeast.longitude),
  ];
  final farthest = corners
      .map((corner) => haversineMeters(center, corner))
      .reduce(math.max);
  return farthest.round().clamp(
    kNearbyMinRadiusMeters,
    kNearbyMaxRadiusMeters,
  );
}

/// Ground resolution at zoom 0 on the equator, in metres per logical pixel
/// (Web Mercator, 256 px tiles).
const _equatorMetersPerPixel = 156543.03392;

/// How many logical pixels on screen [meters] of ground covers at [latitude]
/// and [zoom] — what the home map's scan ring needs to draw a search radius
/// at the size it was actually queried at, rather than a flattering constant.
double screenPixelsForMeters({
  required int meters,
  required double latitude,
  required double zoom,
}) => meters / metersPerPixel(latitude, zoom);

/// Ground metres covered by one logical pixel at [latitude] and [zoom], in the
/// Web Mercator projection Google Maps uses. The scan ring sizes itself with
/// it; the home map's member capsules project their screen positions with it.
double metersPerPixel(double latitude, double zoom) =>
    _equatorMetersPerPixel *
    math.cos(latitude * math.pi / 180) /
    math.pow(2, zoom);

int estimatedNearbyRadius({
  required Size size,
  required double bottomPadding,
  required LatLng center,
  required double zoom,
}) {
  // The map centres its target in the space left above [bottomPadding], so the
  // farthest corner is a bottom one.
  final dx = size.width / 2;
  final dy = (size.height + bottomPadding) / 2;
  final meters =
      math.sqrt(dx * dx + dy * dy) *
      metersPerPixel(
        center.latitude,
        zoom,
      );
  return meters.round().clamp(kNearbyMinRadiusMeters, kNearbyMaxRadiusMeters);
}

/// How much bigger a requested radius may be than an already-covered one and
/// still count as covered. A pinch that grows the viewport by more than this
/// reaches stations the previous query never asked for.
const _radiusGrowthTolerance = 1.2;

/// What one nearby query covered: where it was centred and how far it reached.
@immutable
class NearbyCoverage {
  const NearbyCoverage(this.center, this.radiusMeters);

  final LatLng center;
  final int radiusMeters;

  bool covers(LatLng center, int radiusMeters, double thresholdMeters) =>
      haversineMeters(center, this.center) < thresholdMeters &&
      radiusMeters <= this.radiusMeters * _radiusGrowthTolerance;
}

class NearbyViewportQuery {
  const NearbyViewportQuery({this.inFlight, this.lastSuccessful});

  final NearbyCoverage? inFlight;
  final NearbyCoverage? lastSuccessful;

  /// Whether a query at [center] out to [radiusMeters] is worth sending.
  bool shouldQuery(
    LatLng center,
    int radiusMeters, {
    double thresholdMeters = 200,
  }) =>
      !(inFlight?.covers(center, radiusMeters, thresholdMeters) ?? false) &&
      !(lastSuccessful?.covers(center, radiusMeters, thresholdMeters) ?? false);

  NearbyViewportQuery withAttempted(LatLng center, int radiusMeters) =>
      NearbyViewportQuery(
        inFlight: NearbyCoverage(center, radiusMeters),
        lastSuccessful: lastSuccessful,
      );

  /// Promotes the in-flight query to the covered one. A response with nothing
  /// in flight (a bloc-driven retry, say) leaves the coverage untouched.
  NearbyViewportQuery withSuccess() => NearbyViewportQuery(
    lastSuccessful: inFlight ?? lastSuccessful,
  );

  NearbyViewportQuery withFailure() =>
      NearbyViewportQuery(lastSuccessful: lastSuccessful);
}
