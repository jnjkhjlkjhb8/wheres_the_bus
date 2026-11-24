import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;
import 'package:wheres_the_bus/data/generated/planner.pb.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';

// The planner's itineraries are restated in the MaasService route shape
// because everything downstream (the map, navigation, the tracking card and
// the saved-route box) reads that shape. Saving a route then writes the same
// bytes a saved snapshot has always held.

/// The mode names MaasService sent, which the app's glyphs and colours key on.
const _legacyModes = <PlannerTransitMode, String>{
  PlannerTransitMode.PLANNER_TRANSIT_MODE_BUS: 'Bus',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_COACH: 'HighwayBus',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_SUBWAY: 'Subway',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_TRAM: 'Tram',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_HIGH_SPEED_RAIL: 'THSR',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_RAIL: 'Rail',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_FERRY: 'Ferry',
  PlannerTransitMode.PLANNER_TRANSIT_MODE_CABLE_CAR: 'CableCar',
};

PlanResult planResultFromPlanner(PlannerResponse response) => PlanResult(
  routes: [for (final i in response.itineraries) planRouteFromItinerary(i)],
  previousPageCursor: response.previousPageCursor,
  nextPageCursor: response.nextPageCursor,
);

PlanRoute planRouteFromItinerary(PlannerItinerary itinerary) =>
    PlanRoute.fromProto(
      maas.Route(
        travelTime: itinerary.durationSeconds,
        startTime: _clock(itinerary.hasStartTime(), itinerary.startTime),
        endTime: _clock(itinerary.hasEndTime(), itinerary.endTime),
        transfers: itinerary.transferCount,
        totalFare: itinerary.totalFare,
        sections: itinerary.legs.map(_section),
      ),
      id: itinerary.id,
      fareComplete: itinerary.fareComplete,
      transferMargins: [
        for (final t in itinerary.transfers) PlanTransfer.fromProto(t),
      ],
      walkSeconds: itinerary.walkSeconds.toInt(),
    );

maas.Section _section(PlannerLeg leg) {
  final transit = leg.kind == PlannerLegKind.PLANNER_LEG_KIND_TRANSIT;
  final section = maas.Section(
    type: transit ? 'transit' : 'pedestrian',
    travelSummary: maas.Summary(
      duration: leg.durationSeconds,
      length: leg.distanceMeters,
    ),
    departure: _place(leg.from, _clock(leg.hasStartTime(), leg.startTime)),
    arrival: _place(leg.to, _clock(leg.hasEndTime(), leg.endTime)),
    transport: _transport(leg),
    intermediateStops: leg.intermediateStops.map(_intermediateStop),
    fare: leg.fare,
    walkSteps: leg.walkSteps,
    alternatives: leg.alternatives.map(_section),
  );
  // One path field carries both: the street for a walk, the vehicle's shape
  // for a ride. MaasService kept them apart.
  (transit ? section.transitPath : section.walkPath).addAll(leg.path);
  _addOperator(section, leg);
  return section;
}

void _addOperator(maas.Section section, PlannerLeg leg) {
  if (leg.transit.hasAgency()) section.agency = leg.transit.agency;
  if (leg.hasNotificationIdentity()) {
    section.notificationIdentity = leg.notificationIdentity;
  }
}

maas.Transport? _transport(PlannerLeg leg) {
  if (!leg.hasTransit()) return null;
  final transit = leg.transit;
  return maas.Transport(
    mode: _legacyModes[leg.mode],
    name: transit.name,
    shortName: transit.shortName,
    longName: transit.longName,
    headsign: transit.headsign,
    routeColor: transit.routeColor,
  );
}

/// A timetable stop and a street coordinate render differently, and MaasService
/// told them apart by these two type names.
maas.Place _place(PlannerStop stop, String time) => maas.Place(
  name: stop.name,
  type: stop.stopId.isEmpty ? 'place' : 'station',
  location: stop.location,
  time: time,
);

maas.IntermediateStop _intermediateStop(PlannerStop stop) =>
    maas.IntermediateStop(
      name: stop.name,
      location: stop.location,
      departureTime: _clock(stop.hasDeparture(), stop.departure),
    );

/// Local wall-clock time, which the clock labels read the hour from and
/// which parses back as the same moment on this device. An unset time stays
/// empty rather than becoming 1970.
String _clock(bool present, Timestamp time) =>
    present ? time.toDateTime().toLocal().toIso8601String() : '';
