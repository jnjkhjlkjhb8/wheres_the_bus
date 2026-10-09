import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

abstract class PlaceSearchEvent {
  const PlaceSearchEvent();
}

/// Hydrate recents and saved places from local storage (on bloc construction).
class PlaceSearchStarted extends PlaceSearchEvent {
  const PlaceSearchStarted();
}

class PlaceQueryChanged extends PlaceSearchEvent {
  const PlaceQueryChanged(this.query, {this.bias});
  final String query;
  final LatLng? bias;
}

/// Resolve a suggestion's coordinates. [intent] decides what the view does
/// with the result; a `pick` also records the place as a recent.
class PlaceResolveRequested extends PlaceSearchEvent {
  const PlaceResolveRequested(this.placeId, this.intent);
  final String placeId;
  final ResolveIntent intent;
}

/// Mirrors the current-location lookup the view runs, which stays there
/// because it names the place from the active locale.
class LocationResolving extends PlaceSearchEvent {
  const LocationResolving({required this.active, this.failed = false});
  final bool active;
  final bool failed;
}

/// Pin a place under a user-chosen label and icon. Also the edit path: the
/// repository updates the row at those coordinates in place.
class PlaceSaved extends PlaceSearchEvent {
  const PlaceSaved(this.place, {required this.name, required this.iconKey});
  final PlannedPlace place;
  final String name;
  final String iconKey;
}

class RecentRemoved extends PlaceSearchEvent {
  const RecentRemoved(this.place);
  final PlannedPlace place;
}

/// Undo of [RecentRemoved].
class RecentRestored extends PlaceSearchEvent {
  const RecentRestored(this.place);
  final PlannedPlace place;
}

class SavedRemoved extends PlaceSearchEvent {
  const SavedRemoved(this.place);
  final PlannedPlace place;
}

/// Undo of [SavedRemoved].
class SavedRestored extends PlaceSearchEvent {
  const SavedRestored(this.place);
  final PlannedPlace place;
}
