import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';

/// The route being previewed, held by value: a sort change reorders the
/// results, and an index into them would then point at another itinerary.
class PlanPreviewState extends Equatable {
  const PlanPreviewState({this.route});

  final PlanRoute? route;

  bool get previewing => route != null;

  @override
  List<Object?> get props => [route];
}
