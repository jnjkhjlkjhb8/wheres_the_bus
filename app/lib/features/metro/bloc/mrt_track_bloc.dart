import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_track_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_state.dart';
import 'package:wheres_the_bus/features/metro/data/metro_line_names.dart';
import 'package:wheres_the_bus/features/metro/data/mrt_board_eta.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class MrtTrackBloc extends Bloc<MrtTrackEvent, MrtTrackBlocState> {
  MrtTrackBloc({
    required AppI18n i18n,
    MrtTrackRepository? repository,
    AlightTrackChannel? channel,
    bool Function()? liveActivityEnabled,
    Future<void> Function(String trackId, AlightEvent event)? vibrate,
    BoardEtaStream? boardEtaStream,
  }) : _i18n = i18n,
       _repository = repository ?? MrtTrackRepository.instance,
       _boardEtaStream = boardEtaStream ?? defaultBoardEtaStream,
       _channel = channel,
       _liveActivityEnabled =
           liveActivityEnabled ?? (() => HiveStore.liveActivityEnabled),
       _vibrate = vibrate ?? fireAlightHaptics,
       super(const MrtTrackBlocState()) {
    on<MrtAlightPickStarted>(
      (e, emit) => emit(
        state.copyWith(
          pickArrival: e.arrival,
          clearPickTarget: true,
          pickLead: 0,
          createError: MrtTrackCreateError.none,
        ),
      ),
    );
    on<MrtAlightPickCancelled>(
      (e, emit) => emit(state.copyWith(clearPick: true)),
    );
    on<MrtAlightTargetPicked>(
      (e, emit) => emit(state.copyWith(pickTargetStationId: e.stationId)),
    );
    on<MrtAlightTargetCleared>(
      (e, emit) => emit(state.copyWith(clearPickTarget: true)),
    );
    on<MrtAlightLeadChanged>(
      (e, emit) => emit(state.copyWith(pickLead: e.leadStops)),
    );
    on<MrtTrackRequested>(_onRequested);
    on<MrtTrackUpdated>(_onUpdated);
    on<MrtTrackWatchFailed>(_onWatchFailed);
    on<MrtTrackWatchRecovered>(_onWatchRecovered);
    on<MrtTrackWatchLost>(_onWatchLost);
    on<MrtTrackCancelled>(_onCancelled);
    on<MrtTrackRestored>(_onRestored);
    on<MrtTrackPushTokenReceived>(_onPushToken);
    on<MrtBoardEtaTicked>(_onBoardEta);
  }

  final AppI18n _i18n;
  final MrtTrackRepository _repository;
  final BoardEtaStream _boardEtaStream;
  final AlightTrackChannel? _channel;
  final bool Function() _liveActivityEnabled;
  final Future<void> Function(String trackId, AlightEvent event) _vibrate;

  int? _lastRemaining;

  ResilientSubscription<MrtTrackSession>? _watch;
  StreamSubscription<int>? _boardSub;
  int? _lease;

  /// Line data colours as hex. Android's card colours its bar by distance to
  /// the alight stop instead, so these travel only for iOS's line roundel.
  static const _lineColors = <String, String>{
    'BL': '#0070BD',
    'R': '#E3002C',
    'G': '#008659',
    'O': '#F2A83B',
    'BR': '#C48C31',
    'Y': '#FFDB00',
  };

  /// Stand-in for a station code whose line letters match nothing known, so the
  /// roundel is still drawn rather than left blank.
  static const _defaultLineColor = '#0070BD';

  Future<void> _onRequested(
    MrtTrackRequested e,
    Emitter<MrtTrackBlocState> emit,
  ) async {
    emit(
      state.copyWith(creating: true, createError: MrtTrackCreateError.none),
    );
    try {
      final line = mrtLineOfStation(e.boardStationId);
      final session = await _repository.createTrack(
        carId: e.carId,
        boardStationId: e.boardStationId,
        destStationId: e.destStationId,
        targetStationId: e.targetStationId,
        leadStops: e.leadStops,
        vehicleLabel: metroLineName(_i18n, line),
        lineCode: line,
        lineColorHex: _lineColors[line] ?? _defaultLineColor,
      );
      emit(state.copyWith(boardEtaSeconds: e.boardEtaSeconds, clearPick: true));
      await _adopt(session, emit);
      _subscribeBoardEta(e);
    } on GrpcError catch (err) {
      emit(state.copyWith(creating: false, createError: _mapError(err.code)));
    } on Object catch (err, s) {
      CrashReporter.record(err, s);
      emit(
        state.copyWith(
          creating: false,
          createError: MrtTrackCreateError.generic,
        ),
      );
    }
  }

  Future<void> _onRestored(
    MrtTrackRestored e,
    Emitter<MrtTrackBlocState> emit,
  ) async {
    if (state.session != null) return;
    if (!HiveStore.settingsReady) return;
    final raw = HiveStore.mrtTrackSession;
    if (raw == null) return;
    final session = MrtTrackSession.fromJson(raw);
    if (session.trackId.isEmpty || session.status.isTerminal) {
      await _clearPersisted();
      return;
    }
    // A session that outlived a process restart belongs to a rider who is
    // long since aboard; there is no pre-board reading to restore.
    emit(state.copyWith(session: session, clearBoardEta: true));
    _lease = await _startActivity(session);
    _subscribe(session.trackId);
  }

  /// Watches the boarding station until the tracked train pulls in, then stops.
  void _subscribeBoardEta(MrtTrackRequested e) {
    unawaited(_boardSub?.cancel());
    if (e.trainNumber.isEmpty) return;
    _boardSub =
        _boardEtaStream(
          system: e.system,
          stationId: e.boardStationId,
          trainNumber: e.trainNumber,
        ).listen(
          (seconds) => add(MrtBoardEtaTicked(seconds)),
          // Feed drop → hold the last reading rather than blanking the card.
          // The WatchTrack stream takes over the moment the train is in
          // anyway.
          onError: (Object _) {},
        );
  }

  void _onBoardEta(MrtBoardEtaTicked e, Emitter<MrtTrackBlocState> emit) {
    if (state.session == null) return;
    if (e.seconds > 0) {
      emit(state.copyWith(boardEtaSeconds: e.seconds));
    } else {
      // The train is in: the rider is aboard from here, and the station feed
      // has nothing left to say about this trip.
      unawaited(_boardSub?.cancel());
      _boardSub = null;
      emit(state.copyWith(clearBoardEta: true));
    }
    final session = state.session;
    if (session != null) _pushActivity(session);
  }

  void _onUpdated(MrtTrackUpdated e, Emitter<MrtTrackBlocState> emit) {
    final session = e.session;
    // Ignore frames for a session other than the current one (a late frame
    // from a watch that terminal cleanup already tore down).
    final current = state.session;
    if (current != null && current.trackId != session.trackId) return;

    _maybeVibrate(session);
    if (session.status.isTerminal) {
      emit(state.copyWith(clearSession: true));
      unawaited(_endShowingStatus(session));
      return;
    }
    emit(state.copyWith(session: session));
    _persist(session);
    _pushActivity(session);
  }

  static const _watchLostAfter = Duration(minutes: 2);

  Timer? _watchLostTimer;

  void _onWatchFailed(MrtTrackWatchFailed e, Emitter<MrtTrackBlocState> emit) {
    if (state.session == null) return;
    _watchLostTimer?.cancel();
    _watchLostTimer = Timer(
      _watchLostAfter,
      () => add(const MrtTrackWatchLost()),
    );
  }

  void _onWatchRecovered(
    MrtTrackWatchRecovered e,
    Emitter<MrtTrackBlocState> emit,
  ) {
    _watchLostTimer?.cancel();
    _watchLostTimer = null;
  }

  void _onWatchLost(MrtTrackWatchLost e, Emitter<MrtTrackBlocState> emit) {
    // The stream stayed down for the whole window. End the session rather than
    // leaving a stale bell lit — and show it as 追蹤失效 on the system surface,
    // never a silent disappearance.
    final session = state.session;
    if (session == null) return;
    emit(state.copyWith(clearSession: true));
    unawaited(_endShowingStatus(session, override: MrtTrackStatus.lost));
  }

  Future<void> _onCancelled(
    MrtTrackCancelled e,
    Emitter<MrtTrackBlocState> emit,
  ) async {
    final session = state.session;
    emit(state.copyWith(clearSession: true));
    await _teardown(clearPersisted: true);
    if (session != null) {
      // Best-effort: the local session is already gone, so a failed cancel RPC
      // (offline) must not resurrect the bell — the server session self-ends.
      try {
        await _repository.cancel(session.trackId);
      } on Object catch (err, s) {
        CrashReporter.record(err, s);
      }
    }
  }

  Future<void> _adopt(
    MrtTrackSession session,
    Emitter<MrtTrackBlocState> emit,
  ) async {
    if (session.status.isTerminal) {
      emit(
        state.copyWith(creating: false, createError: MrtTrackCreateError.none),
      );
      return;
    }
    // Rebinding while another session is live (a bell on a different arrival):
    // release the previous watch and Live Activity lease before starting the
    // new one, or the old activity leaks on screen with no owner.
    await _teardown(clearPersisted: false);
    emit(
      state.copyWith(
        session: session,
        creating: false,
        createError: MrtTrackCreateError.none,
      ),
    );
    _persist(session);
    _lease = await _startActivity(session);
    // A session restored or created already past a threshold does not buzz for
    // a crossing that happened before it existed; seeding the baseline is what
    // makes the next real crossing the first one felt.
    _lastRemaining = session.remainingStops;
    _subscribe(session.trackId);
  }

  void _maybeVibrate(MrtTrackSession session) {
    final event = alightEventFor(
      previousRemaining: _lastRemaining,
      remaining: session.remainingStops,
      lead: session.leadStops,
    );
    _lastRemaining = session.remainingStops;
    if (event != null) unawaited(_vibrate(session.trackId, event));
  }

  void _persist(MrtTrackSession session) {
    if (!HiveStore.settingsReady) return;
    unawaited(HiveStore.putMrtTrackSession(session.toJson()));
  }

  void _subscribe(String trackId) {
    unawaited(_watch?.cancel());
    _watch = ResilientSubscription<MrtTrackSession>(
      source: () => _repository.watch(trackId),
      onData: (session) => add(MrtTrackUpdated(session)),
      onFailure: (_) => add(const MrtTrackWatchFailed()),
      onRecovered: () => add(const MrtTrackWatchRecovered()),
    );
  }

  Future<void> _onPushToken(
    MrtTrackPushTokenReceived e,
    Emitter<MrtTrackBlocState> emit,
  ) async {
    final trackId = state.session?.trackId;
    if (trackId == null || trackId.isEmpty) return;
    try {
      await _repository.setPushToken(trackId, e.token);
    } on Object catch (err, s) {
      CrashReporter.record(err, s);
    }
  }

  Future<int?> _startActivity(MrtTrackSession session) async {
    if (!_liveActivityEnabled()) return null;
    return _channel?.start(_content(session));
  }

  void _pushActivity(MrtTrackSession session) {
    final lease = _lease;
    if (lease != null) unawaited(_channel?.update(lease, _content(session)));
  }

  /// How long a terminal reading (已到站 / 追蹤失效) stays visible on the system
  /// surface before the activity is dismissed. An ending must be seen, not
  /// vanish — a silently disappearing 追蹤失效 reads as "still tracking".
  static const _endedLinger = Duration(seconds: 5);

  /// Ends the session by first pushing the terminal state to the Live
  /// Activity, then dismissing it after [_endedLinger]. The lease is captured
  /// locally so a new session started during the linger is unaffected.
  Future<void> _endShowingStatus(
    MrtTrackSession session, {
    MrtTrackStatus? override,
  }) async {
    await _watch?.cancel();
    _watch = null;
    await _boardSub?.cancel();
    _boardSub = null;
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      final ended = override ?? session.status;
      unawaited(_channel?.update(lease, _content(session, ended: ended)));
      Timer(_endedLinger, () => unawaited(_channel?.stop(lease)));
    }
    await _clearPersisted();
  }

  Future<void> _teardown({required bool clearPersisted}) async {
    _watchLostTimer?.cancel();
    _watchLostTimer = null;
    await _watch?.cancel();
    _watch = null;
    await _boardSub?.cancel();
    _boardSub = null;
    final lease = _lease;
    _lease = null;
    if (lease != null) unawaited(_channel?.stop(lease));
    if (clearPersisted) await _clearPersisted();
  }

  Future<void> _clearPersisted() async {
    if (!HiveStore.settingsReady) return;
    await HiveStore.clearMrtTrackSession();
  }

  AlightTrackContent _content(MrtTrackSession s, {MrtTrackStatus? ended}) {
    final board = s.pathStationNames.isNotEmpty ? s.pathStationNames.first : '';
    // The bar runs board→target, one segment per hop.
    final hopCount = max(1, s.targetIndex);
    final remaining = s.remainingStops.clamp(0, hopCount);
    final waiting = ended == null && state.waitingToBoard;
    return AlightTrackContent(
      mode: AlightTrackMode.metro,
      phase: switch (ended) {
        MrtTrackStatus.arrived => AlightTrackPhase.arrived,
        MrtTrackStatus.lost || MrtTrackStatus.stale => AlightTrackPhase.lost,
        _ when waiting => AlightTrackPhase.waiting,
        _ when remaining <= s.leadStops + 1 => AlightTrackPhase.approaching,
        _ => AlightTrackPhase.riding,
      },
      // The rider knows which line they are on, not which trip id they are
      // on: 板南線 1021 reads, 列車 12345 does not.
      vehicleLabel: metroLineName(_i18n, s.line),
      vehicleId: s.carId,
      boardStation: board,
      targetStation: s.targetStationName,
      nextStation: s.nextStationName,
      hopCount: hopCount,
      currentIndex: s.currentIndex.clamp(0, hopCount),
      remainingStops: remaining,
      leadStops: s.leadStops,
      lineCode: s.line,
      lineColorHex: _lineColors[s.line] ?? _defaultLineColor,
      trackId: s.trackId,
      // Printed as the feed reported it — nothing counts down locally between
      // the ~15 s frames.
      etaMinutes: waiting ? max(1, (state.boardEtaSeconds! / 60).ceil()) : null,
    );
  }

  static MrtTrackCreateError _mapError(int code) => switch (code) {
    StatusCode.invalidArgument => MrtTrackCreateError.notReachable,
    StatusCode.notFound => MrtTrackCreateError.notFound,
    _ => MrtTrackCreateError.generic,
  };

  @override
  Future<void> close() async {
    await _teardown(clearPersisted: false);
    return super.close();
  }
}
