import 'package:google_maps_flutter/google_maps_flutter.dart';

class PlannedPlace {
  const PlannedPlace({
    required this.name,
    required this.latLng,
    this.isCurrentLocation = false,
    this.iconKey,
  });

  final String name;
  final LatLng latLng;
  final bool isCurrentLocation;

  /// Non-null only for a saved place: the stable key into `SavedPlaceIcons`
  /// chosen when it was saved. It rides along harmlessly when the place is used
  /// as an origin/destination; recents and picked results leave it null.
  final String? iconKey;

  PlannedPlace copyWith({
    String? name,
    LatLng? latLng,
    bool? isCurrentLocation,
    String? iconKey,
  }) {
    return PlannedPlace(
      name: name ?? this.name,
      latLng: latLng ?? this.latLng,
      isCurrentLocation: isCurrentLocation ?? this.isCurrentLocation,
      iconKey: iconKey ?? this.iconKey,
    );
  }
}
