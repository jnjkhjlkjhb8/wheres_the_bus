import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_service_marks.dart';
import 'package:wheres_the_bus/features/settings/settings_option_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

Iterable<GoRoute> _flatten(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route;
    yield* _flatten(route.routes);
  }
}

void main() {
  setUpAll(() => Hive.openBox<dynamic>('settings', bytes: Uint8List(0)));
  tearDownAll(Hive.close);

  Future<Widget Function(String, String, Map<String, String>, Object?)> pages(
    WidgetTester tester,
  ) async {
    late BuildContext context;
    final routes = buildAppRoutes();
    final router = GoRouter(routes: routes);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Widget page(
      String pattern,
      String location,
      Map<String, String> path,
      Object? extra,
    ) {
      final route = _flatten(routes).singleWhere((r) => r.path == pattern);
      final state = GoRouterState(
        router.configuration,
        uri: Uri.parse(location),
        matchedLocation: location,
        fullPath: pattern,
        pathParameters: path,
        extra: extra,
        pageKey: ValueKey(pattern),
        topRoute: route,
      );
      final built = route.pageBuilder!(context, state);
      return switch (built) {
        MaterialPage(:final child) => child,
        NoTransitionPage(:final child) => child,
        _ => throw StateError(
          'Unexpected route page type: ${built.runtimeType}',
        ),
      };
    }

    return page;
  }

  testWidgets('home opens the rail form only on its canonical query link', (
    tester,
  ) async {
    final page = await pages(tester);
    final home = page(AppRoutes.home, '/', {}, null) as HomeScreen;
    final query =
        page(
              AppRoutes.railQueryPattern,
              AppRoutes.railQueryPattern,
              {},
              null,
            )
            as HomeScreen;
    expect(home.showRailQuery, isFalse);
    expect(query.showRailQuery, isTrue);
  });

  testWidgets('bus route dispatch preserves its UID and rejects empty paths', (
    tester,
  ) async {
    final page = await pages(tester);
    final bus =
        page(
              AppRoutes.busRoutePattern,
              '/bus/route/R',
              {'subRouteUid': 'R'},
              null,
            )
            as BusRouteScreen;
    expect(bus.subRouteUid, 'R');
    expect(
      page(AppRoutes.busRoutePattern, '/bus/route/', {}, null),
      isA<RouteErrorScreen>(),
    );
    expect(
      page(AppRoutes.busRoutePattern, '/bus/route/', {'subRouteUid': ''}, null),
      isA<RouteErrorScreen>(),
    );
  });

  testWidgets('planner dispatch carries a valid destination and ignores gaps', (
    tester,
  ) async {
    final page = await pages(tester);
    final filled =
        page(
              AppRoutes.go,
              '/go?destName=Station&destLat=25.1&destLon=121.2',
              {},
              null,
            )
            as GoScreen;
    expect(filled.initialDestination!.name, 'Station');
    expect(filled.initialDestination!.latLng.latitude, 25.1);
    expect(filled.initialDestination!.latLng.longitude, 121.2);
    final empty = page(AppRoutes.go, '/go', {}, null) as GoScreen;
    expect(empty.initialDestination, isNull);
  });

  testWidgets('train links retain service date and warm journey metadata', (
    tester,
  ) async {
    final page = await pages(tester);
    const extra = RailTrainExtra(
      typeLabel: '自強',
      userOrigin: 'A',
      userDest: 'B',
      delayMinutes: 7,
      marks: [RailServiceMark.bike],
      remark: '運轉異動',
    );
    final warm =
        page(
              AppRoutes.railTrainPattern,
              '/rail/train/123?sys=tra&date=2026-07-20',
              {'trainNo': '123'},
              extra,
            )
            as RailTrainScreen;
    expect(warm.trainNo, '123');
    expect(warm.type, '自強');
    expect(warm.date, '2026-07-20');
    expect(warm.userOrigin, 'A');
    expect(warm.userDest, 'B');
    expect(warm.delayMinutes, 7);
    expect(warm.marks, [RailServiceMark.bike]);
    expect(warm.remark, '運轉異動');
    final cold =
        page(
              AppRoutes.railTrainPattern,
              '/rail/train/456?sys=thsr',
              {'trainNo': '456'},
              'invalid extra',
            )
            as RailTrainScreen;
    final now = DateTime.now();
    expect(cold.type, '高鐵');
    expect(
      cold.date,
      '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}',
    );
    expect(cold.delayMinutes, 0);
    expect(cold.marks, isEmpty);
    expect(
      page(AppRoutes.railTrainPattern, '/rail/train/', {}, null),
      isA<RouteErrorScreen>(),
    );
  });

  testWidgets(
    'settings caches accept strings and fall back for malformed data',
    (
      tester,
    ) async {
      final page = await pages(tester);
      SettingsOptionScreen settings(Object? extra) =>
          page(
                'appearance',
                AppRoutes.settingsAppearance,
                {},
                extra,
              )
              as SettingsOptionScreen;
      final cold = settings(null);
      final mixed = settings({
        'options': ['A', 42, 'B'],
        'selected': 'B',
      });
      expect(mixed.options, ['A', 'B']);
      expect(mixed.initialSelected, 'B');
      for (final malformed in [
        'invalid',
        {'options': 42, 'selected': 42},
        {
          'options': <Object>[42],
          'selected': null,
        },
        {'options': <String>[]},
      ]) {
        final fallback = settings(malformed);
        expect(fallback.options, cold.options);
        expect(fallback.initialSelected, cold.initialSelected);
      }
    },
  );
}
