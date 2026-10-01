import 'dart:async';

import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';

typedef LegEtaStream = Stream<Duration?> Function(JourneyLeg leg);

typedef RouteEtaStream =
    Stream<List<BusStopEtaViewModel>> Function(String routeKey);

/// Live per-stop ETA/vehicle stream for a route, used to track a pinned
/// vehicle's stop-by-stop progress toward the alight stop.
Stream<List<BusStopEtaViewModel>> defaultRouteEtaStream(String routeKey) =>
    BusRepository.instance.routeEta(routeKey);

/// Live ETA for bus legs whose notification identity resolved; every other
/// leg counts down from its scheduled departure. Non-bus legs will gain live
/// sources once the planner emits supported identities for them.
Stream<Duration?> defaultLegEtaStream(JourneyLeg leg) {
  final stopKey = leg.identity.departureStopKey;
  if (leg.kind == JourneyLegKind.bus &&
      leg.identity.supported &&
      stopKey.isNotEmpty) {
    return BusRepository.instance.stationEta('', stopKey).map((arrivals) {
      for (final a in arrivals) {
        if (leg.routeLabel.startsWith(a.routeName) && a.minutes != null) {
          return Duration(minutes: a.minutes!);
        }
        if (leg.routeLabel.startsWith(a.routeName) && a.isArriving) {
          return Duration.zero;
        }
      }
      return null;
    });
  }
  if (leg.kind == JourneyLegKind.bus &&
      leg.identity.routeKey.isNotEmpty &&
      stopKey.isNotEmpty) {
    return BusRepository.instance.routeEta(leg.identity.routeKey).map((etas) {
      for (final e in etas) {
        if (e.stopUid != stopKey) continue;
        if (leg.identity.direction.isNotEmpty &&
            '${e.direction}' != leg.identity.direction) {
          continue;
        }
        if (e.stopStatus == 0 && e.estimateSeconds == 0) return Duration.zero;
        if (e.estimateSeconds > 0) return Duration(seconds: e.estimateSeconds);
        return null;
      }
      return null;
    });
  }
  return scheduledCountdown(leg.scheduledDeparture);
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

  // Stops whose effective time has passed (train has reached them).
  var passed = 0;
  for (var i = 0; i < n; i++) {
    if (!eff(i).isAfter(now)) passed++;
  }
  final currentPos = passed == 0 ? 0 : passed - 1; // clamp to the board stop
  final remaining = ((n - 1) - currentPos).clamp(0, n - 1);

  final etaRaw = eff(n - 1).difference(now);
  final eta = etaRaw.isNegative ? Duration.zero : etaRaw;

  // Continuous position along the line. A delayed run keeps the same total
  // span, shifted later — so the denominator is the scheduled span and the
  // numerator starts at the delay-shifted board time.
  final total = schedule.last.scheduledArrival.difference(
    schedule.first.scheduledArrival,
  );
  final elapsed = now.difference(schedule.first.scheduledArrival.add(delay));
  final progress = total.inSeconds <= 0
      ? 1.0
      : (elapsed.inSeconds / total.inSeconds).clamp(0.0, 1.0);

  // The stop the train is heading to (the alight once it's the last hop).
  final nextIdx = passed >= n ? n - 1 : (passed == 0 ? 0 : passed);

  final aboard = passed > 0;
  final toBoardRaw = eff(0).difference(now);

  return (
    remainingStops: remaining,
    etaToAlight: eta,
    progress: progress,
    nextStop: schedule[nextIdx].name,
    aboard: aboard,
    etaToBoard: toBoardRaw.isNegative ? Duration.zero : toBoardRaw,
    // Handed back rather than only folded into the times: the waiting card
    // names the slip ("08:20 開 · 誤點 5 分") instead of quietly restating the
    // timetable, because a rider compares it against the printed board.
    delay: delay,
  );
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
  Duration tick = const Duration(seconds: 30),
  DateTime Function() now = DateTime.now,
}) {
  final schedule = leg.railSchedule;
  final delays = delaySource ?? _railDelayStream(leg);

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
Stream<Duration> _railDelayStream(JourneyLeg leg) {
  if (leg.kind != JourneyLegKind.tra || leg.railSchedule.length < 2) {
    return const Stream<Duration>.empty(); // THSR / no segment: no live feed
  }
  final trainNo = leg.identity.routeKey;
  final date = leg.identity.direction;
  final origin = leg.railSchedule.first.name;
  final dest = leg.railSchedule.last.name;
  return TraRepository.instance
      .delay(date, origin, dest)
      .map((m) => Duration(minutes: m[trainNo] ?? 0));
}
