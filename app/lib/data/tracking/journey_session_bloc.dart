import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/data/tracking/leg_eta_source.dart';

class JourneySessionBloc
    extends Bloc<JourneySessionEvent, JourneySessionState> {
  JourneySessionBloc({
    LegEtaStream etaStream = defaultLegEtaStream,
    RouteEtaStream routeEtaStream = defaultRouteEtaStream,
    RailTrackStream railTrackStream = defaultRailTrackStream,
    AlightTrackChannel? channel,
    Stream<Position> Function()? positions,
    bool Function()? liveActivityEnabled,
    Future<void> Function(String sessionId, AlightEvent event)? vibrate,
    this.sessionTimeout = const Duration(hours: 8),
    this.trackOnlyLinger = const Duration(minutes: 2),
  }) : _etaStream = etaStream,
       _routeEtaStream = routeEtaStream,
       _railTrackStream = railTrackStream,
       _channel = channel,
       _positions = positions,
       _liveActivityEnabled =
           liveActivityEnabled ??
           (() => SettingsRepository.instance.liveActivityEnabled),
       _vibrate = vibrate ?? fireAlightHaptics,
       super(const JourneySessionState()) {
    on<JourneyStarted>(_onStarted);
    on<BoardConfirmed>(_onBoarded);
    on<AlightConfirmed>(_onAlighted);
    on<JourneyCancelled>(_onCancelled);
    on<EtaTicked>(_onEta);
    on<ProgressTicked>(_onProgress);
    on<PinnedStopsUpdated>(_onPinnedStopsUpdated);
    on<RailTrackTicked>(_onRailTrack);
  }

  final LegEtaStream _etaStream;
  final RouteEtaStream _routeEtaStream;
  final RailTrackStream _railTrackStream;
  final AlightTrackChannel? _channel;
  final Stream<Position> Function()? _positions;

  /// Injected so tests can start a session without touching Hive. Defaults to
  /// the user's setting.
  final bool Function() _liveActivityEnabled;

  /// ActivityKit hard-caps activities at 8h; the session ends itself first.
  final Duration sessionTimeout;

  /// How long a trackOnly session keeps showing 進站中 after arrival before
  /// ending itself, when no follow-up ETA frame reveals the bus has left.
  final Duration trackOnlyLinger;

  StreamSubscription<Duration?>? _etaSub;
  StreamSubscription<List<BusStopEtaViewModel>>? _routeEtaSub;
  StreamSubscription<RailTrackFrame>? _railSub;
  StreamSubscription<Position>? _posSub;
  Timer? _timeout;
  Timer? _linger;
  bool _trackedArrived = false;

  /// Bumped on every [JourneyStarted]; see class doc.
  int _generation = 0;

  /// Lease on the shared [AlightTrackChannel]'s current card, handed back by
  /// `start`. Null until this journey has one.
  int? _lease;

  String _trackId = '';

  final Future<void> Function(String sessionId, AlightEvent event) _vibrate;

  /// Stops remaining on the previous card push, so a buzz fires on the
  /// crossing rather than on every frame sitting at the threshold. Null while
  /// waiting — see [_maybeVibrate].
  int? _lastRemaining;

  Future<void> _onStarted(
    JourneyStarted event,
    Emitter<JourneySessionState> emit,
  ) async {
    if (event.legs.isEmpty) return;
    if (!_liveActivityEnabled()) return;
    _timeout?.cancel();
    _timeout = Timer(sessionTimeout, () => add(const JourneyCancelled()));
    _linger?.cancel();
    _trackedArrived = false;
    final generation = ++_generation;
    // Unique per session so one ride's tombstone can never refuse the next
    // one's card; the clock is enough, sessions are minutes apart.
    _trackId =
        '${AlightTrackContent.localTrackIdPrefix}'
        '${DateTime.now().microsecondsSinceEpoch}';
    emit(
      JourneySessionState(
        phase: JourneyPhase.waiting,
        legs: event.legs,
        trackOnly: event.trackOnly,
        plate: event.plate,
        leadStops: event.leadStops,
      ),
    );
    if (state.isRailTrack) {
      _subscribeRailTracking(event.legs.first, generation);
    } else {
      _subscribeEta(event.legs.first, generation);
      _subscribeRouteEta(
        event.legs.first,
        event.trackOnly,
        event.plate,
        generation,
      );
    }
    final lease = await _channel?.start(_content(state));
    if (generation == _generation) {
      _lease = lease;
    } else if (lease != null) {
      // Another journey started (or this one was cancelled — _end bumps the
      // generation) while the start round-trip was in flight: nothing will
      // ever stop this lease through _end, so release it here.
      unawaited(_channel?.stop(lease));
    }
  }

  void _onBoarded(BoardConfirmed _, Emitter<JourneySessionState> emit) {
    if (state.phase != JourneyPhase.waiting || state.trackOnly) return;
    unawaited(_etaSub?.cancel());
    emit(
      state.copyWith(
        phase: JourneyPhase.riding,
        clearEta: true,
        nextStopIndex: 0,
        suggestBoarding: false,
      ),
    );
    _subscribePositions();
    _pushUpdate();
  }

  void _onAlighted(AlightConfirmed _, Emitter<JourneySessionState> emit) {
    if (state.phase != JourneyPhase.riding) return;
    unawaited(_posSub?.cancel());
    if (state.isLastLeg) {
      _end(emit);
      return;
    }
    final next = state.legIndex + 1;
    emit(
      state.copyWith(
        phase: JourneyPhase.waiting,
        legIndex: next,
        clearEta: true,
        nextStopIndex: 0,
        suggestBoarding: false,
      ),
    );
    _subscribeEta(state.legs[next], _generation);
    _pushUpdate();
  }

  void _onCancelled(JourneyCancelled event, Emitter<JourneySessionState> emit) {
    if (state.phase == JourneyPhase.idle) return;
    _end(emit, userInitiated: event.userInitiated);
  }

  void _onEta(EtaTicked event, Emitter<JourneySessionState> emit) {
    if (event.generation != _generation) return; // stale journey
    if (state.phase != JourneyPhase.waiting) return;
    final arrived = event.eta != null && event.eta! <= Duration.zero;
    // trackOnly never rides, so 進站中 is the terminal display, not a
    // boarding prompt.
    emit(
      state.copyWith(
        eta: event.eta,
        suggestBoarding: arrived && !state.trackOnly,
      ),
    );
    _pushUpdate();
    if (!state.trackOnly) return;
    if (arrived && !_trackedArrived) {
      _trackedArrived = true;
      _linger = Timer(trackOnlyLinger, () => add(const JourneyCancelled()));
    } else if (_trackedArrived &&
        event.eta != null &&
        event.eta! > const Duration(minutes: 1)) {
      // The ETA jumped back up after arrival: the tracked bus has left and
      // the stream now counts down the following one — end the session.
      add(const JourneyCancelled());
    }
  }

  void _onProgress(ProgressTicked event, Emitter<JourneySessionState> emit) {
    if (event.generation != _generation) return; // stale journey
    if (state.phase != JourneyPhase.riding) return;
    if (event.nextStopIndex <= state.nextStopIndex) return;
    emit(state.copyWith(nextStopIndex: event.nextStopIndex));
    _pushUpdate();
  }

  void _onPinnedStopsUpdated(
    PinnedStopsUpdated event,
    Emitter<JourneySessionState> emit,
  ) {
    if (event.generation != _generation) return; // stale journey
    if (state.phase != JourneyPhase.waiting) return;
    // A frame that can't resolve the target stop or the pinned plate (bus
    // momentarily between stops) leaves the prior stops-remaining in place
    // rather than blanking the Live Activity's 還剩 N 站 back to null.
    if (event.stopsRemaining == null) return;
    emit(state.copyWith(pinnedStopsRemaining: event.stopsRemaining));
    _pushUpdate();
  }

  void _end(Emitter<JourneySessionState> emit, {bool userInitiated = false}) {
    unawaited(_etaSub?.cancel());
    unawaited(_routeEtaSub?.cancel());
    unawaited(_railSub?.cancel());
    unawaited(_posSub?.cancel());
    _timeout?.cancel();
    _linger?.cancel();
    // Invalidates any in-flight events and, crucially, an _onStarted start
    // round-trip that hasn't resolved yet — its generation check will see
    // the bump and release the lease instead of adopting it post-mortem.
    _generation++;
    emit(state.copyWith(phase: JourneyPhase.done, suggestBoarding: false));
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      unawaited(_channel?.stop(lease));
    } else if (userInitiated) {
      // No lease to present, and a rider asking for the card to go. Honour it
      // unarbitrated: see JourneyCancelled.userInitiated.
      unawaited(_channel?.stopAny());
    }
  }

  /// Pushes [_content] through the shared channel under this journey's
  /// current lease; a no-op once another owner has superseded it.
  void _pushUpdate() {
    final content = _content(state);
    final lease = _lease;
    if (lease != null) unawaited(_channel?.update(lease, content));
    _maybeVibrate(content);
  }

  void _maybeVibrate(AlightTrackContent content) {
    if (content.phase == AlightTrackPhase.waiting) {
      _lastRemaining = null;
      return;
    }
    final event = alightEventFor(
      previousRemaining: _lastRemaining,
      remaining: content.remainingStops,
      lead: content.leadStops,
    );
    _lastRemaining = content.remainingStops;
    if (event != null) {
      unawaited(_vibrate(_trackId, event));
    }
  }

  void _subscribeEta(JourneyLeg leg, int generation) {
    unawaited(_etaSub?.cancel());
    // Stream error (gRPC drop) → fall back to the scheduled countdown, per
    // spec: never blank the card mid-journey.
    _etaSub = _etaStream(leg).listen(
      (eta) => add(EtaTicked(eta, generation: generation)),
      onError: (Object _) {
        unawaited(_etaSub?.cancel());
        _etaSub = scheduledCountdown(leg.scheduledDeparture).listen(
          (eta) => add(EtaTicked(eta, generation: generation)),
        );
      },
    );
  }

  /// A pinned (plate-tracked) trackOnly session additionally tracks the
  /// pinned vehicle's live stop-distance from the alight stop. Unpinned and
  /// MaaS (non-trackOnly) sessions never subscribe here.
  void _subscribeRouteEta(
    JourneyLeg leg,
    bool trackOnly,
    String? plate,
    int generation,
  ) {
    unawaited(_routeEtaSub?.cancel());
    _routeEtaSub = null;
    if (!trackOnly || plate == null) return;
    final routeKey = leg.identity.routeKey;
    if (routeKey.isEmpty) return;
    // Stream error (gRPC drop) → stopsRemaining simply stops updating; the
    // card keeps its last-known value rather than going blank.
    _routeEtaSub = _routeEtaStream(routeKey).listen(
      (etas) => add(
        PinnedStopsUpdated(
          _pinnedStopsRemaining(etas, leg, plate),
          generation: generation,
        ),
      ),
      onError: (Object _) {},
    );
  }

  int? _pinnedStopsRemaining(
    List<BusStopEtaViewModel> etas,
    JourneyLeg leg,
    String plate,
  ) {
    final direction = leg.identity.direction;
    final inDirection = direction.isEmpty
        ? etas
        : etas.where((e) => '${e.direction}' == direction);

    BusStopEtaViewModel? target;
    BusStopEtaViewModel? plateStop;
    // e.plate is server-normalized (trimmed + upper-cased); the tracked
    // plate comes from the raw position feed and isn't. Normalize only for
    // this comparison — state/Live Activity keep the plate as tracked.
    final normalizedPlate = plate.trim().toUpperCase();
    for (final e in inDirection) {
      if (e.stopUid == leg.identity.departureStopKey) target = e;
      if (e.plate.isNotEmpty && e.plate == normalizedPlate) {
        if (plateStop == null || e.sequence < plateStop.sequence) {
          plateStop = e;
        }
      }
    }
    if (target == null || plateStop == null) return null;
    final diff = target.sequence - plateStop.sequence;
    return diff < 0 ? 0 : diff;
  }

  /// A rail trackOnly session derives its live 還剩 N 站 / progress / ETA from
  /// the leg's carried timetable + live TRA delay (see
  /// [defaultRailTrackStream]).
  void _subscribeRailTracking(JourneyLeg leg, int generation) {
    unawaited(_railSub?.cancel());
    _railSub = _railTrackStream(leg).listen(
      (f) => add(
        RailTrackTicked(
          eta: f.etaToAlight,
          remainingStops: f.remainingStops,
          progress: f.progress,
          nextStop: f.nextStop,
          aboard: f.aboard,
          etaToBoard: f.etaToBoard,
          delay: f.delay,
          generation: generation,
        ),
      ),
      onError: (Object _) {},
    );
  }

  void _onRailTrack(RailTrackTicked e, Emitter<JourneySessionState> emit) {
    if (e.generation != _generation) return; // stale journey
    if (state.phase != JourneyPhase.waiting) return;
    final arrived = e.eta <= Duration.zero;
    emit(
      state.copyWith(
        // Before boarding the meaningful countdown is to the train's departure,
        // not to a stop the rider cannot reach yet.
        eta: e.aboard ? e.eta : e.etaToBoard,
        pinnedStopsRemaining: e.remainingStops,
        railProgress: e.progress,
        railNextStop: e.nextStop,
        railAboard: e.aboard,
        railDelay: e.delay,
      ),
    );
    _pushUpdate();
    // Arrived at the alight: linger briefly, then end (mirrors _onEta's
    // trackOnly arrival handling — a train that reaches the alight is done).
    if (arrived && !_trackedArrived) {
      _trackedArrived = true;
      _linger = Timer(trackOnlyLinger, () => add(const JourneyCancelled()));
    }
  }

  void _subscribePositions() {
    final positions = _positions;
    if (positions == null) return;
    unawaited(_posSub?.cancel());
    // Stream error (permission revoked mid-ride) → riding continues on manual
    // stop control; position-based progress simply stops updating.
    _posSub = positions().listen(_onPosition, onError: (Object _) {});
  }

  void _onPosition(Position pos) {
    final leg = state.currentLeg;
    if (leg == null || state.phase != JourneyPhase.riding) return;
    // Nearest upcoming stop wins; never move backwards (index is monotonic).
    var best = state.nextStopIndex;
    var bestDist = double.infinity;
    for (var i = state.nextStopIndex; i < leg.stopLocations.length; i++) {
      final p = leg.stopLocations[i];
      final d = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        p.lat,
        p.lng,
      );
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    if (best != state.nextStopIndex) {
      add(ProgressTicked(best, generation: _generation));
    }
  }

  AlightTrackContent _content(JourneySessionState s) {
    final leg = s.currentLeg!;
    final rail = s.isRailTrack;
    final aboard =
        s.phase == JourneyPhase.riding ||
        (rail && s.railAboard) ||
        (!rail && s.plate != null);

    final names = [...leg.stopNames, leg.alightStop];

    // One segment per hop, board→alight. A rail leg carries its geometry as
    // railSchedule; a bus leg as stopLocations.
    final geometryHops = rail
        ? leg.railSchedule.length - 1
        : leg.stopLocations.length;
    final remaining = max(
      0,
      s.pinnedStopsRemaining ??
          (s.phase == JourneyPhase.riding
              ? leg.stopLocations.length - s.nextStopIndex
              : geometryHops),
    );
    final hopCount = max(1, max(geometryHops, remaining));
    final clampedRemaining = remaining.clamp(0, hopCount);
    final travelled = hopCount - clampedRemaining;
    final nextIndex = s.phase == JourneyPhase.riding
        ? s.nextStopIndex
        : travelled;
    // Falls back to the stop the session opened at: a leg whose stop list
    // never landed has no name to advance through, and naming the target
    // there would read as "you are already there".
    final nextName = nextIndex < names.length
        ? names[nextIndex]
        : leg.boardStop;

    return AlightTrackContent(
      mode: switch (leg.kind) {
        JourneyLegKind.metro => AlightTrackMode.metro,
        JourneyLegKind.tra => AlightTrackMode.tra,
        JourneyLegKind.thsr => AlightTrackMode.thsr,
        JourneyLegKind.bus || JourneyLegKind.other => AlightTrackMode.bus,
      },
      phase: switch (s.phase) {
        JourneyPhase.done => AlightTrackPhase.arrived,
        _ when !aboard => AlightTrackPhase.waiting,
        // `lead + 1` rather than `lead`: the card turns warm on the frame the
        // rider is buzzed, and at the default lead of 0 that is "your stop is
        // next" — on `<= lead` a default session would never warm at all.
        _ when clampedRemaining <= s.leadStops + 1 =>
          AlightTrackPhase.approaching,
        _ => AlightTrackPhase.riding,
      },
      vehicleLabel: leg.routeLabel.split(' 往').first.trim(),
      vehicleId: s.plate,
      boardStation: leg.boardStop,
      targetStation: leg.alightStop,
      nextStation: rail ? (s.railNextStop ?? leg.boardStop) : nextName,
      hopCount: hopCount,
      currentIndex: travelled,
      remainingStops: clampedRemaining,
      leadStops: s.leadStops,
      etaMs: s.eta == null
          ? null
          : DateTime.now().add(s.eta!).millisecondsSinceEpoch,
      etaMinutes: s.eta == null ? null : max(0, (s.eta!.inSeconds / 60).ceil()),
      walkMinutes: aboard ? 0 : leg.leadingWalkMinutes,
      // Only while the train is still to come: a rider on the platform reads
      // the timetable and the slip against it, not a stop count. Both drop
      // away the moment they are aboard.
      scheduledDepartureMs: rail && !aboard
          ? leg.railSchedule.first.scheduledArrival.millisecondsSinceEpoch
          : null,
      delayMinutes: rail && !aboard ? s.railDelay.inMinutes : 0,
      trackId: _trackId,
    );
  }

  @override
  Future<void> close() {
    unawaited(_etaSub?.cancel());
    unawaited(_routeEtaSub?.cancel());
    unawaited(_railSub?.cancel());
    unawaited(_posSub?.cancel());
    _timeout?.cancel();
    _linger?.cancel();
    return super.close();
  }
}
