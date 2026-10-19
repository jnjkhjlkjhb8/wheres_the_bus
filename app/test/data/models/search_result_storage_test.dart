import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';

void main() {
  Map<String, Object?> valid({Map<String, Object?> overrides = const {}}) => {
    'type': 'busStation',
    'uid': 'u1',
    'name': 'Taipei Main',
    'subtitle': 'Zhongzheng',
    'city': 'Taipei',
    'lat': 25,
    'lon': 121.5,
    ...overrides,
  };

  test('storageKey joins the type name and uid', () {
    const result = SearchResult(
      type: SearchResultType.mrtStation,
      uid: 'BL12',
      name: 'n',
      subtitle: 's',
    );
    expect(result.storageKey, 'mrtStation:BL12');
  });

  test('toStorageMap writes every field under its own key', () {
    const result = SearchResult(
      type: SearchResultType.thsrTrain,
      uid: '0123',
      name: 'Train',
      subtitle: 'Express',
      city: 'Taichung',
      lat: 24.1,
      lon: 120.6,
    );
    expect(result.toStorageMap(), {
      'type': 'thsrTrain',
      'uid': '0123',
      'name': 'Train',
      'subtitle': 'Express',
      'city': 'Taichung',
      'lat': 24.1,
      'lon': 120.6,
    });
  });

  test('a stored map parses back into the same result', () {
    const result = SearchResult(
      type: SearchResultType.bikeStation,
      uid: 'b9',
      name: 'Bike',
      subtitle: 'Dock',
      city: 'NewTaipei',
      lat: 25.01,
      lon: 121.46,
    );
    expect(SearchResult.fromStorageMap(result.toStorageMap()), result);
  });

  test('every type name resolves to its own enum value', () {
    for (final type in SearchResultType.values) {
      final parsed = SearchResult.fromStorageMap(
        valid(overrides: {'type': type.name}),
      );
      expect(parsed!.type, type);
    }
  });

  test('numeric coordinates of any kind become doubles', () {
    final parsed = SearchResult.fromStorageMap(valid())!;
    expect(parsed.lat, 25.0);
    expect(parsed.lat, isA<double>());
    expect(parsed.lon, 121.5);
    expect(parsed.city, 'Taipei');
    expect(parsed.subtitle, 'Zhongzheng');
    expect(parsed.uid, 'u1');
    expect(parsed.name, 'Taipei Main');
  });

  test('a missing subtitle falls back to an empty string', () {
    final parsed = SearchResult.fromStorageMap(valid()..remove('subtitle'));
    expect(parsed!.subtitle, '');
  });

  test('missing optional fields stay null', () {
    final parsed = SearchResult.fromStorageMap({
      'type': 'busRoute',
      'uid': 'r1',
      'name': 'Route',
    });
    expect(parsed!.city, isNull);
    expect(parsed.lat, isNull);
    expect(parsed.lon, isNull);
  });

  test('entries without a navigable identity are dropped', () {
    final unusable = <Map<String, Object?>>[
      valid(overrides: {'type': null}),
      valid(overrides: {'type': 'unknownType'}),
      valid(overrides: {'type': ''}),
      valid(overrides: {'uid': ''}),
      valid(overrides: {'uid': null}),
      valid(overrides: {'name': ''}),
      valid(overrides: {'name': null}),
      valid(overrides: {'uid': '', 'name': ''}),
    ];
    for (final map in unusable) {
      expect(SearchResult.fromStorageMap(map), isNull, reason: '$map');
    }
  });
}
