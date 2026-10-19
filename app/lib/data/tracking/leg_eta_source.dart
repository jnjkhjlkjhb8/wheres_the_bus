import 'dart:async';

import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';

typedef LegEtaStream = Stream<Duration?> Function(JourneyLeg leg);

typedef RouteEtaStream =
    Stream<List<BusStopEtaViewModel>> Function(String routeKey);

/// Live per-stop ETA/vehicle stream for a route, used to track a pinned
/// vehicle's stop-by-stop progress toward the alight stop.
Stream<List<BusStopEtaViewModel>> defaultRouteEtaStream(
  String routeKey, {
  BusRepository? repository,
}) => resilientStream(
  () => (repository ?? BusRepository.instance).routeEta(routeKey),
  foreground: alwaysForeground,
);

/// Live ETA for bus legs whose notification identity resolved; every other
/// leg counts down from its scheduled departure. Non-bus legs will gain live
/// sources once the planner emits supported identities for them.
Stream<Duration?> defaultLegEtaStream(
  JourneyLeg leg, {
  BusRepository? repository,
}) {
  final bus = repository ?? BusRepository.instance;
  final stopKey = leg.identity.departureStopKey;
  if (_hasStationFeed(leg, stopKey)) {
    return resilientStream(
      () => bus.stationEta('', stopKey),
      foreground: alwaysForeground,
    ).map((arrivals) => _stationEta(leg, arrivals));
  }
  if (_hasRouteFeed(leg, stopKey)) {
    return resilientStream(
      () => bus.routeEta(leg.identity.routeKey),
      foreground: alwaysForeground,
    ).map((etas) => _routeStopEta(leg, etas));
  }
  return scheduledCountdown(leg.scheduledDeparture);
}

bool _hasStationFeed(JourneyLeg leg, String stopKey) =>
    leg.kind == JourneyLegKind.bus &&
    leg.identity.supported &&
    stopKey.isNotEmpty;

bool _hasRouteFeed(JourneyLeg leg, String stopKey) =>
    leg.kind == JourneyLegKind.bus &&
    leg.identity.routeKey.isNotEmpty &&
    stopKey.isNotEmpty;

Duration? _stationEta(JourneyLeg leg, List<BusStopArrival> arrivals) {
  for (final arrival in arrivals) {
    if (!leg.routeLabel.startsWith(arrival.routeName)) continue;
    final eta = _arrivalEta(arrival);
    if (eta != null) return eta;
  }
  return null;
}

Duration? _arrivalEta(BusStopArrival arrival) {
  if (arrival.minutes != null) return Duration(minutes: arrival.minutes!);
  return arrival.isArriving ? Duration.zero : null;
}

Duration? _routeStopEta(JourneyLeg leg, List<BusStopEtaViewModel> etas) {
  for (final eta in etas) {
    if (_matchesRouteStop(leg, eta)) return _stopEta(eta);
  }
  return null;
}

bool _matchesRouteStop(JourneyLeg leg, BusStopEtaViewModel eta) {
  if (eta.stopUid != leg.identity.departureStopKey) return false;
  return leg.identity.direction.isEmpty ||
      '${eta.direction}' == leg.identity.direction;
}

Duration? _stopEta(BusStopEtaViewModel eta) {
  if (eta.stopStatus == 0 && eta.estimateSeconds == 0) return Duration.zero;
  return eta.estimateSeconds > 0
      ? Duration(seconds: eta.estimateSeconds)
      : null;
}

