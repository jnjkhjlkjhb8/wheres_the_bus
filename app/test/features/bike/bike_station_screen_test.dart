import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/data/models/bike_models.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/bike_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_bloc.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_event.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_state.dart';
import 'package:wheres_the_bus/features/bike/view/bike_station_detail_view.dart';
import 'package:wheres_the_bus/features/bike/view/bike_station_screen.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

import '../../helpers/test_firebase_crash_recorder.dart';
import '../../support/fakes/map_platform.dart';

class _Bike implements BikeRepository {
  final info = Completer<BikeStationInfo>();
  final live = StreamController<BikeAvailability>.broadcast();
  @override
  Future<BikeStationInfo> stationStatic(String uid) => info.future;
  @override
  Stream<BikeAvailability> stationEta(String uid) => live.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Location extends GeolocatorPlatform {
  bool fail = false;
  int requests = 0;
  Completer<Position>? deferred;

  Position get fix => Position(
    latitude: 25,
    longitude: 121,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    requests++;
    if (fail) throw StateError('GPS unavailable');
    final pending = deferred;
    if (pending != null) return pending.future;
    return fix;
  }
}

class _Favorites implements FavoritesRepository {
  @override
  bool get isReady => true;
  @override
  Stream<void> changes() => const Stream.empty();
  @override
  List<Favorite> all() => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _station = BikeStationInfo(
  name: 'Test bike station',
  capacity: 20,
  lat: 24,
  lon: 120,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final crashes = TestFirebaseCrashRecorder();
  setUpAll(crashes.install);
  setUp(crashes.clear);
  tearDownAll(crashes.dispose);
  late FakeMapPlatform map;
  late _Location location;
  setUp(() {
    final oldMap = GoogleMapsFlutterPlatform.instance;
    final oldLocation = GeolocatorPlatform.instance;
    map = FakeMapPlatform();
    location = _Location();
    GoogleMapsFlutterPlatform.instance = map;
    GeolocatorPlatform.instance = location;
    addTearDown(() {
      GoogleMapsFlutterPlatform.instance = oldMap;
      GeolocatorPlatform.instance = oldLocation;
    });
  });

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<GoRouter> mount(
    WidgetTester tester,
    _Bike bike, {
    bool hint = false,
    bool dark = false,
    bool reduced = false,
    double? seedLat,
    double? seedLon,
    void Function(Object, StackTrace)? onError,
  }) async {
    final favorites = FavoritesBloc(_Favorites(), ValueNotifier(true));
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => BlocProvider.value(
            value: favorites,
            child: BikeStationScreen(
              stationUid: 'bike',
              repository: bike,
              name: hint ? 'Seed' : null,
              lat: seedLat ?? (hint ? 23 : null),
              lon: seedLon ?? (hint ? 119 : null),
              reportError: onError ?? CrashReporter.record,
            ),
          ),
        ),
        GoRoute(
          path: '/go',
          builder: (_, _) => const Scaffold(body: Text('Planner destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(favorites.close);
    addTearDown(bike.live.close);
    // Runs before the screen's bloc is closed with the widget tree.
    addTearDown(() {
      if (!bike.info.isCompleted) bike.info.complete(_station);
    });
    await tester.pumpWidget(
      MaterialApp.router(
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
      ),
    );
    await flush(tester);
    return router;
  }

  testWidgets(
    'crash recorder observes actual reporter delivery',
    (tester) async {
      CrashReporter.record(StateError('recorder control'), StackTrace.current);
      await flush(tester);
      expect(crashes.errorCount, FirebaseGate.enabled ? 1 : 0);
    },
  );

  testWidgets('disposed bike screen ignores its pending initial GPS fix', (
    tester,
  ) async {
    location.deferred = Completer<Position>();
    final bike = _Bike();
    await mount(tester, bike);
    bike.info.complete(
      const BikeStationInfo(name: '', capacity: 0, lat: 0, lon: 0),
    );
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(map.disposed, containsAll(map.created));
    final updates = map.cameraUpdates.length;
    location.deferred!.complete(location.fix);
    await flush(tester);
    expect(map.cameraUpdates.length, updates);
    expect(crashes.errorCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed bike screen ignores a pending manual recenter', (
    tester,
  ) async {
    final bike = _Bike();
    await mount(tester, bike, hint: true);
    bike.info.complete(_station);
    await flush(tester);
    location.deferred = Completer<Position>();
    await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
    await flush(tester);
    expect(location.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(map.disposed, containsAll(map.created));
    final updates = map.cameraUpdates.length;
    location.deferred!.complete(location.fix);
    await flush(tester);
    expect(map.cameraUpdates.length, updates);
    expect(crashes.errorCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late initial GPS preserves the loaded station camera target',
    (tester) async {
      location.deferred = Completer<Position>();
      final bike = _Bike();
      await mount(tester, bike);
      expect(location.requests, 1);
      expect(map.cameraUpdates, isEmpty);
      bike.info.complete(_station);
      await flush(tester);
      final updates = map.cameraUpdates.length;
      expect(updates, greaterThan(0));
      location.deferred!.complete(location.fix);
      await flush(tester);
      expect(map.cameraUpdates.length, updates);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    },
  );

  testWidgets(
    'cold map shares GPS then pans to station and plans walking',
    (tester) async {
      final bike = _Bike();
      final router = await mount(tester, bike);
      expect(location.requests, 1);
      expect(tester.widget<GoogleMap>(find.byType(GoogleMap)).markers, isEmpty);
      expect(map.cameraUpdates, isNotEmpty);
      bike.info.complete(_station);
      await flush(tester);
      final widget = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(widget.markers.single.position, const LatLng(24, 120));
      expect(widget.markers.single.infoWindow.title, 'Test bike station');
      expect(find.text('Test bike station'), findsOneWidget);
      final cameraCount = map.cameraUpdates.length;
      bike.live.add(
        const BikeAvailability(
          generalBikes: 4,
          electricBikes: 2,
          returnDocks: 14,
        ),
      );
      await flush(tester);
      expect(map.cameraUpdates.length, cameraCount);
      final i18n = AppI18n.of(
        tester.element(find.byType(BikeStationDetailView)),
      );
      await tester.ensureVisible(find.text(i18n.bikePlanRoute));
      await tester.tap(find.text(i18n.bikePlanRoute));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/go');
      expect(router.state.uri.query, contains('24'));
      expect(map.disposed.intersection(map.created), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      expect(map.disposed, containsAll(map.created));
    },
  );

  testWidgets(
    'seed skips GPS then dark-mode recenter requests a fresh fix',
    (tester) async {
      final bike = _Bike();
      await mount(tester, bike, hint: true, dark: true);
      expect(location.requests, 0);
      expect(
        tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .initialCameraPosition
            .target,
        const LatLng(23, 119),
      );
      bike.info.complete(_station);
      await flush(tester);
      await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
      await flush(tester);
      expect(location.requests, 1);
      expect(map.cameraUpdates, isNotEmpty);
      expect(find.byIcon(Icons.gps_fixed_rounded), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
      expect(map.disposed, containsAll(map.created));
    },
  );

  testWidgets(
    'GPS failures leave map usable and static failure renders error',
    (tester) async {
      location.fail = true;
      final bike = _Bike();
      await mount(tester, bike);
      bike.info.completeError(StateError('station unavailable'));
      await flush(tester);
      expect(find.text(AppI18nZh().errorUnknownTitle), findsOneWidget);
      expect(find.textContaining('station unavailable'), findsNothing);
      await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
      await flush(tester);
      expect(location.requests, 2);
      expect(map.cameraUpdates, isEmpty);
      expect(find.byIcon(Icons.gps_fixed_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'unknown station retains fallback title and reports live outage',
    (tester) async {
      final bike = _Bike();
      await mount(tester, bike);
      bike.info.complete(
        const BikeStationInfo(name: '', capacity: 0, lat: 0, lon: 0),
      );
      await flush(tester);
      expect(find.text('bike'), findsOneWidget);
      final bloc = tester
          .widget<BlocConsumer<BikeStationBloc, BikeStationState>>(
            find.byType(BlocConsumer<BikeStationBloc, BikeStationState>),
          )
          .bloc!;
      void send(BikeStationEvent event) => bloc.add(event);
      send(const BikeStationEtaFailed(OfflineError()));
      await flush(tester);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
      send(
        const BikeStationEtaUpdated(
          available: 0,
          returnDocks: 0,
          generalBikes: 0,
          electricBikes: 0,
        ),
      );
      await flush(tester);
      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
      expect(tester.widget<GoogleMap>(find.byType(GoogleMap)).markers, isEmpty);
    },
  );

  testWidgets('cold map opens on the default position at zoom 16', (
    tester,
  ) async {
    final bike = _Bike();
    await mount(tester, bike);

    final camera = tester
        .widget<GoogleMap>(find.byType(GoogleMap))
        .initialCameraPosition;
    expect(camera.target, const LatLng(25.0330, 121.5654));
    expect(camera.zoom, 16);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  testWidgets('station marker is a centred bike icon at the station', (
    tester,
  ) async {
    final bike = _Bike();
    await mount(tester, bike, hint: true);
    bike.info.complete(_station);
    await flush(tester);

    final marker = tester
        .widget<GoogleMap>(find.byType(GoogleMap))
        .markers
        .single;
    expect(marker.anchor, const Offset(0.5, 0.5));
    expect(marker.icon, isNot(BitmapDescriptor.defaultMarker));
    expect(
      tester
          .widget<GoogleMap>(find.byType(GoogleMap))
          .initialCameraPosition
          .zoom,
      16,
    );
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  for (final dark in [false, true]) {
    testWidgets('locate button styling (dark=$dark)', (tester) async {
      final bike = _Bike();
      await mount(tester, bike, hint: true, dark: dark);
      final cs = (dark ? AppTheme.dark : AppTheme.light).colorScheme;

      final positioned = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byIcon(Icons.gps_fixed_rounded),
              matching: find.byType(Positioned),
            )
            .first,
      );
      final sheetOffset = tester
          .widget<AppSheet>(find.byType(AppSheet))
          .controller!
          .value;
      expect(sheetOffset, greaterThan(0));
      expect(positioned.right, 16);
      expect(positioned.bottom, sheetOffset! + 16);

      final box = tester.widget<Container>(
        find
            .ancestor(
              of: find.byIcon(Icons.gps_fixed_rounded),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(
        decoration.color,
        dark ? cs.surfaceContainerHigh : Colors.white,
      );
      expect(decoration.borderRadius, BorderRadius.circular(12));
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    });
  }

  testWidgets('disposing the screen closes its bloc', (tester) async {
    final bike = _Bike();
    await mount(tester, bike, hint: true);
    final bloc = tester
        .widget<BlocConsumer<BikeStationBloc, BikeStationState>>(
          find.byType(BlocConsumer<BikeStationBloc, BikeStationState>),
        )
        .bloc!;
    expect(bloc.isClosed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await flush(tester);

    expect(bloc.isClosed, isTrue);
  });

  testWidgets('recentering shows the spinner until the fix lands', (
    tester,
  ) async {
    final bike = _Bike();
    await mount(tester, bike, hint: true);
    location.deferred = Completer<Position>();

    await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AppSpinner), findsOneWidget);
    expect(find.byIcon(Icons.gps_fixed_rounded), findsNothing);

    location.deferred!.complete(location.fix);
    await flush(tester);
    expect(find.byType(AppSpinner), findsNothing);
    expect(find.byIcon(Icons.gps_fixed_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  testWidgets('every GPS failure is reported once per request', (tester) async {
    location.fail = true;
    final reported = <Object>[];
    final bike = _Bike();
    await mount(tester, bike, onError: (e, _) => reported.add(e));
    // Init and map creation each await the shared initial fix.
    expect(reported, hasLength(2));

    await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
    await flush(tester);

    expect(reported, hasLength(3));
    expect(reported.last, isA<StateError>());
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  testWidgets('a late initial fix pans both the init and map-ready waiters', (
    tester,
  ) async {
    location.deferred = Completer<Position>();
    final bike = _Bike();
    await mount(tester, bike);
    expect(map.cameraUpdates, isEmpty);

    location.deferred!.complete(location.fix);
    await flush(tester);

    expect(map.cameraUpdates, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  for (final reduced in [true, false]) {
    final label = reduced ? 'reduced motion snaps' : 'normal motion animates';

    void expectCameraMode(int count) {
      expect(map.cameraUpdates, hasLength(count));
      expect(map.movedUpdates, hasLength(reduced ? count : 0));
      expect(map.animatedUpdates, hasLength(reduced ? 0 : count));
    }

    testWidgets('$label for the late initial GPS pan', (tester) async {
      location.deferred = Completer<Position>();
      final bike = _Bike();
      await mount(tester, bike, reduced: reduced);

      location.deferred!.complete(location.fix);
      await flush(tester);

      expectCameraMode(2);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    });

    testWidgets('$label for the recenter button', (tester) async {
      final bike = _Bike();
      await mount(tester, bike, hint: true, reduced: reduced);
      expect(map.cameraUpdates, isEmpty);

      await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
      await flush(tester);

      expectCameraMode(1);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    });

    testWidgets('$label when the station arrives', (tester) async {
      location.deferred = Completer<Position>();
      final bike = _Bike();
      await mount(tester, bike, reduced: reduced);

      bike.info.complete(_station);
      await flush(tester);

      expect(map.cameraUpdates, isNotEmpty);
      expect(map.movedUpdates.isNotEmpty, reduced);
      expect(map.animatedUpdates.isNotEmpty, !reduced);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    });
  }

  for (final seed in [(0.0, 119.0), (23.0, 0.0)]) {
    testWidgets('a seed with one zero coordinate still skips GPS $seed', (
      tester,
    ) async {
      final bike = _Bike();
      await mount(tester, bike, seedLat: seed.$1, seedLon: seed.$2);

      expect(location.requests, 0);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    });
  }

  for (final change in [
    (const LatLng(23, 120), const LatLng(24, 120)),
    (const LatLng(24, 119), const LatLng(24, 120)),
  ]) {
    testWidgets('the map follows a station moving only ${change.$1}', (
      tester,
    ) async {
      final bike = _Bike();
      await mount(
        tester,
        bike,
        seedLat: change.$1.latitude,
        seedLon: change.$1.longitude,
      );

      bike.info.complete(_station);
      await flush(tester);

      expect(
        tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .markers
            .single
            .position,
        change.$2,
      );
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    });
  }
}
