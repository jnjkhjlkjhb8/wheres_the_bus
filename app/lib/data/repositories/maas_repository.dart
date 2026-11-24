import 'package:grpc/grpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' show Location;
import 'package:wheres_the_bus/data/generated/planner.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/models/planner_itinerary.dart';

/// One stage of a streamed plan. `complete` is false while the router is still
/// resolving map geometry: the routes are final, but a section may still have
/// an empty walk/transit path and draw as a straight line.
typedef PlanUpdate = ({PlanResult result, bool complete});

/// Why a plan failed, in terms the screen can explain. Transport codes stop
/// here: a rider is told the routing service did not answer, not `DEADLINE
/// _EXCEEDED`.
enum PlanFailureKind {
  /// The router's own 20s ceiling, or the client deadline, ran out.
  timeout,

  /// Upstream routing is unreachable or refusing work (includes the per-caller
  /// planner quota).
  unavailable,

  /// Routing answered, with no itinerary for this pair.
  noRoute,
  unknown,
}

class PlanFailure implements Exception {
  const PlanFailure(this.kind);

  final PlanFailureKind kind;

  @override
  String toString() => 'PlanFailure(${kind.name})';
}

// The ids the options sheet stores, which are MaasPlanRequest's. The bus id
// asks for BUS only: the planner filters BUS and COACH together.
const _transitModes = <int, PlannerTransitMode>{
  3: PlannerTransitMode.PLANNER_TRANSIT_MODE_HIGH_SPEED_RAIL,
  4: PlannerTransitMode.PLANNER_TRANSIT_MODE_RAIL,
  5: PlannerTransitMode.PLANNER_TRANSIT_MODE_BUS,
  6: PlannerTransitMode.PLANNER_TRANSIT_MODE_SUBWAY,
  7: PlannerTransitMode.PLANNER_TRANSIT_MODE_TRAM,
  8: PlannerTransitMode.PLANNER_TRANSIT_MODE_FERRY,
  9: PlannerTransitMode.PLANNER_TRANSIT_MODE_CABLE_CAR,
};

const _sorts = <PlanSort, PlannerSort>{
  PlanSort.fastest: PlannerSort.PLANNER_SORT_FASTEST,
  PlanSort.cheapest: PlannerSort.PLANNER_SORT_CHEAPEST,
  PlanSort.fewestTransfers: PlannerSort.PLANNER_SORT_FEWEST_TRANSFERS,
  PlanSort.leastWalking: PlannerSort.PLANNER_SORT_LEAST_WALKING,
};

const _accessModes = <int, PlannerAccessMode>{
  0: PlannerAccessMode.PLANNER_ACCESS_MODE_WALK,
  1: PlannerAccessMode.PLANNER_ACCESS_MODE_BIKE,
  2: PlannerAccessMode.PLANNER_ACCESS_MODE_CAR,
  3: PlannerAccessMode.PLANNER_ACCESS_MODE_SHARED_BIKE,
};

class MaasRepository {
  MaasRepository({PlannerServiceClient? client}) : _client = client;

  static final MaasRepository instance = MaasRepository();

  final PlannerServiceClient? _client;
  PlannerServiceClient get _grpc => _client ?? GrpcClient.instance.planner;

  Stream<PlanUpdate> planStream({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required String date,
    required String time,
    bool arriveBy = false,
    PlanOptions options = const PlanOptions(),
    String pageCursor = '',
    int legAlternatives = 0,
    PlanSort sort = PlanSort.fastest,
  }) {
    final request = PlannerRequest(
      from: Location(lat: fromLat, lng: fromLon),
      to: Location(lat: toLat, lng: toLon),
      time: _requestTime(date, time),
      arriveBy: arriveBy,
      sort: _sorts[sort],
      pageCursor: pageCursor,
      legAlternatives: legAlternatives,
    );
    _applyOptions(request, options);
    return _grpc
        .planStream(request)
        .map(
          (update) => (
            result: planResultFromPlanner(update.plan),
            complete: update.complete,
          ),
        )
        .handleError(
          (Object error) => throw PlanFailure(_failureKind(error)),
        );
  }

  PlanFailureKind _failureKind(Object error) {
    if (error is! GrpcError) return PlanFailureKind.unknown;
    return switch (error.code) {
      StatusCode.deadlineExceeded => PlanFailureKind.timeout,
      StatusCode.notFound => PlanFailureKind.noRoute,
      StatusCode.unavailable ||
      StatusCode.resourceExhausted => PlanFailureKind.unavailable,
      _ => PlanFailureKind.unknown,
    };
  }

  // The unary `plan` RPC, and all of MaasService, stay on the router for app
  // versions already in the wild; nothing in this build calls them.

  /// The minute the screen showed the rider, not the moment of sending: a
  /// sort change resends the same question, and the planner answers a repeat
  /// from its cache. An unparseable pair leaves the time unset, which plans
  /// from now.
  Timestamp? _requestTime(String date, String time) {
    final local = DateTime.tryParse('${date}T$time');
    return local == null ? null : Timestamp.fromDateTime(local);
  }

  void _applyOptions(PlannerRequest request, PlanOptions options) {
    request
      ..transitModes.addAll(
        options.transitModes.map((id) => _transitModes[id]).nonNulls,
      )
      ..top = options.top
      ..transferBufferMinutes = options.transferBufferMinutes
      ..firstMileMode = _accessModes[options.firstMileMode]!
      ..firstMileMinutes = options.firstMileTime
      ..lastMileMode = _accessModes[options.lastMileMode]!
      ..lastMileMinutes = options.lastMileTime
      ..wheelchair = options.wheelchair
      ..walkSpeedCmPerSec = options.walkSpeedCmPerSec
      ..avoidReservation = options.avoidReservation
      ..carryBike = options.carryBike;
    // Left unset rather than sent as 0: this field carries proto3 presence
    // precisely because 0 is a request — direct connections only — and a rider
    // who never touched the control has not made it.
    final maxTransfers = options.maxTransfers;
    if (maxTransfers != null) request.maxTransfers = maxTransfers;
  }
}
