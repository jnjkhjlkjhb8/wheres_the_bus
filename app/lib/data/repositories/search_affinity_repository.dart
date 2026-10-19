import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';

/// What the rider's past selections say about one result.
class SearchAffinity {
  const SearchAffinity({
    required this.result,
    required this.picks,
    required this.lastPickedMs,
    required this.queries,
    required this.hourMask,
  });

  /// The result as it looked when it was last picked. Kept whole so the
  /// "常去" section can render rows without a round trip to the router.
  final SearchResult result;

  final int picks;
  final int lastPickedMs;

  /// The last few queries that ended on this result, lower-cased. Ranking
  /// treats a prefix relationship in either direction as a match, so "beit"
  /// finds what "beitou" was picked for and vice versa.
  final List<String> queries;

  /// Bitmask over hour-of-day (0-23) of when this result was picked. One int
  /// instead of a histogram: the commute signal only asks whether this hour
  /// has happened before, not how often.
  final int hourMask;

  bool pickedAtHour(int hour) => hourMask & (1 << hour) != 0;

  bool matchesQuery(String query) {
    if (query.isEmpty) return false;
    final q = query.toLowerCase();
    return queries.any((s) => s.startsWith(q) || q.startsWith(s));
  }
}

class SearchAffinityRepository {
  const SearchAffinityRepository._();
  static const instance = SearchAffinityRepository._();

  static const _key = 'search_affinity';

  /// Ceiling on tracked results. The keyspace is whatever the rider searches
  /// for, so it needs a bound; the least recently picked entry is evicted.
  static const _maxEntries = 100;

  /// Queries remembered per entry. Enough to cover a rider who reaches the
  /// same stop by name and by route number, short enough that the record
  /// stays small.
  static const _maxQueriesPerEntry = 3;

  Map<String, SearchAffinity> all() {
    if (!HiveStore.settingsReady) return const {};
    final raw = HiveStore.settings.get(
      _key,
      defaultValue: <dynamic, dynamic>{},
    );
    if (raw is! Map) return const {};
    return _storedAffinities(raw);
  }

  static Map<String, SearchAffinity> _storedAffinities(
    Map<dynamic, dynamic> raw,
  ) {
    final out = <String, SearchAffinity>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final affinity = _storedAffinity(entry.value);
      if (affinity == null) continue;
      out[key] = affinity;
    }
    return out;
  }

  static SearchAffinity? _storedAffinity(dynamic value) {
    if (value is! Map) return null;
    final resultMap = value['r'];
    if (resultMap is! Map) return null;
    final result = SearchResult.fromStorageMap(resultMap);
    if (result == null) return null;
    return SearchAffinity(
      result: result,
      picks: (value['n'] as num?)?.toInt() ?? 0,
      lastPickedMs: (value['t'] as num?)?.toInt() ?? 0,
      queries:
          (value['q'] as List?)?.whereType<String>().toList(growable: false) ??
          const [],
      hourMask: (value['h'] as num?)?.toInt() ?? 0,
    );
  }

  /// Results the rider opens most, most-picked first, ties broken by recency.
  List<SearchResult> frequent({int limit = 5}) {
    final entries = all().values.toList()
      ..sort((a, b) {
        final byPicks = b.picks.compareTo(a.picks);
        return byPicks != 0
            ? byPicks
            : b.lastPickedMs.compareTo(a.lastPickedMs);
      });
    return entries.take(limit).map((e) => e.result).toList(growable: false);
  }

  /// Records that [result] was opened from [query] at [now].
  Future<void> record(
    SearchResult result, {
    required String query,
    required DateTime now,
  }) async {
    if (!HiveStore.settingsReady) return;
    final current = all();
    final key = result.storageKey;
    final existing = current[key];
    final q = query.trim().toLowerCase();
    // Newest query first, and a repeat moves rather than duplicates, so the
    // cap evicts the query the rider has stopped using.
    final queries = [
      if (q.isNotEmpty) q,
      ...?existing?.queries.where((s) => s != q),
    ].take(_maxQueriesPerEntry).toList(growable: false);

    final next = <String, Object?>{
      for (final e in current.entries)
        e.key: {
          'r': e.value.result.toStorageMap(),
          'n': e.value.picks,
          't': e.value.lastPickedMs,
          'q': e.value.queries,
          'h': e.value.hourMask,
        },
      key: {
        'r': result.toStorageMap(),
        'n': (existing?.picks ?? 0) + 1,
        't': now.millisecondsSinceEpoch,
        'q': queries,
        'h': (existing?.hourMask ?? 0) | (1 << now.hour),
      },
    };
    await HiveStore.settings.put(_key, _evictOldest(next));
  }

  /// Drops the least recently picked entries down to [_maxEntries].
  static Map<String, Object?> _evictOldest(Map<String, Object?> entries) {
    if (entries.length <= _maxEntries) return entries;
    final keys = entries.keys.toList()
      ..sort((a, b) {
        int stamp(String k) {
          final v = entries[k];
          return v is Map ? ((v['t'] as num?)?.toInt() ?? 0) : 0;
        }

        return stamp(b).compareTo(stamp(a));
      });
    return {for (final k in keys.take(_maxEntries)) k: entries[k]};
  }

  /// Wiped together with the visible search history: a rider who clears
  /// their history expects the app to stop favouring what they used to pick,
  /// not just to stop listing it.
  Future<void> clear() async {
    if (!HiveStore.settingsReady) return;
    await HiveStore.settings.delete(_key);
  }
}
