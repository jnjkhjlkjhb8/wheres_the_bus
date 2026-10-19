import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/features/go/view/place_search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';

import '../../support/fakes/map_platform.dart';
import 'go_plan_overlay_test.dart' show route, section;

Position fix(double latitude, double longitude) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: DateTime.utc(2030, 1, 2),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

class _Location extends GeolocatorPlatform {
  bool enabled = true;
  final positions = StreamController<Position>.broadcast();
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => fix(25, 121);
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => null;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;
}

class _Plan extends PlanBloc {
  _Plan(PlanState state) : super() {
    emit(state);
    events.clear();
  }
  final events = <PlanEvent>[];
  @override
  void add(PlanEvent event) => events.add(event);
  void show(PlanState state) => emit(state);
}

class _Journey extends JourneySessionBloc {
  _Journey() : super(liveActivityEnabled: () => false);
  final events = <JourneySessionEvent>[];
  @override
  void add(JourneySessionEvent event) => events.add(event);
  void show(JourneySessionState state) => emit(state);
}

PlanRoute walkingRoute({List<PlanWalkStep> steps = const []}) {
  final base = section(walk: true);
  return route([
    PlanSection(
      type: base.type,
      travelSummary: base.travelSummary,
      departure: base.departure,
      arrival: base.arrival,
      transport: base.transport,
      intermediateStops: base.intermediateStops,
      walkSteps: steps,
    ),
  ]);
}

PlanWalkStep step(
  String modifier,
  String instruction,
  double distance, {
  String maneuver = 'turn',
}) => PlanWalkStep(
  instruction: instruction,
  maneuverType: maneuver,
  modifier: modifier,
  distanceMeters: distance,
  durationSeconds: 60,
  location: const PlanPoint(lat: 25, lng: 121),
);

