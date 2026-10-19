import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bike_models.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/bike_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_bloc.dart';
import 'package:wheres_the_bus/features/bike/view/bike_station_detail_view.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/availability_gauge.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';

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

void main() {
  late _Bike bike;
  late AppI18n i18n;

  Future<void> mount(WidgetTester tester, {String? name}) async {
    bike = _Bike();
    addTearDown(bike.live.close);
    final bloc = BikeStationBloc(
      stationUid: 'bike-uid',
      repository: bike,
      name: name,
    );
    addTearDown(bloc.close);
    final favorites = FavoritesBloc(_Favorites(), ValueNotifier(true));
    addTearDown(favorites.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: BlocProvider.value(
          value: favorites,
          child: Scaffold(
            body: BikeStationDetailView(stationUid: 'bike-uid', bloc: bloc),
          ),
        ),
      ),
    );
    i18n = AppI18n.of(tester.element(find.byType(Scaffold)));
    // Runs before the bloc closes: a test that fails early must not leave the
    // static fetch pending, or Bloc.close waits on it until the timeout.
    addTearDown(() {
      if (!bike.info.isCompleted) {
        bike.info.complete(
          const BikeStationInfo(name: '', capacity: 0, lat: 0, lon: 0),
        );
      }
    });
  }

  Future<void> land(
    WidgetTester tester, {
    String name = '',
    int capacity = 0,
    double lat = 0,
    double lon = 0,
  }) async {
    bike.info.complete(
      BikeStationInfo(name: name, capacity: capacity, lat: lat, lon: lon),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  FreshnessStamp stamp(WidgetTester tester) =>
      tester.widget<FreshnessStamp>(find.byType(FreshnessStamp));

  group('while the station is loading', () {
    testWidgets('a stand-in gauge keeps the loaded geometry', (tester) async {
      await mount(tester);

      final gauge = tester.widget<AvailabilityGauge>(
        find.byType(AvailabilityGauge),
      );
      expect(gauge.available, 12);
      expect(gauge.docks, 8);
      expect(gauge.capacity, 20);
      expect(gauge.generalBikes, 9);
      expect(gauge.electricBikes, 3);

      // Bloc.close waits for the pending static fetch, and nothing pumps
      // during teardown, so let the station land before the test ends.
      await land(tester);
    });
  });

  group('header', () {
    testWidgets('a landed name alone retitles it', (tester) async {
      await mount(tester);
      expect(find.text('bike-uid'), findsOneWidget);

      await land(tester, name: '測試站');

      expect(find.text('測試站'), findsOneWidget);
      expect(find.text('bike-uid'), findsNothing);
    });

    testWidgets('a landed capacity alone adds the dock count', (tester) async {
      await mount(tester, name: '測試站');
      expect(find.byType(FreshnessStamp), findsNothing);

      await land(tester, name: '測試站', capacity: 10);

      expect(stamp(tester).leading, i18n.bikeDockCount(10));
      expect(stamp(tester).at, isNull);
    });

    testWidgets('a first live count alone adds the freshness stamp', (
      tester,
    ) async {
      await mount(tester, name: '測試站');
      await land(tester, name: '測試站');
      expect(find.byType(FreshnessStamp), findsNothing);

      bike.live.add(
        const BikeAvailability(
          generalBikes: 2,
          electricBikes: 1,
          returnDocks: 4,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(stamp(tester).at, isNotNull);
      expect(stamp(tester).leading, isNull);
    });

    testWidgets('a nonsensical negative capacity shows nothing', (
      tester,
    ) async {
      await mount(tester, name: '測試站');

      await land(tester, name: '測試站', capacity: -1);

      expect(find.byType(FreshnessStamp), findsNothing);
    });
  });

  group('walk there', () {
    for (final (lat, lon, shown) in const [
      (0.0, 0.0, false),
      (24.0, 0.0, true),
      (0.0, 120.0, true),
      (24.0, 120.0, true),
    ]) {
      testWidgets('lat $lat lon $lon: button shown $shown', (tester) async {
        await mount(tester, name: '測試站');

        await land(tester, name: '測試站', capacity: 10, lat: lat, lon: lon);

        expect(
          find.text(i18n.bikePlanRoute),
          shown ? findsOneWidget : findsNothing,
        );
      });
    }
  });
}
