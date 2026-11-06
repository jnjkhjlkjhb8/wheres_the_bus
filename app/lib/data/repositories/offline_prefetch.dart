import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';

/// Upper bound on favourites warmed per launch. A rider with more than this
/// many saved items still gets the pinned and earliest-ordered ones.
const int _maxFavorites = 30;

typedef _Read = Future<void> Function();

/// Warms the static offline cache (ADR-0017) with what the rider is most
/// likely to open without a connection: favourited bus routes and stops, and
/// today's timetable for recent rail origin/destination pairs.
Future<void> prefetchOfflineStatics() => warmOfflineStatics(
  bus: BusRepository.instance,
  tra: TraRepository.instance,
  thsr: ThsrRepository.instance,
  favorites: FavoritesRepository.instance.all(),
  recentOd: HiveStore.recentOdQueries,
  now: DateTime.now(),
);

/// Each read goes through the repositories' own `offlineCached` calls, so the
/// cache keys, freshness rules and epoch truncation stay in one place. Reads
/// run one at a time to keep this off the launch path's network budget, and
/// every failure is swallowed: a missed warm-up only means that item is not
/// available offline, which is the state the app was already in.
@visibleForTesting
Future<void> warmOfflineStatics({
  required BusRepository bus,
  required TraRepository tra,
  required ThsrRepository thsr,
  required List<Favorite> favorites,
  required List<Map<String, dynamic>> recentOd,
  required DateTime now,
}) async {
  if (!_canWarm()) return;
  final date = _isoDate(now);
  await _runWhileOnline([
    for (final fav in favorites.take(_maxFavorites))
      ..._favoriteReads(fav, bus),
    for (final od in recentOd) ..._odReads(od, date, tra, thsr),
  ]);
}

bool _canWarm() => AppNetwork.online.value && HiveStore.staticCacheReady;

Future<void> _runWhileOnline(List<_Read> reads) async {
  for (final read in reads) {
    if (!AppNetwork.online.value) return;
    try {
      await read();
    } on Object {
      // Best effort: see warmOfflineStatics.
    }
  }
}

/// MRT is already offline through PowerSync; the other favourite types have
/// no static, rider-independent read worth warming. Legacy stop favourites
/// store the stop name as refId and have no group to fetch.
List<_Read> _favoriteReads(Favorite fav, BusRepository bus) =>
    switch (fav.type) {
      FavoriteType.busRoute => [
        () => bus.routeStatic(fav.refId),
        () => bus.routeDaily(fav.refId),
      ],
      FavoriteType.busStop when fav.refId != fav.title => [
        () => bus.stationGroup(fav.refId),
      ],
      _ => const [],
    };

List<_Read> _odReads(
  Map<String, dynamic> od,
  String date,
  TraRepository tra,
  ThsrRepository thsr,
) {
  final origin = _odEnd(od, 'originId', 'originName');
  final dest = _odEnd(od, 'destId', 'destName');
  if (origin.isEmpty || dest.isEmpty) return const [];
  return _systemReads(od['system'], date, origin, dest, tra, thsr);
}

/// Mirrors RailBloc._stationId: the router resolves names when no id exists.
String _odEnd(Map<String, dynamic> od, String idKey, String nameKey) {
  final id = od[idKey] as String? ?? '';
  return id.isNotEmpty ? id : od[nameKey] as String? ?? '';
}

List<_Read> _systemReads(
  Object? system,
  String date,
  String origin,
  String dest,
  TraRepository tra,
  ThsrRepository thsr,
) => switch (system) {
  'tra' => [
    () => tra.timetable(date, origin, dest),
    () => tra.fares(origin, dest),
  ],
  'thsr' => [
    () => thsr.timetable(date, origin, dest),
    () => thsr.fares(date, origin, dest),
  ],
  _ => const [],
};

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
