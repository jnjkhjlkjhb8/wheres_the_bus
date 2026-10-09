import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/generated/maas.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';

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
  /// TDX quota).
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

class MaasRepository {
  MaasRepository({MaasServiceClient? client}) : _client = client;

  static final MaasRepository instance = MaasRepository();

  final MaasServiceClient? _client;
  MaasServiceClient get _grpc => _client ?? GrpcClient.instance.maas;

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
  }) {
    return _grpc
        .planStream(
          _request(
            fromLat: fromLat,
            fromLon: fromLon,
            toLat: toLat,
            toLon: toLon,
            date: date,
            time: time,
            arriveBy: arriveBy,
            options: options,
            pageCursor: pageCursor,
            legAlternatives: legAlternatives,
          ),
        )
        .map(
          (update) => (
            result: PlanResult.fromProto(update.plan),
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

  // The unary `plan` RPC stays on the router for app versions already in the
  // wild, but nothing in this build calls it: every plan goes through the
  // streaming path above.

  MaasPlanRequest _request({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required String date,
    required String time,
    required bool arriveBy,
    required PlanOptions options,
    required String pageCursor,
    required int legAlternatives,
  }) {
    final request = MaasPlanRequest(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      date: date,
      time: time,
      arriveBy: arriveBy,
      gc: options.gc,
      transitModes: options.transitModes,
      top: options.top,
      transferTimeMin: options.transferMin,
      transferTimeMax: options.transferMax,
      firstMileMode: options.firstMileMode,
      firstMileTime: options.firstMileTime,
      lastMileMode: options.lastMileMode,
      lastMileTime: options.lastMileTime,
      wheelchair: options.wheelchair,
      walkSpeedCmPerSec: options.walkSpeedCmPerSec,
      avoidReservation: options.avoidReservation,
      carryBike: options.carryBike,
      pageCursor: pageCursor,
      legAlternatives: legAlternatives,
    );
    // Left unset rather than sent as 0: this field carries proto3 presence
    // precisely because 0 is a request — direct connections only — and a rider
    // who never touched the control has not made it.
    final maxTransfers = options.maxTransfers;
    if (maxTransfers != null) request.maxTransfers = maxTransfers;
    return request;
  }
}
