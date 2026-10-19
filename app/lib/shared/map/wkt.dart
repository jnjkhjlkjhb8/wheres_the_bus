import 'package:google_maps_flutter/google_maps_flutter.dart';

List<List<LatLng>> parseWktLines(String wkt) {
  final out = <List<LatLng>>[];
  for (final match in RegExp(r'\(([^()]*)\)').allMatches(wkt)) {
    final line = _lineFromCoordinates(match.group(1)!);
    if (line.length >= 2) out.add(line);
  }
  return out;
}

List<LatLng> _lineFromCoordinates(String coordinates) {
  final line = <LatLng>[];
  for (final pair in coordinates.split(',')) {
    final point = _coordinate(pair);
    if (point != null) line.add(point);
  }
  return line;
}

LatLng? _coordinate(String pair) {
  final parts = pair.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return null;
  final lon = double.tryParse(parts[0]);
  final lat = double.tryParse(parts[1]);
  if (lon == null || lat == null) return null;
  return LatLng(lat, lon);
}
