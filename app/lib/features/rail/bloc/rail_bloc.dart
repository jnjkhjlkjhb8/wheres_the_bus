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
    final s = t.contains('T') ? t.split('T').last : t;
    final parts = s.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  List<T> _sortedFiltered<T>(
    List<T> items,
    String Function(T) departureOf,
    String Function(T) arrivalOf,
    int? cutoff,
    bool isDeparture,
  ) {
    final keyOf = isDeparture ? departureOf : arrivalOf;
    final sorted = [...items]
      ..sort(
        (a, b) => (_minutesOfDay(keyOf(a)) ?? -1).compareTo(
          _minutesOfDay(keyOf(b)) ?? -1,
        ),
      );
    if (cutoff == null) return sorted;
    return sorted.where((item) {
      final m = _minutesOfDay(keyOf(item));
      if (m == null) return true;
      return isDeparture ? m >= cutoff : m <= cutoff;
    }).toList();
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
      final originId = _stationId(event.origin);
      final destId = _stationId(event.destination);
      final fareFuture = system == RailSystem.thsr
          ? _loadFares(event.date, originId, destId)
          : Future<RailFareQuote?>.value();
      if (system == RailSystem.tra) {
        final items = await _traRepository.timetable(
          event.date,
          originId,
          destId,
        );
        if (gen != _timetableGeneration) return;
        final fares = await fareFuture;
        emit(
          RailTimetableLoaded(
            system: system,
            originName: originName,
            destName: destName,
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
      } else {
        final items = await _thsrRepository.timetable(
          event.date,
          originId,
          destId,
        );
        if (gen != _timetableGeneration) return;
        final fares = await fareFuture;
        emit(
          RailTimetableLoaded(
            system: system,
            originName: originName,
            destName: destName,
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
    } on Object catch (e) {
      if (gen != _timetableGeneration) return;
      emit(RailError(AppError.from(e)));
    }
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
      final current = state;
      final system = current is RailTimetableLoaded
          ? current.system
          : RailSystem.tra;
      if (system == RailSystem.tra) {
        final stops = await _traRepository.stops(
          event.date,
          event.trainNo,
        );
        if (gen != _trainStopsGeneration) return;
        emit(
          RailTrainStopsLoaded(
            system: system,
            trainNo: event.trainNo,
            trainType: '台鐵',
            traStops: stops,
          ),
        );
      } else {
        final stops = await _thsrRepository.stops(
          event.date,
          event.trainNo,
        );
        if (gen != _trainStopsGeneration) return;
        emit(
          RailTrainStopsLoaded(
            system: system,
            trainNo: event.trainNo,
            trainType: '高鐵',
            thsrStops: stops,
          ),
        );
      }
    } on Object catch (e) {
      if (gen != _trainStopsGeneration) return;
      emit(RailError(AppError.from(e)));
    }
  }
}
