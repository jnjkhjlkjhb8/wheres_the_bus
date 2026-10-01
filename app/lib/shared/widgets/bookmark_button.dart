import 'package:flutter/material.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';

class BookmarkButton extends StatelessWidget {
  const BookmarkButton({
    required this.routeType,
    required this.routeKey,
    required this.routeLabel,
    this.onPlate = false,
    super.key,
  });

  final String routeType;
  final String routeKey;
  final String routeLabel;

  /// See [FavoriteToggleButton.onPlate].
  final bool onPlate;

  Favorite get _favorite => routeType == 'bus'
      ? Favorite(
          type: FavoriteType.busRoute,
          refId: routeKey,
          title: routeLabel,
        )
      : Favorite(
          type: FavoriteType.railTrain,
          refId: routeKey,
          title: routeLabel,
          // [routeType] is already the rail system's rider-facing label, which
          // is exactly what the 收藏 needs to record so opening it reaches the
          // right system — see [railSystemFromLabel].
          subtitle: routeType,
        );

  @override
  Widget build(BuildContext context) =>
      FavoriteToggleButton(favorite: _favorite, onPlate: onPlate);
}
