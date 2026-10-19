import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

const _degToRad = math.pi / 180;

double? bearingIfMoved(LatLng a, LatLng b, {double minMeters = 5}) {
  const metresPerDegree = 111320.0;
  final north = (b.latitude - a.latitude) * metresPerDegree;
  final east =
      (b.longitude - a.longitude) *
      metresPerDegree *
      math.cos(a.latitude * _degToRad);
  if (north * north + east * east < minMeters * minMeters) return null;
  // Dividing by the same constant that scaled the latitude makes a sign slip
  // there visible in the bearing: cos alone is even and would hide it.
  final degrees = math.atan2(east, north) / _degToRad;
  return degrees < 0 ? degrees + 360 : degrees;
}

double lerpHeading(double a, double b, double t) {
  final turn = (b - a).remainder(360);
  if (turn >= 180) return a + (turn - 360) * t;
  if (turn < -180) return a + (turn + 360) * t;
  return a + turn * t;
}
