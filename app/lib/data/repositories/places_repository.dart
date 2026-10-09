import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_google_places_sdk/flutter_google_places_sdk.dart'
    as places;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

/// One autocomplete row: a place id plus display text, no coordinates yet.
/// Coordinates come from [PlacesRepository.details] on selection.
class PlaceSuggestion {
  const PlaceSuggestion({
    required this.placeId,
    required this.primaryText,
    required this.secondaryText,
  });

  final String placeId;
  final String primaryText;
  final String secondaryText;
}

class PlacesRepository {
  PlacesRepository._();
  static final PlacesRepository instance = PlacesRepository._();

  /// A Places key carries a platform restriction (Android package +
  /// signing SHA-1, or iOS bundle id), so each platform needs its own key.
  /// `GOOGLE_PLACES_API_KEY` stays the fallback for single-key setups.
  static const _apiKeyIos = String.fromEnvironment('GOOGLE_PLACES_API_KEY_IOS');
  static const _apiKeyAndroid = String.fromEnvironment(
    'GOOGLE_PLACES_API_KEY_ANDROID',
  );
  static const _apiKeyShared = String.fromEnvironment('GOOGLE_PLACES_API_KEY');

  static String get _apiKey {
    final platformKey = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => _apiKeyIos,
      TargetPlatform.android => _apiKeyAndroid,
      _ => '',
    };
    return platformKey.isEmpty ? _apiKeyShared : platformKey;
  }

  static bool get _useRest => defaultTargetPlatform == TargetPlatform.iOS;

  /// Null client when REST is in use or no key is configured (e.g. test env)
  /// so the UI degrades to just the current-location option instead of
  /// erroring.
  late final places.FlutterGooglePlacesSdk? _client =
      _useRest || _apiKey.isEmpty
      ? null
      : places.FlutterGooglePlacesSdk(
          _apiKey,
          locale: const Locale('zh', 'TW'),
          useNewApi: true,
        );

  late final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'https://places.googleapis.com/v1/',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  /// The key restriction is checked against this, so it has to be the real
  /// bundle id rather than a constant that can drift from the Xcode project.
  late final Future<String> _bundleId = PackageInfo.fromPlatform().then(
    (info) => info.packageName,
  );

  /// Shared by the keystrokes of one search and the details lookup that ends
  /// it, so Google bills them as a single session. Cleared in [details].
  String? _sessionToken;

  Map<String, PlannedPlace> _motisPlaces = const {};

  Future<List<PlaceSuggestion>> autocomplete(
    String query, {
    LatLng? bias,
  }) async {
    if (query.isEmpty) return const [];
    final fromMotis = await _motisAutocomplete(query, bias);
    if (fromMotis.isNotEmpty) return fromMotis;
    if (_apiKey.isEmpty) return const [];
    if (_useRest) return _restAutocomplete(query);
    final client = _client;
    if (client == null) return const [];
    final res = await client.findAutocompletePredictions(
      query,
      countries: const ['tw'],
    );
    return [
      for (final p in res.predictions)
        PlaceSuggestion(
          placeId: p.placeId,
          primaryText: p.primaryText,
          secondaryText: p.secondaryText,
        ),
    ];
  }

  Future<PlannedPlace> details(String placeId) async {
    final resolved = _motisPlaces[placeId];
    if (resolved != null) return resolved;
    if (_apiKey.isEmpty) {
      throw StateError('Places API key not configured');
    }
    if (_useRest) return _restDetails(placeId);
    final client = _client;
    if (client == null) {
      throw StateError('Places API key not configured');
    }
    final res = await client.fetchPlace(
      placeId,
      fields: const [places.PlaceField.Location, places.PlaceField.Name],
    );
    return plannedPlaceFrom(
      lat: res.place?.latLng?.lat,
      lng: res.place?.latLng?.lng,
      name: res.place?.name,
    );
  }

  /// Our own geocoder, through the router. Any failure returns an empty list so
  /// the Google path runs: this source is an addition, and it must never be
  /// able to take the picker down with it.
  Future<List<PlaceSuggestion>> _motisAutocomplete(
    String query,
    LatLng? bias,
  ) async {
    try {
      final response = await HttpClient.instance.dio.get<Map<String, dynamic>>(
        '/api/geocode',
        queryParameters: {
          'text': query,
          if (bias != null) 'lat': bias.latitude,
          if (bias != null) 'lon': bias.longitude,
        },
      );
      final parsed = motisSuggestionsFromJson(response.data ?? const {});
      _motisPlaces = parsed.places;
      return parsed.suggestions;
    } on Object {
      _motisPlaces = const {};
      return const [];
    }
  }

  Future<List<PlaceSuggestion>> _restAutocomplete(String query) async {
    final res = await _dio.post<Map<String, dynamic>>(
      'places:autocomplete',
      data: {
        'input': query,
        'includedRegionCodes': const ['tw'],
        'languageCode': 'zh-TW',
        'sessionToken': _sessionToken ??= const Uuid().v4(),
      },
      options: await _restOptions(),
    );
    return suggestionsFromJson(res.data ?? const {});
  }

  Future<PlannedPlace> _restDetails(String placeId) async {
    final token = _sessionToken;
    _sessionToken = null;
    final res = await _dio.get<Map<String, dynamic>>(
      'places/$placeId',
      // Without languageCode the place name comes back in English, while the
      // Android SDK path is constructed with a zh-TW locale.
      queryParameters: {'languageCode': 'zh-TW', 'sessionToken': ?token},
      options: await _restOptions(fieldMask: 'location,displayName'),
    );
    return plannedPlaceFromJson(res.data ?? const {});
  }

  Future<Options> _restOptions({String? fieldMask}) async => Options(
    headers: {
      'X-Goog-Api-Key': _apiKey,
      'X-Ios-Bundle-Identifier': await _bundleId,
      'X-Goog-FieldMask': ?fieldMask,
    },
  );

  /// Pure mapper (unit-tested): a Places API (New) autocomplete response ->
  /// suggestion rows. Entries without a place id are dropped rather than
  /// shown as a row [details] would fail to resolve.
  static List<PlaceSuggestion> suggestionsFromJson(Map<String, dynamic> json) {
    final out = <PlaceSuggestion>[];
    for (final entry in json['suggestions'] as List? ?? const []) {
      final prediction = (entry as Map?)?['placePrediction'] as Map?;
      final placeId = prediction?['placeId'] as String?;
      if (placeId == null) continue;
      final format = prediction?['structuredFormat'] as Map?;
      out.add(
        PlaceSuggestion(
          placeId: placeId,
          // structuredFormat is absent for query predictions; the flat `text`
          // is the only label those carry.
          primaryText:
              _text(format?['mainText']) ?? _text(prediction?['text']) ?? '',
          secondaryText: _text(format?['secondaryText']) ?? '',
        ),
      );
    }
    return out;
  }

  /// Pure mapper (unit-tested): a Places API (New) place resource ->
  /// a [PlannedPlace].
  static PlannedPlace plannedPlaceFromJson(Map<String, dynamic> json) {
    final location = json['location'] as Map?;
    return plannedPlaceFrom(
      lat: location?['latitude'] as num?,
      lng: location?['longitude'] as num?,
      name: _text(json['displayName']),
    );
  }

  /// Pure mapper (unit-tested): a place location/name -> a [PlannedPlace].
  /// Guards the lat/lng ordering and the missing-location case.
  static PlannedPlace plannedPlaceFrom({
    required num? lat,
    required num? lng,
    required String? name,
  }) {
    if (lat == null || lng == null) {
      throw const FormatException('Place details missing location');
    }
    return PlannedPlace(
      name: name ?? '地點',
      latLng: LatLng(lat.toDouble(), lng.toDouble()),
    );
  }

  /// Unwraps a Places `LocalizedText` (`{"text": ...}`) node.
  static String? _text(Object? node) => (node as Map?)?['text'] as String?;

  static MotisPlaceResults motisSuggestionsFromJson(Map<String, dynamic> json) {
    final suggestions = <PlaceSuggestion>[];
    final places = <String, PlannedPlace>{};
    final rows = json['suggestions'] as List? ?? const [];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as Map?;
      if (row == null) continue;
      final name = row['name'] as String?;
      final lat = row['lat'] as num?;
      final lng = row['lon'] as num?;
      // A row the rider can tap and get nothing from is worse than no row.
      if (name == null || name.isEmpty || lat == null || lng == null) continue;
      final id = 'motis:$i';
      suggestions.add(
        PlaceSuggestion(
          placeId: id,
          primaryText: name,
          secondaryText: row['address'] as String? ?? '',
        ),
      );
      places[id] = PlannedPlace(
        name: name,
        latLng: LatLng(lat.toDouble(), lng.toDouble()),
      );
    }
    return MotisPlaceResults(suggestions: suggestions, places: places);
  }
}

/// One `/api/geocode` response: the rows to show, and the coordinates they
/// resolve to. The two travel together because MOTIS answers both in one call,
/// unlike Google, which needs a second lookup per pick.
class MotisPlaceResults {
  const MotisPlaceResults({required this.suggestions, required this.places});

  final List<PlaceSuggestion> suggestions;
  final Map<String, PlannedPlace> places;
}
