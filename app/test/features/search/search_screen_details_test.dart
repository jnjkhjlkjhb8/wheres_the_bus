import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_ask_lane.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class _Search implements SearchRepository {
  Map<String?, List<SearchResult>> byCity = {};
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
    if (pending != null) return pending!.future;
    return byCity[city] ?? results;
  }
}

class _History implements SearchRecentRepository {
  @override
  List<SearchResult> all() => const [];
  @override
  Future<void> add(SearchResult result) async {}
  @override
  Future<void> remove(SearchResult result) async {}
  @override
  Future<void> restore(SearchResult result, int index) async {}
  @override
  Future<void> clear() async {}
}

class _Location implements LocationService {
  @override
  Future<Position?> lastKnownPosition() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SearchResult _result(
  SearchResultType type, {
  String uid = 'uid',
  String name = 'Result',
  String? city,
}) => SearchResult(
  type: type,
  uid: uid,
  name: name,
  subtitle: 'Direction',
  city: city,
  lat: 25,
  lon: 121,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<GoRouter> _mount(WidgetTester tester, _Search search) async {
  final bloc = SearchBloc(
    searchRepository: search,
    recentRepository: _History(),
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
        builder: (_, _) => SearchScreen(bloc: bloc),
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
  await _settle(tester);
  return router;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await _settle(tester);
}

String? _bodyKey(WidgetTester tester) {
  const keys = ['loading', 'recents', 'results', 'empty', 'error'];
  final bodies = tester
      .widgetList<KeyedSubtree>(find.byType(KeyedSubtree))
      .map((w) => w.key)
      .whereType<ValueKey<String>>()
      .map((k) => k.value)
      .where(keys.contains)
      .toList();
  return bodies.length == 1 ? bodies.single : null;
}

void main() {
  for (final (type, system) in [
    (SearchResultType.traTrain, RailSystem.tra),
    (SearchResultType.thsrTrain, RailSystem.thsr),
  ]) {
    testWidgets('a $type result opens its own rail system', (tester) async {
      final router = await _mount(tester, _Search()..results = [_result(type)]);
      await _type(tester, 'q');
      await tester.tap(find.text('Result'));
      await tester.pumpAndSettle();
      expect(
        router.state.uri.toString(),
        AppRoutes.railTrain('uid', system: system),
      );
    });
  }

  testWidgets('the field is a 12px rounded card', (tester) async {
    await _mount(tester, _Search());
    final cards = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.borderRadius == BorderRadius.circular(12));
    expect(cards, hasLength(1));
  });

  testWidgets('the clear button follows whether there is text', (tester) async {
    await _mount(
      tester,
      _Search()..results = [_result(SearchResultType.busRoute)],
    );
    final clear = find.byWidgetPredicate(
      (w) => w is Icon && w.icon == Icons.close_rounded && w.size == 12,
    );
    expect(clear, findsNothing);
    await _type(tester, 'a');
    expect(clear, findsOneWidget);
    await _type(tester, 'ab');
    expect(clear, findsOneWidget);
    await _type(tester, '');
    expect(clear, findsNothing);
  });

  testWidgets('the ask lane always sees the latest query', (tester) async {
    await _mount(
      tester,
      _Search()..results = [_result(SearchResultType.busRoute)],
    );
    expect(tester.widget<GenUiAskLane>(find.byType(GenUiAskLane)).query, '');
    await _type(tester, 'abc');
    expect(
      tester.widget<GenUiAskLane>(find.byType(GenUiAskLane)).query,
      'abc',
    );
  });

  testWidgets('a first search shows skeleton rows and no count', (
    tester,
  ) async {
    final search = _Search()..pending = Completer();
    await _mount(tester, search);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 350));
    expect(_bodyKey(tester), 'loading');
    expect(find.textContaining('（'), findsNothing);
    search.pending!.complete([]);
    await _settle(tester);
  });

  testWidgets('a follow-up search keeps the rows and shows progress', (
    tester,
  ) async {
    final search = _Search()..results = [_result(SearchResultType.busRoute)];
    await _mount(tester, search);
    await _type(tester, 'a');
    expect(find.text('Result'), findsOneWidget);
    search.pending = Completer();
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Result'), findsOneWidget);
    expect(_bodyKey(tester), 'results');
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    final cs = Theme.of(
      tester.element(find.byType(LinearProgressIndicator)),
    ).colorScheme;
    expect(bar.color, cs.onSurfaceVariant.withValues(alpha: 0.4));
    search.pending!.complete([_result(SearchResultType.busRoute)]);
    await _settle(tester);
  });

  testWidgets('results are titled with their count, errors are not', (
    tester,
  ) async {
    final search = _Search()..results = [_result(SearchResultType.busRoute)];
    await _mount(tester, search);
    await _type(tester, 'a');
    expect(find.textContaining('（1）'), findsOneWidget);
    expect(_bodyKey(tester), 'results');

    search.error = StateError('offline');
    await _type(tester, 'ab');
    expect(find.textContaining('（'), findsNothing);
    expect(_bodyKey(tester), 'error');
  });

  testWidgets('no matches names the query back', (tester) async {
    await _mount(tester, _Search());
    await _type(tester, 'zzz');
    expect(_bodyKey(tester), 'empty');
    final i18n = AppI18n.of(tester.element(find.byType(SearchScreen)));
    expect(find.text(i18n.searchNoMatch('zzz')), findsOneWidget);
    expect(find.text(i18n.searchNoMatchHint), findsOneWidget);
    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
  });

  for (final cities in [
    ['Taipei', 'Tainan'],
    ['Taipei', 'Tainan', 'Taichung'],
  ]) {
    testWidgets('${cities.length} cities keep the filter rail while a '
        'filtered search finds nothing', (tester) async {
      final search = _Search()
        ..results = [
          for (final (i, c) in cities.indexed)
            _result(
              SearchResultType.busRoute,
              uid: 'u$i',
              name: 'Row $i',
              city: c,
            ),
        ]
        ..byCity = {'Tainan': const []};
      await _mount(tester, search);
      await _type(tester, 'a');
      expect(_bodyKey(tester), 'results');
      await tester.tap(find.text(cityName('Tainan')));
      await _settle(tester);
      expect(_bodyKey(tester), 'results');
      expect(find.text(cityName('Taipei')), findsOneWidget);
    });
  }
}
