import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';

class PlanBloc extends Bloc<PlanEvent, PlanState> {
  PlanBloc({MaasRepository? repository})
    : _repository = repository ?? MaasRepository.instance,
      super(const PlanState()) {
    on<PlanSearchRequested>(_onSearch);
    on<PlanSearchCancelled>(_onSearchCancelled);
    on<RouteSelected>(_onRouteSelected);
    on<PreviewClosed>(_onPreviewClosed);
    on<NavigationStarted>(_onNavigationStarted);
    on<StopArrived>(_onStopArrived);
    on<NavigationEnded>(_onNavigationEnded);
    on<WalkStepAdvanced>(_onWalkStepAdvanced);
    on<SavedRoutesLoaded>(_onSavedRoutesLoaded);
    on<RouteSaveToggled>(_onRouteSaveToggled);
    on<SavedRouteOpened>(_onSavedRouteOpened);
    add(const SavedRoutesLoaded());
  }

  final MaasRepository _repository;

  // PlanSearchRequested handlers run concurrently (no transformer); a slow
  // earlier search can otherwise resolve after a newer one and clobber it.
  var _searchGeneration = 0;

  // Cancelled by _stopPlanStream on replacement, cancellation, and close.
  // ignore: cancel_subscriptions
  StreamSubscription<PlanUpdate>? _planSub;
  void Function()? _planFinish;

  List<PlanRoute> _readSavedRoutes() {
    if (!HiveStore.savedPlansReady) {
      throw StateError('saved_plans must be ready before reading routes');
    }
    final routes = <PlanRoute>[];
    for (final e in HiveStore.savedPlanEntries) {
      final bytes = e['bytes'];
      if (bytes is! List) continue;
      routes.add(PlanRoute.fromBytes(bytes.cast<int>()));
    }
    return routes;
  }

  Future<void> _onSavedRoutesLoaded(
    SavedRoutesLoaded _,
    Emitter<PlanState> emit,
  ) async {
    try {
      await HiveStore.ensureSavedPlansReady();
      emit(
        state.copyWith(
          savedRoutes: _readSavedRoutes(),
          savedRoutesReady: true,
          savedRoutesLoadError: false,
        ),
      );
    } on Object {
      emit(state.copyWith(savedRoutesReady: false, savedRoutesLoadError: true));
    }
  }

  Future<void> _onRouteSaveToggled(
    RouteSaveToggled event,
    Emitter<PlanState> emit,
  ) async {
    try {
      await HiveStore.ensureSavedPlansReady();
    } on Object {
      emit(state.copyWith(savedRoutesReady: false, savedRoutesLoadError: true));
      return;
    }
    final key = event.route.savedKey;
    if (state.savedKeys.contains(key)) {
      await _removeSavedByContent(key);
    } else if (event.route.raw != null) {
      await HiveStore.putSavedPlan(key, event.route.raw!);
    }
    emit(
      state.copyWith(
        savedRoutes: _readSavedRoutes(),
        savedRoutesReady: true,
        savedRoutesLoadError: false,
      ),
    );
  }

  Future<void> _removeSavedByContent(String savedKey) async {
    await HiveStore.ensureSavedPlansReady();
    for (final e in HiveStore.savedPlanEntries) {
      final bytes = e['bytes'];
      if (bytes is! List) continue;
      if (PlanRoute.fromBytes(bytes.cast<int>()).savedKey == savedKey) {
        await HiveStore.removeSavedPlan(e['key'] as String);
      }
    }
  }

  // A saved route lands directly in preview: a one-route result with no results
  // list behind it. `previewFromSaved` marks that so PreviewClosed restores the
  // pre-search planner instead of an empty results list.
  void _onSavedRouteOpened(SavedRouteOpened event, Emitter<PlanState> emit) {
    emit(
      state.copyWith(
        status: PlanStatus.success,
        result: PlanResult(routes: [event.route]),
        selectedRouteIndex: 0,
        previewing: true,
        previewFromSaved: true,
        clearError: true,
      ),
    );
  }

