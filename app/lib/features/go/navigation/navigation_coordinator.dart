import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart'
    show isWalk;

// GPS-noise tunables for decideNavAction. Bump these if real-world
// testing shows false triggers; the ceiling is "wide enough to fire near a
// stop, narrow enough not to fire from the next block over".
const _kWalkArrivalRadiusMeters = 40.0;
const _kBoardDepartRadiusMeters = 80.0;
const _kAlightArrivalRadiusMeters = 60.0;

// display-only radius for advancing the current turn-by-turn walk
// step to the next maneuver. Deliberately tighter than the leg-arrival radius:
// tuning it only changes which instruction line shows, never leg progress.
const _kWalkStepAdvanceRadiusMeters = 20.0;

/// What the autopilot decided to do with one GPS fix.
enum NavAction { none, board, alight, advance }

NavAction decideNavAction({
  required PlanSection section,
  required bool boarded,
  required double lat,
  required double lon,
}) {
  if (isWalk(section)) {
    return _arrivalAction(
      section.arrival.location,
      lat,
      lon,
      _kWalkArrivalRadiusMeters,
      NavAction.advance,
    );
  }
  if (!boarded) return _boardingAction(section.departure.location, lat, lon);
  return _arrivalAction(
    section.arrival.location,
    lat,
    lon,
    _kAlightArrivalRadiusMeters,
    NavAction.alight,
  );
}

NavAction _arrivalAction(
  PlanPoint arrival,
  double lat,
  double lon,
  double radius,
  NavAction action,
) {
  final distance = Geolocator.distanceBetween(
    lat,
    lon,
    arrival.lat,
    arrival.lng,
  );
  return distance <= radius ? action : NavAction.none;
}

NavAction _boardingAction(PlanPoint departure, double lat, double lon) {
  final distance = Geolocator.distanceBetween(
    lat,
    lon,
    departure.lat,
    departure.lng,
  );
  return distance > _kBoardDepartRadiusMeters
      ? NavAction.board
      : NavAction.none;
}

/// Pure: advance the current walk-step index when the GPS fix reaches the next
/// maneuver point. Display-only — it never advances the leg. The index only
/// increases, so GPS jitter can never rewind the shown instruction.
int advanceWalkStep({
  required List<PlanWalkStep> steps,
  required int current,
  required double lat,
  required double lon,
}) {
  if (current >= steps.length - 1) return current;
  final next = steps[current + 1].location;
  final distance = Geolocator.distanceBetween(lat, lon, next.lat, next.lng);
  return distance <= _kWalkStepAdvanceRadiusMeters ? current + 1 : current;
}

const _kHeadingMinDeltaDeg = 3.0;
const _kHeadingMinInterval = Duration(milliseconds: 200);
const _kFullTurnDeg = 360.0;

bool shouldApplyHeading({
  required double? last,
  required double next,
  required Duration sinceLast,
}) {
  if (last == null) return true;
  if (sinceLast < _kHeadingMinInterval) return false;
  final raw = (next - last).abs() % _kFullTurnDeg;
  final delta = raw > _kFullTurnDeg / 2 ? _kFullTurnDeg - raw : raw;
  return delta > _kHeadingMinDeltaDeg;
}

class NavigationAdvanceResult {
  const NavigationAdvanceResult({required this.arrived, this.nextCameraPoint});

  final bool arrived;
  final PlanPoint? nextCameraPoint;
}

class NavigationCoordinator {
  NavigationCoordinator({
    required PlanBloc planBloc,
    required JourneySessionBloc journeySessionBloc,
    required bool Function() liveActivityEnabled,
    Stream<Position> Function()? positions,
    // Callback signature follows the event producer.
    // ignore: avoid_positional_boolean_parameters
    void Function(NavAction action, PlanPoint? cameraTarget, bool arrived)?
    onAutoAction,
    // Callback signature follows the event producer.
    // ignore: avoid_positional_boolean_parameters
    void Function(bool driving)? onAutopilotStatus,
    void Function(Position fix)? onFollowUpdate,
  }) : _planBloc = planBloc,
       _journeySessionBloc = journeySessionBloc,
       _liveActivityEnabled = liveActivityEnabled,
       _positions = positions,
       _onAutoAction = onAutoAction,
       _onAutopilotStatus = onAutopilotStatus,
       _onFollowUpdate = onFollowUpdate;

