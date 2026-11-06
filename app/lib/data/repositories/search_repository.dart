import 'dart:collection';

import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';

/// Fetches ranked/semantic results from the router's `/api/search`.
typedef SearchHttpFetch =
    Future<List<SearchResult>> Function(String query, int limit, String? city);

/// How many query→results pairs stay in memory. Sized for the shape of a
/// single search session — type, backspace, retype, toggle a city filter and
/// back — not for offline coverage.
const int _memoLimit = 24;

class SearchRepository {
  SearchRepository({SearchHttpFetch? httpFetch, LocalDb? localDb})
    : _httpFetch = httpFetch ?? _fetchFromRouter,
      _localDb = localDb;

  static final SearchRepository instance = SearchRepository();

  final SearchHttpFetch _httpFetch;

  // Resolved lazily so tests that never go offline need no PowerSync.
  final LocalDb? _localDb;
  LocalDb get _db => _localDb ?? PowerSyncService.instance;

  final LinkedHashMap<String, List<SearchResult>> _memo = LinkedHashMap();

  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async {
    final key = '${city ?? ''}|$limit|$query';
    final cached = _memo[key];
    if (cached != null) return cached;
    final (:results, :live) = await _fetchOrLocal(query, limit, city);
    // Local answers are not memoized: the next keystroke retries the router.
    if (live) _remember(key, results);
    return results;
  }

  Future<({List<SearchResult> results, bool live})> _fetchOrLocal(
    String query,
    int limit,
    String? city,
  ) async {
    try {
      return (results: await _httpFetch(query, limit, city), live: true);
    } on Object catch (e, stack) {
      final error = AppError.from(e);
      final local = await _offlineFallback(error, query, limit, city);
      if (local == null) Error.throwWithStackTrace(error, stack);
      return (results: local, live: false);
    }
  }

  void _remember(String key, List<SearchResult> results) {
    _memo[key] = results;
    if (_memo.length > _memoLimit) _memo.remove(_memo.keys.first);
  }

  /// Answers from the PowerSync copy of `search_vector` when the router is
  /// unreachable. Network-first, like the static cache (ADR-0017): a local
  /// LIKE ranks worse than the router's trigram search, so it must never
  /// shadow an online answer.
  ///
  /// Returns null — and the caller rethrows the original error — when the
  /// router did reply, when the local table is missing or not yet synced, or
  /// when nothing matches. An empty list would read as "no results", which is
  /// a different claim than "we could not reach the server".
  Future<List<SearchResult>?> _offlineFallback(
    AppError error,
    String query,
    int limit,
    String? city,
  ) async {
    if (error is! OfflineError && error is! TimeoutError) return null;
    final results = [
      for (final row in await _localRows(query, limit, city)) ?_fromRow(row),
    ];
    return results.isEmpty ? null : results;
  }

  /// A missing or not-yet-synced local table reads as no rows.
  Future<List<Map<String, dynamic>>> _localRows(
    String query,
    int limit,
    String? city,
  ) async {
    try {
      return await _db.getAll(_localSearchSql, [
        _likeEscape(query),
        _likeEscape(stripZhuyinTones(query)),
        city ?? '',
        limit,
      ]);
    } on Object {
      return const [];
    }
  }

  /// Mirrors the router's tiers (`_textSearchSQL`): exact uid, then name
  /// prefix, then name or endpoint contains, then reading/abbreviation
  /// (`alias`) — alias hits always rank below every `name` hit. Train rows
  /// have no city, so a city-scoped search excludes them, as on the router.
  static const _localSearchSql = r'''
SELECT type, uid, name, city, depart, destin, lat, lon,
  CASE
    WHEN uid = ?1 THEN 0
    WHEN name LIKE ?1 || '%' ESCAPE '\' THEN 1
    WHEN name LIKE '%' || ?1 || '%' ESCAPE '\'
      OR depart LIKE '%' || ?1 || '%' ESCAPE '\'
      OR destin LIKE '%' || ?1 || '%' ESCAPE '\' THEN 2
    ELSE 3
  END AS tier
FROM search_vector
WHERE (uid = ?1
    OR name LIKE '%' || ?1 || '%' ESCAPE '\'
    OR depart LIKE '%' || ?1 || '%' ESCAPE '\'
    OR destin LIKE '%' || ?1 || '%' ESCAPE '\'
    OR alias LIKE '%' || ?2 || '%' ESCAPE '\')
  AND (?3 = '' OR city = ?3)
ORDER BY tier, length(name), name
LIMIT ?4''';

  static String _likeEscape(String s) =>
      s.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');

  static SearchResult? _fromRow(Map<String, dynamic> row) {
    final rawType = row['type'] as String? ?? '';
    // Rail stations are no longer search entries — the rail query flow lives
    // on the home sheet, so a station row would have nowhere to navigate.
    if (rawType == 'tra_station' || rawType == 'thsr_station') return null;
    final city = row['city'] as String?;
    return SearchResult(
      type: _parseType(rawType),
      uid: row['uid'] as String? ?? '',
      name: row['name'] as String? ?? '',
      subtitle: _rowSubtitle(row, city),
      city: city,
      lat: (row['lat'] as num?)?.toDouble(),
      lon: (row['lon'] as num?)?.toDouble(),
    );
  }

  static String _rowSubtitle(Map<String, dynamic> row, String? city) {
    final depart = row['depart'] as String? ?? '';
    final destin = row['destin'] as String? ?? '';
    if (depart.isNotEmpty && destin.isNotEmpty) {
      return '$depart → $destin';
    }
    return _citySubtitle(city);
  }

  static String _citySubtitle(String? city) =>
      city == null || city.isEmpty ? '' : cityName(city);

  static SearchResultType _parseType(String t) =>
      const {
        'bus_route': SearchResultType.busRoute,
        'bus_station': SearchResultType.busStation,
        'bike_station': SearchResultType.bikeStation,
        'mrt_station': SearchResultType.mrtStation,
        'tra_train': SearchResultType.traTrain,
        'thsr_train': SearchResultType.thsrTrain,
      }[t] ??
      SearchResultType.busRoute;

  static Future<List<SearchResult>> _fetchFromRouter(
    String query,
    int limit,
    String? city,
  ) async {
    final res = await HttpClient.instance.dio.get<Map<String, dynamic>>(
      '/api/search',
      queryParameters: {'q': query, 'limit': limit, 'city': ?city},
    );
    final list = (res.data?['results'] as List?) ?? [];
    final results = <SearchResult>[];
    for (final r in list) {
      final result = _fromRow(Map<String, dynamic>.from(r as Map));
      if (result != null) results.add(result);
    }
    return results;
  }
}

/// Zhuyin tone marks, as `services/shared/zhuyin.go` strips them: aliases are
/// stored toneless, so toned input must lose its marks before matching.
const _zhuyinToneMarks = 'ˊˇˋ˙';

String stripZhuyinTones(String q) =>
    q.split('').where((c) => !_zhuyinToneMarks.contains(c)).join();
