import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_event.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_state.dart';

class NearbyBloc extends Bloc<NearbyEvent, NearbyState> {
  NearbyBloc({NearRepository? repository})
    : _repository = repository ?? NearRepository.instance,
      super(const NearbyState()) {
    on<NearbyRequested>(_onRequested);
    on<NearbyRetried>(_onRetried);
    on<NearbyStationsReceived>(_onStationsReceived);
    on<NearbyStreamFailed>(_onStreamFailed);
  }

  final NearRepository _repository;

  /// The most recently issued query, kept even on failure so [NearbyRetried]
  /// replays the same dragged viewport instead of falling back to GPS.
  NearbyRequested? _lastAttempted;

  /// Issue counter, compared after the GPS await so a query whose fix resolved
  /// late doesn't enqueue behind the newer one that overtook it.
  var _issued = 0;

  /// Whether the query in flight is already a replay of one a dropped stream
  /// swallowed — see [_onStreamFailed]. Bounds the recovery to a single extra
  /// attempt, so a backend that is genuinely down still reaches the rider.
  var _replayed = false;

  StreamController<NearQuery>? _queries;

  // Cancelled by _detachStream when the subscription is replaced or closed.
  // ignore: cancel_subscriptions
  StreamSubscription<List<NearStationViewModel>>? _responses;

  Future<void> _onRetried(
    NearbyRetried event,
    Emitter<NearbyState> emit,
  ) async {
    final last = _lastAttempted;
    if (last == null) return;
    await _send(last, emit);
  }

  Future<void> _onRequested(
    NearbyRequested event,
    Emitter<NearbyState> emit,
  ) async {
    _lastAttempted = event;
    _replayed = false;
    await _send(event, emit);
  }

  void _onStationsReceived(
    NearbyStationsReceived event,
    Emitter<NearbyState> emit,
  ) {
    _replayed = false;
    final stations = [...event.stations]
      ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    emit(state.copyWith(stations: stations, loading: false, clearError: true));
  }

  void _onStreamFailed(NearbyStreamFailed event, Emitter<NearbyState> emit) {
    // A broken gRPC stream stays broken, so drop it here and let the next
    // query open a fresh one.
    _detachStream();
    if (!state.loading) return;
    // A query *was* in flight, and its answer is now never coming. Replay it
    // once on a fresh stream — only a second failure is the backend saying no.
    final pending = _lastAttempted;
    if (!_replayed && pending != null) {
      _replayed = true;
      add(const NearbyRetried());
      return;
    }
    _replayed = false;
    emit(state.copyWith(loading: false, error: AppError.from(event.error)));
  }

  Future<void> _send(NearbyRequested event, Emitter<NearbyState> emit) async {
    final issue = ++_issued;
    emit(state.copyWith(loading: true, clearError: true));
    final double lat;
    final double lon;
    if (event.lat == null || event.lon == null) {
      try {
        final position = await LocationService.instance.currentPosition();
        lat = position.latitude;
        lon = position.longitude;
      } on Object catch (e) {
        if (issue != _issued) return;
        emit(state.copyWith(loading: false, error: AppError.from(e)));
        return;
      }
      if (issue != _issued) return;
    } else {
      lat = event.lat!;
      lon = event.lon!;
    }
    _attachStream();
    _queries?.add(NearQuery(lat: lat, lon: lon, radius: event.radius));
  }

  void _attachStream() {
    if (_queries != null) return;
    final queries = StreamController<NearQuery>();
    _queries = queries;
    _responses = _repository
        .near(queries.stream)
        .listen(
          (stations) => add(NearbyStationsReceived(stations)),
          onError: (Object error) => add(NearbyStreamFailed(error)),
          onDone: _detachStream,
        );
  }

  void _detachStream() {
    final responses = _responses;
    final queries = _queries;
    _responses = null;
    _queries = null;
    unawaited(responses?.cancel());
    unawaited(queries?.close());
  }

  @override
  Future<void> close() {
    _detachStream();
    return super.close();
  }
}
