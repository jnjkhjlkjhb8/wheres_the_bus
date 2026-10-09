import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/firebase_telemetry.dart';
import 'package:wheres_the_bus/data/decoders/fare_decoder.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/firebase_repository.dart';
import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';

class BusRouteBloc extends Bloc<BusRouteEvent, BusRouteState> {
  BusRouteBloc({
    required this.subRouteUid,
    bool autoStart = true,
    BusRepository? busRepository,
    FirebaseRepository? firebaseRepository,
    RemindersRepository? remindersRepository,
  }) : _bus = busRepository ?? BusRepository.instance,
       _firebase = firebaseRepository ?? FirebaseRepository.instance,
       _reminders = remindersRepository ?? RemindersRepository.instance,
       super(const BusRouteState()) {
    on<BusRouteStarted>(_onStarted);
    on<BusRouteDirectionToggled>(_onDirectionToggled);
    on<BusRouteEtaUpdated>(_onEtaUpdated);
    on<BusRouteDetailsUpdated>(_onDetailsUpdated);
    on<BusRoutePinnedReminderArmed>(_onPinnedReminderArmed);
    on<BusRouteStreamFailed>(_onStreamFailed);
    on<BusRouteStreamRecovered>(_onStreamRecovered);
    if (autoStart) add(const BusRouteStarted());
  }

  final String subRouteUid;
  final BusRepository _bus;
  final FirebaseRepository _firebase;
  final RemindersRepository _reminders;
  // Replace policy + 15s decay live inside the feed; the bloc keys the emitted
  // list into etaMap on arrival (etaKey), preserving the map-shaped state.
  final _feed = ArrivalFeed<BusStopEtaViewModel>.replace(
    decay: (e, now) => e.decayed(now),
  );
  StreamSubscription<ArrivalFeedEmission<BusStopEtaViewModel>>? _etaSub;

  static String etaKey(BusStopEtaViewModel eta) => eta.sequence > 0
      ? 'seq:${eta.direction}:${eta.sequence}'
      : 'uid:${eta.stopUid}';

  Future<void> _onStarted(
    BusRouteStarted _,
    Emitter<BusRouteState> emit,
  ) async {
    await _etaSub?.cancel();
    _etaSub = null;
    emit(
      state.copyWith(
        loading: true,
        clearError: true,
        reminders: _reminders.active(subRouteUid),
      ),
    );
    try {
      final route = await _bus.routeStatic(subRouteUid);
      emit(
        state.copyWith(
          route: route,
          fare: route.fare,
          bufferSequences: decodeBufferSequences(route.fare),
          // A return-only sub-route has no outbound stops; opening on
          // direction 0 would show an empty timeline.
          direction: route.soleDirection ?? state.direction,
          loading: false,
        ),
      );

      _etaSub = _feed
          .watch(
            source: () => _bus.routeEta(subRouteUid),
            onFailure: (e) => add(BusRouteStreamFailed(e)),
            onRecovered: () => add(const BusRouteStreamRecovered()),
          )
          .listen(
            // Decay re-emissions carry the same shape as source frames here;
            // the route bloc has no freshness timestamp to protect, so it
            // forwards every emission regardless of kind.
            (emission) => add(
              BusRouteEtaUpdated({
                for (final e in emission.arrivals) etaKey(e): e,
              }),
            ),
          );

      final details = await _loadDetails();
      if (details != null) {
        add(
          BusRouteDetailsUpdated(
            daily: details.daily,
            fare: details.fare,
          ),
        );
      }
    } on Object catch (e) {
      emit(state.copyWith(loading: false, error: AppError.from(e)));
    }
  }

  Future<({BusDailyTimetable? daily, BusFareInfo? fare})?>
  _loadDetails() async {
    BusDailyTimetable? daily;
    try {
      daily = await _bus.routeDaily(subRouteUid);
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
      daily = null;
    }
    final fare = state.fare;
    if (daily == null && fare == null) return null;
    return (daily: daily, fare: fare);
  }

  void _onDirectionToggled(
    BusRouteDirectionToggled event,
    Emitter<BusRouteState> emit,
  ) {
    emit(state.copyWith(direction: event.direction));
  }

  void _onEtaUpdated(BusRouteEtaUpdated event, Emitter<BusRouteState> emit) {
    // The feed guards empty frames upstream; this stays a defensive no-op.
    if (event.etaMap.isEmpty && state.etaMap.isNotEmpty) return;
    emit(state.copyWith(etaMap: event.etaMap, updatedAt: DateTime.now()));
  }

  void _onDetailsUpdated(
    BusRouteDetailsUpdated event,
    Emitter<BusRouteState> emit,
  ) {
    emit(
      state.copyWith(
        daily: event.daily,
        fare: event.fare,
        bufferSequences: decodeBufferSequences(event.fare),
      ),
    );
  }

  static const _reminderTtl = Duration(hours: 2);

  // A pinned reminder fires one stop before the alight target.
  static const _pinnedLeadMinutes = 1;

  // Arms a one-shot arrival reminder for the tracked vehicle: carries the
  // pinned plate and a one-stop lead, and mirrors its state into the local
  // RemindersRepository so it survives navigation.
  Future<void> _onPinnedReminderArmed(
    BusRoutePinnedReminderArmed event,
    Emitter<BusRouteState> emit,
  ) async {
    // Already armed on this stop by a prior pin: leave it be.
    if (state.reminders.containsKey(event.stopUid)) return;
    final expiresAt = DateTime.now().add(_reminderTtl);
    emit(
      state.copyWith(
        reminders: {...state.reminders, event.stopUid: 'pending'},
      ),
    );
    try {
      final receipt = await _firebase.createArrivalReminder(
        routeType: 'bus',
        routeKey: subRouteUid,
        stopKey: event.stopUid,
        direction: '${state.direction}',
        leadMinutes: _pinnedLeadMinutes,
        expiresAt: expiresAt,
        plate: event.plate,
        alightEvent: event.event.name,
      );
      if (emit.isDone) return;
      emit(
        state.copyWith(
          reminders: {...state.reminders, event.stopUid: receipt.reminderId},
        ),
      );
      await _reminders.put(
        subRouteUid,
        event.stopUid,
        receipt.reminderId,
        expiresAt,
      );
      unawaited(
        FirebaseTelemetry.instance.arrivalReminderChanged(
          routeType: 'bus',
          routeKey: subRouteUid,
          enabled: true,
          leadMinutes: _pinnedLeadMinutes,
        ),
      );
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
      if (emit.isDone) return;
      emit(
        state.copyWith(
          reminders: Map.of(state.reminders)..remove(event.stopUid),
        ),
      );
    }
  }

  void _onStreamFailed(
    BusRouteStreamFailed event,
    Emitter<BusRouteState> emit,
  ) {
    emit(state.copyWith(error: event.error));
  }

  void _onStreamRecovered(
    BusRouteStreamRecovered _,
    Emitter<BusRouteState> emit,
  ) {
    emit(state.copyWith(clearError: true));
  }

  @override
  Future<void> close() async {
    await _etaSub?.cancel();
    return super.close();
  }
}
