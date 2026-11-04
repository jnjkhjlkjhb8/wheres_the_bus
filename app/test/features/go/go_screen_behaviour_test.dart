import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart'
    show PlanFailureKind;
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/fakes/map_platform.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'support/go_harness.dart';

PlanSection _leg(
  PlanPoint from,
  PlanPoint to, {
  bool walk = false,
  String fromName = 'A',
  String toName = 'B',
  String mode = 'BUS',
}) => PlanSection(
  type: walk ? 'pedestrian' : 'transit',
  travelSummary: const PlanTravelSummary(duration: 600, length: 100),
  departure: PlanPlace(name: fromName, type: '', location: from, time: ''),
  arrival: PlanPlace(name: toName, type: '', location: to, time: ''),
  transport: PlanTransport(
    mode: walk ? '' : mode,
    name: '307',
    shortName: '307',
    longName: '',
    headsign: '',
    category: '',
    routeColor: '',
  ),
  intermediateStops: const [],
);

PlanRoute _route(List<PlanSection> sections) => PlanRoute(
  travelTime: 600,
  startTime: '',
  endTime: '',
  transfers: 0,
  sections: sections,
);

const _a = PlanPoint(lat: 25, lng: 121);
const _b = PlanPoint(lat: 25.1, lng: 121.1);
const _c = PlanPoint(lat: 26, lng: 122);
const _d = PlanPoint(lat: 26.1, lng: 122.1);

List<Object?> _json(CameraUpdate update) => update.toJson() as List<Object?>;

Iterable<List<Object?>> _updates(FakeMapPlatform maps, String kind) => [
  for (final update in maps.cameraUpdates)
    if (_json(update).first == kind) _json(update),
];

