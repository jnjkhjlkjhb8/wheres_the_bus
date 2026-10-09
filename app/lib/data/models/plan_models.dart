import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;

class PlanResult extends Equatable {
  const PlanResult({
    required this.routes,
    this.previousPageCursor = '',
    this.nextPageCursor = '',
  });

  factory PlanResult.fromProto(maas.MaasPlanResponse proto) => PlanResult(
    routes: [for (final route in proto.routes) PlanRoute.fromProto(route)],
    previousPageCursor: proto.previousPageCursor,
    nextPageCursor: proto.nextPageCursor,
  );

  final List<PlanRoute> routes;

  /// Cursors for the 更早 / 更晚 departures action. Empty when the planner does
  /// not page (TDX) or there is nothing further in that direction — which is
  /// also what tells the results list not to offer the action.
  final String previousPageCursor;
  final String nextPageCursor;

  @override
  List<Object?> get props => [routes, previousPageCursor, nextPageCursor];
}

class PlanRoute extends Equatable {
  const PlanRoute({
    required this.travelTime,
    required this.startTime,
    required this.endTime,
    required this.transfers,
    required this.sections,
    this.totalFare = 0,
    this.raw,
  });

  factory PlanRoute.fromProto(maas.Route proto) => PlanRoute(
    travelTime: proto.travelTime.toInt(),
    startTime: proto.startTime,
    endTime: proto.endTime,
    transfers: proto.transfers,
    totalFare: proto.totalFare,
    sections: [
      for (final section in proto.sections) PlanSection.fromProto(section),
    ],
    raw: proto.writeToBuffer(),
  );

  /// Rebuild a route from bytes produced by [raw] — a lossless round-trip
  /// through the same proto path, so saved snapshots stay in sync with the
  /// model without a hand-written serializer.
  factory PlanRoute.fromBytes(List<int> bytes) =>
      PlanRoute.fromProto(maas.Route.fromBuffer(bytes));

  final int travelTime;
  final String startTime;
  final String endTime;
  final int transfers;

  /// Sum of resolved section fares (NT$); 0 when no fare could be resolved.
  final int totalFare;
  final List<PlanSection> sections;

  /// The verbatim TDX proto bytes this route decoded from; null for routes not
  /// built via the proto factory. Persisted as-is when a snapshot is saved.
  final List<int>? raw;

  String get savedKey {
    final bytes = raw;
    if (bytes == null) {
      final origin = sections.isNotEmpty ? sections.first.departure.name : '';
      final dest = sections.isNotEmpty ? sections.last.arrival.name : '';
      return '$origin|$dest|$startTime';
    }
    // FNV-1a over the bytes: deterministic across app restarts (unlike
    // Object.hashCode), and collision-safe enough for a local bookmark id.
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    }
    return 'r$hash';
  }

  PlanPoint? firstPoint({int leg = 0}) {
    if (leg >= sections.length) return null;
    final loc = sections[leg].departure.location;
    if (loc.lat == 0 && loc.lng == 0) return null;
    return loc;
  }

  List<PlanPoint> get points {
    final pts = <PlanPoint>[];
    for (final section in sections) {
      void add(PlanPoint point) {
        if (point.lat != 0 || point.lng != 0) pts.add(point);
      }

      add(section.departure.location);
      for (final stop in section.intermediateStops) {
        add(stop.location);
      }
      add(section.arrival.location);
    }
    return pts;
  }

  @override
  List<Object?> get props => [
    travelTime,
    startTime,
    endTime,
    transfers,
    totalFare,
    sections,
  ];
}

class PlanSection extends Equatable {
  const PlanSection({
    required this.type,
    required this.travelSummary,
    required this.departure,
    required this.arrival,
    required this.transport,
    required this.intermediateStops,
    this.identity = const PlanIdentity.empty(),
    this.fare = 0,
    this.walkPath = const [],
    this.walkSteps = const [],
    this.transitPath = const [],
    this.alternatives = const [],
  });

  factory PlanSection.fromProto(maas.Section proto) => PlanSection(
    type: proto.type,
    travelSummary: PlanTravelSummary.fromProto(proto.travelSummary),
    departure: PlanPlace.fromProto(proto.departure),
    arrival: PlanPlace.fromProto(proto.arrival),
    transport: PlanTransport.fromProto(proto.transport),
    intermediateStops: [
      for (final stop in proto.intermediateStops) PlanStop.fromProto(stop),
    ],
    identity: PlanIdentity.fromProto(proto.notificationIdentity),
    fare: proto.fare,
    walkPath: [for (final p in proto.walkPath) PlanPoint.fromProto(p)],
    walkSteps: [for (final s in proto.walkSteps) PlanWalkStep.fromProto(s)],
    transitPath: [
      for (final p in proto.transitPath) PlanPoint.fromProto(p),
    ],
    alternatives: [
      for (final a in proto.alternatives) PlanSection.fromProto(a),
    ],
  );

  final String type;
  final PlanTravelSummary travelSummary;
  final PlanPlace departure;
  final PlanPlace arrival;
  final PlanTransport transport;
  final List<PlanStop> intermediateStops;
  final PlanIdentity identity;

