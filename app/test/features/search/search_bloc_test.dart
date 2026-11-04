import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_affinity_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/bloc/search_event.dart';
import 'package:wheres_the_bus/features/search/bloc/search_state.dart';

void main() {
  test('loads recents on construction', () async {
    final recent = _FakeSearchRecentRepository(recents: [_result('recent')]);
    final bloc = SearchBloc(
      searchRepository: _FakeSearchRepository(),
      recentRepository: recent,
    );
    addTearDown(bloc.close);

    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.recentResults, hasLength(1));
  });

  testWidgets('debounces query changes and searches latest query once', (
    tester,
  ) async {
    final search = _FakeSearchRepository(results: [_result('result')]);
    final bloc = SearchBloc(
      searchRepository: search,
      recentRepository: _FakeSearchRecentRepository(),
      locationService: _FakeLocationService(),
    );

    try {
      bloc
        ..add(const SearchQueryChanged('tai'))
        ..add(const SearchQueryChanged('taipei'));

      await tester.pump();
      expect(bloc.state.query, 'taipei');
      expect(bloc.state.loading, isTrue);
      await tester.pump(const Duration(milliseconds: 179));
      expect(search.queries, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));

      expect(search.queries, ['taipei']);
      expect(bloc.state.results, hasLength(1));
    } finally {
      await _closeBloc(tester, bloc);
    }
  });

  test('search errors emit AppError state', () async {
    final bloc = SearchBloc(
      searchRepository: _FakeSearchRepository(error: StateError('offline')),
      recentRepository: _FakeSearchRecentRepository(),
    );
    addTearDown(bloc.close);

    await _searchAction(
      bloc,
      () => bloc.add(const SearchQueryChanged('taipei')),
    );

    expect(bloc.state.error, isNotNull);
    expect(bloc.state.loading, isFalse);
  });

  group('city filter', () {
    test('offers the cities the unfiltered results span, most first', () async {
      final bloc = SearchBloc(
        searchRepository: _FakeSearchRepository(
          results: [
            _result('a', city: 'Kaohsiung'),
            _result('b', city: 'Taipei'),
            _result('c', city: 'Taipei'),
          ],
        ),
        recentRepository: _FakeSearchRecentRepository(),
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('中正路')),
      );

      expect(bloc.state.cityOptions, ['Taipei', 'Kaohsiung']);
      expect(bloc.state.city, isNull);
    });

    test('re-queries the router instead of filtering the page', () async {
      final search = _FakeSearchRepository(
        results: [
          _result('a', city: 'Taipei'),
          _result('b', city: 'Tainan'),
        ],
        byCity: {
          'Tainan': [
            _result('b', city: 'Tainan'),
            _result('x', city: 'Tainan'),
            _result('y', city: 'Tainan'),
          ],
        },
      );
      final bloc = SearchBloc(
        searchRepository: search,
        recentRepository: _FakeSearchRecentRepository(),
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('中正路')),
      );
      await _searchAction(
        bloc,
        () => bloc.add(const SearchCityToggled('Tainan')),
      );

      expect(search.cities, [null, 'Tainan']);
      expect(bloc.state.city, 'Tainan');
      // Three rows, not the one Tainan row that was on the unfiltered page:
      // the filter has to reach the database to find the rest.
      expect(bloc.state.results, hasLength(3));
    });

    test(
      'keeps the options from the unfiltered query while filtered',
      () async {
        final bloc = SearchBloc(
          searchRepository: _FakeSearchRepository(
            results: [
              _result('a', city: 'Taipei'),
              _result('b', city: 'Tainan'),
            ],
            byCity: {
              'Tainan': [_result('b', city: 'Tainan')],
            },
          ),
          recentRepository: _FakeSearchRecentRepository(),
        );
        addTearDown(bloc.close);

        await _searchAction(
          bloc,
          () => bloc.add(const SearchQueryChanged('中正路')),
        );
        await _searchAction(
          bloc,
          () => bloc.add(const SearchCityToggled('Tainan')),
        );

        // Recomputing from the filtered response would leave one chip and no
        // way back to the other cities.
        expect(bloc.state.cityOptions, ['Taipei', 'Tainan']);
      },
    );

    test('tapping the selected city clears the filter', () async {
      final search = _FakeSearchRepository(
        results: [
          _result('a', city: 'Taipei'),
          _result('b', city: 'Tainan'),
        ],
      );
      final bloc = SearchBloc(
        searchRepository: search,
        recentRepository: _FakeSearchRecentRepository(),
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('中正路')),
      );
      await _searchAction(
        bloc,
        () => bloc.add(const SearchCityToggled('Tainan')),
      );
      await _searchAction(
        bloc,
        () => bloc.add(const SearchCityToggled('Tainan')),
      );

      expect(bloc.state.city, isNull);
      expect(search.cities, [null, 'Tainan', null]);
    });

    test('emptying the query drops the filter with the results', () async {
      final bloc = SearchBloc(
        searchRepository: _FakeSearchRepository(
          results: [
            _result('a', city: 'Taipei'),
            _result('b', city: 'Tainan'),
          ],
        ),
        recentRepository: _FakeSearchRecentRepository(),
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('中正路')),
      );
      await _searchAction(
        bloc,
        () => bloc.add(const SearchCityToggled('Tainan')),
      );
      await _afterState(
        bloc,
        (state) =>
            state.query.isEmpty &&
            state.city == null &&
            state.results.isEmpty &&
            state.cityOptions.isEmpty &&
            !state.loading,
        () => bloc.add(const SearchQueryChanged('')),
      );

      // Recents don't render the chip row, so a filter kept here would be
      // invisible state waiting to swallow the next search.
      expect(bloc.state.city, isNull);
      expect(bloc.state.cityOptions, isEmpty);
    });

    test('a filtered request that lands late is ignored', () async {
      final search = _FakeSearchRepository(
        results: [
          _result('a', city: 'Taipei'),
          _result('b', city: 'Tainan'),
        ],
      );
      final bloc = SearchBloc(
        searchRepository: search,
        recentRepository: _FakeSearchRecentRepository(),
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('中正路')),
      );
      // Two taps in the same frame: the first response must not overwrite
      // the second selection.
      await _searchAction(
        bloc,
        () => bloc
          ..add(const SearchCityToggled('Tainan'))
          ..add(const SearchCityToggled('Taipei')),
      );

      expect(bloc.state.city, 'Taipei');
      expect(bloc.state.loading, isFalse);
    });
  });

  test('selected result is added to recents', () async {
    final recent = _FakeSearchRecentRepository();
    final bloc = SearchBloc(
      searchRepository: _FakeSearchRepository(),
      recentRepository: recent,
    );
    addTearDown(bloc.close);

    final result = _result('bus-1');
    bloc.add(SearchResultSelected(result));
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.recentResults, [result]);
  });

  group('personalisation', () {
    test('records the query a result was opened from', () async {
      final affinity = _FakeSearchAffinityRepository();
      final bloc = SearchBloc(
        searchRepository: _FakeSearchRepository(results: [_result('a')]),
        recentRepository: _FakeSearchRecentRepository(),
        affinityRepository: affinity,
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('307')),
      );
      bloc.add(SearchResultSelected(_result('a')));
      await Future<void>.delayed(Duration.zero);

      expect(affinity.recorded, [('busRoute:a', '307')]);
    });

    test('a previously opened result is ranked first', () async {
      final bloc = SearchBloc(
        searchRepository: _FakeSearchRepository(
          results: [_result('a'), _result('b'), _result('picked')],
        ),
        recentRepository: _FakeSearchRecentRepository(),
        affinityRepository: _FakeSearchAffinityRepository(
          entries: {
            'busRoute:picked': SearchAffinity(
              result: _result('picked'),
              picks: 4,
              lastPickedMs: DateTime(2026, 8, 11, 7).millisecondsSinceEpoch,
              queries: const ['307'],
              hourMask: 1 << 7,
            ),
          },
        ),
        now: () => DateTime(2026, 8, 11, 8),
      );
      addTearDown(bloc.close);

      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('307')),
      );

      expect(bloc.state.results.first.uid, 'picked');
    });

    test('clearing history also clears the ranking signal', () async {
      final affinity = _FakeSearchAffinityRepository(
        entries: {
          'busRoute:a': SearchAffinity(
            result: _result('a'),
            picks: 1,
            lastPickedMs: DateTime(2026, 8, 11, 8).millisecondsSinceEpoch,
            queries: const ['307'],
            hourMask: 1 << 8,
          ),
        },
      );
      final bloc = SearchBloc(
        searchRepository: _FakeSearchRepository(),
        recentRepository: _FakeSearchRecentRepository(recents: [_result('a')]),
        affinityRepository: affinity,
      );
      addTearDown(bloc.close);
      await Future<void>.delayed(Duration.zero);

      bloc.add(const SearchRecentsCleared());
      await Future<void>.delayed(Duration.zero);

      expect(affinity.entries, isEmpty);
      expect(bloc.state.recentResults, isEmpty);
    });
  });

  group('recents and stale work', () {
    SearchBloc build(
      SearchRepository search,
      _FakeSearchRecentRepository recent,
    ) {
      final bloc = SearchBloc(
        searchRepository: search,
        recentRepository: recent,
        locationService: _FakeLocationService(),
      );
      addTearDown(bloc.close);
      return bloc;
    }

    test('removing a recent drops it from state', () async {
      final bloc = build(
        _FakeSearchRepository(),
        _FakeSearchRecentRepository(recents: [_result('a'), _result('b')]),
      );
      await Future<void>.delayed(Duration.zero);
      bloc.add(SearchRecentRemoved(_result('a')));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.recentResults.map((r) => r.uid), ['b']);
    });

    test('restoring a recent puts it back at its index', () async {
      final bloc = build(
        _FakeSearchRepository(),
        _FakeSearchRecentRepository(recents: [_result('b'), _result('c')]),
      );
      await Future<void>.delayed(Duration.zero);
      bloc.add(SearchRecentRestored(_result('a'), 1));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.recentResults.map((r) => r.uid), ['b', 'a', 'c']);
    });

    test('clearing the search keeps the recents and drops the rest', () async {
      final bloc = build(
        _FakeSearchRepository(results: [_result('r')]),
        _FakeSearchRecentRepository(recents: [_result('a')]),
      );
      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('taipei')),
      );
      bloc.add(const SearchCleared());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.query, isEmpty);
      expect(bloc.state.results, isEmpty);
      expect(bloc.state.recentResults.map((r) => r.uid), ['a']);
    });

    test(
      'a submission with a stale id or a different query is ignored',
      () async {
        final search = _FakeSearchRepository(results: [_result('r')]);
        final bloc = build(search, _FakeSearchRecentRepository())
          ..add(const SearchQueryChanged('abc'));
        await Future<void>.delayed(Duration.zero);
        bloc
          ..add(const SearchQuerySubmitted('abc', 0))
          ..add(const SearchQuerySubmitted('zzz', 1));
        await Future<void>.delayed(Duration.zero);
        expect(search.queries, isEmpty);
      },
    );

    test(
      'results that land after the search was cleared are dropped',
      () async {
        final gate = Completer<List<SearchResult>>();
        final search = _GatedSearchRepository(gate);
        final bloc = build(search, _FakeSearchRecentRepository())
          ..add(const SearchQueryChanged('abc'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(search.calls, 1);
        bloc.add(const SearchCleared());
        await Future<void>.delayed(Duration.zero);
        gate.complete([_result('late')]);
        await Future<void>.delayed(Duration.zero);
        expect(bloc.state.results, isEmpty);
        expect(bloc.state.loading, isFalse);
      },
    );

    test(
      'a failure that lands after the search was cleared is dropped',
      () async {
        final gate = Completer<List<SearchResult>>();
        final search = _GatedSearchRepository(gate);
        final bloc = build(search, _FakeSearchRecentRepository())
          ..add(const SearchQueryChanged('abc'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        bloc.add(const SearchCleared());
        await Future<void>.delayed(Duration.zero);
        gate.completeError(StateError('late'));
        await Future<void>.delayed(Duration.zero);
        expect(bloc.state.error, isNull);
      },
    );

    test('cities with equal counts are listed north to south', () async {
      final bloc = build(
        _FakeSearchRepository(
          results: [
            _result('a', city: 'Kaohsiung'),
            _result('b', city: 'Taipei'),
          ],
        ),
        _FakeSearchRecentRepository(),
      );
      await _searchAction(
        bloc,
        () => bloc.add(const SearchQueryChanged('中正路')),
      );
      expect(bloc.state.cityOptions, ['Taipei', 'Kaohsiung']);
    });
  });
}

class _GatedSearchRepository implements SearchRepository {
  _GatedSearchRepository(this.gate);

  final Completer<List<SearchResult>> gate;
  int calls = 0;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) {
    calls++;
    return gate.future;
  }
}