  Future<void> _onSearch(
    PlanSearchRequested event,
    Emitter<PlanState> emit,
  ) async {
    final gen = ++_searchGeneration;
    emit(
      state.copyWith(
        status: PlanStatus.loading,
        previewing: false,
        previewFromSaved: false,
        clearError: true,
        geometryPending: false,
      ),
    );
    _stopPlanStream();
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _planFinish = finish;
    _planSub = _repository
        .planStream(
          fromLat: event.fromLat,
          fromLon: event.fromLon,
          toLat: event.toLat,
          toLon: event.toLon,
          date: event.date,
          time: event.time,
          arriveBy: event.arriveBy,
          options: event.options,
          pageCursor: event.pageCursor,
          legAlternatives: event.legAlternatives,
        )
        .listen(
          (update) {
            if (gen != _searchGeneration || emit.isDone) return;
            emit(
              state.copyWith(
                status: PlanStatus.success,
                result: update.result,
                selectedRouteIndex: 0,
                previewing: false,
                previewFromSaved: false,
                geometryPending: !update.complete,
              ),
            );
          },
          onError: (Object e) {
            if (gen == _searchGeneration && !emit.isDone) {
              emit(
                state.copyWith(
                  status: PlanStatus.failure,
                  error: e.toString(),
                  failure: e is PlanFailure ? e.kind : PlanFailureKind.unknown,
                  geometryPending: false,
                ),
              );
            }
            finish();
          },
          onDone: finish,
          cancelOnError: true,
        );
    await done.future;
  }

  // Cancelling drops the in-flight RPC and rewinds to the pre-search planner,
  // keeping the saved snapshots so the entry surface still has its 路線箱.
  void _onSearchCancelled(PlanSearchCancelled _, Emitter<PlanState> emit) {
    _searchGeneration++;
    _stopPlanStream();
    emit(PlanState(savedRoutes: state.savedRoutes));
  }

  // Drops the in-flight plan stream and lets its handler return. Cancelling a
  // subscription never fires onDone, so the waiting handler has to be released
  // here or it would sit open for the life of the bloc.
  void _stopPlanStream() {
    final sub = _planSub;
    final finish = _planFinish;
    _planSub = null;
    _planFinish = null;
    unawaited(sub?.cancel());
    finish?.call();
  }

  void _onRouteSelected(RouteSelected event, Emitter<PlanState> emit) {
    emit(state.copyWith(selectedRouteIndex: event.index, previewing: true));
  }

  void _onPreviewClosed(PreviewClosed _, Emitter<PlanState> emit) {
    // A saved-route preview has no results list behind it; reset to the fresh
    // planner state (keeping the saved snapshots) so the saved list re-shows.
    if (state.previewFromSaved) {
      emit(PlanState(savedRoutes: state.savedRoutes));
      return;
    }
    emit(state.copyWith(previewing: false));
  }

  void _onNavigationStarted(NavigationStarted _, Emitter<PlanState> emit) {
    emit(
      state.copyWith(
        activeLegIndex: 0,
        activeStopIndex: 0,
        activeWalkStepIndex: 0,
      ),
    );
  }

  void _onStopArrived(StopArrived event, Emitter<PlanState> emit) {
    emit(
      state.copyWith(
        activeLegIndex: event.legIndex,
        activeStopIndex: event.stopIndex,
        // Each leg starts at its first walk step; the coordinator advances it.
        activeWalkStepIndex: 0,
      ),
    );
  }

  void _onWalkStepAdvanced(WalkStepAdvanced event, Emitter<PlanState> emit) {
    emit(state.copyWith(activeWalkStepIndex: event.index));
  }

  void _onNavigationEnded(NavigationEnded _, Emitter<PlanState> emit) {
    emit(state.copyWith(clearNavigation: true));
  }

  @override
  Future<void> close() {
    _stopPlanStream();
    return super.close();
  }
}
