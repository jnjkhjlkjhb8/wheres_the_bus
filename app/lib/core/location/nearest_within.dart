import 'package:geolocator/geolocator.dart';

/// How stale a cached fix may be before auto-focus ignores it. A fix from
/// hours ago is usually another part of the city — or another city — and
/// selecting the station it points at is worse than selecting nothing.
const autoFocusMaxFixAge = Duration(minutes: 5);

bool usableAutoFocusFix(
  Position? fix, {
  required double maxAccuracyMeters,
  required DateTime now,
}) {
  if (fix == null) return false;
  if (fix.accuracy <= 0 || fix.accuracy > maxAccuracyMeters) return false;
  return now.difference(fix.timestamp.toUtc()) <= autoFocusMaxFixAge;
}

T? nearestWithin<T>(
  Iterable<T> items, {
  required double lat,
  required double lon,
  required double radiusMeters,
  required double Function(T) latOf,
  required double Function(T) lonOf,
}) {
  T? best;
  var bestDistance = double.infinity;
  for (final item in items) {
    final itemLat = latOf(item);
    final itemLon = lonOf(item);
    if (_missingLocation(itemLat, itemLon)) continue;
    final distance = Geolocator.distanceBetween(lat, lon, itemLat, itemLon);
    if (_outsideCandidate(distance, radiusMeters, bestDistance)) continue;
    best = item;
    bestDistance = distance;
  }
  return best;
}

bool _missingLocation(double lat, double lon) => lat == 0 && lon == 0;
bool _outsideCandidate(double distance, double radius, double bestDistance) =>
    distance > radius || distance >= bestDistance;
