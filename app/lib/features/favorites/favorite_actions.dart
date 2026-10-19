import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/shared/rail_system_labels.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

TransportType transportTypeForFavorite(Favorite fav) => switch (fav.type) {
  FavoriteType.busStop => TransportType.busStop,
  FavoriteType.busRoute => TransportType.bus,
  FavoriteType.metroStation => _metroLine(fav.refId),
  FavoriteType.railStation || FavoriteType.railTrain => TransportType.tra,
  FavoriteType.bikeStation => TransportType.bike,
};

final RegExp _metroLineSeparator = RegExp(r'[_\d]');

TransportType _metroLine(String id) {
  final code = id.split(_metroLineSeparator).first;
  return switch (code) {
    'R' => TransportType.mrtR,
    'G' => TransportType.mrtG,
    'BR' => TransportType.mrtBR,
    'O' => TransportType.mrtO,
    _ => TransportType.mrtBL,
  };
}

void openFavorite(BuildContext context, Favorite fav) {
  unawaited(context.push(_favoriteLocation(fav)));
}

String _favoriteLocation(Favorite fav) => switch (fav.type) {
  // Legacy name-as-refId favorites still reach the stop screen's empty state.
  FavoriteType.busStop => AppRoutes.busStopLocation(
    stopName: fav.title,
    stopId: fav.refId,
    city: fav.subtitle,
  ),
  FavoriteType.busRoute => AppRoutes.busRoute(fav.refId),
  FavoriteType.metroStation => AppRoutes.metroStation(fav.refId),
  // A station favorite chooses an origin without submitting a destination.
  FavoriteType.railStation => AppRoutes.railLocation(
    system: railSystemFromLabel(fav.subtitle),
    originName: fav.title,
    originId: fav.refId,
  ),
  FavoriteType.railTrain => AppRoutes.railTrain(
    fav.refId,
    system: railSystemFromLabel(fav.subtitle),
  ),
  FavoriteType.bikeStation => AppRoutes.bikeStationLocation(
    stationUid: fav.refId,
  ),
};
