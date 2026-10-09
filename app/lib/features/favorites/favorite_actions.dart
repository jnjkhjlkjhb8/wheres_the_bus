import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/shared/rail_system_labels.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

TransportType transportTypeForFavorite(Favorite fav) {
  switch (fav.type) {
    case FavoriteType.busStop:
      return TransportType.busStop;
    case FavoriteType.busRoute:
      return TransportType.bus;
    case FavoriteType.metroStation:
      return _metroLine(fav.refId);
    case FavoriteType.railStation:
    case FavoriteType.railTrain:
      return TransportType.tra;
    case FavoriteType.bikeStation:
      return TransportType.bike;
  }
}

final RegExp _metroLineSeparator = RegExp(r'[_\d]');

TransportType _metroLine(String id) {
  final code = id.split(_metroLineSeparator).first;
  switch (code) {
    case 'R':
      return TransportType.mrtR;
    case 'G':
      return TransportType.mrtG;
    case 'BR':
      return TransportType.mrtBR;
    case 'O':
      return TransportType.mrtO;
    default:
      return TransportType.mrtBL;
  }
}

void openFavorite(BuildContext context, Favorite fav) {
  switch (fav.type) {
    case FavoriteType.busStop:
      // refId holds the station group_uid, subtitle the city; title is the
      // display name. Legacy favorites saved name-as-refId still open (the
      // stop screen surfaces an empty state when the id is not a group_uid).
      unawaited(
        context.push(
          AppRoutes.busStopLocation(
            stopName: fav.title,
            stopId: fav.refId,
            city: fav.subtitle,
          ),
        ),
      );
    case FavoriteType.busRoute:
      unawaited(context.push(AppRoutes.busRoute(fav.refId)));
    case FavoriteType.metroStation:
      // refId is the line map's station id — see [metroMapStations].
      unawaited(context.push(AppRoutes.metroStation(fav.refId)));
    case FavoriteType.railStation:
      // The station as the timetable's origin, not submitted: a station 收藏
      // says where the rider starts, never where they are going.
      unawaited(
        context.push(
          AppRoutes.railLocation(
            system: railSystemFromLabel(fav.subtitle),
            originName: fav.title,
            originId: fav.refId,
          ),
        ),
      );
    case FavoriteType.railTrain:
      unawaited(
        context.push(
          AppRoutes.railTrain(
            fav.refId,
            system: railSystemFromLabel(fav.subtitle),
          ),
        ),
      );
    case FavoriteType.bikeStation:
      unawaited(
        context.push(AppRoutes.bikeStationLocation(stationUid: fav.refId)),
      );
  }
}
