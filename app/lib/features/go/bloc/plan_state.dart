import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';

enum PlanStatus { initial, loading, success, failure }

class PlanState extends Equatable {
  const PlanState({
    this.status = PlanStatus.initial,
    this.result,
    this.error,
    this.selectedRouteIndex,
    this.previewing = false,
    this.previewFromSaved = false,
    this.activeLegIndex,
    this.activeStopIndex,
    this.activeWalkStepIndex = 0,
    this.savedRoutes = const [],
    this.savedRoutesReady = false,
    this.savedRoutesLoadError = false,
    this.geometryPending = false,
    this.failure,
  });

  final PlanStatus status;
  final PlanResult? result;
  final String? error;
  final int? selectedRouteIndex;

  /// Whether the selected route is shown as a full itinerary (plan preview),
  /// as opposed to the results list. Navigation can only start from preview.
  final bool previewing;

  /// Whether the current preview was entered directly from a saved route, so
  /// there is no results list behind it. Closing such a preview clears the
  /// injected result rather than falling back to a (non-existent) results list.
  final bool previewFromSaved;

  final int? activeLegIndex;
  final int? activeStopIndex;

  /// Index into the active walk section's steps; display-only, resets to 0 on
  /// each leg change and advances as the walker passes maneuver points.
  final int activeWalkStepIndex;

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

  PlanState copyWith({
    PlanStatus? status,
    PlanResult? result,
    String? error,
    bool clearError = false,
    int? selectedRouteIndex,
    bool? previewing,
    bool? previewFromSaved,
    bool clearNavigation = false,
    int? activeLegIndex,
    int? activeStopIndex,
    int? activeWalkStepIndex,
    List<PlanRoute>? savedRoutes,
    bool? savedRoutesReady,
    bool? savedRoutesLoadError,
    bool? geometryPending,
    PlanFailureKind? failure,
  }) {
    return PlanState(
      status: status ?? this.status,
      result: result ?? this.result,
      error: clearError ? null : error ?? this.error,
      selectedRouteIndex: selectedRouteIndex ?? this.selectedRouteIndex,
      previewing: previewing ?? this.previewing,
      previewFromSaved: previewFromSaved ?? this.previewFromSaved,
      activeLegIndex: clearNavigation
          ? null
          : activeLegIndex ?? this.activeLegIndex,
      activeStopIndex: clearNavigation
          ? null
          : activeStopIndex ?? this.activeStopIndex,
      activeWalkStepIndex: clearNavigation
          ? 0
          : activeWalkStepIndex ?? this.activeWalkStepIndex,
      savedRoutes: savedRoutes ?? this.savedRoutes,
      savedRoutesReady: savedRoutesReady ?? this.savedRoutesReady,
      savedRoutesLoadError:
          savedRoutesLoadError ?? this.savedRoutesLoadError,
      geometryPending: geometryPending ?? this.geometryPending,
      failure: clearError ? null : failure ?? this.failure,
    );
  }

  @override
  List<Object?> get props => [
    status,
    result,
    error,
    selectedRouteIndex,
    previewing,
    previewFromSaved,
    activeLegIndex,
    activeStopIndex,
    activeWalkStepIndex,
    savedRoutes,
    savedRoutesReady,
    savedRoutesLoadError,
    geometryPending,
    failure,
  ];
}