SearchResult _result(String uid, {String? city}) => SearchResult(
  type: SearchResultType.busRoute,
  uid: uid,
  name: '307',
  subtitle: '板橋 $uid',
  city: city,
);

Future<void> _closeBloc(WidgetTester tester, SearchBloc bloc) async {
  var closed = false;
  Object? failure;
  StackTrace? failureStack;
  // The stream callbacks need fake-zone pumps while close awaits native work.
  await tester.runAsync(() async {
    unawaited(
      bloc.close().then<void>(
        (_) => closed = true,
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          closed = true;
        },
      ),
    );
  });
  final elapsed = Stopwatch()..start();
  while (!closed) {
    if (elapsed.elapsed >= const Duration(seconds: 5)) {
      fail('SearchBloc.close did not complete within five seconds');
    }
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
  await tester.pump();
}

Future<SearchState> _afterState(
  SearchBloc bloc,
  bool Function(SearchState) matches,
  void Function() action,
) {
  final completed = bloc.stream
      .firstWhere(matches)
      .timeout(const Duration(seconds: 5));
  action();
  return completed;
}

Future<SearchState> _searchAction(SearchBloc bloc, void Function() action) {
  var sawLoading = false;
  return _afterState(bloc, (state) {
    // QueryChanged first publishes its query with the previous loading value.
    // Await the loading cycle so that initial emission cannot end the wait.
    if (state.loading) sawLoading = true;
    return sawLoading &&
        !state.loading &&
        (state.error != null || state.results.isNotEmpty);
  }, action);
}

