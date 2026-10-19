import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/features/search/bloc/search_event.dart';

const _result = SearchResult(
  type: SearchResultType.busRoute,
  uid: 'u1',
  name: '307',
  subtitle: '板橋',
);

const _other = SearchResult(
  type: SearchResultType.busStation,
  uid: 'u2',
  name: '台北車站',
  subtitle: '忠孝西路',
);

void main() {
  group('events without a payload', () {
    test('carry no props and are equal to each other', () {
      expect(const SearchCleared().props, isEmpty);
      expect(const SearchSuggestionsRequested().props, isEmpty);
      expect(const SearchRecentsCleared().props, isEmpty);
      expect(const SearchCleared(), const SearchCleared());
      expect(
        const SearchSuggestionsRequested(),
        const SearchSuggestionsRequested(),
      );
      expect(const SearchRecentsCleared(), const SearchRecentsCleared());
    });

    test('differ from each other even though both are empty', () {
      expect(
        const SearchCleared() == const SearchRecentsCleared(),
        isFalse,
      );
    });
  });

  group('events with a payload expose it as props', () {
    test('query changed', () {
      expect(const SearchQueryChanged('abc').props, ['abc']);
      expect(const SearchQueryChanged('abc'), const SearchQueryChanged('abc'));
      expect(
        const SearchQueryChanged('abc') == const SearchQueryChanged('abd'),
        isFalse,
      );
    });

    test('result selected and recent removed', () {
      expect(const SearchResultSelected(_result).props, [_result]);
      expect(const SearchRecentRemoved(_result).props, [_result]);
      expect(
        const SearchResultSelected(_result) ==
            const SearchResultSelected(_other),
        isFalse,
      );
      expect(
        const SearchRecentRemoved(_result) == const SearchRecentRemoved(_other),
        isFalse,
      );
    });

    test('recent restored keeps the index', () {
      const restored = SearchRecentRestored(_result, 3);
      expect(restored.props, [_result, 3]);
      expect(restored, const SearchRecentRestored(_result, 3));
      expect(restored == const SearchRecentRestored(_result, 4), isFalse);
      expect(restored == const SearchRecentRestored(_other, 3), isFalse);
    });

    test('query submitted keeps the request id and the city', () {
      const submitted = SearchQuerySubmitted('q', 7, city: '台北市');
      expect(submitted.props, ['q', 7, '台北市']);
      expect(submitted, const SearchQuerySubmitted('q', 7, city: '台北市'));
      expect(
        submitted == const SearchQuerySubmitted('q', 8, city: '台北市'),
        isFalse,
      );
      expect(submitted == const SearchQuerySubmitted('q', 7), isFalse);
      expect(const SearchQuerySubmitted('q', 7).props, ['q', 7, null]);
    });

    test('city toggled', () {
      expect(const SearchCityToggled('台北市').props, ['台北市']);
      expect(
        const SearchCityToggled('台北市') == const SearchCityToggled('新北市'),
        isFalse,
      );
    });
  });
}
