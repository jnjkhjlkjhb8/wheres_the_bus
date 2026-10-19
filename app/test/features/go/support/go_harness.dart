import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../../support/fakes/map_platform.dart';

Position goFix(double latitude, double longitude) => Position(
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

class GoLocation extends GeolocatorPlatform {
  bool enabled = true;

  /// When set, every distance query answers this many metres.
  double? distance;

  final positions = StreamController<Position>.broadcast();
  @override
  double distanceBetween(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) {
    final fixed = distance;
    if (fixed != null) return fixed;
    const earth = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(endLatitude - startLatitude);
    final dLon = rad(endLongitude - startLongitude);
    final h =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(startLatitude)) *
            math.cos(rad(endLatitude)) *
            math.pow(math.sin(dLon / 2), 2);
    return earth * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => goFix(25, 121);
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => null;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;
}

class GoPlan extends PlanBloc {
  GoPlan(PlanState state) : super() {
    emit(state);
    events.clear();
  }
  final events = <PlanEvent>[];
  @override
  void add(PlanEvent event) => events.add(event);
  void show(PlanState state) => emit(state);
}

class GoJourney extends JourneySessionBloc {
  GoJourney() : super(liveActivityEnabled: () => false);
  final events = <JourneySessionEvent>[];
  @override
  void add(JourneySessionEvent event) => events.add(event);
  void show(JourneySessionState state) => emit(state);
}

/// Mounts [GoScreen] against fake map, location and bloc doubles. Call
/// [GoHarness.install] once from `main`.
class GoHarness {
  late GoogleMapsFlutterPlatform _previousMap;
  late GeolocatorPlatform _previousLocation;
  late FakeMapPlatform maps;
  late GoLocation location;
  var compassCancels = 0;

  /// Haptic types fired since the test began, e.g. `lightImpact`.
  final haptics = <String>[];

  void install() {
    setUpAll(() async {
      final directory = await Directory.systemTemp.createTemp('go-harness-');
      Hive.init(directory.path);
      await Hive.openBox<dynamic>('settings');
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
    });
    setUp(() {
      _previousMap = GoogleMapsFlutterPlatform.instance;
      _previousLocation = GeolocatorPlatform.instance;
      maps = FakeMapPlatform();
      location = GoLocation();
      GoogleMapsFlutterPlatform.instance = maps;
      GeolocatorPlatform.instance = location;
      LocationService.denial.value = null;
      compassCancels = 0;
      haptics.clear();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockStreamHandler(
        const EventChannel('hemanthraj/flutter_compass'),
        MockStreamHandler.inline(
          onListen: (_, events) => events.success([90.0, 0.0, 1.0]),
          onCancel: (_) => compassCancels++,
        ),
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add((call.arguments as String).split('.').last);
        }
        return null;
      });
    });
    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      GoogleMapsFlutterPlatform.instance = _previousMap;
      GeolocatorPlatform.instance = _previousLocation;
      LocationService.denial.value = null;
      await location.positions.close();
    });
  }

  Future<(GoPlan, GoJourney)> pump(
    WidgetTester tester,
    PlanState state, {
    PlannedPlace? destination,
    bool dark = false,
    PlannerRepository? repository,
  }) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final plan = GoPlan(state);
    final journey = GoJourney();
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
            plannerRepository:
                repository ?? PlannerRepository(fetchBody: () async => {}),
            initialDestination: destination,
          ),
        ),
      ),
    );
    await tester.pump();
    return (plan, journey);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }
}

const goTestDestination = PlannedPlace(
  name: '目的地',
  latLng: LatLng(25.2, 121.2),
);