class _FakeLocationService implements LocationService {
  @override
  Future<Position?> lastKnownPosition() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by this test',
  );
}

class _FakeSearchRepository implements SearchRepository {
  _FakeSearchRepository({this.results = const [], this.error, this.byCity});

  final List<SearchResult> results;
  final Error? error;

  /// Results keyed by city code, for the filter tests. Falls back to
  /// [results] for a city that isn't listed.
  final Map<String, List<SearchResult>>? byCity;

  final List<String> queries = [];
  final List<String?> cities = [];

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async {
    queries.add(query);
    cities.add(city);
    final error = this.error;
    if (error != null) throw error;
    if (city == null) return results;
    return byCity?[city] ?? results;
  }
}

class _FakeSearchAffinityRepository implements SearchAffinityRepository {
  _FakeSearchAffinityRepository({
    Map<String, SearchAffinity> entries = const {},
  }) : entries = {...entries};

  final Map<String, SearchAffinity> entries;

  /// (storage key, query) of every recorded selection, in order.
  final List<(String, String)> recorded = [];

  @override
  Map<String, SearchAffinity> all() => Map.unmodifiable(entries);

  @override
  List<SearchResult> frequent({int limit = 5}) =>
      entries.values.map((e) => e.result).take(limit).toList();

  @override
  Future<void> record(
    SearchResult result, {
    required String query,
    required DateTime now,
  }) async {
    recorded.add((result.storageKey, query));
    entries[result.storageKey] = SearchAffinity(
      result: result,
      picks: (entries[result.storageKey]?.picks ?? 0) + 1,
      lastPickedMs: now.millisecondsSinceEpoch,
      queries: [query],
      hourMask: 1 << now.hour,
    );
  }

  @override
  Future<void> clear() async => entries.clear();
}

class _FakeSearchRecentRepository implements SearchRecentRepository {
  _FakeSearchRecentRepository({List<SearchResult> recents = const []})
    : _recents = [...recents];

  final List<SearchResult> _recents;

  @override
  List<SearchResult> all() => List.unmodifiable(_recents);

  @override
  Future<void> add(SearchResult result) async {
    _recents
      ..removeWhere((r) => r.type == result.type && r.uid == result.uid)
      ..insert(0, result);
  }

  @override
  Future<void> remove(SearchResult result) async {
    _recents.removeWhere((r) => r.type == result.type && r.uid == result.uid);
  }

  @override
  Future<void> restore(SearchResult result, int index) async {
    _recents
      ..removeWhere((r) => r.type == result.type && r.uid == result.uid)
      ..insert(index.clamp(0, _recents.length), result);
  }

  @override
  Future<void> clear() async {
    _recents.clear();
  }
}
