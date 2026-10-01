import 'dart:collection';

import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
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
  SearchRepository({SearchHttpFetch? httpFetch})
    : _httpFetch = httpFetch ?? _fetchFromRouter;

  static final SearchRepository instance = SearchRepository();

  final SearchHttpFetch _httpFetch;

  final LinkedHashMap<String, List<SearchResult>> _memo = LinkedHashMap();

  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async {
    final key = '${city ?? ''}|$limit|$query';
    final cached = _memo[key];
    if (cached != null) return cached;
    final List<SearchResult> results;
    try {
      results = await _httpFetch(query, limit, city);
    } on Object catch (e) {
      throw AppError.from(e);
    }
    _memo[key] = results;
    if (_memo.length > _memoLimit) _memo.remove(_memo.keys.first);
    return results;
  }

  static SearchResult? _fromRow(Map<String, dynamic> row) {
    final rawType = row['type'] as String? ?? '';
    // Rail stations are no longer search entries — the rail query flow lives
    // on the home sheet, so a station row would have nowhere to navigate.
    if (rawType == 'tra_station' || rawType == 'thsr_station') return null;
    final depart = row['depart'] as String? ?? '';
    final destin = row['destin'] as String? ?? '';
    final city = row['city'] as String?;
    final subtitle = depart.isNotEmpty && destin.isNotEmpty
        ? '$depart → $destin'
        // The row carries the raw TDX code; the reader gets the city's name.
        : (city == null || city.isEmpty ? '' : cityName(city));
    return SearchResult(
      type: _parseType(rawType),
      uid: row['uid'] as String? ?? '',
      name: row['name'] as String? ?? '',
      subtitle: subtitle,
      city: city,
      lat: (row['lat'] as num?)?.toDouble(),
      lon: (row['lon'] as num?)?.toDouble(),
    );
  }

  static SearchResultType _parseType(String t) => switch (t) {
    'bus_route' => SearchResultType.busRoute,
    'bus_station' => SearchResultType.busStation,
    'bike_station' => SearchResultType.bikeStation,
    'mrt_station' => SearchResultType.mrtStation,
    'tra_train' => SearchResultType.traTrain,
    'thsr_train' => SearchResultType.thsrTrain,
    _ => SearchResultType.busRoute,
  };

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
