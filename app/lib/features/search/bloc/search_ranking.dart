import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_affinity_repository.dart';

class SearchRankWeights {
  const SearchRankWeights._();

  /// The rider has explicitly saved this. Strongest single signal there is —
  /// stronger than anything inferred from behaviour.
  static const favorite = 8.0;

  /// Ceiling on the picked-before bonus, reached by a result picked often
  /// and recently. Scaled by [affinityHalfLife] and [affinityFullPicks].
  static const affinity = 5.0;

  /// This exact query led here before. Applied on top of [affinity]: the
  /// rider is repeating a search that already has a known answer.
  static const affinityQueryMatch = 3.0;

  /// Distance bands. Two bands rather than a continuous falloff — the
  /// question is "is this the one I'm standing at" and then "is this even in
  /// walking range", and nothing in between changes the answer.
  static const nearMeters = 500.0;
  static const near = 4.0;
  static const walkableMeters = 2000.0;
  static const walkable = 2.0;

  /// Picked at this hour before, during a weekday commute window.
  static const commute = 2.0;

  /// A pick stops counting for recency after this long. Half the bonus at
  /// half the age.
  static const affinityHalfLife = Duration(days: 7);

  /// Picks beyond this add nothing — the difference between habit and strong
  /// habit isn't worth more places in the list.
  static const affinityFullPicks = 5;
}

/// Weekday hours the commute bonus applies in. Outside these, "I picked this
/// at 3pm once" says nothing about now.
bool inCommuteWindow(DateTime now) {
  if (now.weekday > DateTime.friday) return false;
  const hours = [(7, 9), (17, 19)];
  return hours.any((range) => now.hour >= range.$1 && now.hour < range.$2);
}

List<SearchResult> rankSearchResults(
  List<SearchResult> results, {
  required String query,
  required List<Favorite> favorites,
  required Map<String, SearchAffinity> affinity,
  required DateTime now,
  Position? fix,
}) {
  if (results.length < 2) return results;
  final favoriteKeys = _favoriteKeys(favorites);
  final commuting = inCommuteWindow(now);

  final scored = <({SearchResult result, int index, double score})>[];
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    var score = i.toDouble();
    score -= _favoriteBonus(favoriteKeys, r);
    score -= _pickedBeforeBonus(affinity[r.storageKey], query, now, commuting);
    score -= _distanceBonus(r, fix);
    scored.add((result: r, index: i, score: score));
  }

  scored.sort(_compareRankedResults);
  return scored.map((e) => e.result).toList(growable: false);
}

double _favoriteBonus(Set<String> keys, SearchResult result) {
  final isFavorite =
      keys.contains(_favoriteKeyOf(result, result.uid)) ||
      keys.contains(_favoriteKeyOf(result, result.name));
  return isFavorite ? SearchRankWeights.favorite : 0;
}

int _compareRankedResults(
  ({SearchResult result, int index, double score}) a,
  ({SearchResult result, int index, double score}) b,
) {
  final byScore = a.score.compareTo(b.score);
  // Router order breaks ties, so equal scores never reshuffle between
  // rebuilds of the same result set.
  return byScore != 0 ? byScore : a.index.compareTo(b.index);
}

double _pickedBeforeBonus(
  SearchAffinity? affinity,
  String query,
  DateTime now,
  bool commuting,
) {
  if (affinity == null) return 0;
  var bonus = _affinityBonus(affinity, now);
  if (affinity.matchesQuery(query)) {
    bonus += SearchRankWeights.affinityQueryMatch;
  }
  return bonus + _commuteBonus(affinity, now.hour, commuting);
}

double _commuteBonus(SearchAffinity affinity, int hour, bool commuting) =>
    commuting && affinity.pickedAtHour(hour) ? SearchRankWeights.commute : 0;

double _affinityBonus(SearchAffinity a, DateTime now) {
  final ageMs = now.millisecondsSinceEpoch - a.lastPickedMs;
  if (ageMs < 0) return 0;
  final halfLifeMs = SearchRankWeights.affinityHalfLife.inMilliseconds;
  final recency = math.max<double>(0, 1 - (ageMs / halfLifeMs));
  final frequency = (a.picks / SearchRankWeights.affinityFullPicks).clamp(
    0.0,
    1.0,
  );
  return SearchRankWeights.affinity * recency * frequency;
}

double _distanceBonus(SearchResult r, Position? fix) {
  if (fix == null) return 0;
  final lat = r.lat;
  final lon = r.lon;
  if (lat == null || lon == null) return 0;
  return _coordinateDistanceBonus(fix, lat, lon);
}

double _coordinateDistanceBonus(Position fix, double lat, double lon) {
  // (0, 0) is how the bus feeds spell "no coordinates" — see nearestWithin.
  if (lat == 0 && lon == 0) return 0;
  final meters = Geolocator.distanceBetween(
    fix.latitude,
    fix.longitude,
    lat,
    lon,
  );
  return distanceBand(meters);
}

@visibleForTesting
double distanceBand(double meters) {
  if (meters <= SearchRankWeights.nearMeters) return SearchRankWeights.near;
  if (meters <= SearchRankWeights.walkableMeters) {
    return SearchRankWeights.walkable;
  }
  return 0;
}

Set<String> _favoriteKeys(List<Favorite> favorites) => {
  for (final f in favorites) ...[
    '${f.type.name}:${f.refId}',
    '${f.type.name}:${f.title}',
  ],
};

String _favoriteKeyOf(SearchResult r, String ref) =>
    '${_favoriteTypeOf(r.type).name}:$ref';

FavoriteType _favoriteTypeOf(SearchResultType type) => switch (type) {
  SearchResultType.busRoute => FavoriteType.busRoute,
  SearchResultType.busStation => FavoriteType.busStop,
  SearchResultType.bikeStation => FavoriteType.bikeStation,
  SearchResultType.mrtStation => FavoriteType.metroStation,
  SearchResultType.traTrain ||
  SearchResultType.thsrTrain => FavoriteType.railTrain,
};