  final PlanBloc _planBloc;
  final JourneySessionBloc _journeySessionBloc;
  final bool Function() _liveActivityEnabled;
  final Stream<Position> Function()? _positions;
  // Callback signature follows the event producer.
  // ignore: avoid_positional_boolean_parameters
  final void Function(NavAction action, PlanPoint? cameraTarget, bool arrived)?
  _onAutoAction;
  // Callback signature follows the event producer.
  // ignore: avoid_positional_boolean_parameters
  final void Function(bool driving)? _onAutopilotStatus;
  // Raw fix passed to the UI on every tick so the camera can follow the user;
  // the UI owns the camera (MaaS navigation definition), the coordinator only
  // forwards the position it already subscribes to (no second GPS stream).
  final void Function(Position fix)? _onFollowUpdate;

  StreamSubscription<Position>? _posSub;

  /// Dedupe guard for [_onAutopilotStatus]: null until the first emission
  /// after `start()`, so the optimistic `true` fired there always emits even
  /// if a prior navigation last emitted `true` too.
  bool? _driving;

  /// Guards advance/alight against re-firing while a GPS fix lingers inside
  /// the trigger radius.
  int? _lastAutoAdvancedLeg;

  int? _lastAutoBoardedLeg;

  Future<PlanPoint?> start({
    required PlanRoute route,
    required int routeIndex,
  }) async {
    _planBloc
      ..add(RouteSelected(index: routeIndex))
      ..add(const NavigationStarted());
    final legs = JourneyLeg.legsFromRoute(route);
    if (legs.isNotEmpty && _liveActivityEnabled()) {
      _journeySessionBloc.add(JourneyStarted(legs: legs));
    }
    _lastAutoAdvancedLeg = null;
    _lastAutoBoardedLeg = null;
    _driving = null;
    _setDriving(true);
    _subscribePositions();
    return route.firstPoint();
  }

  void _subscribePositions() {
    final positions = _positions;
    if (positions == null) return;
    unawaited(_posSub?.cancel());
    _posSub = positions().listen(
      (position) {
        _setDriving(true);
        _onFollowUpdate?.call(position);
        _onPosition(position);
      },
      onError: (Object _) => _setDriving(false),
      onDone: () => _setDriving(false),
    );
  }

  /// Emits [_onAutopilotStatus] only on an actual change, so the nav sheet
  /// doesn't rebuild on every GPS fix once the manual controls are already
  /// hidden.
  void _setDriving(bool v) {
    if (_driving == v) return;
    _driving = v;
    _onAutopilotStatus?.call(v);
  }

  void _onPosition(Position position) {
    final navigation = _activeNavigation();
    if (navigation == null) return;
    final (route, activeLeg) = navigation;
    final section = route.sections[activeLeg];
    _advanceWalkInstruction(section, position);
    final boarded =
        _lastAutoBoardedLeg == activeLeg ||
        _journeySessionBloc.state.phase == JourneyPhase.riding;
    final action = decideNavAction(
      section: section,
      boarded: boarded,
      lat: position.latitude,
      lon: position.longitude,
    );
    _applyAction(action, boarded, route, activeLeg);
  }

  (PlanRoute, int)? _activeNavigation() {
    final activeLeg = _planBloc.state.activeLegIndex;
    if (activeLeg == null) return null;
    final route = _currentRoute();
    if (route == null) return null;
    return activeLeg < route.sections.length ? (route, activeLeg) : null;
  }

