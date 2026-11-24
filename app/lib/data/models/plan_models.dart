import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;
import 'package:wheres_the_bus/data/generated/planner.pb.dart'
    show PlannerTransfer, TransferLevel;

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
  /// not page or there is nothing further in that direction — which is
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
    this.id = '',
    this.fareComplete = true,
    this.transferMargins = const [],
    this.walkSeconds,
  });

  /// [id], [fareComplete], [transferMargins] and [walkSeconds] exist only on a
  /// route planned through PlannerService; a saved snapshot's bytes carry none
  /// of them.
  factory PlanRoute.fromProto(
    maas.Route proto, {
    String id = '',
    bool fareComplete = true,
    List<PlanTransfer> transferMargins = const [],
    int? walkSeconds,
  }) => PlanRoute(
    travelTime: proto.travelTime.toInt(),
    startTime: proto.startTime,
    endTime: proto.endTime,
    transfers: proto.transfers,
    totalFare: proto.totalFare,
    sections: [
      for (final section in proto.sections) PlanSection.fromProto(section),
    ],
    raw: proto.writeToBuffer(),
    id: id,
    fareComplete: fareComplete,
    transferMargins: transferMargins,
    walkSeconds: walkSeconds,
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

  /// The verbatim proto bytes this route decoded from; null for routes not
  /// built via the proto factory. Persisted as-is when a snapshot is saved.
  final List<int>? raw;

  /// The planner's itinerary id; empty for a saved snapshot.
  final String id;

  /// False when a transit leg went unpriced, so [totalFare] is a partial sum
  /// that would read as cheaper than the trip is.
  final bool fareComplete;

  /// One entry per change between two transit legs, in leg order.
  final List<PlanTransfer> transferMargins;

  /// Time on foot across the whole trip, without the transfer buffer that a
  /// transfer walk's own duration runs on to. Null for a saved snapshot.
  final int? walkSeconds;

  /// The transfer most likely to be missed: the smallest margin among those
  /// the planner could time. Null when there is none to speak of.
  PlanTransfer? get weakestTransfer {
    PlanTransfer? weakest;
    for (final transfer in transferMargins.where((t) => t.timed)) {
      if (weakest == null || transfer.marginSeconds < weakest.marginSeconds) {
        weakest = transfer;
      }
    }
    return weakest;
  }

  /// The change onto section [leg], if one leads into it and the planner could
  /// time it.
  PlanTransfer? timedTransferInto(int leg) {
    for (final transfer in transferMargins.where((t) => t.timed)) {
      if (transfer.toLeg == leg) return transfer;
    }
    return null;
  }

  /// This itinerary as it appears in [routes], so a held copy picks up the
  /// geometry the planner's second message adds. A saved snapshot has no id
  /// to match by and stays as it is.
  PlanRoute refreshedFrom(List<PlanRoute> routes) {
    if (id.isEmpty) return this;
    for (final route in routes) {
      if (route.id == id) return route;
    }
    return this;
  }

  String get savedKey {
    final bytes = raw;
    if (bytes == null) return _namedSavedKey;
    // FNV-1a over the bytes: deterministic across app restarts (unlike
    // Object.hashCode), and collision-safe enough for a local bookmark id.
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    }
    return 'r$hash';
  }

  String get _namedSavedKey {
    if (sections.isEmpty) return '||$startTime';
    final origin = sections.first.departure.name;
    final destination = sections.last.arrival.name;
    return '$origin|$destination|$startTime';
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
    id,
    fareComplete,
    transferMargins,
    walkSeconds,
  ];
}

/// How safe a change between two rides looks. Unknown when the planner was
/// missing a time to measure it with.
enum TransferReliability { unknown, comfortable, tight }

const _reliability = <TransferLevel, TransferReliability>{
  TransferLevel.TRANSFER_LEVEL_COMFORTABLE: TransferReliability.comfortable,
  TransferLevel.TRANSFER_LEVEL_TIGHT: TransferReliability.tight,
};

/// One change between two transit legs, as the planner measured it.
class PlanTransfer extends Equatable {
  const PlanTransfer({
    required this.fromLeg,
    required this.toLeg,
    required this.marginSeconds,
    required this.reliability,
    required this.timesEstimated,
  });

  factory PlanTransfer.fromProto(PlannerTransfer proto) => PlanTransfer(
    fromLeg: proto.fromLeg,
    toLeg: proto.toLeg,
    marginSeconds: proto.marginSeconds.toInt(),
    reliability: _reliability[proto.level] ?? TransferReliability.unknown,
    timesEstimated: proto.timesEstimated,
  );

  final int fromLeg;
  final int toLeg;

  /// Negative once a delay has already broken the connection.
  final int marginSeconds;
  final TransferReliability reliability;

  /// The arriving leg's times are distance-estimated, not observed, so the
  /// margin is a guess.
  final bool timesEstimated;

  /// Whether the planner had both times to measure the margin with.
  bool get timed => reliability != TransferReliability.unknown;

  bool get tight => reliability == TransferReliability.tight;

  /// Whole minutes, rounded down: a margin read as longer than it is would
  /// tell a rider they have time they do not.
  int get marginMinutes => marginSeconds.isNegative ? 0 : marginSeconds ~/ 60;

  @override
  List<Object?> get props => [
    fromLeg,
    toLeg,
    marginSeconds,
    reliability,
    timesEstimated,
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

  /// Foot-route geometry for a walk section; empty when not a walk or the
  /// planner returned no geometry (the map then draws a straight line).
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