void main() {
  final harness = GoHarness()..install();
  final i18n = lookupAppI18n(const Locale('zh'));

  PlanResult result(List<PlanRoute> routes, {String next = ''}) =>
      PlanResult(routes: routes, nextPageCursor: next);

  PlanState results(
    List<PlanRoute> routes, {
    bool previewing = false,
    int? selected = 0,
    String next = '',
  }) => PlanState(
    status: PlanStatus.success,
    result: result(routes, next: next),
    selectedRouteIndex: selected,
    previewing: previewing,
  );

  PlanState navigating(PlanRoute route, {int leg = 0}) => PlanState(
    status: PlanStatus.success,
    result: result([route]),
    selectedRouteIndex: 0,
    activeLegIndex: leg,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> tapLabel(WidgetTester tester, String label) async {
    tester
        .widgetList<Pressable>(find.byType(Pressable))
        .firstWhere((p) => p.semanticLabel == label)
        .onTap!();
    await tester.pump();
  }

  testWidgets('the map opens on the default city view at zoom 14', (
    tester,
  ) async {
    await harness.pump(
      tester,
      const PlanState(status: PlanStatus.loading),
      destination: goTestDestination,
    );
    await settle(tester);
    expect(
      harness.maps.initialPositions.first,
      const CameraPosition(target: LatLng(25.0416, 121.5438), zoom: 14),
    );
    await harness.dispose(tester);
  });

  testWidgets('framing: results fit every route, preview only the chosen', (
    tester,
  ) async {
    final routes = [
      _route([_leg(_a, _b)]),
      _route([_leg(_c, _d)]),
    ];
    final (plan, _) = await harness.pump(
      tester,
      const PlanState(status: PlanStatus.loading),
      destination: goTestDestination,
    );
    await settle(tester);
    harness.maps.cameraUpdates.clear();
    plan.show(results(routes));
    await settle(tester);
    var fit = harness.maps.cameraUpdates.last as CameraUpdateNewLatLngBounds;
    expect(fit.bounds.southwest, const LatLng(25, 121));
    expect(fit.bounds.northeast, const LatLng(26.1, 122.1));
    plan.show(results(routes, previewing: true, selected: 1));
    await settle(tester);
    fit = harness.maps.cameraUpdates.last as CameraUpdateNewLatLngBounds;
    expect(fit.bounds.southwest, const LatLng(26, 122));
    expect(fit.bounds.northeast, const LatLng(26.1, 122.1));
    await harness.dispose(tester);
  });

  testWidgets('an empty result frames nothing; loading frames the trip', (
    tester,
  ) async {
    final (plan, _) = await harness.pump(
      tester,
      const PlanState(),
      destination: goTestDestination,
    );
    await settle(tester);
    harness.maps.cameraUpdates.clear();
    plan.show(results(const []));
    await settle(tester);
    expect(harness.maps.cameraUpdates, isEmpty);
    plan.show(const PlanState(status: PlanStatus.loading));
    await settle(tester);
    expect(_updates(harness.maps, 'newLatLngBounds'), hasLength(1));
    plan.show(
      const PlanState(
        status: PlanStatus.failure,
        failure: PlanFailureKind.timeout,
      ),
    );
    await settle(tester);
    expect(_updates(harness.maps, 'newLatLngBounds'), hasLength(1));
    await harness.dispose(tester);
  });

  testWidgets('a map created over a preview frames that route', (tester) async {
    final routes = [
      _route([_leg(_a, _b)]),
      _route([_leg(_c, _d)]),
    ];
    await harness.pump(
      tester,
      results(routes, previewing: true, selected: 1),
      destination: goTestDestination,
    );
    await settle(tester);
    final fit = _updates(harness.maps, 'newLatLngBounds').first;
    expect(fit, isNotEmpty);
    final bounds =
        harness.maps.cameraUpdates.firstWhere(
              (u) => _json(u).first == 'newLatLngBounds',
            )
            as CameraUpdateNewLatLngBounds;
    expect(bounds.bounds.northeast, const LatLng(26.1, 122.1));
    await harness.dispose(tester);
  });

  testWidgets('a map created over results frames every route', (tester) async {
    final routes = [
      _route([_leg(_a, _b)]),
      _route([_leg(_c, _d)]),
    ];
    await harness.pump(tester, results(routes), destination: goTestDestination);
    await settle(tester);
    final bounds =
        harness.maps.cameraUpdates.firstWhere(
              (u) => _json(u).first == 'newLatLngBounds',
            )
            as CameraUpdateNewLatLngBounds;
    expect(bounds.bounds.southwest, const LatLng(25, 121));
    expect(bounds.bounds.northeast, const LatLng(26.1, 122.1));
    await harness.dispose(tester);
  });

  testWidgets('back is allowed only from the bare results list', (
    tester,
  ) async {
    final routes = [
      _route([_leg(_a, _b)]),
    ];
    final (plan, _) = await harness.pump(
      tester,
      results(routes),
      destination: goTestDestination,
    );
    await settle(tester);
    bool canPop() => tester
        .widget<PopScope<Object?>>(
          find
              .ancestor(
                of: find.byType(Scaffold).first,
                matching: find.byWidgetPredicate((w) => w is PopScope),
              )
              .first,
        )
        .canPop;
    expect(canPop(), isTrue);
    plan.show(results(routes, previewing: true));
    await settle(tester);
    expect(canPop(), isFalse);
    plan.show(navigating(routes.first));
    await settle(tester);
    expect(canPop(), isFalse);
    await harness.dispose(tester);
  });

  testWidgets('the fastest badge marks only the first of several routes', (
    tester,
  ) async {
    final routes = [
      _route([_leg(_a, _b)]),
      _route([_leg(_c, _d)]),
    ];
    final (plan, _) = await harness.pump(
      tester,
      results(routes, previewing: true, selected: 0),
      destination: goTestDestination,
    );
    await settle(tester);
    expect(find.text(i18n.goBadgeFastest), findsOneWidget);
    plan.show(results(routes, previewing: true, selected: 1));
    await settle(tester);
    expect(find.text(i18n.goBadgeFastest), findsNothing);
    plan.show(results([routes.first], previewing: true, selected: 0));
    await settle(tester);
    expect(find.text(i18n.goBadgeFastest), findsNothing);
    await harness.dispose(tester);
  });

  testWidgets('a chosen route index picks that route, not the first', (
    tester,
  ) async {
    final routes = [
      _route([_leg(_a, _b, fromName: 'First', toName: 'FirstEnd')]),
      _route([_leg(_c, _d, fromName: 'Second', toName: 'SecondEnd')]),
    ];
    await harness.pump(
      tester,
      results(routes, previewing: true, selected: 1),
      destination: goTestDestination,
    );
    await settle(tester);
    expect(find.textContaining('Second'), findsWidgets);
    expect(find.textContaining('First'), findsNothing);
    await harness.dispose(tester);
  });

  testWidgets('route changes while planning re-frame the map', (tester) async {
    final routes = [
      _route([_leg(_a, _b)]),
      _route([_leg(_c, _d)]),
    ];
    final (plan, _) = await harness.pump(
      tester,
      results(routes),
      destination: goTestDestination,
    );
    await settle(tester);
    harness.maps.cameraUpdates.clear();
    plan.show(results(routes, selected: 1));
    await settle(tester);
    expect(_updates(harness.maps, 'newLatLngBounds'), hasLength(1));
    harness.maps.cameraUpdates.clear();
    plan.show(results(routes, selected: 1, previewing: true));
    await settle(tester);
    expect(_updates(harness.maps, 'newLatLngBounds'), hasLength(1));
    await harness.dispose(tester);
  });

  testWidgets('the origin is swapped with a set destination and replans', (
    tester,
  ) async {
    final (plan, _) = await harness.pump(
      tester,
      const PlanState(status: PlanStatus.loading),
      destination: goTestDestination,
    );
    await settle(tester);
    plan.events.clear();
    await tapLabel(tester, i18n.goSwapEndpoints);
    final request = plan.events.whereType<PlanSearchRequested>().single;
    expect((request.fromLat, request.fromLon), (25.2, 121.2));
    expect((request.toLat, request.toLon), (25, 121));
    await harness.dispose(tester);
  });

  testWidgets('swapping a lone origin moves it into the destination', (
    tester,
  ) async {
    await harness.pump(tester, const PlanState());
    await settle(tester);
    expect(find.text(i18n.goSuggestedRoutes), findsNothing);
    await tapLabel(tester, i18n.goSwapEndpoints);
    await settle(tester);
    // The entry surface gives way to the map once a destination exists.
    expect(find.byType(GoogleMap), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('back from results of a picked destination returns to the form', (
    tester,
  ) async {
    final (plan, _) = await harness.pump(tester, const PlanState());
    await settle(tester);
    await tapLabel(tester, i18n.goSwapEndpoints);
    await settle(tester);
    expect(find.byType(GoogleMap), findsOneWidget);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(GoogleMap), findsNothing);
    expect(plan.events.whereType<PlanSearchCancelled>(), hasLength(1));
    await harness.dispose(tester);
  });

  testWidgets('swapping with nothing to swap changes nothing', (tester) async {
    harness.location.enabled = false;
    final (plan, _) = await harness.pump(tester, const PlanState());
    await settle(tester);
    await tapLabel(tester, i18n.goSwapEndpoints);
    await settle(tester);
    expect(find.byType(GoogleMap), findsNothing);
    expect(plan.events.whereType<PlanSearchRequested>(), isEmpty);
    await harness.dispose(tester);
  });

  testWidgets('paging asks for the cursor and taps lightly', (tester) async {
    final (plan, _) = await harness.pump(
      tester,
      results([
        _route([_leg(_a, _b)]),
      ], next: 'later-cursor'),
      destination: goTestDestination,
    );
    await settle(tester);
    plan.events.clear();
    await tapLabel(tester, i18n.goLaterDepartures);
    final request = plan.events.whereType<PlanSearchRequested>().single;
    expect(request.pageCursor, 'later-cursor');
    expect(harness.haptics, ['lightImpact']);
    await harness.dispose(tester);
  });

  testWidgets('a saved route for the same trip is offered while waiting', (
    tester,
  ) async {
    final saved = _route([_leg(_a, const PlanPoint(lat: 25.2, lng: 121.2))]);
    final other = _route([_leg(_a, _c)]);
    await harness.pump(
      tester,
      PlanState(status: PlanStatus.loading, savedRoutes: [other]),
      destination: goTestDestination,
    );
    await settle(tester);
    expect(find.text(i18n.goLastRouteTitle), findsNothing);
    await harness.dispose(tester);
    await harness.pump(
      tester,
      PlanState(status: PlanStatus.loading, savedRoutes: [other, saved]),
      destination: goTestDestination,
    );
    await settle(tester);
    expect(find.text(i18n.goLastRouteTitle), findsOneWidget);
    await harness.dispose(tester);
    final startsElsewhere = _route([
      _leg(_c, const PlanPoint(lat: 25.2, lng: 121.2)),
    ]);
    await harness.pump(
      tester,
      PlanState(status: PlanStatus.loading, savedRoutes: [startsElsewhere]),
      destination: goTestDestination,
    );
    await settle(tester);
    expect(find.text(i18n.goLastRouteTitle), findsNothing);
    await harness.dispose(tester);
  });

  testWidgets('a trip end exactly 400 m away still counts as the same', (
    tester,
  ) async {
    final saved = _route([_leg(_c, _d)]);
    for (final (meters, offered) in [(400.0, true), (400.5, false)]) {
      harness.location.distance = meters;
      await harness.pump(
        tester,
        PlanState(status: PlanStatus.loading, savedRoutes: [saved]),
        destination: goTestDestination,
      );
      await settle(tester);
      expect(
        find.text(i18n.goLastRouteTitle),
        offered ? findsOneWidget : findsNothing,
        reason: '$meters',
      );
      await harness.dispose(tester);
    }
  });

  group('navigation', () {
    final trip = _route([_leg(_a, _b)]);
    final tripThenWalk = _route([
      _leg(_a, _b),
      _leg(_b, _c, walk: true),
    ]);

    Future<(GoPlan, GoJourney)> startNav(
      WidgetTester tester,
      PlanRoute route,
    ) async {
      final (plan, journey) = await harness.pump(
        tester,
        results([route], previewing: true),
        destination: goTestDestination,
      );
      await settle(tester);
      harness.maps.cameraUpdates.clear();
      harness.haptics.clear();
      tester
          .widget<AppButton>(
            find.widgetWithText(AppButton, i18n.goStartNavigation),
          )
          .onPressed!();
      await tester.pump();
      await settle(tester);
      plan.show(navigating(route));
      await settle(tester);
      return (plan, journey);
    }

    Map<Object?, Object?> lastPosition(WidgetTester tester) =>
        _updates(harness.maps, 'newCameraPosition').last[1]!
            as Map<Object?, Object?>;

    testWidgets('starting navigation flies to the first stop, heavily', (
      tester,
    ) async {
      await startNav(tester, trip);
      final first =
          _updates(harness.maps, 'newCameraPosition').first[1]!
              as Map<Object?, Object?>;
      expect(first['target'], [25.0, 121.0]);
      expect(first['zoom'], 15.5);
      expect(first['tilt'], 45.0);
      expect(first['bearing'], 30.0);
      expect(harness.haptics.first, 'heavyImpact');
      await harness.dispose(tester);
    });

    testWidgets('fixes steer the camera until the rider pans away', (
      tester,
    ) async {
      await startNav(tester, trip);
      harness.maps.cameraUpdates.clear();
      harness.location.positions.add(goFix(25.05, 121.05));
      await settle(tester);
      var position = lastPosition(tester);
      expect(position['target'], [25.05, 121.05]);
      expect(position['zoom'], 15.5);
      expect(position['tilt'], 45.0);
      expect(position['bearing'], 30.0);
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      // Our own animation just finished: a move start now is still ours.
      map.onCameraMoveStarted!();
      await tester.pump();
      harness.maps.cameraUpdates.clear();
      harness.location.positions.add(goFix(25.06, 121.06));
      await settle(tester);
      expect(lastPosition(tester)['target'], [25.06, 121.06]);
      // Past the grace window the same callback is the rider's own gesture.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      map.onCameraMoveStarted!();
      await tester.pump();
      harness.maps.cameraUpdates.clear();
      harness.location.positions.add(goFix(25.07, 121.07));
      await settle(tester);
      expect(_updates(harness.maps, 'newCameraPosition'), isEmpty);
      await harness.dispose(tester);
    });

    testWidgets('the puck sits on the fix and recentres on tap', (
      tester,
    ) async {
      await startNav(tester, trip);
      harness.location.positions.add(goFix(25.05, 121.05));
      await settle(tester);
      Marker? puck() => harness.maps.objects.markers
          .where((m) => m.markerId.value == 'nav_puck')
          .firstOrNull;
      for (var i = 0; i < 100 && puck() == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(puck()!.position, const LatLng(25.05, 121.05));
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      map.onCameraMoveStarted!();
      await tester.pump();
      harness.maps.cameraUpdates.clear();
      harness.haptics.clear();
      puck()!.onTap!();
      await settle(tester);
      expect(lastPosition(tester)['target'], [25.05, 121.05]);
      expect(harness.haptics, contains('lightImpact'));
      harness.maps.cameraUpdates.clear();
      harness.location.positions.add(goFix(25.08, 121.08));
      await settle(tester);
      expect(lastPosition(tester)['target'], [25.08, 121.08]);
      await harness.dispose(tester);
    });

    testWidgets('the end-navigation button meets the 44pt touch target', (
      tester,
    ) async {
      await startNav(tester, trip);
      final end = find.byWidgetPredicate(
        (w) => w is Pressable && w.semanticLabel == i18n.goEndNavigation,
      );
      final size = tester.getSize(end);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      await harness.dispose(tester);
    });

    testWidgets('ending navigation resets the camera and releases compass', (
      tester,
    ) async {
      final (plan, _) = await startNav(tester, trip);
      harness.maps.cameraUpdates.clear();
      harness.haptics.clear();
      await tapLabel(tester, i18n.goEndNavigation);
      await settle(tester);
      expect(plan.events.last, isA<NavigationEnded>());
      expect(harness.haptics, ['lightImpact']);
      final reset = lastPosition(tester);
      expect(reset['target'], [25.0416, 121.5438]);
      expect(reset['zoom'], 14.0);
      expect(harness.compassCancels, greaterThan(0));
      await harness.dispose(tester);
    });

    testWidgets('a finished journey resets the camera only when it is over', (
      tester,
    ) async {
      final (_, journey) = await startNav(tester, trip);
      harness.maps.cameraUpdates.clear();
      journey.show(const JourneySessionState(phase: JourneyPhase.done));
      await settle(tester);
      expect(lastPosition(tester)['zoom'], 14.0);
      await harness.dispose(tester);
      final (_, other) = await startNav(tester, tripThenWalk);
      harness.maps.cameraUpdates.clear();
      other.show(const JourneySessionState(phase: JourneyPhase.done));
      await settle(tester);
      expect(_updates(harness.maps, 'newCameraPosition'), isEmpty);
      await harness.dispose(tester);
    });

    testWidgets('only reaching done ends the plan navigation', (tester) async {
      final (plan, journey) = await startNav(tester, trip);
      plan.events.clear();
      journey.show(const JourneySessionState(phase: JourneyPhase.waiting));
      await settle(tester);
      journey.show(const JourneySessionState(phase: JourneyPhase.riding));
      await settle(tester);
      expect(plan.events.whereType<NavigationEnded>(), isEmpty);
      await harness.dispose(tester);
    });

    testWidgets('while navigating the sheet yields to the map', (tester) async {
      final (plan, _) = await startNav(tester, trip);
      expect(find.text(i18n.goSuggestedRoutes), findsNothing);
      plan.show(
        const PlanState(status: PlanStatus.success, activeLegIndex: 0),
      );
      await settle(tester);
      expect(find.text(i18n.goSuggestedRoutes), findsOneWidget);
      await harness.dispose(tester);
    });

    testWidgets('toggling a save taps lightly', (tester) async {
      await harness.pump(
        tester,
        results([trip], previewing: true),
        destination: goTestDestination,
      );
      await settle(tester);
      harness.haptics.clear();
      await tapLabel(tester, i18n.goSaveRoute);
      expect(harness.haptics, ['lightImpact']);
      await harness.dispose(tester);
    });

    testWidgets('swapping sheets slides the incoming one up from below', (
      tester,
    ) async {
      final (plan, _) = await harness.pump(
        tester,
        results([trip]),
        destination: goTestDestination,
      );
      await settle(tester);
      plan.show(results([trip], previewing: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final offsets = [
        for (final slide in tester.widgetList<SlideTransition>(
          find.byType(SlideTransition),
        ))
          slide.position.value.dy,
      ];
      expect(offsets.where((dy) => dy > 0 && dy <= 0.03), isNotEmpty);
      expect(offsets.where((dy) => dy < 0), isEmpty);
      await harness.dispose(tester);
    });
  });

  testWidgets('the planner honours the capabilities the router reports', (
    tester,
  ) async {
    await harness.pump(
      tester,
      results([
        _route([_leg(_a, _b)]),
      ]),
      destination: goTestDestination,
      repository: PlannerRepository(
        fetchBody: () async => {
          'capabilities': ['carryBike'],
        },
      ),
    );
    await settle(tester);
    await tapLabel(tester, i18n.goRouteOptions);
    await tester.pumpAndSettle();
    expect(find.text(i18n.goCarryBike), findsOneWidget);
    await harness.dispose(tester);
  });
}
