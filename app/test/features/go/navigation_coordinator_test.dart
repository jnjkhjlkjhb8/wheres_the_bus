import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/navigation/navigation_coordinator.dart';

void main() {
  late PlanBloc planBloc;
  late JourneySessionBloc journeyBloc;

  setUp(() {
    planBloc = PlanBloc(repository: _FakeMaasRepository());
    journeyBloc = JourneySessionBloc(
      etaStream: (_) => const Stream.empty(),
      liveActivityEnabled: () => true,
    );
  });

  tearDown(() async {
    await planBloc.close();
    await journeyBloc.close();
  });

  NavigationCoordinator coordinator({
    required bool liveActivityEnabled,
    Stream<Position> Function()? positions,
    // Callback signature follows the event producer.
    // ignore: avoid_positional_boolean_parameters
    void Function(NavAction action, PlanPoint? cameraTarget, bool arrived)?
    onAutoAction,
    // Callback signature follows the event producer.
    // ignore: avoid_positional_boolean_parameters
    void Function(bool driving)? onAutopilotStatus,
  }) => NavigationCoordinator(
    planBloc: planBloc,
    journeySessionBloc: journeyBloc,
    liveActivityEnabled: () => liveActivityEnabled,
    positions: positions,
    onAutoAction: onAutoAction,
    onAutopilotStatus: onAutopilotStatus,
  );

  test('enabled start begins the plan and the transit journey', () async {
    final route = _route([_walkSection(25), _transitSection(25.1)]);
    final planReady = expectLater(
      planBloc.stream,
      emitsThrough(predicate<PlanState>((state) => state.activeLegIndex == 0)),
    );
    final journeyReady = expectLater(
      journeyBloc.stream,
      emitsThrough(
        predicate<JourneySessionState>(
          (state) => state.phase == JourneyPhase.waiting,
        ),
      ),
    );

    final cameraPoint = await coordinator(
      liveActivityEnabled: true,
    ).start(route: route, routeIndex: 2);

    await planReady;
    await journeyReady;
    expect(planBloc.state.selectedRouteIndex, 2);
    expect(journeyBloc.state.legs, hasLength(1));
    expect(cameraPoint, const PlanPoint(lat: 25, lng: 121));
  });

  test('disabled start begins only plan navigation', () async {
    final route = _route([_transitSection(25)]);
    final planReady = expectLater(
      planBloc.stream,
      emitsThrough(predicate<PlanState>((state) => state.activeLegIndex == 0)),
    );

    await coordinator(
      liveActivityEnabled: false,
    ).start(route: route, routeIndex: 0);

    await planReady;
    expect(journeyBloc.state.phase, JourneyPhase.idle);
  });

  test(
    'non-final advance moves only plan and returns next camera point',
    () async {
      final route = _route([_walkSection(25), _transitSection(25.1)]);
      final advanced = expectLater(
        planBloc.stream,
        emitsThrough(
          predicate<PlanState>((state) => state.activeLegIndex == 1),
        ),
      );

      final result = await coordinator(
        liveActivityEnabled: true,
      ).advance(route: route, activeLeg: 0);

      await advanced;
      expect(result.arrived, isFalse);
      expect(result.nextCameraPoint, const PlanPoint(lat: 25.1, lng: 121));
      expect(journeyBloc.state.phase, JourneyPhase.idle);
    },
  );

  test('final advance ends both lifecycles and reports arrival', () async {
    final route = _route([_transitSection(25)]);
    planBloc.add(const NavigationStarted());
    journeyBloc.add(JourneyStarted(legs: JourneyLeg.legsFromRoute(route)));
    await _waitForJourneyPhase(journeyBloc, JourneyPhase.waiting);
    await _waitForPlanLeg(planBloc, 0);

    final result = await coordinator(
      liveActivityEnabled: true,
    ).advance(route: route, activeLeg: 0);

    await _waitForJourneyPhase(journeyBloc, JourneyPhase.done);
    await _waitForPlanLeg(planBloc, null);
    expect(result.arrived, isTrue);
    expect(result.nextCameraPoint, isNull);
  });

  test('explicit end stops the plan and the journey', () async {
    final route = _route([_transitSection(25)]);
    planBloc.add(const NavigationStarted());
    journeyBloc.add(JourneyStarted(legs: JourneyLeg.legsFromRoute(route)));
    await _waitForJourneyPhase(journeyBloc, JourneyPhase.waiting);
    await _waitForPlanLeg(planBloc, 0);

    await coordinator(liveActivityEnabled: true).end();

    await _waitForJourneyPhase(journeyBloc, JourneyPhase.done);
    await _waitForPlanLeg(planBloc, null);
  });

  test('self-completed journey reconciliation ends the active plan', () async {
    planBloc.add(const NavigationStarted());
    await _waitForPlanLeg(planBloc, 0);

    final shouldResetCamera = await coordinator(
      liveActivityEnabled: true,
    ).reconcileJourneyDone();

    await _waitForPlanLeg(planBloc, null);
    expect(shouldResetCamera, isTrue);
  });

  test('route without transit starts plan without journey or PiP', () async {
    final route = _route([_walkSection(25), _walkSection(25.1)]);
    final planReady = expectLater(
      planBloc.stream,
      emitsThrough(predicate<PlanState>((state) => state.activeLegIndex == 0)),
    );

    await coordinator(
      liveActivityEnabled: true,
    ).start(route: route, routeIndex: 0);

    await planReady;
    expect(journeyBloc.state.phase, JourneyPhase.idle);
  });

  group('decideNavAction', () {
    const base = PlanPoint(lat: 25, lng: 121.5);
    final far = _northOf(base, 5000);

    PlanSection walk({required PlanPoint arrival}) =>
        _autopilotSection(type: 'walk', departure: base, arrival: arrival);

    PlanSection transit({
      required PlanPoint departure,
      required PlanPoint arrival,
    }) => _autopilotSection(
      type: 'transit',
      departure: departure,
      arrival: arrival,
    );

    NavAction decide({
      required PlanSection section,
      required bool boarded,
      required PlanPoint at,
    }) => decideNavAction(
      section: section,
      boarded: boarded,
      lat: at.lat,
      lon: at.lng,
    );

    test('walk well within 40m of arrival advances', () {
      final section = walk(arrival: base);
      expect(
        decide(section: section, boarded: false, at: _northOf(base, 5)),
        NavAction.advance,
      );
    });

    test('walk just inside 40m of arrival advances', () {
      final section = walk(arrival: base);
      expect(
        decide(section: section, boarded: false, at: _northOf(base, 39.5)),
        NavAction.advance,
      );
    });

    test('walk just outside 40m of arrival is none', () {
      final section = walk(arrival: base);
      expect(
        decide(section: section, boarded: false, at: _northOf(base, 40.5)),
        NavAction.none,
      );
    });

    test('walk well outside 40m of arrival is none', () {
      final section = walk(arrival: base);
      expect(
        decide(section: section, boarded: false, at: far),
        NavAction.none,
      );
    });

    test('walk ignores boarded and still advances within 40m', () {
      // Walk sections never read `boarded`; a stray `true` (e.g. leftover
      // from a prior transit leg) must not change the outcome.
      final section = walk(arrival: base);
      expect(
        decide(section: section, boarded: true, at: _northOf(base, 5)),
        NavAction.advance,
      );
    });

    test('transit not boarded well within 80m of departure is none', () {
      final section = transit(departure: base, arrival: far);
      expect(
        decide(section: section, boarded: false, at: _northOf(base, 5)),
        NavAction.none,
      );
    });

    test('transit not boarded just inside 80m of departure is none', () {
      final section = transit(departure: base, arrival: far);
      expect(
        decide(section: section, boarded: false, at: _northOf(base, 79.5)),
        NavAction.none,
      );
    });

    test('transit not boarded just outside 80m of departure boards', () {
      final section = transit(departure: base, arrival: far);
      expect(
        decide(section: section, boarded: false, at: _northOf(base, 80.5)),
        NavAction.board,
      );
    });

    test('transit not boarded well outside 80m of departure boards', () {
      final section = transit(departure: base, arrival: far);
      expect(
        decide(section: section, boarded: false, at: far),
        NavAction.board,
      );
    });

    test('transit boarded well within 60m of arrival alights', () {
      final section = transit(departure: far, arrival: base);
      expect(
        decide(section: section, boarded: true, at: _northOf(base, 5)),
        NavAction.alight,
      );
    });

    test('transit boarded just inside 60m of arrival alights', () {
      final section = transit(departure: far, arrival: base);
      expect(
        decide(section: section, boarded: true, at: _northOf(base, 59.5)),
        NavAction.alight,
      );
    });

    test('transit boarded just outside 60m of arrival is none', () {
      final section = transit(departure: far, arrival: base);
      expect(
        decide(section: section, boarded: true, at: _northOf(base, 60.5)),
        NavAction.none,
      );
    });

    test('transit boarded well outside 60m of arrival is none', () {
      final section = transit(departure: far, arrival: base);
      expect(
        decide(section: section, boarded: true, at: far),
        NavAction.none,
      );
    });
  });

  group('advanceWalkStep', () {
    const a = PlanPoint(lat: 25, lng: 121.5);
    final b = _northOf(a, 100);
    final c = _northOf(a, 200);
    List<PlanWalkStep> steps() => [
      _walkStep('depart', a),
      _walkStep('turn', b),
      _walkStep('arrive', c),
    ];
    int advance(int current, PlanPoint at) => advanceWalkStep(
      steps: steps(),
      current: current,
      lat: at.lat,
      lon: at.lng,
    );

    test('advances when within 20m of the next maneuver', () {
      expect(advance(0, _northOf(b, 10)), 1);
    });

    test('stays when outside 20m of the next maneuver', () {
      expect(advance(0, _northOf(b, 50)), 0);
    });

    test('advances only one step even when standing on a later maneuver', () {
      // At step 2's point while on step 0: the next maneuver is step 1 (100m
      // away), so the index must not skip ahead.
      expect(advance(0, c), 0);
    });

    test('reaching the next maneuver from a middle step moves forward one', () {
      expect(advance(1, _northOf(c, 5)), 2);
    });

    test('never advances past the last step', () {
      expect(advance(2, c), 2);
    });
  });

  group('shouldApplyHeading', () {
    // A gap comfortably past the ~200ms rate limit, so these cases isolate the
    // angular-delta decision from the rate limit.
    const past = Duration(seconds: 1);

    test('the first heading always applies (no prior bearing)', () {
      expect(
        shouldApplyHeading(last: null, next: 123, sinceLast: Duration.zero),
        isTrue,
      );
    });

    test('a delta above the 3 degree threshold applies', () {
      expect(shouldApplyHeading(last: 100, next: 104, sinceLast: past), isTrue);
    });

    test('a delta at or below the 3 degree threshold does not apply', () {
      expect(
        shouldApplyHeading(last: 100, next: 103, sinceLast: past),
        isFalse,
      );
      expect(
        shouldApplyHeading(last: 100, next: 102.5, sinceLast: past),
        isFalse,
      );
    });

    test('a large turn within the rate-limit window is held back', () {
      // 40 degrees is well past the angular threshold, but only 100ms elapsed
      // (< ~200ms), so the ~5/sec ceiling suppresses it.
      expect(
        shouldApplyHeading(
          last: 100,
          next: 140,
          sinceLast: const Duration(milliseconds: 100),
        ),
        isFalse,
      );
    });

    test('the same large turn applies once the rate-limit window passes', () {
      expect(
        shouldApplyHeading(
          last: 100,
          next: 140,
          sinceLast: const Duration(milliseconds: 250),
        ),
        isTrue,
      );
    });

    test('359 to 1 is a 2 degree circular delta and does not apply', () {
      // Linearly this is 358 degrees; on the circle it is 2, below threshold.
      expect(shouldApplyHeading(last: 359, next: 1, sinceLast: past), isFalse);
    });

    test('359 to 5 is a 6 degree circular delta and applies', () {
      expect(shouldApplyHeading(last: 359, next: 5, sinceLast: past), isTrue);
    });

    test('the wraparound delta is symmetric (1 to 359 stays below)', () {
      expect(shouldApplyHeading(last: 1, next: 359, sinceLast: past), isFalse);
    });
  });

  group('autopilot stream', () {
    test('drives walk-advance, board, and alight from GPS alone', () async {
      const pointB = PlanPoint(lat: 25, lng: 121.5);
      final pointC = _northOf(pointB, 5000);
      final route = _route([
        _autopilotSection(
          type: 'walk',
          departure: _northOf(pointB, 300),
          arrival: pointB,
        ),
        _autopilotSection(type: 'transit', departure: pointB, arrival: pointC),
      ]);
      final autoActions = <(NavAction, PlanPoint?, bool)>[];
      final controller = StreamController<Position>();
      addTearDown(controller.close);

      final autopilotPlanBloc = PlanBloc(
        repository: _FakeMaasRepository(routes: [route]),
      );
      addTearDown(autopilotPlanBloc.close);
      autopilotPlanBloc.add(
        const PlanSearchRequested(
          fromLat: 0,
          fromLon: 0,
          toLat: 0,
          toLon: 0,
          date: '2026-07-10',
          time: '12:00',
        ),
      );
      await autopilotPlanBloc.stream.firstWhere((s) => s.result != null);

      await NavigationCoordinator(
        planBloc: autopilotPlanBloc,
        journeySessionBloc: journeyBloc,
        liveActivityEnabled: () => true,
        positions: () => controller.stream,
        onAutoAction: (action, target, arrived) =>
            autoActions.add((action, target, arrived)),
      ).start(route: route, routeIndex: 0);

      await _waitForPlanLeg(autopilotPlanBloc, 0);
      await _waitForJourneyPhase(journeyBloc, JourneyPhase.waiting);

      controller
        ..add(_posAt(_northOf(pointB, 10)))
        ..add(_posAt(_northOf(pointB, 10)));
      await _waitForPlanLeg(autopilotPlanBloc, 1);

      // Moving away from the transit departure stop implies boarding.
      controller.add(_posAt(_northOf(pointB, 500)));
      await _waitForJourneyPhase(journeyBloc, JourneyPhase.riding);

      // Arriving near the transit leg's endpoint alights and, since this is
      // the final section, ends the whole navigation session.
      controller.add(_posAt(_northOf(pointC, 10)));
      await _waitForJourneyPhase(journeyBloc, JourneyPhase.done);
      await _waitForPlanLeg(autopilotPlanBloc, null);

      expect(
        autoActions.map((e) => e.$1),
        [NavAction.advance, NavAction.board, NavAction.alight],
      );
      expect(autoActions[0].$2, route.firstPoint(leg: 1));
      expect(autoActions[1].$2, isNull);
      expect(autoActions[2].$2, isNull);
      // The transit leg is the route's final section, so alighting it
      // arrives at the destination.
      expect(autoActions[0].$3, isFalse);
      expect(autoActions[1].$3, isFalse);
      expect(autoActions[2].$3, isTrue);
    });

    test(
      'dispose cancels the position subscription so no further autopilot '
      'transitions fire',
      () async {
        final route = _route([_transitSection(25)]);
        final autoActions = <NavAction>[];
        final controller = StreamController<Position>();
        addTearDown(controller.close);

        final autopilotPlanBloc = PlanBloc(
          repository: _FakeMaasRepository(routes: [route]),
        );
        addTearDown(autopilotPlanBloc.close);
        autopilotPlanBloc.add(
          const PlanSearchRequested(
            fromLat: 0,
            fromLon: 0,
            toLat: 0,
            toLon: 0,
            date: '2026-07-10',
            time: '12:00',
          ),
        );
        await autopilotPlanBloc.stream.firstWhere((s) => s.result != null);

        final coordinator = NavigationCoordinator(
          planBloc: autopilotPlanBloc,
          journeySessionBloc: journeyBloc,
          liveActivityEnabled: () => true,
          positions: () => controller.stream,
          onAutoAction: (action, target, arrived) => autoActions.add(action),
        );

        await coordinator.start(route: route, routeIndex: 0);
        await _waitForPlanLeg(autopilotPlanBloc, 0);
        await _waitForJourneyPhase(journeyBloc, JourneyPhase.waiting);

        coordinator.dispose();

        // Well outside the 80m board radius: if the subscription were still
        // live this would immediately dispatch BoardConfirmed and fire the
        // board haptic via onAutoAction.
        controller.add(
          _posAt(_northOf(const PlanPoint(lat: 25, lng: 121), 500)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(autoActions, isEmpty);
        expect(journeyBloc.state.phase, JourneyPhase.waiting);
        expect(autopilotPlanBloc.state.activeLegIndex, 0);
      },
    );

    test(
      'repeated waiting-phase positions past the board radius fire the '
      'board action exactly once',
      () async {
        final route = _route([_transitSection(25)]);
        final autoActions = <NavAction>[];
        final controller = StreamController<Position>();
        addTearDown(controller.close);

        final autopilotPlanBloc = PlanBloc(
          repository: _FakeMaasRepository(routes: [route]),
        );
        addTearDown(autopilotPlanBloc.close);
        autopilotPlanBloc.add(
          const PlanSearchRequested(
            fromLat: 0,
            fromLon: 0,
            toLat: 0,
            toLon: 0,
            date: '2026-07-10',
            time: '12:00',
          ),
        );
        await autopilotPlanBloc.stream.firstWhere((s) => s.result != null);

        await NavigationCoordinator(
          planBloc: autopilotPlanBloc,
          journeySessionBloc: journeyBloc,
          liveActivityEnabled: () => true,
          positions: () => controller.stream,
          onAutoAction: (action, target, arrived) => autoActions.add(action),
        ).start(route: route, routeIndex: 0);

        await _waitForPlanLeg(autopilotPlanBloc, 0);
        await _waitForJourneyPhase(journeyBloc, JourneyPhase.waiting);

        final farPos = _posAt(
          _northOf(const PlanPoint(lat: 25, lng: 121), 500),
        );
        controller
          ..add(farPos)
          ..add(farPos)
          ..add(farPos);

        await _waitForJourneyPhase(journeyBloc, JourneyPhase.riding);

        expect(autoActions.where((a) => a == NavAction.board), hasLength(1));
      },
    );

    test(
      'boards and alights a transit leg from GPS alone when Live Activity '
      'is off, without JourneySession ever being started',
      () async {
        const pointB = PlanPoint(lat: 25, lng: 121.5);
        final pointC = _northOf(pointB, 5000);
        final route = _route([
          _autopilotSection(
            type: 'transit',
            departure: pointB,
            arrival: pointC,
          ),
        ]);
        final autoActions = <NavAction>[];
        final controller = StreamController<Position>();
        addTearDown(controller.close);

        final autopilotPlanBloc = PlanBloc(
          repository: _FakeMaasRepository(routes: [route]),
        );
        addTearDown(autopilotPlanBloc.close);
        autopilotPlanBloc.add(
          const PlanSearchRequested(
            fromLat: 0,
            fromLon: 0,
            toLat: 0,
            toLon: 0,
            date: '2026-07-10',
            time: '12:00',
          ),
        );
        await autopilotPlanBloc.stream.firstWhere((s) => s.result != null);

        await NavigationCoordinator(
          planBloc: autopilotPlanBloc,
          journeySessionBloc: journeyBloc,
          liveActivityEnabled: () => false,
          positions: () => controller.stream,
          onAutoAction: (action, target, arrived) => autoActions.add(action),
        ).start(route: route, routeIndex: 0);

        await _waitForPlanLeg(autopilotPlanBloc, 0);
        // liveActivityEnabled is false, so start() never dispatched
        // JourneyStarted: JourneySession stays idle for the whole test.
        expect(journeyBloc.state.phase, JourneyPhase.idle);

        controller.add(_posAt(_northOf(pointB, 500)));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(autoActions, [NavAction.board]);
        expect(journeyBloc.state.phase, JourneyPhase.idle);

        // Arriving near the transit leg's endpoint alights and, since this
        // is the route's only/final section, ends the whole navigation.
        controller.add(_posAt(_northOf(pointC, 10)));
        await _waitForPlanLeg(autopilotPlanBloc, null);

        expect(autoActions, [NavAction.board, NavAction.alight]);
        expect(journeyBloc.state.phase, JourneyPhase.idle);
      },
    );

    test(
      'a manual board via JourneySession suppresses the phantom auto-board '
      'and still alights normally',
      () async {
        const pointB = PlanPoint(lat: 25, lng: 121.5);
        final pointC = _northOf(pointB, 5000);
        final route = _route([
          _autopilotSection(
            type: 'transit',
            departure: pointB,
            arrival: pointC,
          ),
        ]);
        final autoActions = <NavAction>[];
        final controller = StreamController<Position>();
        addTearDown(controller.close);

        final autopilotPlanBloc = PlanBloc(
          repository: _FakeMaasRepository(routes: [route]),
        );
        addTearDown(autopilotPlanBloc.close);
        autopilotPlanBloc.add(
          const PlanSearchRequested(
            fromLat: 0,
            fromLon: 0,
            toLat: 0,
            toLon: 0,
            date: '2026-07-10',
            time: '12:00',
          ),
        );
        await autopilotPlanBloc.stream.firstWhere((s) => s.result != null);

        await NavigationCoordinator(
          planBloc: autopilotPlanBloc,
          journeySessionBloc: journeyBloc,
          liveActivityEnabled: () => true,
          positions: () => controller.stream,
          onAutoAction: (action, target, arrived) => autoActions.add(action),
        ).start(route: route, routeIndex: 0);

        await _waitForPlanLeg(autopilotPlanBloc, 0);
        await _waitForJourneyPhase(journeyBloc, JourneyPhase.waiting);

        // Mirrors the manual 我上車了 button: BoardConfirmed dispatched
        // straight to JourneySessionBloc, bypassing the coordinator, so
        // `_lastAutoBoardedLeg` never learns about this board.
        journeyBloc.add(const BoardConfirmed());
        await _waitForJourneyPhase(journeyBloc, JourneyPhase.riding);

        controller.add(_posAt(_northOf(pointB, 500)));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(autoActions, isEmpty);

        // Arriving near the transit leg's endpoint still alights normally.
        controller.add(_posAt(_northOf(pointC, 10)));
        await _waitForJourneyPhase(journeyBloc, JourneyPhase.done);
        await _waitForPlanLeg(autopilotPlanBloc, null);

        expect(autoActions, [NavAction.alight]);
      },
    );

    test(
      'start() optimistically emits driving=true before any GPS fix',
      () async {
        final route = _route([_transitSection(25)]);
        final controller = StreamController<Position>();
        addTearDown(controller.close);
        final driving = <bool>[];

        await coordinator(
          liveActivityEnabled: true,
          positions: () => controller.stream,
          onAutopilotStatus: driving.add,
        ).start(route: route, routeIndex: 0);

        expect(driving, [true]);
      },
    );

    test('a stream error emits driving=false', () async {
      final route = _route([_transitSection(25)]);
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final driving = <bool>[];

      await coordinator(
        liveActivityEnabled: true,
        positions: () => controller.stream,
        onAutopilotStatus: driving.add,
      ).start(route: route, routeIndex: 0);
      controller.addError(Exception('no permission'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(driving, [true, false]);
    });

    test(
      'a subsequent valid position emits driving=true again after an error',
      () async {
        final route = _route([_transitSection(25)]);
        final controller = StreamController<Position>();
        addTearDown(controller.close);
        final driving = <bool>[];

        await coordinator(
          liveActivityEnabled: true,
          positions: () => controller.stream,
          onAutopilotStatus: driving.add,
        ).start(route: route, routeIndex: 0);
        controller.addError(Exception('no permission'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        controller.add(_posAt(const PlanPoint(lat: 25, lng: 121)));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(driving, [true, false, true]);
      },
    );

    test(
      'two consecutive positions do not emit driving=true twice in a row '
      '(dedupe on unchanged value)',
      () async {
        final route = _route([_transitSection(25)]);
        final controller = StreamController<Position>();
        addTearDown(controller.close);
        final driving = <bool>[];

        await coordinator(
          liveActivityEnabled: true,
          positions: () => controller.stream,
          onAutopilotStatus: driving.add,
        ).start(route: route, routeIndex: 0);
        controller
          ..add(_posAt(const PlanPoint(lat: 25, lng: 121)))
          ..add(_posAt(const PlanPoint(lat: 25.001, lng: 121)));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Only the optimistic emission from start() fires; both positions
        // land on the already-`true` value, so neither re-emits.
        expect(driving, [true]);
      },
    );
  });

  group('reconcileJourneyDone', () {
    test(
      'a trailing walk after the last transit leg keeps navigating alive',
      () async {
        final route = _route([_transitSection(25), _walkSection(25.1)]);
        final testPlanBloc = PlanBloc(
          repository: _FakeMaasRepository(routes: [route]),
        );
        addTearDown(testPlanBloc.close);
        testPlanBloc.add(
          const PlanSearchRequested(
            fromLat: 0,
            fromLon: 0,
            toLat: 0,
            toLon: 0,
            date: '2026-07-10',
            time: '12:00',
          ),
        );
        await testPlanBloc.stream.firstWhere((s) => s.result != null);

        final coord = NavigationCoordinator(
          planBloc: testPlanBloc,
          journeySessionBloc: journeyBloc,
          liveActivityEnabled: () => false,
        );
        await coord.start(route: route, routeIndex: 0);
        await _waitForPlanLeg(testPlanBloc, 0);
        // Alighting the last transit leg already advanced the active leg to
        // the trailing walk section, mirroring what _onPosition/advance()
        // would have done before JourneySession reported `done`.
        testPlanBloc.add(const StopArrived(legIndex: 1, stopIndex: 0));
        await _waitForPlanLeg(testPlanBloc, 1);

        final shouldResetCamera = await coord.reconcileJourneyDone();

        expect(shouldResetCamera, isFalse);
        expect(testPlanBloc.state.activeLegIndex, 1);
      },
    );

    test(
      'no trailing walk after the last transit leg ends the navigation',
      () async {
        final route = _route([_walkSection(25), _transitSection(25.1)]);
        final testPlanBloc = PlanBloc(
          repository: _FakeMaasRepository(routes: [route]),
        );
        addTearDown(testPlanBloc.close);
        testPlanBloc.add(
          const PlanSearchRequested(
            fromLat: 0,
            fromLon: 0,
            toLat: 0,
            toLon: 0,
            date: '2026-07-10',
            time: '12:00',
          ),
        );
        await testPlanBloc.stream.firstWhere((s) => s.result != null);

        final coord = NavigationCoordinator(
          planBloc: testPlanBloc,
          journeySessionBloc: journeyBloc,
          liveActivityEnabled: () => false,
        );
        await coord.start(route: route, routeIndex: 0);
        await _waitForPlanLeg(testPlanBloc, 0);
        testPlanBloc.add(const StopArrived(legIndex: 1, stopIndex: 0));
        await _waitForPlanLeg(testPlanBloc, 1);

        final shouldResetCamera = await coord.reconcileJourneyDone();

        await _waitForPlanLeg(testPlanBloc, null);
        expect(shouldResetCamera, isTrue);
      },
    );
  });
}

/// Earth radius (meters) used by geolocator's `distanceBetween`, kept in
/// sync so `_northOf` offsets land at an exact distance for boundary tests.
const _earthRadiusMeters = 6378137.0;

/// A point `meters` due north of [base]. Pure latitude offset: geolocator's
/// haversine distance for a same-longitude pair reduces to `R * dLatRadians`
/// exactly, so this hits the requested distance with no small-angle error.
PlanPoint _northOf(PlanPoint base, double meters) {
  final dLatDeg = (meters / _earthRadiusMeters) * 180 / math.pi;
  return PlanPoint(lat: base.lat + dLatDeg, lng: base.lng);
}

Position _posAt(PlanPoint point) => Position(
  latitude: point.lat,
  longitude: point.lng,
  timestamp: DateTime.now(),
  accuracy: 0,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

PlanSection _autopilotSection({
  required String type,
  required PlanPoint departure,
  required PlanPoint arrival,
}) => PlanSection(
  type: type,
  travelSummary: const PlanTravelSummary(duration: 300, length: 1000),
  departure: PlanPlace(
    name: '起點',
    type: 'stop',
    location: departure,
    time: '2026-07-10T12:00:00+08:00',
  ),
  arrival: PlanPlace(
    name: '終點',
    type: 'stop',
    location: arrival,
    time: '2026-07-10T12:05:00+08:00',
  ),
  transport: type == 'walk'
      ? const PlanTransport(
          mode: 'walk',
          name: '步行',
          shortName: '',
          longName: '',
          headsign: '',
          category: '',
          routeColor: '',
        )
      : const PlanTransport(
          mode: 'bus',
          name: '公車',
          shortName: '307',
          longName: '',
          headsign: '終點',
          category: '',
          routeColor: '',
        ),
  intermediateStops: const [],
  identity: const PlanIdentity(
    routeType: 'bus',
    routeKey: '307',
    direction: '0',
    departureStopKey: 'A',
    arrivalStopKey: 'B',
    supported: true,
  ),
);

Future<void> _waitForJourneyPhase(
  JourneySessionBloc bloc,
  JourneyPhase phase,
) async {
  if (bloc.state.phase == phase) return;
  await bloc.stream.firstWhere((state) => state.phase == phase);
}

Future<void> _waitForPlanLeg(PlanBloc bloc, int? leg) async {
  if (bloc.state.activeLegIndex == leg) return;
  await bloc.stream.firstWhere((state) => state.activeLegIndex == leg);
}

PlanRoute _route(List<PlanSection> sections) => PlanRoute(
  travelTime: 600,
  startTime: '12:00',
  endTime: '12:10',
  transfers: 0,
  sections: sections,
);

PlanSection _walkSection(double lat) => _section(
  type: 'walk',
  lat: lat,
  transport: const PlanTransport(
    mode: 'walk',
    name: '步行',
    shortName: '',
    longName: '',
    headsign: '',
    category: '',
    routeColor: '',
  ),
);

PlanSection _transitSection(double lat) => _section(
  type: 'transit',
  lat: lat,
  transport: const PlanTransport(
    mode: 'bus',
    name: '公車',
    shortName: '307',
    longName: '',
    headsign: '終點',
    category: '',
    routeColor: '',
  ),
);

PlanSection _section({
  required String type,
  required double lat,
  required PlanTransport transport,
}) => PlanSection(
  type: type,
  travelSummary: const PlanTravelSummary(duration: 300, length: 1000),
  departure: PlanPlace(
    name: '起點',
    type: 'stop',
    location: PlanPoint(lat: lat, lng: 121),
    time: '2026-07-10T12:00:00+08:00',
  ),
  arrival: PlanPlace(
    name: '終點',
    type: 'stop',
    location: PlanPoint(lat: lat + 0.01, lng: 121.01),
    time: '2026-07-10T12:05:00+08:00',
  ),
  transport: transport,
  intermediateStops: const [],
  identity: const PlanIdentity(
    routeType: 'bus',
    routeKey: '307',
    direction: '0',
    departureStopKey: 'A',
    arrivalStopKey: 'B',
    supported: true,
  ),
);

PlanWalkStep _walkStep(String maneuverType, PlanPoint location) => PlanWalkStep(
  instruction: maneuverType,
  maneuverType: maneuverType,
  modifier: '',
  distanceMeters: 100,
  durationSeconds: 80,
  location: location,
);

class _FakeMaasRepository implements MaasRepository {
  _FakeMaasRepository({this.routes = const []});

  final List<PlanRoute> routes;

  @override
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
  }) => Stream.value((result: PlanResult(routes: routes), complete: true));
}
