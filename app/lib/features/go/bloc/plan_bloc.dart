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
    on<PlanSortChanged>(_onSortChanged);
    on<SavedRoutesLoaded>(_onSavedRoutesLoaded);
    on<RouteSaveToggled>(_onRouteSaveToggled);
    add(const SavedRoutesLoaded());
  }

  final MaasRepository _repository;

  // PlanSearchRequested handlers run concurrently (no transformer); a slow
  // earlier search can otherwise resolve after a newer one and clobber it.
  var _searchGeneration = 0;

  /// What a sort change asks again. Null before the first search and after a
  /// cancel, when there is nothing to reorder.
  PlanSearchRequested? _lastSearch;

  // Cancelled by _stopPlanStream on replacement, cancellation, and close.
  // ignore: cancel_subscriptions
  StreamSubscription<PlanUpdate>? _planSub;
  void Function()? _planFinish;

  List<PlanRoute> _readSavedRoutes() {
    if (!HiveStore.savedPlansReady) {
      throw StateError('saved_plans must be ready before reading routes');
    }
    return _decodeSavedEntries();
  }

  List<PlanRoute> _decodeSavedEntries() {
    final routes = <PlanRoute>[];
    for (final entry in HiveStore.savedPlanEntries) {
      final bytes = entry['bytes'];
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
      // A Hive box open that never completes would leave the loading spinner up
      // forever; the timeout routes it to the retry state instead.
      await HiveStore.ensureSavedPlansReady().timeout(
        const Duration(seconds: 5),
      );
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
    await _toggleSavedRoute(event.route);
    emit(
      state.copyWith(
        savedRoutes: _readSavedRoutes(),
        savedRoutesReady: true,
        savedRoutesLoadError: false,
      ),
    );
  }

  Future<void> _toggleSavedRoute(PlanRoute route) async {
    final key = route.savedKey;
    if (state.savedKeys.contains(key)) {
      await _removeSavedByContent(key);
    } else if (route.raw != null) {
      await HiveStore.putSavedPlan(key, route.raw!);
    }
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

  Future<void> _onSearch(
    PlanSearchRequested event,
    Emitter<PlanState> emit,
  ) async {
    _lastSearch = event;
    await _plan(event, emit);
  }

  Future<void> _onSortChanged(
    PlanSortChanged event,
    Emitter<PlanState> emit,
  ) async {
    if (event.sort == state.sort) return;
    emit(state.copyWith(sort: event.sort));
    final last = _lastSearch;
    if (last != null) await _plan(last, emit, resort: true);
  }

  // A re-sort is answered from the server's cache, so it keeps the current
  // results on screen instead of flashing the waiting panel and refitting.
  Future<void> _plan(
    PlanSearchRequested event,
    Emitter<PlanState> emit, {
    bool resort = false,
  }) async {
    final gen = ++_searchGeneration;
    if (!resort) {
      emit(
        state.copyWith(
          status: PlanStatus.loading,
          clearError: true,
          geometryPending: false,
        ),
      );
    }
    _stopPlanStream();
    final done = Completer<void>();
    void finish() => _completeSearch(done);

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
          sort: state.sort,
        )
        .listen(
          (update) => _planUpdated(update, gen, emit),
          onError: (Object error) {
            _planErrored(error, gen, emit);
            finish();
          },
          onDone: finish,
          cancelOnError: true,
        );
    await done.future;
  }

  void _completeSearch(Completer<void> done) {
    if (!done.isCompleted) done.complete();
  }

  void _planUpdated(
    PlanUpdate update,
    int generation,
    Emitter<PlanState> emit,
  ) {
    if (generation != _searchGeneration) return;
    emit(
      state.copyWith(
        status: PlanStatus.success,
        result: update.result,
        geometryPending: !update.complete,
      ),
    );
  }

  void _planErrored(Object error, int generation, Emitter<PlanState> emit) {
    if (generation != _searchGeneration) return;
    emit(
      state.copyWith(
        status: PlanStatus.failure,
        error: error.toString(),
        failure: _failureKind(error),
        geometryPending: false,
      ),
    );
  }

  PlanFailureKind _failureKind(Object error) =>
      error is PlanFailure ? error.kind : PlanFailureKind.unknown;

  // Cancelling drops the in-flight RPC and rewinds to the pre-search planner,
  // keeping the saved snapshots so the entry surface still has its 路線箱.
  void _onSearchCancelled(PlanSearchCancelled _, Emitter<PlanState> emit) {
    _searchGeneration++;
    _lastSearch = null;
    _stopPlanStream();
    emit(PlanState(savedRoutes: state.savedRoutes, sort: state.sort));
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

  @override
  Future<void> close() {
    _stopPlanStream();
    return super.close();
  }
}
