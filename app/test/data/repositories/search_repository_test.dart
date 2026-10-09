import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';

void main() {
  group('failures', () {
    test('surfaces the failure rather than an empty list — "no results" is '
        'a different claim than "we could not reach the server"', () async {
      final repo = SearchRepository(
        httpFetch: (query, limit, city) async => throw StateError('down'),
      );

      await expectLater(repo.search('nowhere'), throwsA(isA<UnknownError>()));
    });

    test('maps a socket failure to OfflineError for the caller', () async {
      final repo = SearchRepository(
        httpFetch: (query, limit, city) async =>
            throw const SocketException('no route to host'),
      );

      await expectLater(repo.search('nowhere'), throwsA(isA<OfflineError>()));
    });
  });

  group('city filter', () {
    test('passes the city through to the router', () async {
      final seen = <String?>[];
      final repo = SearchRepository(
        httpFetch: (query, limit, city) async {
          seen.add(city);
          return const [];
        },
      );

      await repo.search('中正路', city: 'Taipei');
      await repo.search('中正路');

      expect(seen, ['Taipei', null]);
    });
  });

  group('memo', () {
    test('repeats a query from memory instead of the network', () async {
      var calls = 0;
      final repo = SearchRepository(
        httpFetch: (query, limit, city) async {
          calls++;
          return [_result('r-1')];
        },
      );

      final first = await repo.search('307');
      final second = await repo.search('307');

      expect(calls, 1);
      expect(second, same(first));
    });

    test(
      'keys on the city, so a filtered page is not served unfiltered',
      () async {
        final repo = SearchRepository(
          httpFetch: (query, limit, city) async => [_result(city ?? 'all')],
        );

        final filtered = await repo.search('307', city: 'Taipei');
        final unfiltered = await repo.search('307');

        expect(filtered.single.uid, 'Taipei');
        expect(unfiltered.single.uid, 'all');
      },
    );

    test(
      'a failed query is not memoized, so a retry actually retries',
      () async {
        var calls = 0;
        final repo = SearchRepository(
          httpFetch: (query, limit, city) async {
            calls++;
            throw const SocketException('offline');
          },
        );

        await expectLater(repo.search('307'), throwsA(isA<OfflineError>()));
        await expectLater(repo.search('307'), throwsA(isA<OfflineError>()));
        expect(calls, 2);
      },
    );
  });
}

SearchResult _result(String uid) => SearchResult(
  type: SearchResultType.busRoute,
  uid: uid,
  name: '307',
  subtitle: '板橋',
);
