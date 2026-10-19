import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';

void main() {
  const base = SearchResult(
    type: SearchResultType.busRoute,
    uid: 'u',
    name: 'n',
    subtitle: 's',
    city: 'Taipei',
    lat: 1,
    lon: 2,
  );

  test('equality covers every field', () {
    expect(
      base,
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'u',
        name: 'n',
        subtitle: 's',
        city: 'Taipei',
        lat: 1,
        lon: 2,
      ),
    );
    final others = [
      const SearchResult(
        type: SearchResultType.busStation,
        uid: 'u',
        name: 'n',
        subtitle: 's',
        city: 'Taipei',
        lat: 1,
        lon: 2,
      ),
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'x',
        name: 'n',
        subtitle: 's',
        city: 'Taipei',
        lat: 1,
        lon: 2,
      ),
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'u',
        name: 'x',
        subtitle: 's',
        city: 'Taipei',
        lat: 1,
        lon: 2,
      ),
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'u',
        name: 'n',
        subtitle: 'x',
        city: 'Taipei',
        lat: 1,
        lon: 2,
      ),
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'u',
        name: 'n',
        subtitle: 's',
        city: 'x',
        lat: 1,
        lon: 2,
      ),
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'u',
        name: 'n',
        subtitle: 's',
        city: 'Taipei',
        lat: 9,
        lon: 2,
      ),
      const SearchResult(
        type: SearchResultType.busRoute,
        uid: 'u',
        name: 'n',
        subtitle: 's',
        city: 'Taipei',
        lat: 1,
        lon: 9,
      ),
    ];
    for (final o in others) {
      expect(o, isNot(base));
    }
  });
}
