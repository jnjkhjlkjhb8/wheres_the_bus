import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';

/// The trip under way, advanced on the device from GPS as navigation always
/// has been. Holds its own copy of the route, so a new search or a sort change
/// cannot swap the itinerary out from under it.
class TripState extends Equatable {
  const TripState({
    this.route,
    this.activeLegIndex,
    this.activeStopIndex,
    this.activeWalkStepIndex = 0,
  });

  final PlanRoute? route;
  final int? activeLegIndex;
  final int? activeStopIndex;

  /// Index into the active walk section's steps; display-only, resets to 0 on
  /// each leg change and advances as the walker passes maneuver points.
  final int activeWalkStepIndex;

  bool get active => route != null && activeLegIndex != null;

  @override
  List<Object?> get props => [
    route,
    activeLegIndex,
    activeStopIndex,
    activeWalkStepIndex,
  ];
}
