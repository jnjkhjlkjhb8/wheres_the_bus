import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_affinity_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_ranking.dart';

// A Wednesday 14:00: outside the commute windows, so only the signal under
// test moves a result.
final _midday = DateTime(2026, 8, 12, 14);
final _commute = DateTime(2026, 8, 12, 8);

const _fillers = 11;

SearchResult _stop(String uid, {double? lat, double? lon}) => SearchResult(
  type: SearchResultType.busStation,
  uid: uid,
  name: uid,
  subtitle: '',
  lat: lat,
  lon: lon,
);

Position _fix(double lat, double lon) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: _midday,
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

SearchAffinity _picked({
  required DateTime now,
  Duration age = Duration.zero,
  int picks = 5,
  List<String> queries = const [],
  int? hourMask,
}) => SearchAffinity(
  result: _stop('t'),
  picks: picks,
  lastPickedMs: now.subtract(age).millisecondsSinceEpoch,
  queries: queries,
  hourMask: hourMask ?? 1 << now.hour,
);

/// Where the target ends up when it starts last behind [_fillers] untouched
/// results. Each point of bonus is worth one place, so the position reads the
/// bonus to within one.
int _climbedTo({
  required DateTime now,
  SearchAffinity? affinity,
  String query = '',
  double? lat,
  double? lon,
  Position? fix,
}) {
  final results = [
    for (var i = 0; i < _fillers; i++) _stop('f$i'),
    _stop('t', lat: lat, lon: lon),
  ];
  final ranked = rankSearchResults(
    results,
    query: query,
    favorites: const [],
    affinity: {'busStation:t': ?affinity},
    now: now,
    fix: fix,
  );
  return ranked.indexWhere((r) => r.uid == 't');
}

int _placeFor(double bonus) =>
    bonus <= 0 ? _fillers : (_fillers - bonus).floor() + 1;

void main() {
  test('the weights keep their documented values', () {
    expect(SearchRankWeights.nearMeters, 500);
    expect(SearchRankWeights.near, 4);
    expect(SearchRankWeights.walkableMeters, 2000);
    expect(SearchRankWeights.walkable, 2);
    expect(SearchRankWeights.commute, 2);
  });

  test('distance bands are inclusive at their edges', () {
    expect(distanceBand(0), 4);
    expect(distanceBand(500), 4);
    expect(distanceBand(500.01), 2);
    expect(distanceBand(2000), 2);
    expect(distanceBand(2000.01), 0);
  });

  test('commute window edges: 07:00 and 17:00 in, 09:00 and 19:00 out', () {
    DateTime at(int hour, {int day = 12}) => DateTime(2026, 8, day, hour);
    expect(inCommuteWindow(at(6)), isFalse);
    expect(inCommuteWindow(at(7)), isTrue);
    expect(inCommuteWindow(at(8)), isTrue);
    expect(inCommuteWindow(at(9)), isFalse);
    expect(inCommuteWindow(at(16)), isFalse);
    expect(inCommuteWindow(at(17)), isTrue);
    expect(inCommuteWindow(at(18)), isTrue);
    expect(inCommuteWindow(at(19)), isFalse);
    expect(inCommuteWindow(at(8, day: 14)), isTrue, reason: 'Friday');
    expect(inCommuteWindow(at(8, day: 15)), isFalse, reason: 'Saturday');
  });

  group('picked-before bonus', () {
    test('a fresh, frequent pick is worth the full affinity', () {
      expect(
        _climbedTo(
          now: _midday,
          affinity: _picked(now: _midday),
        ),
        _placeFor(5),
      );
    });

    test('one pick is a fifth of the frequency ceiling', () {
      expect(
        _climbedTo(
          now: _midday,
          affinity: _picked(now: _midday, picks: 1),
        ),
        _placeFor(1),
      );
    });

    test('recency decays linearly: half the half-life leaves half', () {
      expect(
        _climbedTo(
          now: _midday,
          affinity: _picked(now: _midday, age: const Duration(hours: 84)),
        ),
        _placeFor(2.5),
      );
    });

    test('a small bonus is not inflated by the other factors', () {
      expect(
        _climbedTo(
          now: _midday,
          affinity: _picked(
            now: _midday,
            age: const Duration(hours: 84),
            picks: 1,
          ),
        ),
        _placeFor(0.5),
      );
    });

    test('a pick past the half-life never penalises the result', () {
      final stale = _picked(now: _midday, age: const Duration(days: 28));
      final results = [
        _stop('t'),
        for (var i = 0; i < _fillers; i++) _stop('f$i'),
      ];
      final ranked = rankSearchResults(
        results,
        query: '',
        favorites: const [],
        affinity: {'busStation:t': stale},
        now: _midday,
      );
      expect(ranked.first.uid, 't');
    });

    test('a pick from the future counts for nothing', () {
      final future = _picked(now: _midday, age: const Duration(days: -1));
      expect(_climbedTo(now: _midday, affinity: future), _placeFor(0));
    });

    test('a matching query adds three on top of the affinity', () {
      expect(
        _climbedTo(
          now: _midday,
          query: 'zho',
          affinity: _picked(now: _midday, queries: ['zhongzheng']),
        ),
        _placeFor(8),
      );
    });

    test('the commute hour adds two, only inside the window', () {
      expect(
        _climbedTo(
          now: _commute,
          affinity: _picked(now: _commute),
        ),
        _placeFor(7),
      );
      expect(
        _climbedTo(
          now: _commute,
          affinity: _picked(now: _commute, hourMask: 1 << 3),
        ),
        _placeFor(5),
      );
      expect(
        _climbedTo(
          now: _midday,
          affinity: _picked(now: _midday),
        ),
        _placeFor(5),
      );
    });

    test('affinity, query and commute bonuses add up', () {
      expect(
        _climbedTo(
          now: _commute,
          query: 'zho',
          affinity: _picked(now: _commute, queries: ['zhongzheng']),
        ),
        _placeFor(10),
      );
    });
  });

  group('distance bonus', () {
    final fix = _fix(25.033, 121.5654);

    test('within 500 m is worth four', () {
      expect(
        _climbedTo(now: _midday, fix: fix, lat: 25.0331, lon: 121.5654),
        _placeFor(4),
      );
    });

    test('within 2 km is worth two', () {
      expect(
        _climbedTo(now: _midday, fix: fix, lat: 25.042, lon: 121.5654),
        _placeFor(2),
      );
    });

    test('farther than 2 km is worth nothing', () {
      expect(
        _climbedTo(now: _midday, fix: fix, lat: 25.297, lon: 121.565),
        _placeFor(0),
      );
    });

    test('a coordinate on the equator or prime meridian is still real', () {
      expect(
        _climbedTo(now: _midday, fix: _fix(0, 121), lat: 0, lon: 121.001),
        _placeFor(4),
      );
      expect(
        _climbedTo(now: _midday, fix: _fix(25.033, 0), lat: 25.0331, lon: 0),
        _placeFor(4),
      );
    });

    test('(0, 0) means no coordinates, even right on top of the fix', () {
      expect(
        _climbedTo(now: _midday, fix: _fix(0, 0), lat: 0, lon: 0),
        _placeFor(0),
      );
    });
  });
}
