import 'package:wheres_the_bus/data/models/plan_models.dart';

abstract class PlanPreviewEvent {
  const PlanPreviewEvent();
}

/// Show one route as a full itinerary: a results card, a map line, or a saved
/// route.
class PreviewOpened extends PlanPreviewEvent {
  const PreviewOpened(this.route);
  final PlanRoute route;
}

class PreviewClosed extends PlanPreviewEvent {
  const PreviewClosed();
}

/// A newer copy of the results arrived, typically the one with map geometry.
class PreviewRoutesRefreshed extends PlanPreviewEvent {
  const PreviewRoutesRefreshed(this.routes);
  final List<PlanRoute> routes;
}
