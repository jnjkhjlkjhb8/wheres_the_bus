import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';

class RailTrainBloc extends Bloc<RailTrainEvent, RailTrainState> {
  RailTrainBloc({
    required this.type,
    required this.trainNo,
    required this.date,
    this.userOrigin,
    this.userDest,
    TraRepository? tra,
    ThsrRepository? thsr,
  }) : _tra = tra ?? TraRepository.instance,
       _thsr = thsr ?? ThsrRepository.instance,
       super(const RailTrainState()) {
    on<RailTrainStarted>(_onStarted);
    on<RailTrainDelayUpdated>(_onDelayUpdated);
  }

  final String type;
  final String trainNo;

  /// Service date in `yyyy-MM-dd`.
  final String date;

  /// The stations the caller actually searched for, when this train was
  /// opened from an O/D timetable result rather than by train number alone.
  /// Drives which fare is fetched and treated as primary — see [_loadFares].
  final String? userOrigin;
  final String? userDest;

  final TraRepository _tra;
  final ThsrRepository _thsr;
  StreamSubscription<Map<String, int>>? _delaySub;

  bool get _isThsr => type == '高鐵';

  Future<void> _onStarted(
    RailTrainStarted event,
    Emitter<RailTrainState> emit,
  ) async {
    emit(const RailTrainState());
    try {
      final List<RailTrainStop> stops;
      if (_isThsr) {
        final raw = await _thsr.stops(date, trainNo);
        stops = raw
            .map(
              (s) => RailTrainStop(
                name: s.stationName,
                arrive: s.arrivalTime,
                depart: s.departureTime,
              ),
            )
            .toList();
      } else {
        final raw = await _tra.stops(date, trainNo);
        stops = raw
            .map(
              (s) => RailTrainStop(
                name: s.stationName,
                arrive: s.arrivalTime,
                depart: s.departureTime,
              ),
            )
            .toList();
      }

      if (stops.isEmpty) {
        emit(const RailTrainState(status: RailTrainStatus.empty));
        return;
      }

      final (fullFare, userFare) = await _loadFares(stops);
      emit(
        RailTrainState(
          status: RailTrainStatus.loaded,
          stops: stops,
          fullFare: fullFare,
          userFare: userFare,
        ),
      );

      if (!_isThsr && stops.length >= 2 && !isClosed) {
        unawaited(_delaySub?.cancel());
        _delaySub = _tra.delay(date, stops.first.name, stops.last.name).listen(
          (m) {
            if (!isClosed) add(RailTrainDelayUpdated(m[trainNo] ?? 0));
          },
          onError: (Object _) {}, // keep last value; never surface as error
        );
      }
    } on Object catch (e) {
      final error = AppError.from(e);
      emit(
        RailTrainState(
          status: error is NotFoundError
              ? RailTrainStatus.empty
              : RailTrainStatus.error,
          error: error,
        ),
      );
    }
  }

  Future<(RailFareQuote?, RailFareQuote?)> _loadFares(
    List<RailTrainStop> stops,
  ) async {
    final originName = stops.first.name;
    final destName = stops.last.name;
    final hasUserSegment = userOrigin != null && userDest != null;

    if (!hasUserSegment) {
      return (await _loadFare(originName, destName), null);
    }
    // The user's segment can coincide with the train's full run (they
    // searched its terminal stations) — avoid quoting the same fare via two
    // separate RPCs in that case.
    if (userOrigin == originName && userDest == destName) {
      final fare = await _loadFare(originName, destName);
      return (fare, fare);
    }
    final results = await Future.wait([
      _loadFare(originName, destName),
      _loadFare(userOrigin!, userDest!),
    ]);
    return (results[0], results[1]);
  }

  Future<RailFareQuote?> _loadFare(String originName, String destName) async {
    try {
      // The router resolves station names to ids, so the stop names go straight
      // to the fare RPC — the app no longer keeps a local station table.
      if (_isThsr) {
        return RailFareQuote.thsr(
          fares: await _thsr.fares(date, originName, destName),
        );
      }
      return RailFareQuote.tra(
        fares: await _tra.fares(originName, destName),
        trainType: type,
      );
    } on Object {
      return null;
    }
  }

  void _onDelayUpdated(
    RailTrainDelayUpdated event,
    Emitter<RailTrainState> emit,
  ) {
    if (state.status != RailTrainStatus.loaded) return;
    emit(
      state.copyWith(
        liveDelayMinutes: event.minutes,
        delayUpdatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> close() {
    unawaited(_delaySub?.cancel());
    return super.close();
  }
}
