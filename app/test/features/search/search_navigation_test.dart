import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class _Search implements SearchRepository {
  List<SearchResult> results = [];
  Error? error;
  Completer<List<SearchResult>>? pending;
  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async {
    if (error != null) throw error!;
    return pending?.future ?? results;
  }
}

class _History implements SearchRecentRepository {
  List<SearchResult> entries = [];
  @override
  List<SearchResult> all() => List.of(entries);
  @override
  Future<void> add(SearchResult result) async => entries.insert(0, result);
  @override
  Future<void> remove(SearchResult result) async => entries.remove(result);
  @override
  Future<void> restore(SearchResult result, int index) async =>
      entries.insert(index, result);
  @override
  Future<void> clear() async => entries.clear();
}

class _Location implements LocationService {
  @override
  Future<Position?> lastKnownPosition() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SearchResult _result(SearchResultType type, {String name = 'Result'}) =>
    SearchResult(
      type: type,
      uid: 'uid',
      name: name,
      subtitle: 'Direction',
      lat: 25,
      lon: 121,
    );

void main() {
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<GoRouter> mount(
    WidgetTester tester,
    _Search search,
    _History history, {
    String? query,
  }) async {
    final bloc = SearchBloc(
      searchRepository: search,
      recentRepository: history,
      locationService: _Location(),
    );
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(
          path: '/search',
          builder: (_, _) => SearchScreen(bloc: bloc, initialQuery: query),
        ),
        for (final path in [
          AppRoutes.nearStationPattern,
          AppRoutes.busRoutePattern,
          AppRoutes.metro,
          AppRoutes.metroStationPattern,
          AppRoutes.railTrainPattern,
        ])
          GoRoute(
            path: path,
            builder: (_, state) => Scaffold(body: Text(state.uri.toString())),
          ),
      ],
    );
    addTearDown(bloc.close);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
      ),
    );
    await settle(tester);
    return router;
  }

  for (final type in SearchResultType.values) {
    testWidgets('$type opens the matching destination and records history', (
      tester,
    ) async {
      final search = _Search()..results = [_result(type)];
      final history = _History();
      final router = await mount(tester, search, history, query: 'Query');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Query',
      );
      await tester.tap(find.text('Result'));
      await tester.pumpAndSettle();
      final uri = router.state.uri;
      expect(history.entries.single.type, type);
      final expected = switch (type) {
        SearchResultType.busStation => '/near/bus/uid',
        SearchResultType.bikeStation => '/near/bike/uid',
        SearchResultType.busRoute => '/bus/route/uid',
        SearchResultType.mrtStation => '/metro',
        _ => '/rail/train/uid',
      };
      expect(uri.path, expected);
      if (type == SearchResultType.busStation ||
          type == SearchResultType.bikeStation) {
        expect(uri.queryParameters['back'], contains('q=Query'));
      }
    });
  }

  testWidgets('known metro station opens its own board', (tester) async {
    final search = _Search()
      ..results = [_result(SearchResultType.mrtStation, name: '台北車站')];
    final router = await mount(tester, search, _History(), query: '台北');
    await tester.tap(find.text('台北車站'));
    await tester.pumpAndSettle();
    expect(
      router.state.uri.path,
      startsWith('/metro/station/'),
    );
  });

  testWidgets('history clear dialog can keep entries or remove every entry', (
    tester,
  ) async {
    final history = _History()..entries = [_result(SearchResultType.busRoute)];
    await mount(tester, _Search(), history, query: '');
    final i18n = AppI18n.of(tester.element(find.byType(SearchScreen)));
    await tester.tap(find.text(i18n.commonClear));
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.searchRecentKeep));
    await tester.pumpAndSettle();
    expect(history.entries, hasLength(1));
    await tester.tap(find.text(i18n.commonClear));
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.searchRecentClear).last);
    await tester.pumpAndSettle();
    expect(history.entries, isEmpty);
    expect(find.text(i18n.searchRecentEmpty), findsOneWidget);
  });

  testWidgets(
    'recent swipe removes a single entry and undo restores its place',
    (tester) async {
      final history = _History()
        ..entries = [_result(SearchResultType.busRoute)];
      await mount(tester, _Search(), history);
      await tester.drag(find.byType(Dismissible), const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(history.entries, isEmpty);
      final i18n = AppI18n.of(tester.element(find.byType(SearchScreen)));
      await tester.tap(find.text(i18n.commonUndo));
      await tester.pumpAndSettle();
      expect(history.entries.single.uid, 'uid');
    },
  );

  testWidgets('system back from the root search goes home', (tester) async {
    final router = await mount(tester, _Search(), _History());
    expect(router.canPop(), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/');
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets(
    'city filter retains results and shows progress until new rows arrive',
    (tester) async {
      final search = _Search()
        ..results = const [
          SearchResult(
            type: SearchResultType.busRoute,
            uid: 'a',
            name: 'Taipei result',
            subtitle: '',
            city: 'Taipei',
          ),
          SearchResult(
            type: SearchResultType.busRoute,
            uid: 'b',
            name: 'Tainan result',
            subtitle: '',
            city: 'Tainan',
          ),
        ];
      await mount(tester, search, _History(), query: 'City');
      final pending = Completer<List<SearchResult>>();
      search.pending = pending;
      await tester.tap(find.text('台南市'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Taipei result'), findsOneWidget);
      pending.complete([search.results.last]);
      await settle(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Taipei result'), findsNothing);
      expect(find.text('Tainan result'), findsOneWidget);
    },
  );

  testWidgets(
    'search error retry renders a result after the repository recovers',
    (tester) async {
      final search = _Search()..error = StateError('offline');
      await mount(tester, search, _History(), query: 'retry');
      final i18n = AppI18n.of(tester.element(find.byType(SearchScreen)));
      search
        ..error = null
        ..results = [_result(SearchResultType.busRoute)];
      await tester.tap(find.text(i18n.commonRetry));
      await settle(tester);
      expect(find.text('Result'), findsOneWidget);
    },
  );
}
