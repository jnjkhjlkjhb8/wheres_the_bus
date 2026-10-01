import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

class SavedPlaceRepository {
  const SavedPlaceRepository._();
  static const instance = SavedPlaceRepository._();

  static const _key = 'saved_planned_places';

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
    // Re-saving the same coordinates updates the existing row in place rather
    // than appending a duplicate.
    final current = all().where((p) => !_samePlace(p, place)).toList()
      ..add(place);
    await HiveStore.settings.put(_key, current.map(_toMap).toList());
  }

  Future<void> remove(PlannedPlace place) async {
    if (!HiveStore.settingsReady) return;
    final next = all().where((p) => !_samePlace(p, place)).map(_toMap).toList();
    await HiveStore.settings.put(_key, next);
  }

  bool contains(PlannedPlace place) => all().any((p) => _samePlace(p, place));

  // Same place = same coordinates to 6 decimal places. The label can change
  // (an edit) without the row being treated as a different place.
  bool _samePlace(PlannedPlace a, PlannedPlace b) =>
      _round6(a.latLng.latitude) == _round6(b.latLng.latitude) &&
      _round6(a.latLng.longitude) == _round6(b.latLng.longitude);

  int _round6(double v) => (v * 1e6).round();

  Map<String, Object?> _toMap(PlannedPlace place) => {
    'name': place.name,
    'lat': place.latLng.latitude,
    'lon': place.latLng.longitude,
    'icon': place.iconKey,
  };

  PlannedPlace? _fromMap(Map<dynamic, dynamic> map) {
    final name = map['name'] as String? ?? '';
    final lat = (map['lat'] as num?)?.toDouble();
    final lon = (map['lon'] as num?)?.toDouble();
    if (name.isEmpty || lat == null || lon == null) return null;
    return PlannedPlace(
      name: name,
      latLng: LatLng(lat, lon),
      iconKey: map['icon'] as String?,
    );
  }
}