/// Emits the remaining time until [departure] once per 30s, clamped at zero.
Stream<Duration?> scheduledCountdown(
  DateTime? departure, {
  Duration tick = const Duration(seconds: 30),
}) async* {
  if (departure == null) {
    yield null;
    return;
  }
  Duration remaining() {
    final d = departure.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  yield remaining();
  yield* Stream.periodic(tick, (_) => remaining());
}

({
  int remainingStops,
  Duration etaToAlight,
  double progress,
  String nextStop,
  bool aboard,
  Duration etaToBoard,
  Duration delay,
})
railProgress(List<RailStopSchedule> schedule, Duration delay, DateTime now) {
  final n = schedule.length;
  DateTime eff(int i) => schedule[i].scheduledArrival.add(delay);

  final passed = _passedRailStops(schedule, delay, now);
  final currentPos = passed == 0 ? 0 : passed - 1; // clamp to the board stop
  final remaining = ((n - 1) - currentPos).clamp(0, n - 1);

  final etaRaw = eff(n - 1).difference(now);
  final eta = _nonNegative(etaRaw);

  // Continuous position along the line. A delayed run keeps the same total
  // span, shifted later — so the denominator is the scheduled span and the
  // numerator starts at the delay-shifted board time.
  final total = schedule.last.scheduledArrival.difference(
    schedule.first.scheduledArrival,
  );
  final elapsed = now.difference(schedule.first.scheduledArrival.add(delay));
  final progress = _railFraction(total, elapsed);

  // The stop the train is heading to (the alight once it's the last hop).
  final nextIdx = _nextRailStop(passed, n);

  final aboard = passed > 0;
  final toBoardRaw = eff(0).difference(now);

  return (
    remainingStops: remaining,
    etaToAlight: eta,
    progress: progress,
    nextStop: schedule[nextIdx].name,
    aboard: aboard,
    etaToBoard: _nonNegative(toBoardRaw),
    // Handed back rather than only folded into the times: the waiting card
    // names the slip ("08:20 開 · 誤點 5 分") instead of quietly restating the
    // timetable, because a rider compares it against the printed board.
    delay: delay,
  );
}

int _passedRailStops(
  List<RailStopSchedule> schedule,
  Duration delay,
  DateTime now,
) => schedule
    .where((stop) => !stop.scheduledArrival.add(delay).isAfter(now))
    .length;

Duration _nonNegative(Duration duration) =>
    duration.isNegative ? Duration.zero : duration;

double _railFraction(Duration total, Duration elapsed) => total.inSeconds <= 0
    ? 1.0
    : (elapsed.inSeconds / total.inSeconds).clamp(0.0, 1.0);

int _nextRailStop(int passed, int stopCount) {
  if (passed >= stopCount) return stopCount - 1;
  return passed == 0 ? 0 : passed;
}

/// The record [defaultRailTrackStream] emits, mirroring [railProgress].
typedef RailTrackFrame = ({
  int remainingStops,
  Duration etaToAlight,
  double progress,
  String nextStop,
  bool aboard,
  Duration etaToBoard,
  Duration delay,
});

typedef RailTrackStream = Stream<RailTrackFrame> Function(JourneyLeg leg);

Stream<RailTrackFrame> defaultRailTrackStream(
  JourneyLeg leg, {
  Stream<Duration>? delaySource,
  TraRepository? repository,
  Duration tick = const Duration(seconds: 30),
  DateTime Function() now = DateTime.now,
}) {
  final schedule = leg.railSchedule;
  final delays = delaySource ?? _railDelayStream(leg, repository);

  var delay = Duration.zero;
  late StreamController<RailTrackFrame> controller;
  StreamSubscription<Duration>? delaySub;
  Timer? timer;

  void emit() => controller.add(railProgress(schedule, delay, now()));

  controller = StreamController<RailTrackFrame>(
    onListen: () {
      emit(); // seed immediately so the card never starts blank
      timer = Timer.periodic(tick, (_) => emit());
      // Delay-stream error → keep the last delay; never blank the card.
      delaySub = delays.listen(
        (d) {
          delay = d;
          emit();
        },
        onError: (Object _) {},
      );
    },
    onCancel: () async {
      timer?.cancel();
      await delaySub?.cancel();
    },
  );
  return controller.stream;
}

/// TRA → the O/D-segment delay stream filtered to this train; THSR → constant
/// zero (no live feed). Board/alight names come from the carried schedule.
Stream<Duration> _railDelayStream(
  JourneyLeg leg,
  TraRepository? repository,
) {
  if (leg.kind != JourneyLegKind.tra || leg.railSchedule.length < 2) {
    return const Stream<Duration>.empty(); // THSR / no segment: no live feed
  }
  final trainNo = leg.identity.routeKey;
  final date = leg.identity.direction;
  final origin = leg.railSchedule.first.name;
  final dest = leg.railSchedule.last.name;
  return resilientStream(
    () => (repository ?? TraRepository.instance).delay(date, origin, dest),
    foreground: alwaysForeground,
  ).map((m) => Duration(minutes: m[trainNo] ?? 0));
}
