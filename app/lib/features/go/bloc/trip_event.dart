import 'package:wheres_the_bus/data/models/plan_models.dart';

abstract class TripEvent {
  const TripEvent();
}

/// 開始導航 on a previewed route: its first leg becomes the active one.
class TripStarted extends TripEvent {
  const TripStarted(this.route);
  final PlanRoute route;
}

class StopArrived extends TripEvent {
  const StopArrived({required this.legIndex, required this.stopIndex});
  final int legIndex;
  final int stopIndex;
}

/// Display-only: the current turn-by-turn walk step advanced. Does not touch
/// leg progress (owned by [StopArrived]).
class WalkStepAdvanced extends TripEvent {
  const WalkStepAdvanced({required this.index});
  final int index;
}

class TripEnded extends TripEvent {
  const TripEnded();
}

/// A newer copy of the results arrived, typically the one with map geometry.
class TripRoutesRefreshed extends TripEvent {
  const TripRoutesRefreshed(this.routes);
  final List<PlanRoute> routes;
}
