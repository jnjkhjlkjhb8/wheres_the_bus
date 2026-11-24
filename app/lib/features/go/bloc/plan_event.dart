import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';

abstract class PlanEvent {
  const PlanEvent();
}

/// Hydrate saved snapshots from local storage (on bloc construction).
class SavedRoutesLoaded extends PlanEvent {
  const SavedRoutesLoaded();
}

/// Save the route if not already saved, otherwise remove it.
class RouteSaveToggled extends PlanEvent {
  const RouteSaveToggled(this.route);
  final PlanRoute route;
}

class PlanSearchRequested extends PlanEvent {
  const PlanSearchRequested({
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.date,
    required this.time,
    this.arriveBy = false,
    this.options = const PlanOptions(),
    this.pageCursor = '',
    this.legAlternatives = 0,
  });

  final double fromLat;
  final double fromLon;
  final double toLat;
  final double toLon;
  final String date;
  final String time;
  final bool arriveBy;

  /// Everything the rider chose, in one object rather than fifteen parameters
  /// re-listed at each hop between the screen, this event and the RPC.
  final PlanOptions options;

  /// Echoed from a previous response to ask for earlier or later departures.
  /// Empty is a fresh search, which is what resets the paging.
  final String pageCursor;

  /// How many replacement services to ask for per transit leg.
  final int legAlternatives;
}

/// Give up on the in-flight query. Cancels the RPC and returns to the state the
/// planner had before the search, so the fields survive and the rider can edit
/// them instead of leaving the screen.
class PlanSearchCancelled extends PlanEvent {
  const PlanSearchCancelled();
}

/// Order the results another way. The last search is asked again unchanged
/// apart from the sort, which the planner answers from its cache.
class PlanSortChanged extends PlanEvent {
  const PlanSortChanged(this.sort);
  final PlanSort sort;
}
