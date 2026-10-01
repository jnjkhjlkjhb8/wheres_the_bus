/// Builders and lookups for active transit tracking sessions.
library;

import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// The route label a 追蹤 card shows: the route number, plus its headsign when
/// the feed publishes one. One recipe, because a bus tracked from the map and
/// the same bus tracked from the stop list must not read differently.
String busTrackingLabel({
  required String routeName,
  required String headsign,
}) => headsign.isEmpty ? routeName : '$routeName 往$headsign';

JourneyLeg busTrackingLeg({
  required BusRouteViewModel route,
  required List<BusStopModel> stops,
  required int boardIndex,
  required int targetIndex,
  required int direction,
}) {
  final target = stops[targetIndex];
  final from = boardIndex.clamp(0, targetIndex);
  // Empty when the bus already stands at the target: sublist(n, n).
  final ahead = stops.sublist(from + 1, targetIndex + 1);
  return JourneyLeg(
    kind: JourneyLegKind.bus,
    routeLabel: busTrackingLabel(
      routeName: route.routeName,
      headsign: direction == 0 ? route.headsignGo : route.headsignReturn,
    ),
    boardStop: stops[from].stopName,
    alightStop: target.stopName,
    stopNames: [for (final s in ahead) s.stopName],
    identity: PlanIdentity(
      routeType: 'bus',
      routeKey: route.subRouteUid,
      direction: '$direction',
      departureStopKey: target.stopUid,
      arrivalStopKey: '',
      supported: false,
    ),
    leadingWalkMinutes: 0,
    scheduledDeparture: null,
    scheduledArrival: null,
    boardLocation: PlanPoint(lat: stops[from].lat, lng: stops[from].lon),
    stopLocations: [for (final s in ahead) PlanPoint(lat: s.lat, lng: s.lon)],
  );
}

JourneyLeg railTrackingLeg({
  required AppI18n i18n,
  required bool isThsr,
  required String trainNo,
  required String trainLabel,
  required String serviceDate,
  required String boardName,
  required String alightName,
  required DateTime? scheduledDeparture,
  required DateTime? scheduledArrival,
  required int delayMinutes,
  required List<RailStopSchedule> railSchedule,
}) => JourneyLeg(
  kind: isThsr ? JourneyLegKind.thsr : JourneyLegKind.tra,
  routeLabel: i18n.railTrainTowards(trainLabel, trainNo, alightName),
  boardStop: boardName,
  alightStop: alightName,
  stopNames: const [],
  identity: PlanIdentity(
    routeType: isThsr ? 'thsr' : 'tra',
    routeKey: trainNo,
    direction: serviceDate,
    departureStopKey: '',
    arrivalStopKey: '',
    supported: false,
  ),
  leadingWalkMinutes: 0,
  scheduledDeparture: scheduledDeparture?.add(
    Duration(minutes: delayMinutes),
  ),
  scheduledArrival: scheduledArrival,
  boardLocation: const PlanPoint(lat: 0, lng: 0),
  stopLocations: const [],
  railSchedule: railSchedule,
);

String? trackedBusStopUid(JourneySessionState state, String? subRouteUid) {
  final leg = _waitingTrackLeg(state);
  if (leg == null ||
      leg.kind != JourneyLegKind.bus ||
      subRouteUid == null ||
      leg.identity.routeKey != subRouteUid) {
    return null;
  }
  return leg.identity.departureStopKey;
}

bool isTrackingTrain(
  JourneySessionState state, {
  required String trainNo,
  required String serviceDate,
}) {
  final leg = _waitingTrackLeg(state);
  return leg != null &&
      (leg.kind == JourneyLegKind.tra || leg.kind == JourneyLegKind.thsr) &&
      leg.identity.routeKey == trainNo &&
      leg.identity.direction == serviceDate;
}

/// The leg of a running standalone 追蹤 that is still waiting to board, or null
/// for an idle session, a navigation session, or one already under way.
JourneyLeg? _waitingTrackLeg(JourneySessionState state) {
  if (!state.trackOnly || state.phase != JourneyPhase.waiting) return null;
  return state.currentLeg;
}
