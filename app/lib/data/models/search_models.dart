import 'package:equatable/equatable.dart';

/// Result categories for the live `/api/search` path (SearchBloc/SearchResult).
enum SearchResultType {
  busRoute,
  busStation,
  bikeStation,
  mrtStation,
  traTrain,
  thsrTrain,
}

/// A validated search result from the `/api/search` endpoint. Lives in data/
/// so repositories can return it without depending on the search feature.
class SearchResult extends Equatable {
  const SearchResult({
    required this.type,
    required this.uid,
    required this.name,
    required this.subtitle,
    this.city,
    this.lat,
    this.lon,
  });

  final SearchResultType type;
  final String uid;
  final String name;
  final String subtitle;
  final String? city;
  final double? lat;
  final double? lon;

  String get storageKey => '${type.name}:$uid';

  /// Round-trips through the settings box. Shared by every local store that
  /// remembers results (history, affinity) so one shape is written and one
  /// parser has to stay in step with this class.
  Map<String, Object?> toStorageMap() => {
    'type': type.name,
    'uid': uid,
    'name': name,
    'subtitle': subtitle,
    'city': city,
    'lat': lat,
    'lon': lon,
  };

  /// Null when the map is missing the fields that make a result navigable —
  /// a partial entry left by an older build is dropped rather than rendered
  /// as a row that goes nowhere.
  static SearchResult? fromStorageMap(Map<dynamic, dynamic> map) {
    final typeName = map['type'] as String?;
    final type = SearchResultType.values.where((t) => t.name == typeName);
    if (type.isEmpty) return null;
    final uid = map['uid'] as String? ?? '';
    final name = map['name'] as String? ?? '';
    if (uid.isEmpty || name.isEmpty) return null;
    return SearchResult(
      type: type.first,
      uid: uid,
      name: name,
      subtitle: map['subtitle'] as String? ?? '',
      city: map['city'] as String?,
      lat: (map['lat'] as num?)?.toDouble(),
      lon: (map['lon'] as num?)?.toDouble(),
    );
  }

  @override
  List<Object?> get props => [type, uid, name, subtitle, city, lat, lon];
}

/// Search result categories returned by the backend search endpoint.
enum AppSearchResultType {
  busRoute,

  busStation,

  bikeStation,

  mrtStation,

  traStation,

  thsrStation,

  traTrain,

  thsrTrain,

  place,
}

/// Backend-shaped search result data from `/api/search`.
class BackendSearchResult {
  const BackendSearchResult({
    required this.type,
    required this.uid,
    required this.name,
    this.city,
    this.depart = '',
    this.destin = '',
  });

  final AppSearchResultType type;

  /// Stable backend identifier.
  final String uid;

  final String name;

  final String? city;

  final String depart;

  final String destin;
}

/// Presentation data for a search result row.
class SearchResultViewData {
  const SearchResultViewData({
    required this.type,
    required this.uid,
    required this.title,
    required this.subtitle,
  });

  final AppSearchResultType type;

  /// Stable backend identifier.
  final String uid;

  final String title;

  final String subtitle;
}
