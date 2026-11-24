part of 'go_screen.dart';

/// What the planner screen draws from, read across its three blocs: the
/// search and its results, the previewed route, and the trip under way.
class _GoView {
  const _GoView({
    required this.plan,
    required this.preview,
    required this.trip,
  });

  final PlanState plan;
  final PlanRoute? preview;
  final TripState trip;

  bool get navigating => trip.active;
  bool get previewing => preview != null;

  List<PlanRoute> get results => plan.result?.routes ?? const [];

  /// The route the screen is about: the trip's, else the previewed one, else
  /// the first result, which the map highlights among the alternatives.
  PlanRoute? get route =>
      trip.route ?? preview ?? (results.isEmpty ? null : results.first);

  /// Where [route] sits among the results, or -1 when the map should draw it
  /// alone: a trip hides the alternatives, and a saved route is not one of
  /// them.
  int indexInResults(PlanRoute route) =>
      navigating ? -1 : results.indexOf(route);

  /// The 最快 badge: the first result under the fastest sort, which a saved
  /// route reopened on its own never is.
  bool isFastest(PlanRoute route) =>
      plan.firstIsFastest && results.indexOf(route) == 0;
}
