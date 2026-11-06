import 'package:flutter/foundation.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';

/// Recomputes which cities' bus routes sync for offline use and reconnects
/// PowerSync if the set changed (ADR-0029).
Future<void> refreshOfflineBusCities() async {
  final cities = await inferOfflineBusCities(
    db: PowerSyncService.instance,
    chosen: HiveStore.chosenOfflineBusCities,
    position: HiveStore.lastDevicePosition,
    favoriteRouteUids: [
      for (final f in FavoritesRepository.instance.ofType(
        FavoriteType.busRoute,
      ))
        f.refId,
    ],
  );
  await HiveStore.setOfflineBusCities(cities);
  await PowerSyncService.instance.refreshSyncParams();
}

/// The rider's [chosen] cities plus the city of the bus stop nearest
/// [position] and the cities of favourited bus routes, as sorted TDX codes.
/// Inference reads the local `search_vector` copy, which is empty until the
/// first sync; it then contributes nothing and [chosen] stands alone.
@visibleForTesting
Future<List<String>> inferOfflineBusCities({
  required LocalDb db,
  required List<String> chosen,
  required List<double>? position,
  required List<String> favoriteRouteUids,
}) async {
  final names = [
    ...await _nearestStopCity(db, position),
    ...await _routeCities(db, favoriteRouteUids),
  ];
  return {...chosen, ...names.map(cityCodeOf).nonNulls}.toList()..sort();
}

// Squared degrees, not metres: at Taiwan's latitude a degree of longitude is
// ~0.9 of a degree of latitude, which cannot change which city is nearest
// except right on a boundary, where either answer is fine.
Future<List<String>> _nearestStopCity(LocalDb db, List<double>? position) {
  if (position == null) return Future.value(const []);
  final [lat, lon] = position;
  return _cities(
    db,
    'SELECT city FROM search_vector '
    "WHERE type = 'bus_station' AND lat IS NOT NULL "
    'ORDER BY (lat - ?1) * (lat - ?1) + (lon - ?2) * (lon - ?2) LIMIT 1',
    [lat, lon],
  );
}

Future<List<String>> _routeCities(LocalDb db, List<String> uids) {
  if (uids.isEmpty) return Future.value(const []);
  final marks = List.filled(uids.length, '?').join(', ');
  return _cities(
    db,
    'SELECT DISTINCT city FROM search_vector '
    "WHERE type = 'bus_route' AND uid IN ($marks)",
    uids,
  );
}

/// A missing or unsynced table reads as no cities.
Future<List<String>> _cities(
  LocalDb db,
  String sql,
  List<Object?> params,
) async {
  try {
    final rows = await db.getAll(sql, params);
    return [for (final r in rows) ?r['city'] as String?];
  } on Object {
    return const [];
  }
}
