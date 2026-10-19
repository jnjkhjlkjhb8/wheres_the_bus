import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_google_places_sdk/flutter_google_places_sdk.dart'
    as sdk;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';

Dio localDio(
  void Function(RequestOptions, RequestInterceptorHandler) respond,
) =>
    Dio(BaseOptions(baseUrl: 'https://quality.invalid/'))
      ..interceptors.add(InterceptorsWrapper(onRequest: respond));

Dio emptyGeocoder() => localDio((request, handler) {
  handler.resolve(
    Response<Map<String, dynamic>>(
      requestOptions: request,
      data: const {'suggestions': <Object?>[]},
    ),
  );
});

class FakePlacesSdk implements sdk.FlutterGooglePlacesSdk {
  final queries = <String>[];
  final ids = <String>[];
  @override
  Future<sdk.FindAutocompletePredictionsResponse> findAutocompletePredictions(
    String query, {
    List<String>? countries,
    List<sdk.PlaceTypeFilter> placeTypesFilter = const [],
    bool? newSessionToken,
    sdk.LatLng? origin,
    sdk.LatLngBounds? locationBias,
    sdk.LatLngBounds? locationRestriction,
  }) async {
    queries.add(query);
    expect(countries, ['tw']);
    return const sdk.FindAutocompletePredictionsResponse([
      sdk.AutocompletePrediction(
        placeId: 'sdk-place',
        primaryText: '台北站',
        secondaryText: '台北市',
        fullText: '台北站，台北市',
        distanceMeters: null,
      ),
    ]);
  }

  @override
  Future<sdk.FetchPlaceResponse> fetchPlace(
    String placeId, {
    required List<sdk.PlaceField> fields,
  }) async {
    ids.add(placeId);
    expect(fields, [sdk.PlaceField.Location, sdk.PlaceField.Name]);
    return sdk.FetchPlaceResponse(
      sdk.Place.fromJson({
        'name': '台北站',
        'latLng': {'lat': 25.04, 'lng': 121.51},
      }),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'MOTIS suggestions resolve locally and preserve bias parameters',
    () async {
      final requests = <RequestOptions>[];
      final geocoder = localDio((request, handler) {
        requests.add(request);
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: request,
            data: const {
              'suggestions': [
                {'name': '', 'lat': 25, 'lon': 121},
                {'name': '台北站', 'lat': 25.04, 'lon': 121.51, 'address': '北平西路'},
              ],
            },
          ),
        );
      });
      final repository = PlacesRepository(geocoder: geocoder);
      expect(await repository.autocomplete(''), isEmpty);
      expect(requests, isEmpty);
      final results = await repository.autocomplete(
        '台北',
        bias: const LatLng(25, 121),
      );
      expect(results.single.placeId, 'motis:1');
      expect(results.single.secondaryText, '北平西路');
      expect(requests.single.path, '/api/geocode');
      expect(requests.single.queryParameters, {
        'text': '台北',
        'lat': 25.0,
        'lon': 121.0,
      });
      final place = await repository.details(results.single.placeId);
      expect(place.name, '台北站');
      expect(place.latLng, const LatLng(25.04, 121.51));
      expect(requests, hasLength(1));
    },
  );

  test(
    'failed geocoding clears cached MOTIS places and needs no Google key',
    () async {
      var failure = false;
      final repository = PlacesRepository(
        geocoder: localDio((request, handler) {
          if (failure) {
            handler.reject(DioException(requestOptions: request));
          } else {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: request,
                data: const {
                  'suggestions': [
                    {'name': '站', 'lat': 1, 'lon': 2},
                  ],
                },
              ),
            );
          }
        }),
        apiKey: '',
      );
      expect(await repository.autocomplete('站'), hasLength(1));
      failure = true;
      expect(await repository.autocomplete('其他'), isEmpty);
      expect(repository.details('motis:0'), throwsStateError);
    },
  );

  test(
    'SDK fallback requests Taiwan predictions and named coordinates',
    () async {
      final client = FakePlacesSdk();
      final repository = PlacesRepository(
        geocoder: emptyGeocoder(),
        apiKey: 'test-key',
        useRest: false,
        client: client,
      );
      final results = await repository.autocomplete('台北');
      expect(results.single.placeId, 'sdk-place');
      expect(results.single.primaryText, '台北站');
      expect(results.single.secondaryText, '台北市');
      final place = await repository.details('sdk-place');
      expect(place.name, '台北站');
      expect(place.latLng, const LatLng(25.04, 121.51));
      expect(client.queries, ['台北']);
      expect(client.ids, ['sdk-place']);
    },
  );

  test(
    'REST fallback carries one session through details then starts another',
    () async {
      final requests = <RequestOptions>[];
      final rest = localDio((request, handler) {
        requests.add(request);
        final data = request.method == 'POST'
            ? const {
                'suggestions': [
                  {
                    'placePrediction': {
                      'placeId': 'rest-place',
                      'text': {'text': 'Rest'},
                    },
                  },
                ],
              }
            : const {
                'location': {'latitude': 25.01, 'longitude': 121.01},
                'displayName': {'text': 'Rest'},
              };
        handler.resolve(
          Response<Map<String, dynamic>>(requestOptions: request, data: data),
        );
      });
      final repository = PlacesRepository(
        geocoder: emptyGeocoder(),
        restClient: rest,
        apiKey: 'test-key',
        useRest: true,
        bundleId: Future.value('quality.bundle'),
      );
      await repository.autocomplete('first');
      await repository.autocomplete('second');
      final first = (requests[0].data as Map)['sessionToken'];
      expect((requests[1].data as Map)['sessionToken'], first);
      expect((requests[0].data as Map)['input'], 'first');
      expect((requests[0].data as Map)['includedRegionCodes'], ['tw']);
      expect((requests[0].data as Map)['languageCode'], 'zh-TW');
      final place = await repository.details('rest-place');
      expect(place.name, 'Rest');
      expect(place.latLng, const LatLng(25.01, 121.01));
      expect(requests[2].path, 'places/rest-place');
      expect(requests[2].queryParameters, {
        'languageCode': 'zh-TW',
        'sessionToken': first,
      });
      expect(requests[2].headers['X-Goog-Api-Key'], 'test-key');
      expect(requests[2].headers['X-Ios-Bundle-Identifier'], 'quality.bundle');
      expect(requests[2].headers['X-Goog-FieldMask'], 'location,displayName');
      await repository.autocomplete('third');
      expect((requests[3].data as Map)['sessionToken'], isNot(first));
      await repository.details('rest-place');
      await repository.details('rest-place');
      expect(
        requests.last.queryParameters.containsKey('sessionToken'),
        isFalse,
      );
    },
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.linux,
  ]) {
    test('default empty key disables Google on ${platform.name}', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      final repository = PlacesRepository(geocoder: emptyGeocoder());
      expect(await repository.autocomplete('站'), isEmpty);
      expect(repository.details('unknown'), throwsStateError);
    });
  }

  test('MOTIS drops null rows, blank names, and either missing coordinate', () {
    final results = PlacesRepository.motisSuggestionsFromJson(const {
      'suggestions': [
        null,
        {'name': ''},
        {'name': '站', 'lat': 25},
        {'name': '站', 'lon': 121},
        {'lat': 25, 'lon': 121},
        {'name': 'valid', 'lat': 25, 'lon': 121},
      ],
    });
    expect(results.suggestions.single.placeId, 'motis:5');
    expect(results.places.keys, ['motis:5']);
  });
}
