/// Bus stop timeline derivation.
library;

import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

TimelineStopState timelineStopState(BusStopEtaViewModel? eta) {
  // Arriving and approaching say a vehicle is there; only a live time can.
  if (eta == null || !eta.source.isLive) return TimelineStopState.none;
  final status = busStopDisplayStatus(
    estimateSeconds: eta.estimateSeconds,
    stopStatus: eta.stopStatus,
  );
  if (status == BusStopDisplayStatus.arriving) {
    return TimelineStopState.arriving;
  }
  return _approachingState(eta);
}

TimelineStopState _approachingState(BusStopEtaViewModel eta) =>
    _approaching(eta) ? TimelineStopState.approaching : TimelineStopState.none;

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
  final lastBuffer = _lastBuffer(bufferSequences);
  // Only stops past the buffer zone are section 2; buffer stops and everything
  // before them read as section 1 (buffer cells are flagged separately).
  return {
    for (final st in stops) st.sequence: _fareSection(st.sequence, lastBuffer),
  };
}

int _lastBuffer(Set<int> sequences) =>
    sequences.reduce((a, b) => a > b ? a : b);
int _fareSection(int sequence, int lastBuffer) => sequence > lastBuffer ? 2 : 1;

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
          isLiveEta: _isLiveEta(eta),
          etaMinutes: _etaMinutes(eta),
          serviceEnded: _serviceEnded(eta),
          plate: eta?.plate ?? '',
          source: eta?.source ?? EtaSource.live,
        ),
  ];
}

bool _isLiveEta(BusStopEtaViewModel? eta) =>
    eta != null &&
    eta.source.isLive &&
    busStopLabelIsLive(
      estimateSeconds: eta.estimateSeconds,
      stopStatus: eta.stopStatus,
    );

int? _etaMinutes(BusStopEtaViewModel? eta) =>
    eta != null && eta.estimateSeconds > 0
    ? etaCeilMinutes(eta.estimateSeconds)
    : null;

bool _serviceEnded(BusStopEtaViewModel? eta) =>
    eta != null && busStopServiceEnded(eta.stopStatus);

List<BusStopEtaViewModel?> retireStaleArriving(
  List<BusStopEtaViewModel?> etas,
) {
  final stale = _staleArrivingIndices(etas);
  if (stale.isEmpty) return etas;
  return [
    for (final (i, eta) in etas.indexed)
      stale.contains(i)
          ? eta!.copyWith(stopStatus: busStopStatusNoReading)
          : eta,
  ];
}

Set<int> _staleArrivingIndices(List<BusStopEtaViewModel?> etas) {
  final history = _ArrivingHistory();
  for (var i = 0; i < etas.length; i++) {
    final plate = _arrivingPlate(etas[i]);
    if (plate != null) history.record(plate, i);
  }
  return history.stale;
}

String? _arrivingPlate(BusStopEtaViewModel? eta) {
  if (eta == null || !_isArriving(eta)) return null;
  return eta.plate;
}

class _ArrivingHistory {
  final stale = <int>{};
  final _lastByPlate = <String, int>{};
  int? _lastPlateless;

  void record(String plate, int index) {
    if (plate.isEmpty) {
      if (_lastPlateless == index - 1) stale.add(index - 1);
      _lastPlateless = index;
      return;
    }
    final previous = _lastByPlate[plate];
    if (previous != null) stale.add(previous);
    _lastByPlate[plate] = index;
  }
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
    if (_vehicleBoundary(here, behind)) markers.add(i);
  }
  return markers;
}

bool _vehicleBoundary(TimelineStop here, TimelineStop behind) {
  if (here.isLiveEta && !behind.isLiveEta) return true;
  return _etaDrops(behind.etaMinutes, here.etaMinutes);
}

bool _etaDrops(int? before, int? after) =>
    before != null && after != null && after < before;

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
  return _countdownLabel(stop.primaryTime);
}

TimelineEtaLabel _countdownLabel(String? primary) {
  if (primary == null) return TimelineEtaLabel.none;
  return const {'0', '1', '2'}.contains(primary)
      ? TimelineEtaLabel.countdownSoon
      : TimelineEtaLabel.countdown;
}
