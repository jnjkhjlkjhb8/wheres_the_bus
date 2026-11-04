import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/rider_city.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/bloc/search_event.dart';
import 'package:wheres_the_bus/features/search/bloc/search_ranking.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

Position _at(double lat, double lon) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: DateTime(2026),
  accuracy: 1,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

// Taipei Main Station.
final Position _taipeiMain = _at(25.0478, 121.5170);

SearchResult _route(
  String uid, {
  String name = '307',
  String subtitle = 'A → B',
  String? city,
}) => SearchResult(
  type: SearchResultType.busRoute,
  uid: uid,
  name: name,
  subtitle: subtitle,
  city: city,
);

List<SearchResult> _rank(
  List<SearchResult> results, {
  String? riderCity,
}) => rankSearchResults(
  results,
  query: '307',
  favorites: const [],
  affinity: const {},
  now: DateTime(2026, 8, 15, 14),
  riderCity: riderCity,
);

class _Search implements SearchRepository {
  _Search(this.results);
  final List<SearchResult> results;
  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async => results;
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
  _Location(this.fix);
  final Position? fix;
  @override
  Future<Position?> lastKnownPosition() async => fix;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LateLocation implements LocationService {
  _LateLocation(this.fix);
  final Future<Position?> fix;
  @override
  Future<Position?> lastKnownPosition() => fix;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('riderCityFor', () {
    test('no fix means no city', () => expect(riderCityFor(null), isNull));

    test('Taipei Main Station is Taipei, Banqiao is New Taipei', () {
      expect(riderCityFor(_taipeiMain), 'Taipei');
      expect(riderCityFor(_at(25.0140, 121.4630)), 'NewTaipei');
    });

    test('a fix far from every city is none', () {
      expect(riderCityFor(_at(0, 0)), isNull);
    });

    // Each centre is pinned by asking for it: a wrong coordinate puts the
    // fix on another city, or on none.
    test('every covered city answers to its own centre', () {
      const centres = {
        'Keelung': (25.1276, 121.7392),
        'Taipei': (25.0478, 121.5515),
        'NewTaipei': (25.0120, 121.4650),
        'Taoyuan': (24.9936, 121.3010),
        'Hsinchu': (24.8138, 120.9675),
        'HsinchuCounty': (24.8387, 121.0178),
        'MiaoliCounty': (24.5602, 120.8214),
        'Taichung': (24.1477, 120.6736),
        'ChanghuaCounty': (24.0518, 120.5161),
        'NantouCounty': (23.9157, 120.6869),
        'YunlinCounty': (23.7092, 120.4313),
        'Chiayi': (23.4801, 120.4491),
        'ChiayiCounty': (23.4518, 120.2555),
        'Tainan': (22.9999, 120.2270),
        'Kaohsiung': (22.6273, 120.3014),
        'PingtungCounty': (22.6762, 120.4940),
        'YilanCounty': (24.7021, 121.7378),
        'HualienCounty': (23.9772, 121.6044),
        'TaitungCounty': (22.7583, 121.1444),
      };
      for (final MapEntry(:key, :value) in centres.entries) {
        expect(riderCityFor(_at(value.$1, value.$2)), key, reason: key);
      }
    });

    test('the range ends between 33 km and 51 km from a centre', () {
      // Due south of Taitung, where no other centre is nearer.
      expect(riderCityFor(_at(22.4583, 121.1444)), 'TaitungCounty');
      expect(riderCityFor(_at(22.30, 121.1444)), isNull);
    });
  });

  group('ranking', () {
    final others = [
      _route('h', city: 'PingtungCounty', subtitle: 'h1 → h2'),
      _route('k', city: 'Keelung', subtitle: 'k1 → k2'),
      _route('t', city: 'Taipei', subtitle: 't1 → t2'),
    ];

    test('the router names cities in Chinese and the boost still lands', () {
      final ranked = _rank(
        [
          for (var i = 0; i < 5; i++)
            _route('o$i', city: '基隆市', subtitle: 'o$i'),
          _route('local', city: '台北市', subtitle: 'local'),
        ],
        riderCity: 'Taipei',
      );
      expect(ranked.first.uid, 'local');
    });

    test('a result in another city is not mistaken for the rider city', () {
      expect(sameCity('台北市', 'Taipei'), isTrue);
      expect(sameCity('Taipei', 'Taipei'), isTrue);
      expect(sameCity('新北市', 'Taipei'), isFalse);
      expect(sameCity(null, 'Taipei'), isFalse);
      expect(sameCity('台北市', null), isFalse);
    });

    test('the rider city outranks routes the router listed first', () {
      expect(_rank(others, riderCity: 'Taipei').map((r) => r.uid).first, 't');
    });

    test('without a rider city the router order stands', () {
      expect(_rank(others).map((r) => r.uid), ['h', 'k', 't']);
    });

    test('a city bonus lifts a result placed eleven rows down', () {
      final list = [
        for (var i = 0; i < 11; i++)
          _route('o$i', city: 'Keelung', subtitle: '$i'),
        _route('t', city: 'Taipei', subtitle: 'x'),
      ];
      expect(_rank(list, riderCity: 'Taipei').first.uid, 't');
    });

    test('identical routes collapse to one row, the better ranked', () {
      final ranked = _rank(
        [
          _route('1', city: 'Taipei'),
          _route('2', city: 'Taipei'),
        ],
      );
      expect(ranked.map((r) => r.uid), ['1']);
    });

    test('routes differing only by city both stay', () {
      final ranked = _rank(
        [
          _route('1', city: 'Taipei'),
          _route('2', city: 'NewTaipei'),
        ],
      );
      expect(ranked, hasLength(2));
    });

    test('same-named stops are never merged', () {
      const stop = SearchResult(
        type: SearchResultType.busStation,
        uid: 'a',
        name: 'S',
        subtitle: '',
        city: 'Taipei',
      );
      final ranked = _rank([
        stop,
        const SearchResult(
          type: SearchResultType.busStation,
          uid: 'b',
          name: 'S',
          subtitle: '',
          city: 'Taipei',
        ),
      ]);
      expect(ranked, hasLength(2));
    });
  });

  group('bloc', () {
    test('city chips lead with the rider city, then by count', () async {
      final bloc = SearchBloc(
        searchRepository: _Search([
          _route('1', city: 'Kaohsiung', subtitle: '1'),
          _route('2', city: 'Kaohsiung', subtitle: '2'),
          _route('3', city: 'Taipei', subtitle: '3'),
        ]),
        recentRepository: _History(),
        locationService: _Location(_taipeiMain),
      );
      addTearDown(bloc.close);
      await Future<void>.delayed(Duration.zero);

      bloc.add(const SearchQueryChanged('307'));
      await bloc.stream.firstWhere(
        (s) => !s.loading && s.results.isNotEmpty,
      );

      expect(bloc.state.cityOptions, ['Taipei', 'Kaohsiung']);
      expect(bloc.state.results.first.city, 'Taipei');
    });

    test(
      'results already on screen re-rank when the fix arrives late',
      () async {
        final fix = Completer<Position?>();
        final bloc = SearchBloc(
          searchRepository: _Search([
            _route('1', city: 'Kaohsiung', subtitle: '1'),
            _route('2', city: 'Kaohsiung', subtitle: '2'),
            _route('3', city: 'Taipei', subtitle: '3'),
          ]),
          recentRepository: _History(),
          locationService: _LateLocation(fix.future),
        );
        addTearDown(bloc.close);

        bloc.add(const SearchQueryChanged('307'));
        await bloc.stream.firstWhere(
          (s) => !s.loading && s.results.isNotEmpty,
        );
        expect(bloc.state.cityOptions, ['Kaohsiung', 'Taipei']);
        expect(bloc.state.results.first.city, 'Kaohsiung');

        fix.complete(_taipeiMain);
        await bloc.stream.firstWhere((s) => s.results.first.city == 'Taipei');

        expect(bloc.state.cityOptions, ['Taipei', 'Kaohsiung']);
      },
    );

    test('a late fix leaves a city-filtered answer alone', () async {
      final fix = Completer<Position?>();
      final bloc = SearchBloc(
        searchRepository: _Search([
          _route('1', city: 'Kaohsiung', subtitle: '1'),
          _route('3', city: 'Taipei', subtitle: '3'),
        ]),
        recentRepository: _History(),
        locationService: _LateLocation(fix.future),
      );
      addTearDown(bloc.close);

      bloc.add(const SearchQueryChanged('307'));
      await bloc.stream.firstWhere(
        (s) => !s.loading && s.results.isNotEmpty,
      );
      bloc.add(const SearchCityToggled('Kaohsiung'));
      await bloc.stream.firstWhere(
        (s) => !s.loading && s.city == 'Kaohsiung',
      );
      final before = bloc.state;

      fix.complete(_taipeiMain);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.city, 'Kaohsiung');
      expect(bloc.state.results, before.results);
    });

    test('a late fix does not re-rank results for an older query', () async {
      final fix = Completer<Position?>();
      final bloc = SearchBloc(
        searchRepository: _Search([
          _route('1', city: 'Kaohsiung', subtitle: '1'),
          _route('3', city: 'Taipei', subtitle: '3'),
        ]),
        recentRepository: _History(),
        locationService: _LateLocation(fix.future),
      );
      addTearDown(bloc.close);

      bloc.add(const SearchQueryChanged('307'));
      await bloc.stream.firstWhere(
        (s) => !s.loading && s.results.isNotEmpty,
      );
      bloc.add(const SearchQueryChanged('30'));
      await bloc.stream.firstWhere((s) => s.query == '30');
      final before = bloc.state.results;

      fix.complete(_taipeiMain);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.results, before);
    });

    test(
      'chips lead with the rider city when the router names it in Chinese',
      () async {
        final bloc = SearchBloc(
          searchRepository: _Search([
            _route('1', city: '高雄市', subtitle: '1'),
            _route('2', city: '高雄市', subtitle: '2'),
            _route('3', city: '台北市', subtitle: '3'),
          ]),
          recentRepository: _History(),
          locationService: _Location(_taipeiMain),
        );
        addTearDown(bloc.close);
        await Future<void>.delayed(Duration.zero);

        bloc.add(const SearchQueryChanged('307'));
        await bloc.stream.firstWhere(
          (s) => !s.loading && s.results.isNotEmpty,
        );

        expect(bloc.state.cityOptions, ['台北市', '高雄市']);
        expect(bloc.state.results.first.city, '台北市');
      },
    );

    test('without a fix chips stay ordered by count', () async {
      final bloc = SearchBloc(
        searchRepository: _Search([
          _route('1', city: 'Kaohsiung', subtitle: '1'),
          _route('2', city: 'Kaohsiung', subtitle: '2'),
          _route('3', city: 'Taipei', subtitle: '3'),
        ]),
        recentRepository: _History(),
        locationService: _Location(null),
      );
      addTearDown(bloc.close);
      await Future<void>.delayed(Duration.zero);

      bloc.add(const SearchQueryChanged('307'));
      await bloc.stream.firstWhere(
        (s) => !s.loading && s.results.isNotEmpty,
      );

      expect(bloc.state.cityOptions, ['Kaohsiung', 'Taipei']);
    });
  });

  group('row', () {
    test('city leads the route subtitle', () {
      expect(
        searchRowSubtitle(_route('1', city: 'NewTaipei')),
        '新北市 · A → B',
      );
    });

    test('a subtitle that is the city is not repeated', () {
      expect(
        searchRowSubtitle(_route('1', city: 'Taipei', subtitle: '台北市')),
        '台北市',
      );
    });

    test('an empty subtitle falls back to the city', () {
      expect(
        searchRowSubtitle(_route('1', city: 'Taipei', subtitle: '')),
        '台北市',
      );
    });

    test('no city leaves the subtitle alone', () {
      expect(searchRowSubtitle(_route('1')), 'A → B');
      expect(searchRowSubtitle(_route('1', city: '')), 'A → B');
    });

    testWidgets('renders the city and uses the button radius token', (
      tester,
    ) async {
      final bloc = SearchBloc(
        searchRepository: _Search([_route('1', city: 'NewTaipei')]),
        recentRepository: _History(),
        locationService: _Location(null),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => SearchScreen(bloc: bloc, initialQuery: 'q'),
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
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('新北市 · A → B'), findsOneWidget);
      final tile = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.borderRadius != null)
          .map((d) => d.borderRadius);
      expect(
        tile,
        contains(BorderRadius.circular(AppTheme.radiusButton)),
      );
    });
  });
}
