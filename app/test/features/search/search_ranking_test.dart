import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_affinity_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_ranking.dart';

void main() {
  // A Tuesday at 08:00 — inside the weekday morning commute window.
  final commuteTime = DateTime(2026, 8, 11, 8);

  test('no personal signals leaves the router order alone', () {
    final results = [_stop('a'), _stop('b'), _stop('c')];

    expect(
      _rank(results, now: commuteTime).map((r) => r.uid),
      ['a', 'b', 'c'],
    );
  });

  test('a favourite outranks the results above it', () {
    final results = [_stop('a'), _stop('b'), _stop('favourite')];

    final ranked = _rank(
      results,
      now: commuteTime,
      favorites: [
        const Favorite(
          type: FavoriteType.busStop,
          refId: 'favourite',
          title: '站',
        ),
      ],
    );

    expect(ranked.first.uid, 'favourite');
  });

  test('a favourite saved under the display name still matches', () {
    // The metro station page saves under the line-map id, not the search uid,
    // so name is the only thing the two records share.
    final results = [_stop('a'), _metro('TDX-code', name: '北投')];

    final ranked = _rank(
      results,
      now: commuteTime,
      favorites: [
        const Favorite(
          type: FavoriteType.metroStation,
          refId: 'map-id',
          title: '北投',
        ),
      ],
    );

    expect(ranked.first.uid, 'TDX-code');
  });

  test('repeatedly picking a result for a query puts it first', () {
    final results = [_stop('a'), _stop('b'), _stop('picked')];

    final ranked = _rank(
      results,
      query: 'zho',
      now: commuteTime,
      affinity: {
        'busStation:picked': _affinity(
          _stop('picked'),
          picks: 4,
          lastPicked: commuteTime.subtract(const Duration(hours: 2)),
          queries: ['zhongzheng'],
        ),
      },
    );

    expect(ranked.first.uid, 'picked');
  });

  test('a pick older than the half-life stops counting', () {
    final results = [_stop('a'), _stop('stale')];

    final ranked = _rank(
      results,
      now: commuteTime,
      affinity: {
        // Picked at 14:00, so the commute bonus — which is deliberately not
        // recency-decayed, an 8am habit stays an 8am habit — cannot be what
        // this asserts on.
        'busStation:stale': _affinity(
          _stop('stale'),
          picks: 5,
          lastPicked: DateTime(2026, 7, 12, 14),
        ),
      },
    );

    expect(ranked.map((r) => r.uid), ['a', 'stale']);
  });

  test('a nearby result outranks a far one', () {
    // ~100 m and ~30 km from the fix.
    final results = [
      _stop('far', lat: 25.297, lon: 121.565),
      _stop('near', lat: 25.0331, lon: 121.5654),
    ];

    final ranked = _rank(
      results,
      now: commuteTime,
      fix: _fixAt(25.033, 121.5654),
    );

    expect(ranked.first.uid, 'near');
  });

  test('results without coordinates are not penalised into last place', () {
    final results = [
      _stop('nocoords'),
      _stop('far', lat: 25.297, lon: 121.565),
    ];

    final ranked = _rank(
      results,
      now: commuteTime,
      fix: _fixAt(25.033, 121.5654),
    );

    expect(ranked.map((r) => r.uid), ['nocoords', 'far']);
  });

  test('the commute bonus applies only inside the weekday window', () {
    expect(inCommuteWindow(DateTime(2026, 8, 11, 8)), isTrue);
    expect(inCommuteWindow(DateTime(2026, 8, 11, 18)), isTrue);
    expect(inCommuteWindow(DateTime(2026, 8, 11, 14)), isFalse);
    // Saturday 08:00.
    expect(inCommuteWindow(DateTime(2026, 8, 15, 8)), isFalse);
  });

  test('equal scores keep the router order', () {
    final picked = _affinity(
      _stop('x'),
      picks: 3,
      lastPicked: commuteTime.subtract(const Duration(days: 1)),
    );
    final results = [_stop('first'), _stop('second')];

    final ranked = _rank(
      results,
      now: commuteTime,
      affinity: {
        'busStation:first': picked,
        'busStation:second': picked,
      },
    );

    expect(ranked.map((r) => r.uid), ['first', 'second']);
  });
}

List<SearchResult> _rank(
  List<SearchResult> results, {
  required DateTime now,
  String query = '',
  List<Favorite> favorites = const [],
  Map<String, SearchAffinity> affinity = const {},
  Position? fix,
}) => rankSearchResults(
  results,
  query: query,
  favorites: favorites,
  affinity: affinity,
  now: now,
  fix: fix,
);

SearchResult _stop(String uid, {double? lat, double? lon}) => SearchResult(
  type: SearchResultType.busStation,
  uid: uid,
  name: uid,
  subtitle: '',
  lat: lat,
  lon: lon,
);

SearchResult _metro(String uid, {required String name}) => SearchResult(
  type: SearchResultType.mrtStation,
  uid: uid,
  name: name,
  subtitle: '',
);

SearchAffinity _affinity(
  SearchResult result, {
  required int picks,
  required DateTime lastPicked,
  List<String> queries = const [],
}) => SearchAffinity(
  result: result,
  picks: picks,
  lastPickedMs: lastPicked.millisecondsSinceEpoch,
  queries: queries,
  hourMask: 1 << lastPicked.hour,
);

Position _fixAt(double lat, double lon) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: DateTime(2026, 8, 11, 8),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);
