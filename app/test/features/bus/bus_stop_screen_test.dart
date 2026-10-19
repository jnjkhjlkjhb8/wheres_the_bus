import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_detail_view.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_screen.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

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
  bool fail = false;
  int currentReads = 0;
  int lastReads = 0;
  Position get fix => Position(
    latitude: 25,
    longitude: 121,
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
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    currentReads++;
    if (fail) throw StateError('GPS unavailable');
    return fix;
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async {
    lastReads++;
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

class _Alerts implements AlertRepository {
  @override
  Set<String> readAlerts() => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
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
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> mount(WidgetTester tester, _Bus bus, {bool hint = true}) async {
    final favorites = FavoritesBloc(_Favorites(), ValueNotifier(true));
    final alerts = AlertBloc(repository: _Alerts());
    addTearDown(favorites.close);
    addTearDown(alerts.close);
    addTearDown(bus.arrivals.close);
    addTearDown(() {
      if (!bus.members.isCompleted) bus.members.complete(const []);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider<FavoritesBloc>.value(value: favorites),
            BlocProvider<AlertBloc>.value(value: alerts),
          ],
          child: BusStopScreen(
            stopName: 'Station',
            stopId: 'group',
            city: 'Taipei',
            lat: hint ? 24 : null,
            lon: hint ? 120 : null,
            repository: bus,
          ),
        ),
      ),
    );
    await flush(tester);
  }

  testWidgets(
    'hint pin gives way to members and a nearby pole selects itself',
    (tester) async {
      final bus = _Bus();
      await mount(tester, bus);
      expect(location.currentReads, 0);
      expect(
        tester
            .widget<GoogleMap>(find.byType(GoogleMap))
            .initialCameraPosition
            .target,
        const LatLng(24, 120),
      );
      expect(map.objects.markers.single.markerId.value, '_hint');
      bus.members.complete(const [
        BusStationMember(
          stationUid: 'pole',
          stationId: 'pole',
          stationName: 'Near',
          lat: 25,
          lon: 121,
        ),
        BusStationMember(
          stationUid: 'far',
          stationId: 'far',
          stationName: 'Far',
          lat: 25.01,
          lon: 121,
        ),
      ]);
      await flush(tester);
      await flush(tester);
      expect(
        map.objects.markers.map((m) => m.markerId.value),
        unorderedEquals(['pole', 'far']),
      );
      final bloc = tester
          .element(find.byType(BusStopDetailView))
          .read<BusStopBloc>();
      expect(bloc.state.selectedStationUid, 'pole');
      expect(location.lastReads, 1);
      expect(map.cameraUpdates, isNotEmpty);
      await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
      await flush(tester);
      expect(location.currentReads, 1);
      expect(find.byIcon(Icons.gps_fixed_rounded), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
      expect(map.disposed, containsAll(map.created));
    },
  );

  testWidgets(
    'GPS fallback is shared, and a failed recenter releases loading',
    (tester) async {
      final bus = _Bus();
      await mount(tester, bus, hint: false);
      await flush(tester);
      expect(location.currentReads, 1);
      expect(map.cameraUpdates, isNotEmpty);
      expect(map.objects.markers, isEmpty);
      bus.members.complete(const []);
      await flush(tester);
      location.fail = true;
      await tester.tap(find.byIcon(Icons.gps_fixed_rounded));
      await flush(tester);
      expect(location.currentReads, 2);
      expect(find.byIcon(Icons.gps_fixed_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush(tester);
    },
  );
}
