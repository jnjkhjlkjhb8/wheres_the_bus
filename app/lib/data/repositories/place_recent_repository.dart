import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

/// Recently-selected planner destinations, mirroring SearchRecentRepository
/// for the go-planner's Google Places path. Only user-picked places are stored
/// (never the current-location pseudo-place), keyed by name + coordinates.
class PlaceRecentRepository {
  const PlaceRecentRepository._();
  static const instance = PlaceRecentRepository._();

  static const _key = 'recent_planned_places';
  static const _maxItems = 8;

  List<PlannedPlace> all() {
    if (!HiveStore.settingsReady) return const [];
    final raw = HiveStore.settings.get(_key, defaultValue: <dynamic>[]);
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(_fromMap)
        .whereType<PlannedPlace>()
        .toList(growable: false);
  }

  Future<void> add(PlannedPlace place) async {
    if (!HiveStore.settingsReady || place.isCurrentLocation) return;
    final current = all().where((p) => !_samePlace(p, place)).toList();
    final next = [place, ...current].take(_maxItems).map(_toMap).toList();
    await HiveStore.settings.put(_key, next);
  }

  Future<void> remove(PlannedPlace place) async {
    if (!HiveStore.settingsReady) return;
    final next = all().where((p) => !_samePlace(p, place)).map(_toMap).toList();
    await HiveStore.settings.put(_key, next);
  }

  // Same place = same name and coordinates equal to 6 decimal places.
  bool _samePlace(PlannedPlace a, PlannedPlace b) =>
      a.name == b.name &&
      _round6(a.latLng.latitude) == _round6(b.latLng.latitude) &&
      _round6(a.latLng.longitude) == _round6(b.latLng.longitude);

  int _round6(double v) => (v * 1e6).round();

  Map<String, Object?> _toMap(PlannedPlace place) => {
    'name': place.name,
    'lat': place.latLng.latitude,
    'lon': place.latLng.longitude,
  };

  PlannedPlace? _fromMap(Map<dynamic, dynamic> map) {
    final name = map['name'] as String? ?? '';
    final lat = (map['lat'] as num?)?.toDouble();
    final lon = (map['lon'] as num?)?.toDouble();
    if (name.isEmpty || lat == null || lon == null) return null;
    return PlannedPlace(name: name, latLng: LatLng(lat, lon));
  }
}
