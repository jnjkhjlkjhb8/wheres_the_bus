import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/update/update_gate.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/near_models.dart'
    show formatNearDistance;
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';
import 'package:wheres_the_bus/features/home/widgets/home_marker_style.dart'
    show MarkerStyle, markerIcon;
import 'package:wheres_the_bus/features/rail/view/home_rail_query_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

import '../../support/fakes/map_platform.dart';
import '../../support/helpers/in_memory_settings_store.dart';

class _Near implements NearRepository {
  bool fail = false;
  final requests = <NearQuery>[];
  List<NearStationViewModel> stations = [
    const NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'group',
      stationName: 'Test station',
      lat: 25,
      lon: 121,
      walkingMinutes: 1,
      distanceMeters: 40,
    ),
    const NearStationViewModel(
      type: NearStationType.mrt,
      stationId: 'BL15',
      stationName: 'Metro station',
      lat: 25.001,
      lon: 121.001,
      walkingMinutes: 2,
      distanceMeters: 120,
    ),
  ];

  /// Holds every answer back, so a test can look at the loading state.
  Completer<void>? gate;

  List<NearStationViewModel> _answer(NearQuery query) {
    requests.add(query);
    if (fail) throw StateError('nearby unavailable');
    return stations;
  }

  @override
  Stream<List<NearStationViewModel>> near(Stream<NearQuery> input) {
    if (gate == null) return input.map(_answer);
    return input.asyncMap((query) async {
      await gate!.future;
      return _answer(query);
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bus extends BusRepository {
  int memberReads = 0;
  List<BusStationMember>? members;
  Completer<void>? gate;
  List<BusStopArrival> etas = const [];

  /// Holds the arrivals back until the poles are on the map, so a label never
  /// races the first marker publish.
  Completer<void>? etaGate;
  @override
  Future<List<BusStationMember>> stationGroup(String groupUid) async {
    memberReads++;
    await gate?.future;
    return members ??
        const [
          BusStationMember(
            stationId: 'a',
            stationUid: 'pole-a',
            stationName: 'North pole',
            lat: 25,
            lon: 121,
          ),
          BusStationMember(
            stationId: 'b',
            stationUid: 'pole-b',
            stationName: 'South pole',
            lat: 25.001,
            lon: 121.001,
          ),
        ];
  }

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String stationUid) {
    final gate = etaGate;
    if (gate == null) return Stream.value(etas);
    return Stream.fromFuture(gate.future.then((_) => etas));
  }
}

class _Location extends GeolocatorPlatform {
  bool denied = false;
  bool disabled = false;
  int reads = 0;
  int openedSettings = 0;
  int openedApp = 0;
  Error? failure;

  /// What the OS had cached; absent means the live fix.
  Position? cached;

  /// Hold the cached / live answers back so a test can look between them.
  Completer<void>? cachedGate;
  Completer<void>? currentGate;
  Position? next;
  Position get fix => _position(25, 121);
  @override
  Future<bool> isLocationServiceEnabled() async => !disabled;
  @override
  Future<LocationPermission> checkPermission() async =>
      denied ? LocationPermission.deniedForever : LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    reads++;
    await currentGate?.future;
    final error = failure;
    if (error != null) throw error;
    return next ?? fix;
  }

  @override
  Future<bool> openLocationSettings() async {
    openedSettings++;
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    openedApp++;
    return true;
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async {
    await cachedGate?.future;
    return cached ?? fix;
  }
}

Position _position(double lat, double lon) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: DateTime.utc(2026),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

// Leaves no timer behind: a debounce armed just before teardown still has to
// fire once so its mounted guard can drop it.
//
// Opening a metro station's detail dials the real gRPC channel; its connect
// timeout would still be pending at teardown, so the channel is shut down too.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() async {
    await GrpcClient.instance.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  late GoogleMapsFlutterPlatform originalMaps;
  late GeolocatorPlatform originalLocation;
  late FakeMapPlatform maps;
  late _Location location;
  setUpAll(() async {
    for (final name in [
      'settings',
      'favorites',
      'fav_routes',
      'arrival_reminders',
    ]) {
      await Hive.openBox<dynamic>(name, bytes: Uint8List(0));
    }
  });
  tearDownAll(() async {
    await Hive.close();
  });
  setUp(() async {
    for (final favorite in FavoritesRepository.instance.all()) {
      await FavoritesRepository.instance.remove(favorite.id);
    }
    for (final name in ['favorites', 'fav_routes']) {
      await Hive.box<dynamic>(name).clear();
    }
    await Hive.box<dynamic>('settings').delete('last_device_position');
    originalMaps = GoogleMapsFlutterPlatform.instance;
    originalLocation = GeolocatorPlatform.instance;
    maps = FakeMapPlatform();
    location = _Location();
    GoogleMapsFlutterPlatform.instance = maps;
    GeolocatorPlatform.instance = location;
  });
  tearDown(() {
    GoogleMapsFlutterPlatform.instance = originalMaps;
    GeolocatorPlatform.instance = originalLocation;
  });

  Future<void> flush(WidgetTester tester) async {
    for (var frame = 0; frame < 4; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<GoRouter> mount(
    WidgetTester tester,
    _Near near,
    _Bus bus, {
    bool reduced = false,
    bool initializing = false,
    VoidCallback? firstFrame,
  }) async {
    final ready = initializing ? App.isInitialized : ValueNotifier(true);
    final favorites = FavoritesBloc(FavoritesRepository.instance, ready);
    final alerts = AlertBloc(
      repository: AlertRepository(
        settings: SettingsRepository(store: InMemorySettingsStore(const {})),
      ),
    );
    addTearDown(favorites.close);
    addTearDown(alerts.close);
    if (!initializing) addTearDown(ready.dispose);
    final router = GoRouter(
      routes: [
        for (final path in [
          '/',
          AppRoutes.nearStationPattern,
          AppRoutes.railQueryPattern,
        ])
          GoRoute(
            path: path,
            pageBuilder: (context, state) => NoTransitionPage(
              key: const ValueKey('home'),
              child: HomeScreen(
                station: NearStationRouteArgs.fromUri(state.uri),
                showRailQuery: state.uri.path == AppRoutes.railQueryPattern,
                nearRepository: near,
                busRepository: bus,
              ),
            ),
          ),
        GoRoute(
          path: '/favorites',
          builder: (context, state) =>
              const Scaffold(body: Text('favorites destination')),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) =>
              const Scaffold(body: Text('settings destination')),
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) =>
              const Scaffold(body: Text('search destination')),
        ),
        GoRoute(
          path: AppRoutes.metro,
          builder: (context, state) =>
              const Scaffold(body: Text('metro destination')),
        ),
        GoRoute(
          path: AppRoutes.go,
          builder: (context, state) =>
              const Scaffold(body: Text('go destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: favorites),
          BlocProvider.value(value: alerts),
        ],
        child: MaterialApp.router(
          theme: reduced ? AppTheme.dark : AppTheme.light,
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
        ),
      ),
    );
    firstFrame?.call();
    await flush(tester);
    tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
    await flush(tester);
    // Startup work resolves on real time; a loaded host needs more than one
    // flush before the camera and the queries stop moving.
    var last = (-1, -1);
    for (var i = 0; i < 40; i++) {
      final now = (maps.cameraUpdates.length, near.requests.length);
      if (now == last && maps.cameraUpdates.isNotEmpty) break;
      last = now;
      await flush(tester);
    }
    return router;
  }

  testWidgets('rail form follows the location and native back restores home', (
    tester,
  ) async {
    final router = await mount(tester, _Near(), _Bus());
    router.go(AppRoutes.railQuery());
    await flush(tester);
    expect(find.byType(HomeRailQuerySheet), findsOneWidget);
    router.go(AppRoutes.home);
    await flush(tester);
    expect(find.byType(HomeRailQuerySheet), findsNothing);
    router.go(AppRoutes.railQuery());
    await flush(tester);
    await tester.binding.handlePopRoute();
    await flush(tester);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(find.byType(HomeRailQuerySheet), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('the sheet navigator never tells Android back is unhandled', (
    tester,
  ) async {
    // The engine asks the framework to handle back only while the last
    // navigation notification said it could. A pushed-then-popped sheet page
    // leaves its own navigator at one route, and that notification would
    // otherwise win, so the next back exits the app past home's PopScope.
    final handlesBack = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          handlesBack.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    // WidgetsApp reports nothing to the engine until the app is resumed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final router = await mount(tester, _Near(), _Bus());
    router.go(AppRoutes.railQuery());
    await flush(tester);
    await tester.binding.handlePopRoute();
    await flush(tester);

    expect(handlesBack, isNotEmpty);
    expect(handlesBack.last, isTrue);
    await unmount(tester);
  });

  testWidgets('back from the raised root sheet settles at the peek first', (
    tester,
  ) async {
    final router = await mount(tester, _Near(), _Bus());
    router.go(AppRoutes.railQuery());
    await flush(tester);
    await tester.binding.handlePopRoute();
    await flush(tester);
    final controller = tester
        .widget<PagedSheet>(find.byType(PagedSheet))
        .controller!;
    double fraction() =>
        controller.metrics!.offset / controller.metrics!.viewportSize.height;
    // The form's page is gone and the list is left where the form was.
    expect(fraction(), greaterThan(AppSheetSnap.peekFrac + 0.05));

    await tester.binding.handlePopRoute();
    await flush(tester);
    expect(fraction(), closeTo(AppSheetSnap.peekFrac, 0.02));
    await unmount(tester);
  });

  for (final reduced in [false, true]) {
    testWidgets('nearby filtering and return to map preserve rows ($reduced)', (
      tester,
    ) async {
      final near = _Near()
        ..stations = [
          for (var i = 0; i < 35; i++)
            NearStationViewModel(
              type: NearStationType.bus,
              stationId: 'station-$i',
              stationName: 'Bus station $i',
              lat: 25 + i * 0.001,
              lon: 121,
              walkingMinutes: 1,
              distanceMeters: i * 50,
            ),
        ];
      await mount(tester, near, _Bus(), reduced: reduced);
      await tester.drag(
        find.byType(SheetDragHandle).first,
        const Offset(0, -700),
      );
      await flush(tester);
      await tester.tap(find.text('捷運').last);
      await flush(tester);
      expect(find.textContaining('附近沒有'), findsWidgets);
      await tester.tap(find.text('顯示全部站點'));
      await flush(tester);
      expect(find.text('Bus station 0'), findsWidgets);
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await flush(tester);
      final label = lookupAppI18n(const Locale('zh')).homeBackToMap;
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.text(label));
      await flush(tester);
      expect(
        tester.widget<GoogleMap>(find.byType(GoogleMap)).padding.bottom,
        lessThan(350),
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }

  for (final reduced in [true, false]) {
    testWidgets(
      '${reduced ? 'reduced motion jumps' : 'normal motion animates'} '
      'the nearby list back to the top',
      (tester) async {
        final near = _Near()
          ..stations = [
            for (var i = 0; i < 35; i++)
              NearStationViewModel(
                type: NearStationType.bus,
                stationId: 'station-$i',
                stationName: 'Bus station $i',
                lat: 25 + i * 0.001,
                lon: 121,
                walkingMinutes: 1,
                distanceMeters: i * 50,
              ),
          ];
        await mount(tester, near, _Bus(), reduced: reduced);
        await tester.drag(
          find.byType(SheetDragHandle).first,
          const Offset(0, -700),
        );
        await flush(tester);
        await tester.drag(find.byType(ListView).first, const Offset(0, -600));
        await flush(tester);
        final position = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        expect(position.pixels, greaterThan(0));

        await tester.tap(
          find.text(lookupAppI18n(const Locale('zh')).homeBackToMap),
        );
        await tester.pump();

        expect(position.pixels == 0, reduced);
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'cold group coordinates fit distant poles and back restores root',
    (tester) async {
      final bus = _Bus()
        ..members = const [
          BusStationMember(
            stationId: 'a',
            stationUid: 'pole-a',
            stationName: 'A',
            lat: 24.9,
            lon: 120.9,
          ),
          BusStationMember(
            stationId: 'b',
            stationUid: 'pole-b',
            stationName: 'B',
            lat: 25.1,
            lon: 121.1,
          ),
        ];
      final router = await mount(tester, _Near(), bus);
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraMove!(
        const CameraPosition(target: LatLng(24.8, 120.8), zoom: 16),
      );
      router.go(
        AppRoutes.nearStation(
          type: NearStationType.bus,
          id: 'cold',
          name: 'Cold group',
          lat: 25,
          lon: 121,
        ),
      );
      await flush(tester);
      // The member fetch resolves on real time; a loaded host needs more than
      // the fixed flush.
      bool fitted() => maps.cameraUpdates.any(
        (value) => (value.toJson() as List<Object?>).first == 'newLatLngBounds',
      );
      for (var i = 0; i < 40 && !fitted(); i++) {
        await flush(tester);
      }
      expect(find.text('Cold group'), findsWidgets);
      expect(bus.memberReads, 1);
      expect(
        maps.cameraUpdates.map(
          (value) => (value.toJson() as List<Object?>).first,
        ),
        contains('newLatLngBounds'),
      );
      await tester.binding.handlePopRoute();
      await flush(tester);
      expect(router.routeInformationProvider.value.uri.path, '/');
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  group('camera follows reduce motion', () {
    const poles = [
      BusStationMember(
        stationId: 'a',
        stationUid: 'pole-a',
        stationName: 'A',
        lat: 24.9,
        lon: 120.9,
      ),
      BusStationMember(
        stationId: 'b',
        stationUid: 'pole-b',
        stationName: 'B',
        lat: 25.1,
        lon: 121.1,
      ),
    ];

    for (final reduced in [true, false]) {
      final label = reduced ? 'reduced motion snaps' : 'normal motion animates';

      void expectMode() {
        expect(maps.cameraUpdates, isNotEmpty);
        expect(maps.movedUpdates.isNotEmpty, reduced);
        expect(maps.animatedUpdates.isNotEmpty, !reduced);
      }

      void clearUpdates() {
        maps.cameraUpdates.clear();
        maps.movedUpdates.clear();
        maps.animatedUpdates.clear();
      }

      testWidgets('$label for a station tap', (tester) async {
        await mount(tester, _Near(), _Bus(), reduced: reduced);
        tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraMove!(
          const CameraPosition(target: LatLng(25.001, 121.001), zoom: 16),
        );
        clearUpdates();
        final mrt = tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .markers
            .firstWhere((m) => m.markerId.value == 'mrt:BL15');

        mrt.onTap!();
        await flush(tester);

        expectMode();
        await unmount(tester);
      });

      testWidgets('$label when a bus group fits its poles', (tester) async {
        final bus = _Bus()..members = poles;
        await mount(tester, _Near(), bus, reduced: reduced);
        clearUpdates();
        final group = tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .markers
            .firstWhere((m) => m.markerId.value == 'bus:group');

        group.onTap!();
        await flush(tester);

        expect(
          maps.cameraUpdates.whereType<CameraUpdateNewLatLngBounds>(),
          hasLength(1),
        );
        expectMode();
        await unmount(tester);
      });

      testWidgets('$label for the locate button', (tester) async {
        await mount(tester, _Near(), _Bus(), reduced: reduced);
        clearUpdates();
        location.next = _position(25.5, 121.5);

        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is Pressable && w.semanticLabel == '定位目前位置',
          ),
        );
        await flush(tester);

        expectMode();
        await unmount(tester);
      });

      testWidgets('$label for the live fix after the cached one', (
        tester,
      ) async {
        location
          ..cached = _position(24, 120)
          ..cachedGate = Completer()
          ..currentGate = Completer();
        await mount(tester, _Near(), _Bus(), reduced: reduced);
        clearUpdates();
        location.cachedGate!.complete();
        await flush(tester);
        clearUpdates();

        location.currentGate!.complete();
        await flush(tester);

        expectMode();
        await unmount(tester);
      });
    }
  });

  group('bus group spread', () {
    const poles = [
      BusStationMember(
        stationId: 'a',
        stationUid: 'pole-a',
        stationName: 'A',
        lat: 24.9,
        lon: 120.9,
      ),
      BusStationMember(
        stationId: 'b',
        stationUid: 'pole-b',
        stationName: 'B',
        lat: 25.1,
        lon: 121.1,
      ),
    ];

    Map<String, Marker> markers(WidgetTester tester) => {
      for (final m in tester.widget<GoogleMap>(find.byType(GoogleMap)).markers)
        m.markerId.value: m,
    };

    int fits() => maps.cameraUpdates
        .where((u) => (u.toJson() as List<Object?>).first == 'newLatLngBounds')
        .length;

    Future<void> openGroup(WidgetTester tester) async {
      markers(tester)['bus:group']!.onTap!();
      await flush(tester);
    }

    testWidgets('the holding pin stays until the poles arrive', (tester) async {
      final bus = _Bus()
        ..members = poles
        ..gate = Completer<void>();
      await mount(tester, _Near(), bus);
      await openGroup(tester);
      var shown = markers(tester);
      expect(shown.keys.where((id) => id.startsWith('member:')), isEmpty);
      expect(shown['bus:group']!.position, const LatLng(25, 121));
      expect(shown['bus:group']!.anchor, const Offset(0.5, 0.5));
      bus.gate!.complete();
      await flush(tester);
      shown = markers(tester);
      expect(shown.keys, containsAll(['member:pole-a', 'member:pole-b']));
      expect(shown.containsKey('bus:group'), isFalse);
      expect(fits(), 1);
      final fit = maps.cameraUpdates.whereType<CameraUpdateNewLatLngBounds>();
      expect(fit.single.padding, 120);
      await unmount(tester);
    });

    testWidgets('selecting a pole restyles it without refitting the map', (
      tester,
    ) async {
      final bus = _Bus()..members = poles;
      await mount(tester, _Near(), bus);
      await openGroup(tester);
      expect(fits(), 1);
      expect(markers(tester)['member:pole-a']!.zIndexInt, 0);
      final idle = markers(tester)['member:pole-a']!.anchor;
      expect(idle, const Offset(0.5, 0.5));

      markers(tester)['member:pole-a']!.onTap!();
      await flush(tester);
      var shown = markers(tester);
      expect(shown['member:pole-a']!.zIndexInt, 1);
      expect(shown['member:pole-b']!.zIndexInt, 0);
      // The plate sits right of the pin when the pole is west of the station.
      expect(shown['member:pole-a']!.anchor.dx, greaterThan(0.5));

      shown['member:pole-b']!.onTap!();
      await flush(tester);
      shown = markers(tester);
      expect(shown['member:pole-b']!.zIndexInt, 1);
      expect(shown['member:pole-b']!.anchor.dx, lessThan(0.5));

      shown['member:pole-b']!.onTap!();
      await flush(tester);
      shown = markers(tester);
      expect(shown['member:pole-b']!.zIndexInt, 0);
      expect(shown['member:pole-b']!.anchor, const Offset(0.5, 0.5));
      expect(fits(), 1);
      await unmount(tester);
    });
  });

  group('map defaults and nearby bookkeeping', () {
    // Startup work resolves on real time; a loaded host needs more than one
    // flush before the request count stops moving.
    Future<int> settled(WidgetTester tester, _Near near) async {
      var last = -1;
      for (var i = 0; i < 40 && last != near.requests.length; i++) {
        last = near.requests.length;
        await flush(tester);
      }
      return last;
    }

    testWidgets('a cold start frames Taipei at zoom 15 with a 2px logo gap', (
      tester,
    ) async {
      location.denied = true;
      await mount(tester, _Near(), _Bus());
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(
        maps.initialPositions.single,
        const CameraPosition(target: LatLng(25.033, 121.5654), zoom: 15),
      );
      final height =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(map.padding.bottom, height * 0.25 + 2);
      await unmount(tester);
    });

    testWidgets('the remembered device position is latitude then longitude', (
      tester,
    ) async {
      location.denied = true;
      await tester.runAsync(
        () => Hive.box<dynamic>(
          'settings',
        ).put('last_device_position', [24.5, 120.5]),
      );
      await mount(tester, _Near(), _Bus());
      expect(
        maps.initialPositions.single,
        const CameraPosition(target: LatLng(24.5, 120.5), zoom: 15),
      );
      await unmount(tester);
    });

    testWidgets('a settled success covers the viewport; idling asks nothing', (
      tester,
    ) async {
      final near = _Near();
      await mount(tester, near, _Bus());
      final asked = await settled(tester, near);
      expect(asked, greaterThan(0));
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
      expect(await settled(tester, near), asked);
      await unmount(tester);
    });

    testWidgets('a settled failure leaves the viewport open to a retry', (
      tester,
    ) async {
      final near = _Near()..fail = true;
      await mount(tester, near, _Bus());
      final asked = await settled(tester, near);
      near.fail = false;
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
      expect(await settled(tester, near), greaterThan(asked));
      await unmount(tester);
    });

    for (final (metres, asks) in [(0.0003, false), (0.0015, true)]) {
      testWidgets('after a station tap an idle ${metres * 111320}m away '
          '${asks ? 'asks again' : 'stays quiet'}', (tester) async {
        final near = _Near();
        await mount(tester, near, _Bus());
        await settled(tester, near);
        final metro = tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .markers
            .firstWhere((m) => m.markerId.value == 'mrt:BL15');
        metro.onTap!();
        final asked = await settled(tester, near);
        final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
        map.onCameraMove!(
          CameraPosition(target: LatLng(25.001 + metres, 121.001), zoom: 16),
        );
        map.onCameraIdle!();
        expect(await settled(tester, near) > asked, asks);
        await unmount(tester);
      });
    }
  });

  group('bus group labels and framing', () {
    BusStopArrival eta(String uid, String destination) => BusStopArrival(
      stationId: uid,
      subRouteUid: 'r-$uid',
      routeName: '307',
      destination: destination,
      estimateSeconds: 300,
    );

    BusStationMember pole(String uid, double lat, double lon) =>
        BusStationMember(
          stationId: uid,
          stationUid: uid,
          stationName: uid,
          lat: lat,
          lon: lon,
        );

    Map<String, Marker> markers(WidgetTester tester) => {
      for (final m in tester.widget<GoogleMap>(find.byType(GoogleMap)).markers)
        m.markerId.value: m,
    };

    Future<void> open(
      WidgetTester tester,
      List<BusStationMember> members, {
      List<BusStopArrival> etas = const [],
      _Near? near,
    }) async {
      final bus = _Bus()
        ..members = members
        ..etas = etas
        ..etaGate = etas.isEmpty ? null : Completer<void>();
      await mount(tester, near ?? _Near(), bus);
      markers(tester)['bus:group']!.onTap!();
      await flush(tester);
      if (bus.etaGate != null) {
        bus.etaGate!.complete();
        await flush(tester);
      }
    }

    int fits() =>
        maps.cameraUpdates.whereType<CameraUpdateNewLatLngBounds>().length;

    // A labelled capsule sits its plate off the pin's centre.
    bool labelled(WidgetTester tester, String uid) =>
        markers(tester)['member:$uid']!.anchor != const Offset(0.5, 0.5);

    for (final (count, all) in [(2, true), (3, true), (4, false)]) {
      testWidgets('$count named poles ${all ? 'all' : 'none'} labelled', (
        tester,
      ) async {
        final uids = [for (var i = 0; i < count; i++) 'p$i'];
        await open(
          tester,
          [for (final (i, u) in uids.indexed) pole(u, 24.9 + i * 0.1, 120.9)],
          etas: [for (final u in uids) eta(u, '終點$u')],
        );
        for (final uid in uids) {
          expect(labelled(tester, uid), all, reason: uid);
        }
        await unmount(tester);
      });
    }

    testWidgets('a selected pole of a crowded group gains its label', (
      tester,
    ) async {
      final uids = ['p0', 'p1', 'p2', 'p3'];
      await open(
        tester,
        [for (final (i, u) in uids.indexed) pole(u, 24.9 + i * 0.1, 120.9)],
        etas: [for (final u in uids) eta(u, '終點$u')],
      );
      markers(tester)['member:p2']!.onTap!();
      await flush(tester);
      expect(
        [for (final u in uids) labelled(tester, u)],
        [
          false,
          false,
          true,
          false,
        ],
      );
      await unmount(tester);
    });

    testWidgets('three poles far apart are fitted, framed ones are not', (
      tester,
    ) async {
      await open(tester, [
        pole('a', 24.9, 120.9),
        pole('b', 25.1, 121.1),
        pole('c', 25.0, 121.0),
      ]);
      expect(fits(), 1);
      await unmount(tester);
    });

    testWidgets('poles already in view cause no camera move', (tester) async {
      await open(tester, [
        pole('a', 25.0, 121.0),
        pole('b', 25.0005, 121.0005),
      ]);
      expect(fits(), 0);
      await unmount(tester);
    });

    testWidgets('an idle at the fitted centre is the app\'s own', (
      tester,
    ) async {
      final near = _Near();
      await open(tester, [
        pole('a', 24.9, 120.9),
        pole('b', 25.1, 121.1),
      ], near: near);
      var asked = near.requests.length;
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      map.onCameraMove!(
        const CameraPosition(target: LatLng(25, 121), zoom: 12),
      );
      map.onCameraIdle!();
      for (var i = 0; i < 4; i++) {
        await flush(tester);
      }
      expect(near.requests.length, asked);
      asked = near.requests.length;
      map.onCameraMove!(
        const CameraPosition(target: LatLng(25.3, 121.3), zoom: 12),
      );
      map.onCameraIdle!();
      for (var i = 0; i < 4; i++) {
        await flush(tester);
      }
      expect(near.requests.length, greaterThan(asked));
      await unmount(tester);
    });
  });

  group('station taps on the map', () {
    Map<String, Marker> markers(WidgetTester tester) => {
      for (final m in tester.widget<GoogleMap>(find.byType(GoogleMap)).markers)
        m.markerId.value: m,
    };

    void camera(WidgetTester tester, LatLng target, double zoom) {
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraMove!(
        CameraPosition(target: target, zoom: zoom),
      );
    }

    testWidgets('station markers sit on their stop, centred', (tester) async {
      await mount(tester, _Near(), _Bus());
      final shown = markers(tester);
      expect(shown['mrt:BL15']!.position, const LatLng(25.001, 121.001));
      for (final marker in shown.values) {
        expect(marker.anchor, const Offset(0.5, 0.5));
      }
      await unmount(tester);
    });

    testWidgets('a zoomed-out tap raises the zoom to the icon floor', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      camera(tester, const LatLng(25, 121), 12);
      maps.cameraUpdates.clear();
      markers(tester)['mrt:BL15']!.onTap!();
      await flush(tester);
      final update = maps.cameraUpdates
          .whereType<CameraUpdateNewLatLngZoom>()
          .single;
      expect(update.latLng, const LatLng(25.001, 121.001));
      expect(update.zoom, 15.5);
      await unmount(tester);
    });

    testWidgets('a zoomed-in tap on a plain station always pans to it', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      camera(tester, const LatLng(25.001, 121.001), 16);
      maps.cameraUpdates.clear();
      markers(tester)['mrt:BL15']!.onTap!();
      await flush(tester);
      final update = maps.cameraUpdates
          .whereType<CameraUpdateNewLatLng>()
          .single;
      expect(update.latLng, const LatLng(25.001, 121.001));
      await unmount(tester);
    });

    testWidgets('a group already at the centre is not panned to', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      camera(tester, const LatLng(25, 121), 16);
      maps.cameraUpdates.clear();
      markers(tester)['bus:group']!.onTap!();
      await flush(tester);
      expect(
        maps.cameraUpdates.whereType<CameraUpdateNewLatLng>(),
        isEmpty,
      );
      await unmount(tester);
    });

    testWidgets('a group well off centre is panned to', (tester) async {
      await mount(tester, _Near(), _Bus());
      camera(tester, const LatLng(25.01, 121.01), 16);
      maps.cameraUpdates.clear();
      markers(tester)['bus:group']!.onTap!();
      await flush(tester);
      final update = maps.cameraUpdates
          .whereType<CameraUpdateNewLatLng>()
          .single;
      expect(update.latLng, const LatLng(25, 121));
      await unmount(tester);
    });

    testWidgets('the tapped station alone takes the highlighted icon', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      List<int> bytes(String id) =>
          (markers(tester)[id]!.icon as BytesMapBitmap).byteData.buffer
              .asUint8List()
              .toList();
      final busBefore = bytes('bus:group');
      final mrtBefore = bytes('mrt:BL15');
      markers(tester)['mrt:BL15']!.onTap!();
      // The redraw renders a bitmap on real time.
      for (var i = 0; i < 40 && listEquals(bytes('mrt:BL15'), mrtBefore); i++) {
        await flush(tester);
      }
      late List<int> highlighted;
      await tester.runAsync(() async {
        final icon = await markerIcon(
          _Near().stations.last,
          MarkerStyle.largeDot,
          highlighted: true,
        );
        highlighted = (icon as BytesMapBitmap).byteData.buffer
            .asUint8List()
            .toList();
      });
      expect(bytes('mrt:BL15'), highlighted);
      expect(bytes('mrt:BL15'), isNot(mrtBefore));
      expect(bytes('bus:group'), busBefore);
      await unmount(tester);
    });

    testWidgets('crossing into the icon zoom redraws the markers', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      List<int> bytes() => (markers(tester)['mrt:BL15']!.icon as BytesMapBitmap)
          .byteData
          .buffer
          .asUint8List()
          .toList();
      final before = bytes();
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      map.onCameraMove!(
        const CameraPosition(target: LatLng(25, 121), zoom: 16),
      );
      map.onCameraIdle!();
      for (var i = 0; i < 40 && listEquals(bytes(), before); i++) {
        await flush(tester);
      }
      expect(bytes(), isNot(before));
      await unmount(tester);
    });
  });

  testWidgets('favorites readiness switches to real pinned rows', (
    tester,
  ) async {
    final initialized = App.isInitialized.value;
    App.isInitialized.value = false;
    addTearDown(() => App.isInitialized.value = initialized);
    await Hive.box<dynamic>('favorites').close();
    final router = await mount(tester, _Near(), _Bus(), initializing: true);
    await Hive.openBox<dynamic>('favorites', bytes: Uint8List(0));
    await FavoritesRepository.instance.add(
      const Favorite(
        type: FavoriteType.busRoute,
        refId: 'R',
        title: 'Pinned route',
        pinned: true,
      ),
    );
    App.isInitialized.value = true;
    await flush(tester);
    await tester.drag(
      find.byType(SheetDragHandle).first,
      const Offset(0, -500),
    );
    await flush(tester);
    expect(find.text('Pinned route'), findsWidgets);
    final label = lookupAppI18n(const Locale('zh')).homeSeeAllFavorites;
    await tester.tap(find.text(label));
    await flush(tester);
    expect(find.text('favorites destination'), findsOneWidget);
    expect(router.canPop(), isTrue);
    await unmount(tester);
  });

  testWidgets('the sheet states its search hint and the empty pinned tab', (
    tester,
  ) async {
    final router = await mount(tester, _Near(), _Bus());
    final i18n = lookupAppI18n(const Locale('zh'));
    final hint = find.text(i18n.homeSearchHint);
    expect(hint, findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    await tester.drag(
      find.byType(SheetDragHandle).first,
      const Offset(0, -500),
    );
    await flush(tester);
    await tester.tap(find.text(i18n.homeTabFavorites));
    await flush(tester);
    expect(find.text(i18n.homeNoPinned), findsOneWidget);
    expect(
      tester.widget<Text>(find.text(i18n.homeNoPinnedBody)).style!.height,
      1.5,
    );
    await tester.tap(find.text(i18n.homeGoToFavorites));
    await flush(tester);
    expect(find.text('favorites destination'), findsOneWidget);
    router.pop();
    await flush(tester);
    await tester.tap(hint);
    await flush(tester);
    expect(find.text('search destination'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the see-all row is set off by a faint hairline', (tester) async {
    await mount(tester, _Near(), _Bus());
    await FavoritesRepository.instance.add(
      const Favorite(
        type: FavoriteType.busRoute,
        refId: 'R',
        title: 'Pinned route',
        pinned: true,
      ),
    );
    await tester.drag(
      find.byType(SheetDragHandle).first,
      const Offset(0, -500),
    );
    await flush(tester);
    await tester.tap(
      find.text(lookupAppI18n(const Locale('zh')).homeTabFavorites),
    );
    await flush(tester);
    final label = lookupAppI18n(const Locale('zh')).homeSeeAllFavorites;
    final row = tester.widget<Container>(
      find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first,
    );
    final border = (row.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 0.5);
    final outline = Theme.of(
      tester.element(find.text(label)),
    ).colorScheme.outlineVariant;
    expect(border.top.color.a, closeTo(0.3 * outline.a, 1e-3));
    await unmount(tester);
  });

  testWidgets('location service and permission actions open their OS panels', (
    tester,
  ) async {
    location.disabled = true;
    await mount(tester, _Near(), _Bus(), reduced: true);
    final i18n = lookupAppI18n(const Locale('zh'));
    await tester.tap(find.text(i18n.alertsOpenLocationService));
    await flush(tester);
    expect(location.openedSettings, 1);
    location
      ..disabled = false
      ..denied = true;
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Pressable && widget.semanticLabel == '定位目前位置',
      ),
    );
    await flush(tester);
    await tester.tap(find.text(i18n.alertsOpenLocationPermission));
    await flush(tester);
    expect(location.openedApp, 1);
    location
      ..denied = false
      ..failure = StateError('sensor temporarily unavailable');
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Pressable && widget.semanticLabel == '定位目前位置',
      ),
    );
    await flush(tester);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('zooming in renders Taipei and fallback metro icon families', (
    tester,
  ) async {
    final near = _Near()
      ..stations = [
        for (final id in ['BL15', 'C1', 'unknown'])
          NearStationViewModel(
            type: NearStationType.mrt,
            stationId: id,
            stationName: id,
            lat: 25,
            lon: 121,
            walkingMinutes: 1,
            distanceMeters: 30,
          ),
      ];
    await mount(tester, near, _Bus());
    final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
    map.onCameraMove!(const CameraPosition(target: LatLng(25, 121), zoom: 16));
    map.onCameraIdle!();
    await flush(tester);
    expect(
      tester
          .widgetList<TransportIcon>(find.byType(TransportIcon))
          .map((icon) => icon.type),
      contains(TransportType.mrtKG),
    );
    expect(
      tester
          .widget<GoogleMap>(find.byType(GoogleMap))
          .markers
          .map((marker) => marker.markerId.value),
      containsAll(['mrt:BL15', 'mrt:C1', 'mrt:unknown']),
    );
    final fallback = tester
        .widget<GoogleMap>(find.byType(GoogleMap))
        .markers
        .singleWhere((marker) => marker.markerId.value == 'mrt:C1');
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        (fallback.icon as BytesMapBitmap).byteData,
      );
      final image = (await codec.getNextFrame()).image;
      final pixels = (await image.toByteData())!.buffer.asUint8List();
      final center = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      expect(pixels.sublist(center, center + 4), [
        (AppTheme.mrtKG.r * 255).round(),
        (AppTheme.mrtKG.g * 255).round(),
        (AppTheme.mrtKG.b * 255).round(),
        255,
      ]);
      image.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets(
    'native home queries GPS viewport and opens and closes bus poles',
    (tester) async {
      final near = _Near();
      final bus = _Bus();
      final router = await mount(tester, near, bus);
      expect(near.requests, isNotEmpty);
      expect(maps.cameraUpdates, isNotEmpty);
      final initialReads = location.reads;
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Pressable && widget.semanticLabel == '定位目前位置',
        ),
      );
      await flush(tester);
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
      await flush(tester);
      expect(location.reads, initialReads + 1);
      final initialMap = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(
        initialMap.markers.map((marker) => marker.markerId.value),
        contains('bus:group'),
      );
      initialMap.markers
          .firstWhere((marker) => marker.markerId.value == 'bus:group')
          .onTap!();
      await flush(tester);
      expect(router.routeInformationProvider.value.uri.path, '/near/bus/group');
      expect(bus.memberReads, 1);
      expect(find.text('Test station'), findsWidgets);
      await tester.drag(
        find.byType(SheetDragHandle).first,
        const Offset(0, -400),
      );
      await flush(tester);
      router.go('/');
      await flush(tester);
      expect(router.routeInformationProvider.value.uri.path, '/');
      expect(
        tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .markers
            .map((marker) => marker.markerId.value),
        contains('bus:group'),
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
      await tester.pump();
      expect(maps.disposed, maps.created);
    },
  );

  testWidgets('native home retains cached position after permission denial', (
    tester,
  ) async {
    location.denied = true;
    final near = _Near();
    await mount(tester, near, _Bus(), reduced: true);
    expect(near.requests, isNotEmpty);
    expect(location.reads, 0);
    expect(find.byType(GoogleMap), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
  testWidgets(
    'native nearby failures retry the same viewport and clear the error',
    (tester) async {
      final near = _Near()..fail = true;
      await mount(tester, near, _Bus());
      await tester.drag(
        find.byType(SheetDragHandle).first,
        const Offset(0, -400),
      );
      await flush(tester);
      expect(find.text('重試'), findsWidgets);
      final failed = near.requests.last;
      near.fail = false;
      await tester.tap(find.text('重試').first);
      await flush(tester);
      expect(near.requests.last.lat, failed.lat);
      expect(near.requests.last.lon, failed.lon);
      expect(near.requests.last.radius, failed.radius);
      expect(find.text('Test station'), findsWidgets);
      expect(find.text('重試'), findsNothing);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets(
    'native home shows empty nearby without inventing station markers',
    (tester) async {
      final near = _Near()..stations = [];
      await mount(tester, near, _Bus(), reduced: true);
      await tester.drag(
        find.byType(SheetDragHandle).first,
        const Offset(0, -400),
      );
      await flush(tester);
      expect(find.text('附近沒有站點'), findsOneWidget);
      expect(tester.widget<GoogleMap>(find.byType(GoogleMap)).markers, isEmpty);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  group('location fixes, locate button and scan ring', () {
    final locateButton = find.byWidgetPredicate(
      (widget) => widget is Pressable && widget.semanticLabel == '定位目前位置',
    );

    // The painter type is private to the screen's library.
    dynamic ring(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .firstWhere((p) => p.runtimeType.toString() == '_ScanRingPainter');

    List<Object?> sent(int from) => [
      for (final update in maps.cameraUpdates.skip(from)) update.toJson(),
    ];
    Object? target(double lat, double lon) =>
        CameraUpdate.newLatLng(LatLng(lat, lon)).toJson();
    Object? stored() =>
        Hive.box<dynamic>('settings').get('last_device_position');

    Future<void> idle(WidgetTester tester) async {
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    testWidgets('the OS-cached fix is applied first, the live fix after it', (
      tester,
    ) async {
      location
        ..cached = _position(24, 120)
        ..cachedGate = Completer()
        ..currentGate = Completer();
      final near = _Near();
      await mount(tester, near, _Bus());
      final before = maps.cameraUpdates.length;

      location.cachedGate!.complete();
      await flush(tester);
      expect(stored(), orderedEquals([24.0, 120.0]));
      expect(sent(before), [target(24, 120)]);

      location.currentGate!.complete();
      await flush(tester);
      expect(stored(), orderedEquals([25.0, 121.0]));
      expect(sent(before), [target(24, 120), target(25, 121)]);

      await idle(tester);
      await flush(tester);
      expect(near.requests.last.lat, 25);
      expect(near.requests.last.lon, 121);
      await unmount(tester);
    });

    testWidgets('a cached fix puts the first search on the cached centre', (
      tester,
    ) async {
      location
        ..cached = _position(24, 120)
        ..failure = StateError('no live fix');
      final near = _Near();
      await mount(tester, near, _Bus());
      await idle(tester);
      await flush(tester);

      expect(near.requests.last.lat, 24);
      expect(near.requests.last.lon, 120);
      await unmount(tester);
    });

    testWidgets('locating shows a spinner until the fix lands', (tester) async {
      await mount(tester, _Near(), _Bus());
      location.currentGate = Completer();

      await tester.tap(locateButton);
      await tester.pump();
      expect(find.byKey(const ValueKey('locating')), findsOneWidget);

      location.currentGate!.complete();
      await flush(tester);
      expect(find.byKey(const ValueKey('locating')), findsNothing);
      expect(find.byKey(const ValueKey('idle')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a failed locate gives the spinner back', (tester) async {
      await mount(tester, _Near(), _Bus());
      location.failure = StateError('sensor temporarily unavailable');

      await tester.tap(locateButton);
      await flush(tester);

      expect(find.byKey(const ValueKey('locating')), findsNothing);
      expect(find.byKey(const ValueKey('idle')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('locating pans to the fix, then searches around it', (
      tester,
    ) async {
      final near = _Near();
      await mount(tester, near, _Bus());
      final before = maps.cameraUpdates.length;
      location.next = _position(25.5, 121.5);

      await tester.tap(locateButton);
      await flush(tester);
      expect(sent(before), [target(25.5, 121.5)]);

      await idle(tester);
      await flush(tester);
      expect(near.requests.last.lat, 25.5);
      expect(near.requests.last.lon, 121.5);
      await unmount(tester);
    });

    group('scan ring', () {
      testWidgets('a first search sweeps quietly around the map centre', (
        tester,
      ) async {
        await mount(tester, _Near(), _Bus());

        final painter = ring(tester);
        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        final padding = tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .padding
            .bottom;
        expect(painter.still, isTrue);
        expect(
          painter.center,
          Offset(size.width / 2, (size.height - padding) / 2),
        );
        expect(painter.radius, greaterThan(0));
        await unmount(tester);
      });

      testWidgets('an idle the dedup answers plays no sweep', (tester) async {
        await mount(tester, _Near(), _Bus());
        final progress = ring(tester).progress as Animation<double>;
        expect(progress.value, 1);

        tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
        await tester.pump(const Duration(milliseconds: 301));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(progress.value, 1);
        await unmount(tester);
      });

      testWidgets('a locate tap is answered with a full sweep even when the '
          'area is already covered', (tester) async {
        final near = _Near();
        await mount(tester, near, _Bus());
        final asked = near.requests.length;
        final progress = ring(tester).progress as Animation<double>;

        await tester.tap(locateButton);
        await flush(tester);
        tester.widget<GoogleMap>(find.byType(GoogleMap)).onCameraIdle!();
        await tester.pump(const Duration(milliseconds: 301));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(near.requests.length, asked);
        expect(progress.value, allOf(greaterThan(0), lessThan(1)));
        expect(ring(tester).still, isFalse);
        await flush(tester);
        await unmount(tester);
      });

      testWidgets('with reduce motion even a locate sweep holds still', (
        tester,
      ) async {
        await mount(tester, _Near(), _Bus(), reduced: true);

        await tester.tap(locateButton);
        await flush(tester);
        await idle(tester);
        await flush(tester);

        expect(ring(tester).still, isTrue);
        await unmount(tester);
      });
    });

    group('viewport search debounce', () {
      testWidgets('a viewport that never succeeded is searched at once', (
        tester,
      ) async {
        final near = _Near()..fail = true;
        await mount(tester, near, _Bus());
        near.fail = false;
        final asked = near.requests.length;

        await idle(tester);

        expect(near.requests.length, greaterThan(asked));
        await unmount(tester);
      });

      testWidgets('after a success the next idle waits out 300 ms', (
        tester,
      ) async {
        final near = _Near();
        await mount(tester, near, _Bus());
        final asked = near.requests.length;
        final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
        map.onCameraMove!(
          const CameraPosition(target: LatLng(25.02, 121), zoom: 15),
        );
        map.onCameraIdle!();

        await tester.pump(const Duration(milliseconds: 299));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(near.requests.length, asked);

        await tester.pump(const Duration(milliseconds: 2));
        await flush(tester);
        expect(near.requests.length, asked + 1);
        await unmount(tester);
      });
    });

    testWidgets('a readiness ping before the app is ready changes nothing', (
      tester,
    ) async {
      final initialized = App.isInitialized.value;
      App.isInitialized.value = false;
      addTearDown(() => App.isInitialized.value = initialized);
      await Hive.box<dynamic>('favorites').close();
      await mount(tester, _Near(), _Bus(), initializing: true);
      TabController tabs() =>
          tester.widget<TabBarView>(find.byType(TabBarView)).controller!;
      expect(tabs().index, 1);
      await Hive.openBox<dynamic>('favorites', bytes: Uint8List(0));
      await FavoritesRepository.instance.add(
        const Favorite(
          type: FavoriteType.busRoute,
          refId: 'R',
          title: 'Pinned route',
          pinned: true,
        ),
      );

      // ignore: invalid_use_of_protected_member
      App.isInitialized.notifyListeners();
      await flush(tester);
      expect(tabs().index, 1);

      App.isInitialized.value = true;
      await flush(tester);
      expect(tabs().index, 0);
      await unmount(tester);
    });
  });

  group('floating controls', () {
    final i18n = lookupAppI18n(const Locale('zh'));
    final controls = {
      i18n.commonSettings: 'settings destination',
      i18n.modeMetro: 'metro destination',
      i18n.homePlanRoute: 'go destination',
    };
    Finder control(String label) => find.byWidgetPredicate(
      (widget) => widget is Pressable && widget.semanticLabel == label,
    );
    Size screen(WidgetTester tester) =>
        tester.view.physicalSize / tester.view.devicePixelRatio;

    for (final MapEntry(key: label, value: destination) in controls.entries) {
      testWidgets('$label opens its screen', (tester) async {
        await mount(tester, _Near(), _Bus());

        await tester.tap(control(label));
        await flush(tester);

        expect(find.text(destination), findsOneWidget);
        await unmount(tester);
      });
    }

    testWidgets('the notification control opens the sheet', (tester) async {
      await mount(tester, _Near(), _Bus());
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);

      await tester.tap(control(i18n.commonNotifications));
      await flush(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the rail control opens the rail form', (tester) async {
      await mount(tester, _Near(), _Bus());

      await tester.tap(control(i18n.modeRailPair));
      await flush(tester);

      expect(find.byType(HomeRailQuerySheet), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('every control is a 12 px rounded floating square', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      final scheme = Theme.of(
        tester.element(find.byType(HomeScreen)),
      ).colorScheme;

      for (final label in [
        i18n.commonSettings,
        i18n.commonNotifications,
        i18n.modeMetro,
        i18n.modeRailPair,
        i18n.commonLocateMe,
        i18n.homePlanRoute,
      ]) {
        final box = tester.widget<Container>(
          find
              .descendant(of: control(label), matching: find.byType(Container))
              .first,
        );
        expect(
          box.decoration,
          AppTheme.floatingControl(
            scheme,
            borderRadius: BorderRadius.circular(12),
          ),
          reason: label,
        );
      }
      await unmount(tester);
    });

    for (final (version, shown) in [('9.9.9', true), (null, false)]) {
      testWidgets('an available update ($version): badge shown $shown', (
        tester,
      ) async {
        availableUpdate.value = version;
        addTearDown(() => availableUpdate.value = null);
        await mount(tester, _Near(), _Bus());

        final badge = tester.widget<Badge>(
          find.descendant(
            of: control(i18n.commonSettings),
            matching: find.byType(Badge),
          ),
        );

        expect(badge.isLabelVisible, shown);
        await unmount(tester);
      });
    }

    testWidgets('the map controls sit 16 px from the right edge', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());

      expect(
        tester.getRect(control(i18n.commonLocateMe)).right,
        screen(tester).width - 16,
      );
      await unmount(tester);
    });

    testWidgets('they ride the peeking sheet, 16 px above it', (tester) async {
      double? firstBottom;
      await mount(
        tester,
        _Near(),
        _Bus(),
        firstFrame: () =>
            firstBottom = tester.getRect(control(i18n.homePlanRoute)).bottom,
      );
      final height = screen(tester).height;

      final peeking = height - (height * AppSheetSnap.peekFrac + 16);
      expect(firstBottom, peeking);
      expect(tester.getRect(control(i18n.homePlanRoute)).bottom, peeking);
      await unmount(tester);
    });

    testWidgets('a sheet taller than half stops lifting them', (tester) async {
      await mount(tester, _Near(), _Bus());
      final height = screen(tester).height;

      await tester.drag(
        find.byType(SheetDragHandle).first,
        const Offset(0, -500),
      );
      await flush(tester);

      expect(
        tester.getRect(control(i18n.homePlanRoute)).bottom,
        height - (height * AppSheetSnap.halfFrac + 16),
      );
      await unmount(tester);
    });

    testWidgets('while locating the button shows a 20 px spinner', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());
      location.currentGate = Completer();

      await tester.tap(control(i18n.commonLocateMe));
      await tester.pump();

      expect(
        tester.widget<AppSpinner>(find.byKey(const ValueKey('locating'))).size,
        20,
      );
      location.currentGate!.complete();
      await flush(tester);
      await unmount(tester);
    });

    testWidgets('no ring is mounted before any search has run', (tester) async {
      var mounted = true;
      await mount(
        tester,
        _Near(),
        _Bus(),
        firstFrame: () => mounted = find
            .byWidgetPredicate(
              (w) =>
                  w is CustomPaint &&
                  w.painter.runtimeType.toString() == '_ScanRingPainter',
            )
            .evaluate()
            .isNotEmpty,
      );

      expect(mounted, isFalse);
      await unmount(tester);
    });

    testWidgets('back at the peeking sheet leaves the app', (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mount(tester, _Near(), _Bus());

      await tester.binding.handlePopRoute();
      await flush(tester);

      expect(calls, contains('SystemNavigator.pop'));
      await unmount(tester);
    });
  });

  group('nearby tab', () {
    final i18n = lookupAppI18n(const Locale('zh'));
    Finder handle() => find.byType(SheetDragHandle).first;
    double handleY(WidgetTester tester) => tester.getTopLeft(handle()).dy;
    double screenHeight(WidgetTester tester) =>
        tester.view.physicalSize.height / tester.view.devicePixelRatio;

    // Holds the sheet [rise] px above peek and reports how far it really is.
    Future<(TestGesture, double)> holdRisen(
      WidgetTester tester,
      double rise,
    ) async {
      final y0 = handleY(tester);
      final gesture = await tester.startGesture(tester.getCenter(handle()));
      // The move that crosses touch slop starts the drag but is not counted.
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      var risen = y0 - handleY(tester);
      for (var i = 0; i < 400 && risen < rise; i++) {
        await gesture.moveBy(const Offset(0, -1));
        await tester.pump();
        risen = y0 - handleY(tester);
      }
      return (gesture, risen);
    }

    final filterRow = find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );
    Finder filterFade() =>
        find.ancestor(of: filterRow, matching: find.byType(Opacity)).first;
    Finder chip(String label) => find.widgetWithText(Pressable, label);

    Future<void> expandSheet(WidgetTester tester) async {
      await tester.drag(handle(), const Offset(0, -500));
      await flush(tester);
    }

    testWidgets('the filter row is not in the tree while the sheet peeks', (
      tester,
    ) async {
      await mount(tester, _Near(), _Bus());

      expect(filterRow, findsNothing);
      await unmount(tester);
    });

    for (final rise in [40.0, 100.0]) {
      testWidgets('$rise px up, the filter row is revealed along the ease '
          'curve', (tester) async {
        await mount(tester, _Near(), _Bus());

        final (gesture, risen) = await holdRisen(tester, rise);

        final raw = (risen / (screenHeight(tester) * 0.25)).clamp(0.0, 1.0);
        final reveal = AppMotion.easeInOut.transform(raw);
        expect(
          tester.widget<Opacity>(filterFade()).opacity,
          closeTo(reveal, 1e-9),
        );
        expect(
          tester
              .widget<Align>(
                find
                    .ancestor(of: filterRow, matching: find.byType(Align))
                    .first,
              )
              .heightFactor,
          closeTo(reveal, 1e-9),
        );
        await gesture.up();
        await flush(tester);
        await unmount(tester);
      });
    }

    for (final (rise, shown) in [(74.0, false), (75.0, true)]) {
      testWidgets('with reduce motion, ${rise}px up the filter row is '
          '${shown ? 'shown' : 'still hidden'}', (tester) async {
        await mount(tester, _Near(), _Bus(), reduced: true);

        final (gesture, risen) = await holdRisen(tester, rise);

        expect(risen, rise);
        expect(filterRow, shown ? findsOneWidget : findsNothing);
        if (shown) expect(tester.widget<Opacity>(filterFade()).opacity, 1);
        await gesture.up();
        await flush(tester);
        await unmount(tester);
      });
    }

    testWidgets('a filter that hides every nearby station says so, and one '
        'tap shows them all again', (tester) async {
      final near = _Near()
        ..stations = [
          const NearStationViewModel(
            type: NearStationType.mrt,
            stationId: 'BL15',
            stationName: 'Metro station',
            lat: 25,
            lon: 121,
            walkingMinutes: 2,
            distanceMeters: 120,
          ),
        ];
      await mount(tester, near, _Bus());
      await expandSheet(tester);

      await tester.tap(chip(i18n.modeBus));
      await flush(tester);
      expect(
        find.text(i18n.homeNoNearbyFiltered(i18n.modeBus)),
        findsOneWidget,
      );
      expect(find.text('Metro station'), findsNothing);

      await tester.tap(find.text(i18n.homeShowAllStops));
      await flush(tester);
      expect(find.text('Metro station'), findsWidgets);
      await unmount(tester);
    });

    testWidgets('with nothing nearby at all a filter cannot blame itself', (
      tester,
    ) async {
      await mount(tester, _Near()..stations = [], _Bus());
      await expandSheet(tester);

      await tester.tap(chip(i18n.modeBus));
      await flush(tester);

      expect(find.text(i18n.homeNoNearby), findsOneWidget);
      expect(
        find.text(i18n.homeNoNearbyFiltered(i18n.modeBus)),
        findsNothing,
      );
      await unmount(tester);
    });

    testWidgets('while loading, skeleton rows fill the list', (tester) async {
      final near = _Near()..gate = Completer();
      await mount(tester, near, _Bus());
      await expandSheet(tester);

      final list = find.descendant(
        of: find.byKey(const ValueKey('loading')),
        matching: find.byType(ListView),
      );
      final delegate =
          tester.widget<ListView>(list).childrenDelegate
              as SliverChildBuilderDelegate;
      expect(
        delegate.estimatedChildCount,
        (tester.getSize(list).height / 62).ceil(),
      );
      String label(String name, int minutes, int metres) =>
          '$name ${i18n.nearbyWalkAndDistance(minutes, formatNearDistance(metres))}';
      final labels = [
        for (final row in tester.widgetList<Pressable>(
          find.descendant(
            of: find.byKey(const ValueKey('loading')),
            matching: find.byType(Pressable),
          ),
        ))
          row.semanticLabel,
      ];
      expect(labels.take(3), [
        label('囗囗囗囗', 3, 240),
        label('囗囗囗囗囗囗', 5, 420),
        label('囗囗囗', 8, 860),
      ]);

      near.gate!.complete();
      await flush(tester);
      await unmount(tester);
    });

    group('return to map', () {
      List<NearStationViewModel> many() => [
        for (var i = 0; i < 30; i++)
          NearStationViewModel(
            type: NearStationType.bus,
            stationId: 'S$i',
            stationName: 'Station $i',
            lat: 25 + i * 0.0001,
            lon: 121,
            walkingMinutes: 1,
            distanceMeters: 40 + i,
          ),
      ];
      Finder list() => find.byWidgetPredicate(
        (w) =>
            w is ListView &&
            w.childrenDelegate is SliverChildBuilderDelegate &&
            (w.childrenDelegate as SliverChildBuilderDelegate)
                    .estimatedChildCount ==
                30,
      );
      ScrollPosition position(WidgetTester tester) => tester
          .state<ScrollableState>(
            find.descendant(of: list(), matching: find.byType(Scrollable)),
          )
          .position;
      Finder pill() => find.byWidgetPredicate(
        (w) => w is Pressable && w.semanticLabel == i18n.homeBackToMap,
      );

      testWidgets('the pill waits for the list to scroll past 72 px', (
        tester,
      ) async {
        await mount(tester, _Near()..stations = many(), _Bus());
        await expandSheet(tester);
        expect(pill(), findsNothing);

        position(tester).jumpTo(72);
        await flush(tester);
        expect(pill(), findsNothing);

        position(tester).jumpTo(72.5);
        await flush(tester);
        expect(pill(), findsOneWidget);
        await unmount(tester);
      });

      testWidgets('it floats 40 px above the bottom of the list', (
        tester,
      ) async {
        await mount(tester, _Near()..stations = many(), _Bus());
        await expandSheet(tester);
        position(tester).jumpTo(200);
        await flush(tester);

        final slot = find
            .ancestor(of: pill(), matching: find.byType(SizedBox))
            .first;
        expect(tester.getRect(slot).bottom, tester.getRect(list()).bottom - 40);
        await unmount(tester);
      });

      testWidgets('tapping it scrolls the list home and drops the sheet to '
          'the peek', (tester) async {
        await mount(tester, _Near()..stations = many(), _Bus());
        final peekY = handleY(tester);
        await expandSheet(tester);
        position(tester).jumpTo(300);
        await flush(tester);

        await tester.tap(pill());
        await flush(tester);

        expect(position(tester).pixels, 0);
        expect(handleY(tester), peekY);
        await unmount(tester);
      });
    });
  });
}
