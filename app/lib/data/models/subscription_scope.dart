import 'package:wheres_the_bus/data/models/favorite.dart';

/// The line-wide marker a rail-station 收藏 resolves to. It matches no real
/// alert scope, so a subscription holding it receives only the disruptions that
/// name no route — 「台鐵今日全線停駛」reaches it, 「123 次停駛」does not.
const railSystemWideKey = '*';

Set<String> subscriptionScope(Iterable<Favorite> favorites) {
  final scope = <String>{};
  for (final favorite in favorites) {
    scope.addAll(_favoriteScope(favorite));
  }
  return scope;
}

Iterable<String> _favoriteScope(Favorite favorite) {
  if (favorite.type == FavoriteType.metroStation) {
    return metroStationLines(favorite.refId).map((line) => 'mrt:$line');
  }
  const prefixes = {
    FavoriteType.busRoute: ['bus'],
    FavoriteType.railTrain: ['tra', 'thsr'],
    FavoriteType.railStation: ['tra', 'thsr'],
  };
  final key = favorite.type == FavoriteType.railStation
      ? railSystemWideKey
      : favorite.refId;
  return (prefixes[favorite.type] ?? const <String>[]).map(
    (prefix) => '$prefix:$key',
  );
}

Iterable<String> metroStationLines(String stationId) sync* {
  for (final segment in stationId.split('_')) {
    final line = segment.replaceAll(RegExp(r'\d+$'), '');
    if (line.isNotEmpty) yield line;
  }
}
