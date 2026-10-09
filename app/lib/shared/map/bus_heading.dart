import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

double? bearingIfMoved(LatLng a, LatLng b, {double minMeters = 5}) {
  const metresPerDegree = 111320.0;
  final north = (b.latitude - a.latitude) * metresPerDegree;
  final east =
      (b.longitude - a.longitude) *
      metresPerDegree *
      math.cos(a.latitude * math.pi / 180);
  if (north * north + east * east < minMeters * minMeters) return null;
  return (math.atan2(east, north) * 180 / math.pi + 360) % 360;
}

double lerpHeading(double a, double b, double t) =>
    a + (((b - a + 540) % 360) - 180) * t;
