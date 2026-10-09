/// Bus stop timeline derivation.
library;

import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

TimelineStopState timelineStopState(BusStopEtaViewModel? eta) {
  if (eta == null) return TimelineStopState.none;
  final status = busStopDisplayStatus(
    estimateSeconds: eta.estimateSeconds,
    stopStatus: eta.stopStatus,
  );
  if (status == BusStopDisplayStatus.arriving) {
    return TimelineStopState.arriving;
  }
  return _approaching(eta)
      ? TimelineStopState.approaching
      : TimelineStopState.none;
}

bool _approaching(BusStopEtaViewModel? eta) {
  if (eta == null) return false;
  return eta.estimateSeconds > 0 &&
      eta.estimateSeconds <= AppConfig.getInt('eta_approaching_threshold_s');
}

Map<int, int> fareSectionsBySequence({
  required List<BusStopModel> stops,
  required Set<int> bufferSequences,
  required int pricingType,
}) {
  if (bufferSequences.isEmpty || pricingType != 2) return const {};
  final lastBuffer = bufferSequences.reduce((a, b) => a > b ? a : b);
  // Only stops past the buffer zone are section 2; buffer stops and everything
  // before them read as section 1 (buffer cells are flagged separately).
  return {
    for (final st in stops) st.sequence: st.sequence > lastBuffer ? 2 : 1,
  };
}

List<TimelineStop> deriveTimelineStops({
  required AppI18n i18n,
  required List<BusStopModel> stops,
  required Map<String, BusStopEtaViewModel> etaMap,
  required int direction,
  required Set<int> bufferSequences,
  required int pricingType,
}) {
  BusStopEtaViewModel? etaFor(BusStopModel stop) =>
      etaMap['seq:$direction:${stop.sequence}'] ??
      etaMap['uid:${stop.stopUid}'];
  final sections = fareSectionsBySequence(
    stops: stops,
    bufferSequences: bufferSequences,
    pricingType: pricingType,
  );
  final resolved = retireStaleArriving([for (final st in stops) etaFor(st)]);
  return [
    for (final (i, st) in stops.indexed)
      if (resolved[i] case final eta)
        TimelineStop(
          uid: st.stopUid,
          name: st.stopName,
          primaryTime: eta?.displayLabelOf(i18n),
          state: timelineStopState(eta),
          isBuffer: bufferSequences.contains(st.sequence),
          fareSection: sections[st.sequence],
          isLiveEta:
              eta != null &&
              busStopLabelIsLive(
                estimateSeconds: eta.estimateSeconds,
                stopStatus: eta.stopStatus,
              ),
          etaMinutes: eta != null && eta.estimateSeconds > 0
              ? etaCeilMinutes(eta.estimateSeconds)
              : null,
          serviceEnded: eta != null && busStopServiceEnded(eta.stopStatus),
          plate: eta?.plate ?? '',
        ),
  ];
}

List<BusStopEtaViewModel?> retireStaleArriving(
  List<BusStopEtaViewModel?> etas,
) {
  final stale = <int>{};
  final lastByPlate = <String, int>{};
  int? lastPlateless;
  for (var i = 0; i < etas.length; i++) {
    final eta = etas[i];
    if (eta == null || !_isArriving(eta)) continue;
    if (eta.plate.isEmpty) {
      if (lastPlateless == i - 1) stale.add(i - 1);
      lastPlateless = i;
      continue;
    }
    final previous = lastByPlate[eta.plate];
    if (previous != null) stale.add(previous);
    lastByPlate[eta.plate] = i;
  }
  if (stale.isEmpty) return etas;
  return [
    for (final (i, eta) in etas.indexed)
      stale.contains(i)
          ? eta!.copyWith(stopStatus: busStopStatusNoReading)
          : eta,
  ];
}

bool _isArriving(BusStopEtaViewModel eta) =>
    busStopDisplayStatus(
      estimateSeconds: eta.estimateSeconds,
      stopStatus: eta.stopStatus,
    ) ==
    BusStopDisplayStatus.arriving;

Set<int> busVehicleMarkerIndices(List<TimelineStop> stops) {
  final markers = <int>{};
  for (var i = 1; i < stops.length; i++) {
    final here = stops[i];
    final behind = stops[i - 1];
    if (here.isLiveEta && !behind.isLiveEta) {
      markers.add(i);
      continue;
    }
    final a = behind.etaMinutes;
    final b = here.etaMinutes;
    if (a != null && b != null && b < a) markers.add(i);
  }
  return markers;
}

/// Semantic ETA-label classes for a timeline stop, mirroring the horizontal
/// timeline's label ladder. [countdownSoon] is a 0/1/2-minute countdown, which
/// the timeline paints in the arriving color.
enum TimelineEtaLabel { arriving, approaching, countdown, countdownSoon, none }

/// Pure mapping from a derived [TimelineStop] to its ETA-label class. The
/// countdown text itself is [TimelineStop.primaryTime]; this only picks the
/// class the timeline styles it with.
TimelineEtaLabel timelineEtaLabel(TimelineStop stop) {
  if (stop.state == TimelineStopState.arriving) {
    return TimelineEtaLabel.arriving;
  }
  if (stop.state == TimelineStopState.approaching) {
    return TimelineEtaLabel.approaching;
  }
  final primary = stop.primaryTime;
  if (primary == null) return TimelineEtaLabel.none;
  if (primary == '0' || primary == '1' || primary == '2') {
    return TimelineEtaLabel.countdownSoon;
  }
  return TimelineEtaLabel.countdown;
}
