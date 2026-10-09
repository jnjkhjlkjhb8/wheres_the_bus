import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';

void main() {
  _motisSuggestions();
  group('plannedPlaceFrom', () {
    test('maps lat/lng in the right order and keeps the name', () {
      final place = PlacesRepository.plannedPlaceFrom(
        lat: 25.033,
        lng: 121.5654,
        name: '台北101',
      );
      expect(place.name, '台北101');
      expect(place.latLng.latitude, 25.033);
      expect(place.latLng.longitude, 121.5654);
    });

    test('falls back to a default name when null', () {
      final place = PlacesRepository.plannedPlaceFrom(
        lat: 0,
        lng: 0,
        name: null,
      );
      expect(place.name, '地點');
    });

    test('throws when location is missing', () {
      expect(
        () =>
            PlacesRepository.plannedPlaceFrom(lat: null, lng: null, name: 'x'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('plannedPlaceFromJson', () {
    test('reads location and displayName off a place resource', () {
      final place = PlacesRepository.plannedPlaceFromJson(const {
        'location': {'latitude': 25.033, 'longitude': 121.5654},
        'displayName': {'text': '台北101', 'languageCode': 'zh-TW'},
      });
      expect(place.name, '台北101');
      expect(place.latLng.latitude, 25.033);
      expect(place.latLng.longitude, 121.5654);
    });

    test('throws when the response carries no location', () {
      expect(
        () => PlacesRepository.plannedPlaceFromJson(const {
          'displayName': {'text': '台北101'},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('suggestionsFromJson', () {
    test('maps structuredFormat into primary/secondary text', () {
      final results = PlacesRepository.suggestionsFromJson(const {
        'suggestions': [
          {
            'placePrediction': {
              'placeId': 'abc',
              'text': {'text': '台北101, 台灣'},
              'structuredFormat': {
                'mainText': {'text': '台北101'},
                'secondaryText': {'text': '台灣台北市'},
              },
            },
          },
        ],
      });
      expect(results, hasLength(1));
      expect(results.single.placeId, 'abc');
      expect(results.single.primaryText, '台北101');
      expect(results.single.secondaryText, '台灣台北市');
    });

    test('falls back to the flat text when structuredFormat is absent', () {
      final results = PlacesRepository.suggestionsFromJson(const {
        'suggestions': [
          {
            'placePrediction': {
              'placeId': 'abc',
              'text': {'text': '台北101'},
            },
          },
        ],
      });
      expect(results.single.primaryText, '台北101');
      expect(results.single.secondaryText, '');
    });

    test('drops entries without a place id and tolerates an empty body', () {
      expect(
        PlacesRepository.suggestionsFromJson(const {
          'suggestions': [
            {
              'queryPrediction': {
                'text': {'text': '咖啡'},
              },
            },
          ],
        }),
        isEmpty,
      );
      expect(PlacesRepository.suggestionsFromJson(const {}), isEmpty);
    });
  });
}

void _motisSuggestions() {
  group('motisSuggestionsFromJson', () {
    test('keeps the coordinates the suggestion already carries', () {
      final parsed = PlacesRepository.motisSuggestionsFromJson({
        'suggestions': [
          {
            'name': '台北車站',
            'lat': 25.0478,
            'lon': 121.5170,
            'type': 'STOP',
          },
          {
            'name': '忠孝東路一段',
            'address': '忠孝東路一段12號',
            'lat': 25.044,
            'lon': 121.522,
            'type': 'ADDRESS',
          },
        ],
      });

      expect(parsed.suggestions, hasLength(2));
      expect(parsed.suggestions.first.primaryText, '台北車站');
      expect(parsed.suggestions[1].secondaryText, '忠孝東路一段12號');
      // Unlike Google, MOTIS answers coordinates in the same call — that is
      // what lets a pick skip the details round trip.
      final resolved = parsed.places[parsed.suggestions.first.placeId];
      expect(resolved, isNotNull);
      expect(resolved!.latLng.latitude, closeTo(25.0478, 1e-9));
      expect(resolved.latLng.longitude, closeTo(121.5170, 1e-9));
    });

    test('drops rows the rider could tap and get nothing from', () {
      final parsed = PlacesRepository.motisSuggestionsFromJson({
        'suggestions': [
          {'name': '沒有座標'},
          {'lat': 25.0, 'lon': 121.0},
          {'name': '有座標', 'lat': 25.0, 'lon': 121.0},
        ],
      });

      expect(parsed.suggestions, hasLength(1));
      expect(parsed.suggestions.single.primaryText, '有座標');
      expect(parsed.places, hasLength(1));
    });

    test('survives a body that is not the expected shape', () {
      expect(
        PlacesRepository.motisSuggestionsFromJson(const {}).suggestions,
        isEmpty,
      );
    });
  });
}
