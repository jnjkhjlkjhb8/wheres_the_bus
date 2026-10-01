import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/view/rail_screen.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/features/settings/settings_option_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/main_scaffold.dart';

/// Flattens the route tree into the full set of route path patterns.
List<String> collectPaths(List<RouteBase> routes) {
  final paths = <String>[];
  void visit(RouteBase route) {
    if (route is GoRoute) paths.add(route.path);
    route.routes.forEach(visit);
  }

  routes.forEach(visit);
  return paths;
}

void main() {
  setUpAll(() async {
    // SettingsScreen (the /settings shell parent of the option routes) reads
    // the settings box on bloc construction, so back the repository with a
    // real on-disk box the same way other Hive-touching tests do.
    Hive.init('./.dart_tool/hive_test_app_router');
    await Hive.openBox<dynamic>('settings');
  });

  Future<GoRouter> pumpAt(WidgetTester tester, String location) async {
    final router = AppRouter.createRouter(initialLocation: location);
    final alertBloc = AlertBloc();
    final planBloc = PlanBloc();
    // The same blocs `app.dart` provides above the router, minus the platform
    // channels: the routed screens read them on build, so a route test without
    // them proves nothing about whether the location resolves.
    final trackBloc = MrtTrackBloc(i18n: lookupAppI18n(const Locale('zh')));
    final favoritesBloc = FavoritesBloc(
      FavoritesRepository.instance,
      App.isInitialized,
    );
    addTearDown(router.dispose);
    addTearDown(alertBloc.close);
    addTearDown(planBloc.close);
    addTearDown(trackBloc.close);
    addTearDown(favoritesBloc.close);
    // Unmount before the test ends: screens that tick (the rail timetable's
    // minute countdown) cancel in `dispose`, and the framework's pending-timer
    // check runs before it would tear the tree down on its own.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AlertBloc>.value(value: alertBloc),
          BlocProvider<PlanBloc>.value(value: planBloc),
          BlocProvider<MrtTrackBloc>.value(value: trackBloc),
          BlocProvider<FavoritesBloc>.value(value: favoritesBloc),
        ],
        // The settings pickers label themselves from the i18n delegate, so
        // the routes under test only build with it installed. Pinned to
        // zh-TW because `flutter_test` reports an en_US platform locale.
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
        ),
      ),
    );
    await tester.pump();
    return router;
  }

  group('route graph', () {
    test('main routes match the documented architecture', () {
      final paths = collectPaths(buildAppRoutes());
      const expected = [
        '/',
        '/search',
        '/favorites',
        '/bus/stop',
        '/bus/route/:subRouteUid',
        '/bike/station',
        '/rail',
        '/rail/train/:trainNo',
        '/metro',
        '/metro/station/:id',
        '/near/:type/:id',
        '/rail-query',
        '/go',
        '/settings',
      ];
      for (final path in expected) {
        expect(paths, contains(path));
      }
    });

    test('the train page is declared outside the shell', () {
      final topLevel = buildAppRoutes().whereType<GoRoute>().map((r) => r.path);
      expect(topLevel, contains(AppRoutes.railTrainPattern));
    });

    test("the home sheet's layers stay inside the shell", () {
      // The opposite guarantee: they render the home screen itself, so they
      // must keep the banners and the mini bar the shell provides.
      final topLevel = buildAppRoutes().whereType<GoRoute>().map((r) => r.path);
      expect(topLevel, isNot(contains(AppRoutes.nearStationPattern)));
      expect(topLevel, isNot(contains(AppRoutes.railQueryPattern)));
    });
  });

  group('cold deep links (no state.extra)', () {
    testWidgets('settings appearance renders the option screen', (
      tester,
    ) async {
      await pumpAt(tester, AppRoutes.settingsAppearance);
      expect(find.byType(SettingsOptionScreen), findsOneWidget);
      expect(find.byType(RouteErrorScreen), findsNothing);
    });

    testWidgets('settings language renders the option screen', (tester) async {
      await pumpAt(tester, AppRoutes.settingsLanguage);
      expect(find.byType(SettingsOptionScreen), findsOneWidget);
      expect(find.byType(RouteErrorScreen), findsNothing);
    });

    testWidgets('shell wraps routed content in MainScaffold', (tester) async {
      await pumpAt(tester, AppRoutes.settings);
      expect(find.byType(MainScaffold), findsOneWidget);
    });

    testWidgets('the line map opens on the station the location names', (
      tester,
    ) async {
      await pumpAt(tester, AppRoutes.metroStation('BL12'));
      final screen = tester.widget<MetroScreen>(find.byType(MetroScreen));
      expect(screen.stationId, 'BL12');
      expect(screen.mode, MetroMapMode.time);
      expect(find.byType(RouteErrorScreen), findsNothing);
    });

    testWidgets('the line map carries its label mode', (tester) async {
      await pumpAt(
        tester,
        AppRoutes.metroStation('BL12', mode: MetroMapMode.fare),
      );
      expect(
        tester.widget<MetroScreen>(find.byType(MetroScreen)).mode,
        MetroMapMode.fare,
      );
    });

    testWidgets('selecting a station keeps the same line map alive', (
      tester,
    ) async {
      final router = await pumpAt(tester, AppRoutes.metro);
      final before = tester.state(find.byType(MetroScreen));

      router.go(AppRoutes.metroStation('BL12'));
      await tester.pump();

      expect(tester.state(find.byType(MetroScreen)), same(before));
      expect(
        tester.widget<MetroScreen>(find.byType(MetroScreen)).stationId,
        'BL12',
      );
    });

    testWidgets('the timetable arrives with the query filled in', (
      tester,
    ) async {
      // Without `submit`: this asserts the location reaches the screen, and
      // an auto-submitted query would put a live gRPC call in a route test.
      await pumpAt(
        tester,
        AppRoutes.railLocation(
          system: RailSystem.thsr,
          originName: '台北',
          originId: '1000',
          destName: '左營',
          destId: '1210',
        ),
      );
      final args = tester.widget<RailScreen>(find.byType(RailScreen)).args;
      expect(args, isNotNull);
      expect(args!.system, RailSystem.thsr);
      expect(args.originName, '台北');
      expect(args.destName, '左營');
    });

    testWidgets('a bare rail location opens the empty form', (tester) async {
      await pumpAt(tester, AppRoutes.rail);
      final args = tester.widget<RailScreen>(find.byType(RailScreen)).args;
      expect(args?.originName, isEmpty);
      expect(args?.submit, isFalse);
    });

    testWidgets('search opens on the query the location names', (tester) async {
      await pumpAt(tester, AppRoutes.searchLocation(query: '台北車站'));
      expect(
        tester.widget<SearchScreen>(find.byType(SearchScreen)).initialQuery,
        '台北車站',
      );
    });
  });

  group('malformed parameters', () {
    testWidgets('bus stop without a name shows the typed error page', (
      tester,
    ) async {
      await pumpAt(tester, AppRoutes.busStop);
      expect(find.byType(RouteErrorScreen), findsOneWidget);
    });

    testWidgets('bike station without a uid shows the typed error page', (
      tester,
    ) async {
      await pumpAt(tester, AppRoutes.bikeStation);
      expect(find.byType(RouteErrorScreen), findsOneWidget);
    });

    testWidgets('an unknown station kind shows the typed error page', (
      tester,
    ) async {
      await pumpAt(tester, '/near/monorail/1');
      expect(find.byType(RouteErrorScreen), findsOneWidget);
    });

    testWidgets('an unknown location shows the typed error page', (
      tester,
    ) async {
      await pumpAt(tester, '/no-such-route');
      expect(find.byType(RouteErrorScreen), findsOneWidget);
    });
  });
}
