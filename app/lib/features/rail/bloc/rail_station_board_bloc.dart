import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_state.dart';

class RailStationBoardBloc
    extends Bloc<RailStationBoardEvent, RailStationBoardState> {
  RailStationBoardBloc({
    required this.system,
    required this.stationId,
    RailBoardDirection initialDirection = RailBoardDirection.forward,
    TraRepository? traRepository,
    ThsrRepository? thsrRepository,
    DateTime Function()? clock,
  }) : _traRepository = traRepository ?? TraRepository.instance,
       _thsrRepository = thsrRepository ?? ThsrRepository.instance,
       _clock = clock ?? DateTime.now,
       super(RailStationBoardLoading(direction: initialDirection)) {
    on<RailStationBoardRequested>(_onRequested);
    on<RailStationBoardDelaysUpdated>(_onDelaysUpdated);
  }

  final RailSystem system;
  final String stationId;
  final TraRepository _traRepository;
  final ThsrRepository _thsrRepository;
  final DateTime Function() _clock;

  static final _date = DateFormat('yyyy-MM-dd');
  static final _time = DateFormat('HH:mm:ss');

  /// Direction switches run concurrently (no transformer), so a slow earlier
  /// request must not land on top of a newer one.
  var _generation = 0;

  StreamSubscription<Map<String, int>>? _delaySub;

  Future<void> _onRequested(
    RailStationBoardRequested event,
    Emitter<RailStationBoardState> emit,
  ) async {
    final generation = ++_generation;
    final direction = event.direction;
    final carriedDelays = switch (state) {
      RailStationBoardLoaded(:final delays) => delays,
      _ => const <String, int>{},
    };
    emit(RailStationBoardLoading(direction: direction));

    final now = _clock();
    try {
      final departures = system == RailSystem.tra
          ? await _traRepository.stationBoard(
              stationId: stationId,
              date: _date.format(now),
              after: _time.format(now),
              direction: direction,
            )
          : await _thsrRepository.stationBoard(
              stationId: stationId,
              date: _date.format(now),
              after: _time.format(now),
              direction: direction,
            );
      if (generation != _generation) return;
      emit(
        RailStationBoardLoaded(
          direction: direction,
          departures: departures,
          delays: carriedDelays,
        ),
      );
      _subscribeDelays();
    } on Object catch (e) {
      if (generation != _generation) return;
      emit(
        RailStationBoardFailure(direction: direction, error: AppError.from(e)),
      );
    }
  }

  void _subscribeDelays() {
    if (system != RailSystem.tra || _delaySub != null) return;
    _delaySub =
        ArrivalFeed.passthrough(
          source: () => _traRepository.delay(
            _date.format(_clock()),
            stationId,
            stationId,
          ),
        ).listen((delays) {
          if (!isClosed) add(RailStationBoardDelaysUpdated(delays));
        });
  }

  void _onDelaysUpdated(
    RailStationBoardDelaysUpdated event,
    Emitter<RailStationBoardState> emit,
  ) {
    final current = state;
    if (current is! RailStationBoardLoaded) return;
    emit(
      current.copyWith(
        delays: event.delays,
        delaysUpdatedAt: _clock(),
      ),
    );
  }

  @override
  Future<void> close() async {
    await _delaySub?.cancel();
    return super.close();
  }
}