  /// Adult full fare for this section (NT$); 0 when unresolved.
  final int fare;

  /// OSRM foot-route geometry for a walk section; empty when not a walk or
  /// OSRM did not resolve a route (the map then draws a straight line).
  final List<PlanPoint> walkPath;

  /// Turn-by-turn walk steps for a walk section; empty under the same
  /// conditions as [walkPath].
  final List<PlanWalkStep> walkSteps;

  final List<PlanPoint> transitPath;

  final List<PlanSection> alternatives;

  @override
  List<Object?> get props => [
    type,
    travelSummary,
    departure,
    arrival,
    transport,
    intermediateStops,
    identity,
    fare,
    walkPath,
    walkSteps,
    transitPath,
    alternatives,
  ];
}

class PlanWalkStep extends Equatable {
  const PlanWalkStep({
    required this.instruction,
    required this.maneuverType,
    required this.modifier,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.location,
  });

  factory PlanWalkStep.fromProto(maas.WalkStep proto) => PlanWalkStep(
    instruction: proto.instruction,
    maneuverType: proto.maneuverType,
    modifier: proto.modifier,
    distanceMeters: proto.distanceMeters,
    durationSeconds: proto.durationSeconds.toInt(),
    location: PlanPoint.fromProto(proto.location),
  );

  final String instruction;
  final String maneuverType;
  final String modifier;
  final double distanceMeters;
  final int durationSeconds;
  final PlanPoint location;

  @override
  List<Object?> get props => [
    instruction,
    maneuverType,
    modifier,
    distanceMeters,
    durationSeconds,
    location,
  ];
}

class PlanIdentity extends Equatable {
  const PlanIdentity({
    required this.routeType,
    required this.routeKey,
    required this.direction,
    required this.departureStopKey,
    required this.arrivalStopKey,
    required this.supported,
  });

  const PlanIdentity.empty()
    : routeType = '',
      routeKey = '',
      direction = '',
      departureStopKey = '',
      arrivalStopKey = '',
      supported = false;

  factory PlanIdentity.fromProto(maas.NotificationIdentity proto) =>
      PlanIdentity(
        routeType: proto.routeType,
        routeKey: proto.routeKey,
        direction: proto.direction,
        departureStopKey: proto.departureStopKey,
        arrivalStopKey: proto.arrivalStopKey,
        supported: proto.supported,
      );

  final String routeType;
  final String routeKey;
  final String direction;
  final String departureStopKey;
  final String arrivalStopKey;
  final bool supported;

  @override
  List<Object?> get props => [
    routeType,
    routeKey,
    direction,
    departureStopKey,
    arrivalStopKey,
    supported,
  ];
}

class PlanTravelSummary extends Equatable {
  const PlanTravelSummary({required this.duration, required this.length});

  factory PlanTravelSummary.fromProto(maas.Summary proto) => PlanTravelSummary(
    duration: proto.duration.toInt(),
    length: proto.length,
  );

  final int duration;
  final double length;

  @override
  List<Object?> get props => [duration, length];
}

class PlanPlace extends Equatable {
  const PlanPlace({
    required this.name,
    required this.type,
    required this.location,
    required this.time,
  });

  factory PlanPlace.fromProto(maas.Place proto) => PlanPlace(
    name: proto.name,
    type: proto.type,
    location: PlanPoint.fromProto(proto.location),
    time: proto.time,
  );

  final String name;
  final String type;
  final PlanPoint location;
  final String time;

  @override
  List<Object?> get props => [name, type, location, time];
}

class PlanPoint extends Equatable {
  const PlanPoint({required this.lat, required this.lng});

  factory PlanPoint.fromProto(maas.Location proto) =>
      PlanPoint(lat: proto.lat, lng: proto.lng);

  final double lat;
  final double lng;

  @override
  List<Object?> get props => [lat, lng];
}

class PlanTransport extends Equatable {
  const PlanTransport({
    required this.mode,
    required this.name,
    required this.shortName,
    required this.longName,
    required this.headsign,
    required this.category,
    required this.routeColor,
  });

  factory PlanTransport.fromProto(maas.Transport proto) => PlanTransport(
    mode: proto.mode,
    name: proto.name,
    shortName: proto.shortName,
    longName: proto.longName,
    headsign: proto.headsign,
    category: proto.category,
    routeColor: proto.routeColor,
  );

  final String mode;
  final String name;
  final String shortName;
  final String longName;
  final String headsign;
  final String category;
  final String routeColor;

  @override
  List<Object?> get props => [
    mode,
    name,
    shortName,
    longName,
    headsign,
    category,
    routeColor,
  ];
}

class PlanStop extends Equatable {
  const PlanStop({
    required this.name,
    required this.location,
    required this.departureTime,
  });

  factory PlanStop.fromProto(maas.IntermediateStop proto) => PlanStop(
    name: proto.name,
    location: PlanPoint.fromProto(proto.location),
    departureTime: proto.departureTime,
  );

  final String name;
  final PlanPoint location;
  final String departureTime;

  @override
  List<Object?> get props => [name, location, departureTime];
}
