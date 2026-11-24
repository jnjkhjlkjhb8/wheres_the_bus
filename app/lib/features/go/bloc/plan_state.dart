import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';

enum PlanStatus { initial, loading, success, failure }

/// The search and its results, plus the saved-route box shown before any
/// search. The previewed route and the trip under way live in their own blocs.
class PlanState extends Equatable {
  const PlanState({
    this.status = PlanStatus.initial,
    this.result,
    this.error,
    this.sort = PlanSort.fastest,
    this.savedRoutes = const [],
    this.savedRoutesReady = false,
    this.savedRoutesLoadError = false,
    this.geometryPending = false,
    this.failure,
  });

  final PlanStatus status;
  final PlanResult? result;
  final String? error;

  /// How the results are ordered. Kept across searches: it is the rider's
  /// stance, not a property of one trip.
  final PlanSort sort;

  /// Locally saved route snapshots, newest first.
  final List<PlanRoute> savedRoutes;
  final bool savedRoutesReady;
  final bool savedRoutesLoadError;

  /// True between the router's two plan messages: the routes are final and the
  /// list is fully usable, but walk/rail geometry is still resolving, so map
  /// polylines are drawn from their straight-line fallback for now.
  final bool geometryPending;

  /// What went wrong, when [status] is failure — so the screen can name the
  /// cause instead of showing one generic message for every kind of failure.
  final PlanFailureKind? failure;

  /// Keys of saved snapshots, for O(1) "is this saved?" checks on cards.
  Set<String> get savedKeys => {for (final r in savedRoutes) r.savedKey};

  /// Whether the first result is the quickest, which only the fastest sort
  /// promises.
  bool get firstIsFastest =>
      sort == PlanSort.fastest && (result?.routes.length ?? 0) > 1;

  PlanState copyWith({
    PlanStatus? status,
    PlanResult? result,
    String? error,
    bool clearError = false,
    PlanSort? sort,
    List<PlanRoute>? savedRoutes,
    bool? savedRoutesReady,
    bool? savedRoutesLoadError,
    bool? geometryPending,
    PlanFailureKind? failure,
  }) {
    return PlanState(
      status: status ?? this.status,
      result: result ?? this.result,
      error: _clearable(clearError, error, this.error),
      sort: sort ?? this.sort,
      savedRoutes: savedRoutes ?? this.savedRoutes,
      savedRoutesReady: savedRoutesReady ?? this.savedRoutesReady,
      savedRoutesLoadError: savedRoutesLoadError ?? this.savedRoutesLoadError,
      geometryPending: geometryPending ?? this.geometryPending,
      failure: _clearable(clearError, failure, this.failure),
    );
  }

  T? _clearable<T>(bool clear, T? update, T? current) =>
      clear ? null : update ?? current;

  @override
  List<Object?> get props => [
    status,
    result,
    error,
    sort,
    savedRoutes,
    savedRoutesReady,
    savedRoutesLoadError,
    geometryPending,
    failure,
  ];
}
