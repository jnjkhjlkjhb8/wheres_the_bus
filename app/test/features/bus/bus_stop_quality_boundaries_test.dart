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
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_detail_view.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_screen.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';

import '../../helpers/test_firebase_crash_recorder.dart';
import '../../support/fakes/map_platform.dart';

class _Bus extends BusRepository {
  final members = Completer<List<BusStationMember>>();
  final arrivals = StreamController<List<BusStopArrival>>.broadcast();

  @override
  Future<List<BusStationMember>> stationGroup(String groupUid) =>
      members.future;

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) =>
      arrivals.stream;
}

class _Location extends GeolocatorPlatform {
  final requests = <Completer<Position>>[];

  Position get fix => Position(
    latitude: 24,
    longitude: 120,
    timestamp: DateTime.now().toUtc(),
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

  int lastKnownCalls = 0;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async {
    lastKnownCalls++;
    return null;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) {
    final pending = Completer<Position>();
    requests.add(pending);
    return pending.future;
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

class _Alerts implements AlertRepository {
  @override
  Set<String> readAlerts() => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _east = BusStationMember(
  stationUid: 'east',
  stationId: 'east',
  stationName: '東側站牌',
  lat: 25,
  lon: 121,
);
const _west = BusStationMember(
  stationUid: 'west',
  stationId: 'west',
  stationName: '西側站牌',
  lat: 25.01,
  lon: 121.01,
);
const _empty = BusStationMember(
  stationUid: 'empty',
  stationId: 'empty',
  stationName: '沒有班次的站牌',
  lat: 25.02,
  lon: 121.02,
);

BusStopArrival _arrival(
  String pole,
  String route, {
  String? uid,
  int status = 0,
  int seconds = 120,
  String destination = '車站',
}) => BusStopArrival(
  stationId: pole,
  subRouteUid: uid ?? 'route-$route',
  routeName: route,
  destination: destination,
  estimateSeconds: seconds,
  stopStatus: status,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final crashes = TestFirebaseCrashRecorder();
  setUpAll(crashes.install);
  setUp(crashes.clear);
  tearDownAll(crashes.dispose);
  late GoogleMapsFlutterPlatform originalMap;
  late GeolocatorPlatform originalLocation;
  late FakeMapPlatform map;
  late _Location location;

  setUp(() {
    originalMap = GoogleMapsFlutterPlatform.instance;
    originalLocation = GeolocatorPlatform.instance;
    map = FakeMapPlatform();
    location = _Location();
    GoogleMapsFlutterPlatform.instance = map;
    GeolocatorPlatform.instance = location;
  });

  tearDown(() {
    GoogleMapsFlutterPlatform.instance = originalMap;
    GeolocatorPlatform.instance = originalLocation;
  });

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 350));
  }

  void cleanupBus(_Bus bus) {
    addTearDown(bus.arrivals.close);
    addTearDown(() {
      if (!bus.members.isCompleted) bus.members.complete(const []);
    });
  }

  List<BlocProvider> providers() {
    final ready = ValueNotifier(true);
    final favorites = FavoritesBloc(_Favorites(), ready);
    final alerts = AlertBloc(repository: _Alerts());
    addTearDown(ready.dispose);
    addTearDown(favorites.close);
    addTearDown(alerts.close);
    return [
      BlocProvider<FavoritesBloc>.value(value: favorites),
      BlocProvider<AlertBloc>.value(value: alerts),
    ];
  }

  Future<(GoRouter, BusStopBloc)> mountDetail(
    WidgetTester tester,
    _Bus bus, {
    required bool dark,
    ValueChanged<LatLng>? onFocus,
  }) async {
    cleanupBus(bus);
    final bloc = BusStopBloc(
      i18n: await AppI18n.delegate.load(const Locale('zh')),
      stopId: 'group',
      city: 'Taipei',
      repository: bus,
    );
    final scopes = providers();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => MultiBlocProvider(
            providers: [
              ...scopes,
              BlocProvider<BusStopBloc>(lazy: false, create: (_) => bloc),
            ],
            child: Scaffold(
              body: BusStopDetailView(
                stopName: '成員站群',
                stopId: 'group',
                city: 'Taipei',
                bloc: bloc,
                onFocusStation: onFocus,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/bus/route/:subRouteUid',
          builder: (_, state) => Scaffold(
            body: Text('opened ${state.pathParameters['subRouteUid']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: dark),
          child: child!,
        ),
      ),
    );
    await flush(tester);
    return (router, bloc);
  }

  Future<void> mountScreen(
    WidgetTester tester,
    _Bus bus, {
    bool dark = false,
    bool reduced = false,
    bool hint = false,
    double? lat,
    double? lon,
    void Function(Object, StackTrace)? onError,
  }) async {
    cleanupBus(bus);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: MultiBlocProvider(
          providers: providers(),
          child: BusStopScreen(
            stopName: '站群',
            stopId: 'group',
            city: 'Taipei',
            lat: lat ?? (hint ? 25 : null),
            lon: lon ?? (hint ? 121 : null),
            repository: bus,
            reportError: onError ?? CrashReporter.record,
          ),
        ),
      ),
    );
    await flush(tester);
  }

  test(
    'duplicate member destinations receive stable numbered labels',
    () async {
      final i18n = await AppI18n.delegate.load(const Locale('zh'));
      expect(memberStopLabels(const [], const {}), isEmpty);
      expect(
        memberStopLabels(
          const [_east, _west, _empty],
          {
            'east': [BusStopArrivalItem(i18n, _arrival('east', '100'))],
            'west': [BusStopArrivalItem(i18n, _arrival('west', '200'))],
          },
        ),
        {'east': '往車站', 'west': '往車站 2', 'empty': '沒有班次的站牌'},
      );
    },
  );

  for (final dark in [false, true]) {
    testWidgets('member filters focus the pole and return to all ($dark)', (
      tester,
    ) async {
      final bus = _Bus();
      final focused = <LatLng>[];
      final (_, bloc) = await mountDetail(
        tester,
        bus,
        dark: dark,
        onFocus: focused.add,
      );
      bus.members.complete(const [_east, _west, _empty]);
      await flush(tester);
      bus.arrivals.add([
        _arrival('east', '100', seconds: 0),
        _arrival('east', '101', status: 3, seconds: -1),
        _arrival('west', '200', status: 4, seconds: -1),
      ]);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(find.byType(EtaListTile), findsNWidgets(3));
      expect(find.text('沒有班次的站牌'), findsNothing);
      final tiles = tester.widgetList<EtaListTile>(find.byType(EtaListTile));
      expect(
        tiles.singleWhere((tile) => tile.routeNo == '100').highlighted,
        isTrue,
      );
      expect(tiles.where((tile) => tile.muted).length, 2);
      await tester.tap(find.widgetWithText(AnimatedContainer, '往車站 2'));
      await flush(tester);
      expect(focused, [const LatLng(25.01, 121.01)]);
      expect(find.text('100'), findsNothing);
      expect(find.text('200'), findsOneWidget);
      await tester.tap(find.widgetWithText(AnimatedContainer, '全部'));
      await flush(tester);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('200'), findsOneWidget);
      await tester.tap(find.widgetWithText(AnimatedContainer, '往車站'));
      await flush(tester);
      bus.arrivals.add([_arrival('west', '200')]);
      await flush(tester);
      final i18n = AppI18n.of(tester.element(find.byType(BusStopDetailView)));
      expect(find.text(i18n.busStopNoData), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
      expect(bloc.isClosed, isTrue);
    });

    testWidgets('flat arrivals open the route, with a label fallback ($dark)', (
      tester,
    ) async {
      final bus = _Bus();
      final (router, bloc) = await mountDetail(tester, bus, dark: dark);
      bus.members.complete(const []);
      await flush(tester);
      bus.arrivals.add([
        _arrival('unknown', '100', uid: 'special/100'),
        _arrival('unknown', 'fallback', uid: '', status: 3, seconds: -1),
        _arrival('unknown', 'night', status: 4, seconds: -1),
      ]);
      await flush(tester);
      await tester.pumpAndSettle();
      bool muted(String routeNo) => tester
          .widgetList<EtaListTile>(find.byType(EtaListTile))
          .singleWhere((tile) => tile.routeNo == routeNo)
          .muted;
      expect(muted('100'), isFalse);
      expect(muted('fallback'), isTrue);
      expect(muted('night'), isTrue);
      await tester.tap(find.text('100'));
      await tester.pumpAndSettle();
      expect(find.text('opened special/100'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('fallback'));
      await tester.pumpAndSettle();
      expect(find.text('opened fallback'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
      expect(bloc.isClosed, isTrue);
    });
  }

  testWidgets('selecting a member without a focus callback only filters', (
    tester,
  ) async {
    final bus = _Bus();
    final (_, bloc) = await mountDetail(tester, bus, dark: false);
    bus.members.complete(const [_east, _west]);
    await flush(tester);
    bus.arrivals.add([_arrival('east', '100'), _arrival('west', '200')]);
    await flush(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AnimatedContainer, '往車站 2'));
    await flush(tester);
    expect(bloc.state.selectedStationUid, 'west');
    expect(find.text('100'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('loading shows four one-digit placeholder rows counting up', (
    tester,
  ) async {
    final bus = _Bus();
    await mountDetail(tester, bus, dark: false);

    final tiles = tester
        .widgetList<EtaListTile>(find.byType(EtaListTile))
        .toList();
    expect(tiles, hasLength(4));
    expect(
      [for (final tile in tiles) (tile.status as EtaMinutes).value],
      [3, 4, 5, 6],
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets(
    'late initial GPS does not replace authoritative pole coordinates',
    (
      tester,
    ) async {
      final bus = _Bus();
      await mountScreen(tester, bus);
      expect(location.requests, hasLength(1));
      bus.members.complete(const [_east]);
      await flush(tester);
      final updates = map.cameraUpdates.length;
      expect(updates, greaterThan(0));
      location.requests.single.complete(location.fix);
      await flush(tester);
      expect(map.cameraUpdates.length, updates);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    },
  );

  testWidgets('disposed stop screen ignores the pending initial GPS fix', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus);
    bus.members.complete(const []);
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    final updates = map.cameraUpdates.length;
    location.requests.single.complete(location.fix);
    await flush(tester);
    expect(map.cameraUpdates.length, updates);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark recenter shows a spinner until fresh GPS resolves', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus, dark: true, hint: true);
    bus.members.complete(const []);
    await flush(tester);
    await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
    await flush(tester);
    expect(find.byType(AppSpinner), findsOneWidget);
    expect(location.requests, hasLength(1));
    location.requests.single.complete(location.fix);
    await flush(tester);
    expect(find.byType(AppSpinner), findsNothing);
    expect(find.byIcon(Icons.gps_fixed_rounded), findsOneWidget);
    expect(map.cameraUpdates, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  for (final reduced in [true, false]) {
    final label = reduced ? 'reduced motion snaps' : 'normal motion animates';

    void expectMode() {
      expect(map.cameraUpdates, isNotEmpty);
      expect(map.movedUpdates.isNotEmpty, reduced);
      expect(map.animatedUpdates.isNotEmpty, !reduced);
    }

    testWidgets('$label when the first member loads', (tester) async {
      final bus = _Bus();
      await mountScreen(tester, bus, reduced: reduced);
      bus.members.complete(const [_east]);
      await flush(tester);

      expectMode();
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    });

    testWidgets('$label for the manual recenter', (tester) async {
      final bus = _Bus();
      await mountScreen(tester, bus, hint: true, reduced: reduced);
      bus.members.complete(const []);
      await flush(tester);
      expect(map.cameraUpdates, isEmpty);
      await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
      await flush(tester);
      location.requests.single.complete(location.fix);
      await flush(tester);

      expectMode();
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    });
  }

  testWidgets('disposed stop screen ignores a pending manual recenter', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus, hint: true);
    bus.members.complete(const [_east]);
    await flush(tester);
    await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
    await flush(tester);
    expect(location.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(map.disposed, containsAll(map.created));
    final updates = map.cameraUpdates.length;
    location.requests.single.complete(location.fix);
    await flush(tester);
    expect(map.cameraUpdates.length, updates);
    expect(crashes.errorCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('crash recorder observes actual reporter delivery', (
    tester,
  ) async {
    CrashReporter.record(StateError('recorder control'), StackTrace.current);
    await flush(tester);
    expect(crashes.errorCount, FirebaseGate.enabled ? 1 : 0);
  });

  GoogleMap googleMap(WidgetTester tester) =>
      tester.widget<GoogleMap>(find.byType(GoogleMap));

  testWidgets('a cold stop opens on the default position at zoom 16', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus);

    final camera = googleMap(tester).initialCameraPosition;
    expect(camera.target, const LatLng(25.0330, 121.5654));
    expect(camera.zoom, 16);
    bus.members.complete(const []);
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  for (final coordinates in [(25.0, null), (null, 121.0)]) {
    testWidgets('one coordinate alone is not a hint $coordinates', (
      tester,
    ) async {
      final bus = _Bus();
      await mountScreen(
        tester,
        bus,
        lat: coordinates.$1,
        lon: coordinates.$2,
      );

      expect(location.requests, hasLength(1));
      bus.members.complete(const []);
      await flush(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    });
  }

  testWidgets('the hint and member markers are centred bus icons', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus, hint: true);

    final hinted = googleMap(tester).markers.single;
    expect(hinted.markerId.value, '_hint');
    expect(hinted.anchor, const Offset(0.5, 0.5));
    expect(hinted.icon, isNot(BitmapDescriptor.defaultMarker));
    expect(hinted.position, const LatLng(25, 121));
    expect(hinted.infoWindow.title, '站群');

    bus.members.complete(const [_west]);
    await flush(tester);

    final map0 = googleMap(tester);
    final member = map0.markers.single;
    expect(member.markerId.value, 'west');
    expect(member.anchor, const Offset(0.5, 0.5));
    expect(member.icon, isNot(BitmapDescriptor.defaultMarker));
    expect(member.position, const LatLng(25.01, 121.01));
    expect(map0.initialCameraPosition.target, const LatLng(25.01, 121.01));
    expect(map0.initialCameraPosition.zoom, 16);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('init and map-ready both wait on the one initial fix', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus);
    expect(location.requests, hasLength(1));
    expect(map.cameraUpdates, isEmpty);

    location.requests.single.complete(location.fix);
    await flush(tester);

    expect(map.cameraUpdates, hasLength(2));
    bus.members.complete(const []);
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('every failed GPS request is reported once', (tester) async {
    final reported = <Object>[];
    final bus = _Bus();
    await mountScreen(tester, bus, onError: (e, _) => reported.add(e));
    location.requests.single.completeError(StateError('no fix'));
    await flush(tester);
    // Init and map creation each await the shared initial fix.
    expect(reported, hasLength(2));

    bus.members.complete(const []);
    await flush(tester);
    await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
    await flush(tester);
    location.requests.last.completeError(StateError('still no fix'));
    await flush(tester);

    expect(reported, hasLength(3));
    expect((reported.last as StateError).message, 'still no fix');
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('a pole picked before the stop loads is not re-guessed', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus, hint: true);
    final bloc = BlocProvider.of<BusStopBloc>(
      tester.element(find.byType(BusStopDetailView)),
    )..add(const BusStopStationSelected('east'));
    await flush(tester);

    bus.members.complete(const [_east, _west]);
    await flush(tester);

    expect(location.lastKnownCalls, 0);
    expect(bloc.state.selectedStationUid, 'east');
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  testWidgets('with no pole picked the rider position is consulted', (
    tester,
  ) async {
    final bus = _Bus();
    await mountScreen(tester, bus, hint: true);

    bus.members.complete(const [_east, _west]);
    await flush(tester);

    expect(location.lastKnownCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });

  for (final dark in [false, true]) {
    testWidgets('locate button styling (dark=$dark)', (tester) async {
      final bus = _Bus();
      await mountScreen(tester, bus, dark: dark, hint: true);
      bus.members.complete(const []);
      await flush(tester);
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
      expect(decoration.color, dark ? cs.surfaceContainerHigh : Colors.white);
      expect(decoration.borderRadius, BorderRadius.circular(12));
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    });
  }

  group('stop sheet body', () {
    Future<(_Bus, BusStopBloc)> open(WidgetTester tester) async {
      final bus = _Bus();
      final (_, bloc) = await mountDetail(tester, bus, dark: false);
      return (bus, bloc);
    }

    testWidgets('an empty stop leaves loading for its empty message', (
      tester,
    ) async {
      final (bus, _) = await open(tester);
      bus.members.complete(const []);
      await flush(tester);
      bus.arrivals.add(const []);
      await flush(tester);
      await tester.pumpAndSettle();

      final i18n = AppI18n.of(tester.element(find.byType(BusStopDetailView)));
      expect(find.text(i18n.busStopNoRoutes), findsOneWidget);
    });

    testWidgets('a different error replaces the one on screen', (
      tester,
    ) async {
      final (bus, bloc) = await open(tester);
      bus.members.complete(const []);
      await flush(tester);
      bloc.add(const BusStopFailed(OfflineError()));
      await flush(tester);
      ErrorStateView view() =>
          tester.widget<ErrorStateView>(find.byType(ErrorStateView));
      expect(view().error, isA<OfflineError>());

      bloc.add(const BusStopFailed(TimeoutError()));
      await flush(tester);

      expect(view().error, isA<TimeoutError>());
    });

    testWidgets('filter chips, group headers and the freshness line', (
      tester,
    ) async {
      final (bus, _) = await open(tester);
      final i18n = AppI18n.of(tester.element(find.byType(BusStopDetailView)));
      expect(find.text(i18n.busStopFallbackTitle), findsOneWidget);
      bus.members.complete(const [_east, _west]);
      await flush(tester);
      bus.arrivals.add([
        _arrival('east', '100'),
        _arrival('east', '101'),
        _arrival('west', '200'),
      ]);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(find.text(i18n.busStopFallbackTitle), findsNothing);

      final cs = Theme.of(
        tester.element(find.byType(BusStopDetailView)),
      ).colorScheme;
      BoxDecoration chip(String label) =>
          tester
                  .widget<AnimatedContainer>(
                    find.widgetWithText(AnimatedContainer, label),
                  )
                  .decoration!
              as BoxDecoration;
      TextStyle chipText(String label) => tester
          .widget<Text>(
            find.descendant(
              of: find.widgetWithText(AnimatedContainer, label),
              matching: find.byType(Text),
            ),
          )
          .style!;
      expect(chip('全部').color, cs.primary);
      expect(chip('往車站').color, cs.surfaceContainerHighest);
      final selectedText = chipText('全部');
      expect(selectedText.fontSize, 13);
      expect(selectedText.fontWeight, FontWeight.w600);
      expect(selectedText.color, cs.onPrimary);
      final idleText = chipText('往車站');
      expect(idleText.fontSize, 13);
      expect(idleText.fontWeight, FontWeight.w400);
      expect(idleText.color, cs.onSurface);

      expect(find.text(i18n.busRouteCount(2)), findsOneWidget);
      expect(find.text(i18n.busRouteCount(1)), findsOneWidget);

      await tester.tap(find.widgetWithText(AnimatedContainer, '往車站'));
      await flush(tester);
      expect(chip('全部').color, cs.surfaceContainerHighest);
      expect(chip('往車站').color, cs.primary);
      expect(find.text(i18n.busRouteCount(2)), findsNothing);
    });

    testWidgets('one populated pole needs neither chips nor headers', (
      tester,
    ) async {
      final (bus, _) = await open(tester);
      bus.members.complete(const [_east, _west]);
      await flush(tester);
      bus.arrivals.add([_arrival('east', '100'), _arrival('east', '101')]);
      await flush(tester);
      await tester.pumpAndSettle();
      final i18n = AppI18n.of(tester.element(find.byType(BusStopDetailView)));

      expect(find.text('全部'), findsNothing);
      expect(find.text(i18n.busRouteCount(2)), findsNothing);
      expect(find.byType(EtaListTile), findsNWidgets(2));
    });
  });
}
