import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class BusStopBloc extends Bloc<BusStopEvent, BusStopState> {
  BusStopBloc({
    required AppI18n i18n,
    required this.stopId,
    this.city,
    BusRepository? repository,
    void Function(Object error, StackTrace stack) reportError =
        CrashReporter.record,
  }) : _i18n = i18n,
       _repository = repository ?? BusRepository.instance,
       _reportError = reportError,
       super(const BusStopState()) {
    on<BusStopStarted>(_onStarted);
    on<BusStopRetryRequested>(_onStarted);
    on<BusStopArrivalsUpdated>(_onUpdated);
    on<BusStopStationSelected>(_onStationSelected);
    on<BusStopFailed>(_onFailed);
    add(const BusStopStarted());
  }

  final String? stopId;
  final String? city;

  final AppI18n _i18n;
  final BusRepository _repository;
  final void Function(Object error, StackTrace stack) _reportError;
  // Replace policy + 15s decay live inside the feed; the empty-frame guard the
  // bloc used to run in _onUpdated is the feed's replace policy now.
  final _feed = ArrivalFeed<BusStopArrival>.replace(
    decay: (a, now) => a.decayed(now),
  );
  StreamSubscription<ArrivalFeedEmission<BusStopArrival>>? _sub;

  Future<void> _onStarted(BusStopEvent _, Emitter<BusStopState> emit) async {
    final id = stopId ?? '';
    if (id.isEmpty) {
      emit(state.copyWith(status: BusStopStatus.empty, clearError: true));
      return;
    }
    emit(state.copyWith(status: BusStopStatus.loading, clearError: true));
    await _sub?.cancel();
    await _loadStationMembers(id, emit);
    if (isClosed) return;
    _sub = _feed
        .watch(
          source: () => _repository.stationEta(city ?? '', id),
          onFailure: (e) => add(BusStopFailed(e)),
        )
        .listen(
          (emission) => add(
            BusStopArrivalsUpdated(emission.arrivals, kind: emission.kind),
          ),
        );
  }

  Future<void> _loadStationMembers(
    String id,
    Emitter<BusStopState> emit,
  ) async {
    try {
      final members = await _repository.stationGroup(id);
      _emitMembers(members, emit);
    } on Object catch (e, s) {
      _reportError(e, s);
      if (isClosed) return;
      emit(
        state.copyWith(status: BusStopStatus.error, error: AppError.from(e)),
      );
    }
  }

  void _emitMembers(
    List<BusStationMember> members,
    Emitter<BusStopState> emit,
  ) {
    if (isClosed || members.isEmpty) return;
    emit(state.copyWith(status: BusStopStatus.loaded, members: members));
  }

  void _onStationSelected(
    BusStopStationSelected event,
    Emitter<BusStopState> emit,
  ) {
    emit(
      event.stationUid == null
          ? state.copyWith(clearSelection: true)
          : state.copyWith(selectedStationUid: event.stationUid),
    );
  }

  void _onUpdated(BusStopArrivalsUpdated event, Emitter<BusStopState> emit) {
    final changed = !listEquals(event.arrivals, state.arrivals);
    if (event.kind == ArrivalFeedEmissionKind.source) {
      _updateSource(event.arrivals, changed, emit);
    } else {
      _updateDecay(event.arrivals, changed, emit);
    }
  }

  (List<BusStopArrivalItem>, Map<String, List<BusStopArrivalItem>>)
  _arrivalViews(List<BusStopArrival> arrivals) {
    final displays = [
      for (final arrival in arrivals) BusStopArrivalItem(_i18n, arrival),
    ]..sort((a, b) => a.rank.compareTo(b.rank));
    final byStation = <String, List<BusStopArrivalItem>>{};
    for (final item in displays) {
      byStation.putIfAbsent(item.stationId, () => []).add(item);
    }
    return (displays, byStation);
  }

  void _updateDecay(
    List<BusStopArrival> arrivals,
    bool changed,
    Emitter<BusStopState> emit,
  ) {
    if (!changed) return;
    final (displays, byStation) = _arrivalViews(arrivals);
    emit(
      state.copyWith(
        arrivals: arrivals,
        displays: displays,
        arrivalsByStation: byStation,
      ),
    );
  }

  void _updateSource(
    List<BusStopArrival> arrivals,
    bool changed,
    Emitter<BusStopState> emit,
  ) {
    final status = arrivals.isEmpty && state.members.isEmpty
        ? BusStopStatus.empty
        : BusStopStatus.loaded;
    // Repeated source values keep derived objects and freshness unchanged.
    if (!changed) {
      emit(state.copyWith(status: status, clearError: true));
      return;
    }
    final (displays, byStation) = _arrivalViews(arrivals);
    emit(
      state.copyWith(
        status: status,
        arrivals: arrivals,
        displays: displays,
        arrivalsByStation: byStation,
        updatedAt: DateTime.now(),
        clearError: true,
      ),
    );
  }

  void _onFailed(BusStopFailed event, Emitter<BusStopState> emit) {
    emit(state.copyWith(status: BusStopStatus.error, error: event.error));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