  void _applyAction(
    NavAction action,
    bool boarded,
    PlanRoute route,
    int activeLeg,
  ) {
    if (action == NavAction.none) return;
    if (action == NavAction.board) {
      _boardLeg(boarded, activeLeg);
      return;
    }
    _advanceLeg(action, route, activeLeg);
  }

  void _boardLeg(bool boarded, int activeLeg) {
    if (boarded) return;
    _lastAutoBoardedLeg = activeLeg;
    _journeySessionBloc.add(const BoardConfirmed());
    _onAutoAction?.call(NavAction.board, null, false);
  }

  void _advanceLeg(NavAction action, PlanRoute route, int activeLeg) {
    if (_lastAutoAdvancedLeg == activeLeg) return;
    _lastAutoAdvancedLeg = activeLeg;
    if (action == NavAction.alight) {
      _journeySessionBloc.add(const AlightConfirmed());
    }
    unawaited(_autoAdvance(route, activeLeg, action));
  }

  void _advanceWalkInstruction(PlanSection section, Position position) {
    // Display-only: advance the turn-by-turn walk step. Never touches leg
    // advancement, which decideNavAction below still owns exclusively.
    if (isWalk(section) && section.walkSteps.isNotEmpty) {
      final current = _planBloc.state.activeWalkStepIndex;
      final next = advanceWalkStep(
        steps: section.walkSteps,
        current: current,
        lat: position.latitude,
        lon: position.longitude,
      );
      if (next != current) {
        _planBloc.add(WalkStepAdvanced(index: next));
      }
    }
  }

  Future<void> _autoAdvance(
    PlanRoute route,
    int activeLeg,
    NavAction action,
  ) async {
    final result = await advance(route: route, activeLeg: activeLeg);
    _onAutoAction?.call(action, result.nextCameraPoint, result.arrived);
  }

  Future<NavigationAdvanceResult> advance({
    required PlanRoute route,
    required int activeLeg,
  }) async {
    if (activeLeg >= route.sections.length - 1) {
      await end();
      return const NavigationAdvanceResult(arrived: true);
    }
    final nextLeg = activeLeg + 1;
    _planBloc.add(StopArrived(legIndex: nextLeg, stopIndex: 0));
    return NavigationAdvanceResult(
      arrived: false,
      nextCameraPoint: route.firstPoint(leg: nextLeg),
    );
  }

  Future<void> end() async {
    unawaited(_posSub?.cancel());
    _planBloc.add(const NavigationEnded());
    _journeySessionBloc.add(const JourneyCancelled(userInitiated: true));
  }

  Future<bool> reconcileJourneyDone() async {
    final activeLeg = _planBloc.state.activeLegIndex;
    if (activeLeg == null) {
      unawaited(_posSub?.cancel());
      return false;
    }
    final route = _currentRoute();
    if (route != null && _hasTrailingWalk(route)) {
      return false;
    }
    unawaited(_posSub?.cancel());
    _planBloc.add(const NavigationEnded());
    return true;
  }

  /// Resolves the route backing the current navigation, mirroring the lookup
  /// `_onPosition` performs against `PlanBloc`'s `selectedRouteIndex`/`result`.
  PlanRoute? _currentRoute() {
    final routeIndex = _planBloc.state.selectedRouteIndex;
    final routes = _planBloc.state.result?.routes;
    if (routeIndex == null || routes == null || routeIndex >= routes.length) {
      return null;
    }
    return routes[routeIndex];
  }

  /// True iff a walk section follows the route's last transit section, i.e.
  /// alighting the final transit leg does not yet mean the journey is over.
  bool _hasTrailingWalk(PlanRoute route) {
    final lastTransit = route.sections.lastIndexWhere((s) => !isWalk(s));
    return lastTransit != -1 && lastTransit < route.sections.length - 1;
  }

  void dispose() {
    unawaited(_posSub?.cancel());
  }
}
