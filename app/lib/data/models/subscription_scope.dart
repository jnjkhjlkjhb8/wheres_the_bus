import 'package:wheres_the_bus/data/models/favorite.dart';

/// The line-wide marker a rail-station 收藏 resolves to. It matches no real
/// alert scope, so a subscription holding it receives only the disruptions that
/// name no route — 「台鐵今日全線停駛」reaches it, 「123 次停駛」does not.
const railSystemWideKey = '*';

Set<String> subscriptionScope(Iterable<Favorite> favorites) {
  final scope = <String>{};
  for (final favorite in favorites) {
    switch (favorite.type) {
      case FavoriteType.busRoute:
        scope.add('bus:${favorite.refId}');
      case FavoriteType.metroStation:
        scope.addAll(metroStationLines(favorite.refId).map((l) => 'mrt:$l'));
      case FavoriteType.railTrain:
        scope.addAll(['tra:${favorite.refId}', 'thsr:${favorite.refId}']);
      case FavoriteType.railStation:
        scope.addAll(['tra:$railSystemWideKey', 'thsr:$railSystemWideKey']);
      case FavoriteType.busStop:
      case FavoriteType.bikeStation:
        break;
    }
  }
  return scope;
}

Iterable<String> metroStationLines(String stationId) sync* {
  for (final segment in stationId.split('_')) {
    final line = segment.replaceAll(RegExp(r'\d+$'), '');
    if (line.isNotEmpty) yield line;
  }
}