void main() {
  late GoogleMapsFlutterPlatform previousMap;
  late GeolocatorPlatform previousLocation;
  late FakeMapPlatform maps;
  late _Location location;
  var compassCancels = 0;
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'go-screen-quality-',
    );
    Hive.init(directory.path);
    await Hive.openBox<dynamic>('settings');
    addTearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
  });
  setUp(() {
    previousMap = GoogleMapsFlutterPlatform.instance;
    previousLocation = GeolocatorPlatform.instance;
    maps = FakeMapPlatform();
    location = _Location();
    GoogleMapsFlutterPlatform.instance = maps;
    GeolocatorPlatform.instance = location;
    LocationService.denial.value = null;
    compassCancels = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('hemanthraj/flutter_compass'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success([90.0, 0.0, 1.0]),
            onCancel: (_) => compassCancels++,
          ),
        );
  });
  tearDown(() async {
    GoogleMapsFlutterPlatform.instance = previousMap;
    GeolocatorPlatform.instance = previousLocation;
    LocationService.denial.value = null;
    await location.positions.close();
  });

  Future<(_Plan, _Journey)> pumpGo(
    WidgetTester tester,
    PlanState state, {
    bool destination = false,
    bool dark = false,
  }) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final plan = _Plan(state);
    final journey = _Journey();
    addTearDown(plan.close);
    addTearDown(journey.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<PlanBloc>.value(value: plan),
          BlocProvider<JourneySessionBloc>.value(value: journey),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          home: GoScreen(
            plannerRepository: PlannerRepository(fetchBody: () async => {}),
            initialDestination: destination
                ? const PlannedPlace(name: '目的地', latLng: LatLng(25.2, 121.2))
                : null,
          ),
        ),
      ),
    );
    await tester.pump();
    return (plan, journey);
  }

  Future<void> disposeGo(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  void press(WidgetTester tester, String label) {
    final widget = tester
        .widgetList<Pressable>(find.byType(Pressable))
        .singleWhere((w) => w.semanticLabel == label);
    widget.onTap!();
  }

  testWidgets('navigation announces turns, upcoming turn and arrival', (
    tester,
  ) async {
    final trip = walkingRoute(
      steps: [
        step('', '出發', 1500),
        step('left', '左轉進入中山路', 80),
        step('right', '右轉進入巷子', 20),
        step('', '抵達目的地', 0, maneuver: 'arrive'),
      ],
    );
    final initial = PlanState(
      status: PlanStatus.success,
      result: PlanResult(routes: [trip]),
      selectedRouteIndex: 0,
      activeLegIndex: 0,
    );
    final (plan, journey) = await pumpGo(tester, initial);
    expect(find.text('左轉進入中山路'), findsOneWidget);
    expect(find.textContaining('右轉進入巷子', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.turn_left_rounded), findsOneWidget);
    plan.show(initial.copyWith(activeWalkStepIndex: 2));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.sports_score_rounded), findsOneWidget);
    plan.show(initial.copyWith(activeWalkStepIndex: 99));
    await tester.pumpAndSettle();
    expect(find.text('即將抵達'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(plan.events.last, isA<NavigationEnded>());
    expect(journey.events.last, isA<JourneyCancelled>());
    await disposeGo(tester);
  });

  testWidgets('navigation without steps keeps a coarse destination title', (
    tester,
  ) async {
    final trip = walkingRoute();
    await pumpGo(
      tester,
      PlanState(
        status: PlanStatus.success,
        result: PlanResult(routes: [trip]),
        activeLegIndex: 0,
      ),
      dark: true,
    );
    expect(find.textContaining('B'), findsWidgets);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await disposeGo(tester);
  });

  testWidgets(
    'entry retries saved routes after failure and rebuilds readiness',
    (tester) async {
      final (plan, _) = await pumpGo(
        tester,
        const PlanState(savedRoutesLoadError: true),
      );
      expect(find.text('路線箱暫時無法讀取'), findsOneWidget);
      await tester.tap(find.text('重試'));
      expect(plan.events.last, isA<SavedRoutesLoaded>());
      plan.show(const PlanState(savedRoutesReady: true));
      await tester.pumpAndSettle();
      expect(find.text('路線箱暫時無法讀取'), findsNothing);
      await disposeGo(tester);
    },
  );
  testWidgets(
    'GPS origin plans the destination and result changes frame routes',
    (tester) async {
      final saved = route([section(walk: true)]);
      final (plan, _) = await pumpGo(
        tester,
        PlanState(
          status: PlanStatus.failure,
          savedRoutes: [route([]), saved],
          savedRoutesReady: true,
        ),
        destination: true,
      );
      await tester.pumpAndSettle();
      final request = plan.events.whereType<PlanSearchRequested>().single;
      expect((request.fromLat, request.fromLon), (25, 121));
      expect((request.toLat, request.toLon), (25.2, 121.2));
      expect(request.arriveBy, isFalse);
      expect(request.legAlternatives, 0);
      expect(request.date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      final updates = maps.cameraUpdates.length;
      plan.show(const PlanState(status: PlanStatus.loading));
      await tester.pump();
      expect(maps.cameraUpdates.length, greaterThan(updates));
      final result = PlanState(
        status: PlanStatus.success,
        result: PlanResult(
          routes: [
            saved,
            route([section()]),
          ],
        ),
        selectedRouteIndex: 99,
        savedRoutes: [route([]), saved],
        savedRoutesReady: true,
      );
      plan.show(result);
      await tester.pumpAndSettle();
      final fit = maps.cameraUpdates.last as CameraUpdateNewLatLngBounds;
      expect(fit.padding, 72);
      expect(fit.bounds.southwest, const LatLng(25, 121));
      expect(fit.bounds.northeast, const LatLng(25.2, 121.2));
      maps.objects.polylines
          .firstWhere((line) => line.consumeTapEvents)
          .onTap!();
      expect(plan.events.last, isA<RouteSelected>());
      plan.show(result.copyWith(selectedRouteIndex: 0, previewing: true));
      await tester.pumpAndSettle();
      expect(find.text('開始導航'), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_rounded), findsWidgets);
      await tester.tap(find.byIcon(Icons.bookmark_rounded).last);
      await tester.pump();
      expect(plan.events.last, isA<RouteSaveToggled>());
      expect(find.text('已移除收藏'), findsOneWidget);
      press(tester, '復原');
      expect(plan.events.last, isA<RouteSaveToggled>());
      expect(plan.events.whereType<RouteSaveToggled>(), hasLength(2));
      await tester.tap(find.byIcon(Icons.chevron_left_rounded).last);
      expect(plan.events.last, isA<PreviewClosed>());
      await disposeGo(tester);
      expect(maps.disposed, isNotEmpty);
    },
  );

  testWidgets(
    'preview starts navigation, follows GPS and pauses after a map gesture',
    (tester) async {
      final trip = walkingRoute();
      final initial = PlanState(
        status: PlanStatus.success,
        result: PlanResult(routes: [trip]),
        selectedRouteIndex: 0,
        previewing: true,
      );
      final (plan, journey) = await pumpGo(tester, initial, destination: true);
      await tester.pumpAndSettle();
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, '開始導航'))
          .onPressed!();
      await tester.pump();
      expect(plan.events.whereType<NavigationStarted>(), hasLength(1));
      final start = maps.cameraUpdates
          .whereType<CameraUpdateNewCameraPosition>()
          .last
          .cameraPosition;
      expect(start.target, const LatLng(25, 121));
      expect(compassCancels, 0);
      plan.show(initial.copyWith(activeLegIndex: 0));
      await tester.pumpAndSettle();
      location.positions.add(fix(25.01, 121.01));
      await tester.pump();
      expect(
        (maps.cameraUpdates.last.toJson() as List).first,
        'newCameraPosition',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 550)),
      );
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraMoveStarted!();
      await tester.pump();
      final pausedCount = maps.cameraUpdates.length;
      location.positions.add(fix(25.02, 121.02));
      await tester.pump();
      expect(maps.cameraUpdates.length, pausedCount);
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (maps.objects.markers.any((m) => m.markerId.value == 'nav_puck')) {
          break;
        }
      }
      maps.objects.markers
          .singleWhere((m) => m.markerId.value == 'nav_puck')
          .onTap!();
      await tester.pump();
      expect(maps.cameraUpdates.length, greaterThan(pausedCount));
      location.positions.add(fix(25.2, 121.2));
      await tester.pump();
      expect(plan.events.last, isA<NavigationEnded>());
      expect(compassCancels, 1);
      expect(journey.events.last, isA<JourneyCancelled>());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已抵達目的地'), findsOneWidget);
      await disposeGo(tester);
    },
  );

  testWidgets(
    'walk arrival advances the camera to the next transit departure',
    (tester) async {
      final trip = route([
        section(walk: true),
        section(
          from: const PlanPoint(lat: 25.2, lng: 121.2),
          to: const PlanPoint(lat: 25.3, lng: 121.3),
        ),
      ]);
      final initial = PlanState(
        status: PlanStatus.success,
        result: PlanResult(routes: [trip]),
        selectedRouteIndex: 0,
        previewing: true,
      );
      final (plan, _) = await pumpGo(tester, initial, destination: true);
      await tester.pumpAndSettle();
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, '開始導航'))
          .onPressed!();
      await tester.pump();
      plan.show(initial.copyWith(activeLegIndex: 0));
      await tester.pumpAndSettle();
      location.positions.add(fix(25.2, 121.2));
      await tester.pump();
      await tester.pump();
      expect(plan.events.whereType<StopArrived>().single.legIndex, 1);
      expect((maps.cameraUpdates.last.toJson() as List).first, 'newLatLng');
      await disposeGo(tester);
    },
  );

  testWidgets(
    'unavailable GPS offers a retry and resolves after service returns',
    (tester) async {
      location.enabled = false;
      final (plan, _) = await pumpGo(
        tester,
        const PlanState(savedRoutesReady: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('未取得定位 · '), findsOneWidget);
      location.enabled = true;
      await tester.tap(find.text('開啟定位'));
      await tester.pumpAndSettle();
      expect(find.text('目前位置'), findsWidgets);
      expect(plan.events.whereType<PlanSearchRequested>(), isEmpty);
      await disposeGo(tester);
    },
  );

  testWidgets(
    'endpoint, paging and option changes preserve query values',
    (tester) async {
      final trip = walkingRoute();
      final initial = PlanState(
        status: PlanStatus.success,
        result: PlanResult(
          routes: [trip],
          previousPageCursor: 'earlier',
          nextPageCursor: 'later',
        ),
        selectedRouteIndex: 0,
      );
      final (plan, _) = await pumpGo(tester, initial, destination: true);
      await tester.pumpAndSettle();
      press(tester, '目前位置');
      Navigator.of(
        tester.element(find.byType(GoScreen)),
      ).pop(const PlannedPlace(name: '新起點', latLng: LatLng(24, 120)));
      await tester.pumpAndSettle();
      expect(plan.events.whereType<PlanSearchRequested>().last.fromLat, 24);
      press(tester, '目的地');
      Navigator.of(
        tester.element(find.byType(GoScreen)),
      ).pop(const PlannedPlace(name: '新終點', latLng: LatLng(23, 119)));
      await tester.pumpAndSettle();
      press(tester, '對調起訖點');
      await tester.pump();
      final swapped = plan.events.whereType<PlanSearchRequested>().last;
      expect((swapped.fromLat, swapped.toLat), (23, 24));
      press(tester, '更早班次');
      expect(
        plan.events.whereType<PlanSearchRequested>().last.pageCursor,
        'earlier',
      );
      press(tester, '更晚班次');
      expect(
        plan.events.whereType<PlanSearchRequested>().last.pageCursor,
        'later',
      );
      press(tester, '路線選項');
      Navigator.of(
        tester.element(find.byType(GoScreen)),
      ).pop(const PlanOptions(top: 4));
      await tester.pumpAndSettle();
      expect(plan.events.whereType<PlanSearchRequested>().last.options.top, 4);
      final beforeTime = plan.events.whereType<PlanSearchRequested>().length;
      press(tester, '選擇出發時間');
      await tester.pumpAndSettle();
      await tester.tap(find.text('套用'));
      await tester.pumpAndSettle();
      expect(plan.events.whereType<PlanSearchRequested>().length, beforeTime);
      press(tester, '選擇出發時間');
      await tester.pumpAndSettle();
      await tester.tap(find.text('抵達時間'));
      await tester.pumpAndSettle();
      final dateRow = tester.widget<Pressable>(
        find.byWidgetPredicate(
          (w) =>
              w is Pressable && (w.semanticLabel?.startsWith('日期 ') ?? false),
        ),
      );
      expect(
        find.descendant(
          of: find.byWidget(dateRow),
          matching: find.text('日期'),
        ),
        findsOneWidget,
      );
      dateRow.onTap!();
      await tester.pumpAndSettle();
      final day = DateTime.now().add(const Duration(days: 1));
      String two(int v) => v.toString().padLeft(2, '0');
      tester
          .widget<AppDatePicker>(find.byType(AppDatePicker))
          .onDaySelected(day);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Pressable>(find.byType(Pressable))
            .any(
              (w) =>
                  w.semanticLabel?.startsWith(
                    '日期 ${two(day.month)}/${two(day.day)}（',
                  ) ??
                  false,
            ),
        isTrue,
      );
      tester
          .widget<Pressable>(
            find.byWidgetPredicate(
              (w) =>
                  w is Pressable &&
                  (w.semanticLabel?.startsWith('時間 ') ?? false),
            ),
          )
          .onTap!();
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
          .onDateTimeChanged(DateTime(day.year, day.month, day.day, 14, 35));
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, '完成'))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Pressable>(find.byType(Pressable))
            .any((w) => w.semanticLabel == '時間 14:35'),
        isTrue,
      );
      await tester.tap(find.text('套用'));
      await tester.pumpAndSettle();
      final applied = plan.events.whereType<PlanSearchRequested>().last;
      expect(applied.arriveBy, isTrue);
      expect(applied.time, '14:35');
      expect(
        applied.date,
        '${day.year}-${two(day.month)}-${two(day.day)}',
      );
      expect(
        find.textContaining('${two(day.month)}/${two(day.day)} 14:35'),
        findsOneWidget,
      );
      await disposeGo(tester);
    },
  );

  testWidgets(
    'waiting offers the saved matching trip and preview describes transfers',
    (tester) async {
      final saved = walkingRoute();
      final (plan, _) = await pumpGo(
        tester,
        PlanState(
          status: PlanStatus.loading,
          result: PlanResult(routes: [saved]),
          savedRoutes: [saved],
          savedRoutesReady: true,
        ),
        destination: true,
      );
      await tester.pump();
      final waiting = tester.widget<PlanWaitingPanel>(
        find.byType(PlanWaitingPanel),
      );
      expect(waiting.lastRoute, saved);
      waiting.onOpenLast!();
      expect(plan.events.last, isA<RouteSelected>());
      final mixed = route([
        section(walk: true),
        section(),
        section(walk: true),
        section(walk: true),
      ]);
      plan.show(
        PlanState(
          status: PlanStatus.success,
          result: PlanResult(routes: [mixed]),
          selectedRouteIndex: 0,
          previewing: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('307'), findsWidgets);
      expect(find.textContaining('A → B'), findsOneWidget);
      await disposeGo(tester);
    },
  );

  testWidgets(
    'destination selection resolves missing origin and handles cancellation',
    (tester) async {
      location.enabled = false;
      final (plan, _) = await pumpGo(
        tester,
        const PlanState(savedRoutesReady: true),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      const dest = PlannedPlace(name: '終點', latLng: LatLng(25.2, 121.2));
      tester
          .widget<PlaceSearchView>(find.byType(PlaceSearchView))
          .onPicked(dest);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlaceSearchScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(PlaceSearchScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(plan.events.whereType<PlanSearchRequested>(), isEmpty);
      tester
          .widget<PlaceSearchView>(find.byType(PlaceSearchView))
          .onPicked(dest);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      Navigator.of(
        tester.element(find.byType(PlaceSearchScreen)),
      ).pop(const PlannedPlace(name: '起點', latLng: LatLng(24, 120)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      final query = plan.events.whereType<PlanSearchRequested>().single;
      expect((query.fromLat, query.toLat), (24, 25.2));
      await disposeGo(tester);
    },
  );

  testWidgets('saved routes distinguish loading, failure and available cards', (
    tester,
  ) async {
    final (plan, _) = await pumpGo(tester, const PlanState());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    plan.show(const PlanState(savedRoutesLoadError: true));
    await tester.pump();
    await tester.pump();
    expect(find.text('路線箱暫時無法讀取'), findsOneWidget);
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, '重試'))
        .onPressed!();
    final count = plan.events.length;
    expect(count, greaterThan(0));
    plan.show(PlanState(savedRoutesReady: true, savedRoutes: [walkingRoute()]));
    await tester.pumpAndSettle();
    expect(find.text('路線箱'), findsOneWidget);
    await disposeGo(tester);
  });

  testWidgets(
    'system back exits preview and native journey completion ends navigation',
    (tester) async {
      final trip = route([section()]);
      final initial = PlanState(
        status: PlanStatus.success,
        result: PlanResult(routes: [trip]),
        selectedRouteIndex: 0,
        previewing: true,
      );
      final (plan, journey) = await pumpGo(tester, initial, destination: true);
      await tester.pumpAndSettle();
      PopScope<Object?> scope() => tester.widget<PopScope<Object?>>(
        find.byWidgetPredicate(
          (w) => w is PopScope<Object?> && w.onPopInvokedWithResult != null,
        ),
      );
      scope().onPopInvokedWithResult!(false, null);
      expect(plan.events.last, isA<PreviewClosed>());
      plan.show(initial.copyWith(activeLegIndex: 0));
      await tester.pumpAndSettle();
      scope().onPopInvokedWithResult!(false, null);
      expect(plan.events.last, isA<NavigationEnded>());
      journey.show(const JourneySessionState(phase: JourneyPhase.done));
      await tester.pumpAndSettle();
      expect(plan.events.whereType<NavigationEnded>(), hasLength(2));
      await disposeGo(tester);
    },
  );

  testWidgets(
    'live bus countdown yields to rail departure and planned arrival clocks',
    (tester) async {
      PlanSection transit(String mode, String routeType) {
        final base = section();
        return PlanSection(
          type: base.type,
          travelSummary: base.travelSummary,
          departure: const PlanPlace(
            name: 'A',
            type: '',
            location: PlanPoint(lat: 25, lng: 121),
            time: '2030-01-02T08:00:00+08:00',
          ),
          arrival: const PlanPlace(
            name: 'B',
            type: '',
            location: PlanPoint(lat: 25.2, lng: 121.2),
            time: '2030-01-02T09:00:00+08:00',
          ),
          transport: PlanTransport(
            mode: mode,
            name: '307',
            shortName: '307',
            longName: '',
            headsign: 'B',
            category: '',
            routeColor: '#ff0000',
          ),
          intermediateStops: const [],
          identity: PlanIdentity(
            routeType: routeType,
            routeKey: 'route',
            direction: '0',
            departureStopKey: 'A',
            arrivalStopKey: 'B',
            supported: true,
          ),
        );
      }

      final bus = route([transit('BUS', 'bus')]);
      final initial = PlanState(
        status: PlanStatus.success,
        result: PlanResult(routes: [bus]),
        selectedRouteIndex: 0,
        activeLegIndex: 0,
      );
      final (plan, journey) = await pumpGo(tester, initial);
      journey.show(
        const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration(seconds: 61),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 分'), findsOneWidget);
      journey.show(
        const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration.zero,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('進站中'), findsOneWidget);
      final rail = route([transit('RAIL', '')]);
      plan.show(initial.copyWith(result: PlanResult(routes: [rail])));
      await tester.pumpAndSettle();
      expect(find.text('08:00'), findsOneWidget);
      journey.show(const JourneySessionState(phase: JourneyPhase.riding));
      await tester.pumpAndSettle();
      expect(find.text('09:00'), findsOneWidget);
      await disposeGo(tester);
    },
  );
}
