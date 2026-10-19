import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';

class RailBloc extends Bloc<RailEvent, RailState> {
  RailBloc({
    TraRepository? traRepository,
    ThsrRepository? thsrRepository,
  }) : _traRepository = traRepository ?? TraRepository.instance,
       _thsrRepository = thsrRepository ?? ThsrRepository.instance,
       super(const RailInitial()) {
    on<RailSystemChanged>(_onSystemChanged);
    on<RailTimetableRequested>(_onTimetableRequested);
    on<RailTrainStopsRequested>(_onTrainStopsRequested);
    on<RailDelaysUpdated>(_onDelaysUpdated);
  }

  final TraRepository _traRepository;
  final ThsrRepository _thsrRepository;

  // Both handlers run concurrently (no transformer); a slow earlier request
  // can otherwise resolve after a newer one and clobber it.
  var _timetableGeneration = 0;
  var _trainStopsGeneration = 0;

  /// Minutes past midnight for a backend time string (RFC3339 timestamp or a
  /// bare `HH:mm:ss` clock), or null when unparseable.
  static int? _minutesOfDay(String t) {
    final s = _clockPart(t);
    final parts = s.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  static String _clockPart(String time) =>
      time.contains('T') ? time.split('T').last : time;

  bool _withinCutoff(String time, int cutoff, bool isDeparture) {
    final minutes = _minutesOfDay(time);
    if (minutes == null) return true;
    return isDeparture ? minutes >= cutoff : minutes <= cutoff;
  }

  int _compareTimes(String first, String second) =>
      (_minutesOfDay(first) ?? -1).compareTo(_minutesOfDay(second) ?? -1);

  List<T> _sortedFiltered<T>(
    List<T> items,
    String Function(T) departureOf,
    String Function(T) arrivalOf,
    int? cutoff,
    bool isDeparture,
  ) {
    final keyOf = isDeparture ? departureOf : arrivalOf;
    final sorted = [...items]
      ..sort((a, b) => _compareTimes(keyOf(a), keyOf(b)));
    if (cutoff == null) return sorted;
    return sorted
        .where((item) => _withinCutoff(keyOf(item), cutoff, isDeparture))
        .toList();
  }

  // A segment's delay map is a lone live value (a whole map per frame), not an
  // arrival list, so it stays on the feed's passthrough seam.
  StreamSubscription<Map<String, int>>? _delaySub;

  void _onSystemChanged(RailSystemChanged event, Emitter<RailState> emit) {
    // Reset to the pre-query prompt; results only exist after an explicit
    // timetable request for the newly selected system.
    emit(const RailInitial());
  }

  Future<void> _onTimetableRequested(
    RailTimetableRequested event,
    Emitter<RailState> emit,
  ) async {
    final gen = ++_timetableGeneration;
    final system = event.system;
    final originName = event.origin.name;
    final destName = event.destination.name;

    emit(
      RailTimetableLoading(
        system: system,
        originName: originName,
        destName: destName,
        date: event.date,
      ),
    );

    unawaited(
      HiveStore.addRecentOdQuery(
        system: system.name,
        originId: event.origin.id ?? '',
        originName: originName,
        destId: event.destination.id ?? '',
        destName: destName,
      ),
    );

    await _delaySub?.cancel();
    _delaySub = null;

    try {
      await _loadTimetable(event, gen, emit);
    } on Object catch (e) {
      if (gen != _timetableGeneration) return;
      emit(RailError(AppError.from(e)));
    }
  }

  Future<void> _loadTimetable(
    RailTimetableRequested event,
    int gen,
    Emitter<RailState> emit,
  ) async {
    final originId = _stationId(event.origin);
    final destId = _stationId(event.destination);
    final fareFuture = _fareForSystem(event, originId, destId);
    if (event.system == RailSystem.tra) {
      await _loadTraTimetable(event, gen, emit, originId, destId, fareFuture);
    } else {
      await _loadThsrTimetable(event, gen, emit, originId, destId, fareFuture);
    }
  }

  Future<RailFareQuote?> _fareForSystem(
    RailTimetableRequested event,
    String originId,
    String destId,
  ) => event.system == RailSystem.thsr
      ? _loadFares(event.date, originId, destId)
      : Future<RailFareQuote?>.value();

  Future<void> _loadTraTimetable(
    RailTimetableRequested event,
    int gen,
    Emitter<RailState> emit,
    String originId,
    String destId,
    Future<RailFareQuote?> fareFuture,
  ) async {
    final items = await _traRepository.timetable(
      event.date,
      originId,
      destId,
    );
    if (gen != _timetableGeneration) return;
    final fares = await fareFuture;
    emit(
      RailTimetableLoaded(
        system: event.system,
        originName: event.origin.name,
        destName: event.destination.name,
        date: event.date,
        fareQuote: fares,
        traItems: _sortedFiltered(
          items,
          (item) => item.departureTime,
          (item) => item.arrivalTime,
          event.cutoffMinutes,
          event.isDeparture,
        ),
      ),
    );
    _delaySub = ArrivalFeed.passthrough(
      source: () => _traRepository.delay(
        event.date,
        originId,
        destId,
      ),
    ).listen((delays) => add(RailDelaysUpdated(delays)));
  }

  Future<void> _loadThsrTimetable(
    RailTimetableRequested event,
    int gen,
    Emitter<RailState> emit,
    String originId,
    String destId,
    Future<RailFareQuote?> fareFuture,
  ) async {
    final items = await _thsrRepository.timetable(
      event.date,
      originId,
      destId,
    );
    if (gen != _timetableGeneration) return;
    final fares = await fareFuture;
    emit(
      RailTimetableLoaded(
        system: event.system,
        originName: event.origin.name,
        destName: event.destination.name,
        date: event.date,
        fareQuote: fares,
        thsrItems: _sortedFiltered(
          items,
          (item) => item.departureTime,
          (item) => item.arrivalTime,
          event.cutoffMinutes,
          event.isDeparture,
        ),
      ),
    );
  }

  Future<RailFareQuote?> _loadFares(
    String date,
    String originId,
    String destId,
  ) async {
    try {
      return RailFareQuote.thsr(
        fares: await _thsrRepository.fares(date, originId, destId),
      );
    } on Object {
      return null;
    }
  }

  String _stationId(RailStationSelection selection) {
    final id = selection.id;
    return (id != null && id.isNotEmpty) ? id : selection.name;
  }

  @override
  Future<void> close() async {
    await _delaySub?.cancel();
    return super.close();
  }

  void _onDelaysUpdated(RailDelaysUpdated event, Emitter<RailState> emit) {
    final current = state;
    if (current is! RailTimetableLoaded) return;
    if (current.system != RailSystem.tra) return;
    emit(current.copyWith(delays: event.delays));
  }

  Future<void> _onTrainStopsRequested(
    RailTrainStopsRequested event,
    Emitter<RailState> emit,
  ) async {
    final gen = ++_trainStopsGeneration;
    try {
      await _loadTrainStops(event, gen, emit);
    } on Object catch (e) {
      if (gen != _trainStopsGeneration) return;
      emit(RailError(AppError.from(e)));
    }
  }

  RailSystem _currentSystem() {
    final current = state;
    return current is RailTimetableLoaded ? current.system : RailSystem.tra;
  }

  Future<void> _loadTrainStops(
    RailTrainStopsRequested event,
    int gen,
    Emitter<RailState> emit,
  ) async {
    final system = _currentSystem();
    if (system == RailSystem.tra) {
      await _loadTraStops(event, gen, emit);
    } else {
      await _loadThsrStops(event, gen, emit);
    }
  }

  Future<void> _loadTraStops(
    RailTrainStopsRequested event,
    int gen,
    Emitter<RailState> emit,
  ) async {
    final stops = await _traRepository.stops(
      event.date,
      event.trainNo,
    );
    if (gen != _trainStopsGeneration) return;
    emit(
      RailTrainStopsLoaded(
        system: RailSystem.tra,
        trainNo: event.trainNo,
        trainType: '台鐵',
        traStops: stops,
      ),
    );
  }

  Future<void> _loadThsrStops(
    RailTrainStopsRequested event,
    int gen,
    Emitter<RailState> emit,
  ) async {
    final stops = await _thsrRepository.stops(
      event.date,
      event.trainNo,
    );
    if (gen != _trainStopsGeneration) return;
    emit(
      RailTrainStopsLoaded(
        system: RailSystem.thsr,
        trainNo: event.trainNo,
        trainType: '高鐵',
        thsrStops: stops,
      ),
    );
  }
}
