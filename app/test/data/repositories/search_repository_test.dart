import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';

void main() {
  test(
    'router transport decodes modes, city labels and rail exclusion',
    () async {
      final dio = HttpClient.instance.dio;
      final requests = <RequestOptions>[];
      final interceptor = InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: request,
              data: {
                'results': [
                  {
                    'type': 'bus_route',
                    'uid': 'bus',
                    'name': '307',
                    'depart': 'A',
                    'destin': 'B',
                    'city': 'Taipei',
                    'lat': 25,
                    'lon': 121.5,
                  },
                  {'type': 'bus_station', 'city': 'Taipei'},
                  {'type': 'bike_station', 'city': ''},
                  {'type': 'mrt_station'},
                  {'type': 'tra_train', 'city': 'Other'},
                  {'type': 'thsr_train', 'depart': 'A'},
                  {'type': 'unexpected'},
                  <String, dynamic>{},
                  {'type': 'tra_station'},
                  {'type': 'thsr_station'},
                ],
              },
            ),
          );
        },
      );
      dio.interceptors.add(interceptor);
      addTearDown(() => dio.interceptors.remove(interceptor));
      final repo = SearchRepository();
      final rows = await repo.search('query', limit: 9, city: 'Taipei');
      expect(requests.single.path, '/api/search');
      expect(requests.single.queryParameters, {
        'q': 'query',
        'limit': 9,
        'city': 'Taipei',
      });
      expect(rows.map((r) => r.type), [
        SearchResultType.busRoute,
        SearchResultType.busStation,
        SearchResultType.bikeStation,
        SearchResultType.mrtStation,
        SearchResultType.traTrain,
        SearchResultType.thsrTrain,
        SearchResultType.busRoute,
        SearchResultType.busRoute,
      ]);
      expect(rows.first.uid, 'bus');
      expect(rows.first.name, '307');
      expect(rows.first.subtitle, 'A → B');
      expect(rows.first.lat, 25);
      expect(rows.first.lon, 121.5);
      expect(rows[1].subtitle, '台北市');
      expect(rows[2].subtitle, '');
      expect(rows[3].subtitle, '');
      expect(rows[4].subtitle, 'Other');
      expect(rows[5].subtitle, '');
      expect(rows.last.uid, '');
      expect(rows.last.name, '');
      expect(rows.last.lat, isNull);
    },
  );

  test('router missing result lists decode as an empty page', () async {
    final dio = HttpClient.instance.dio;
    final seen = <RequestOptions>[];
    final interceptor = InterceptorsWrapper(
      onRequest: (request, handler) {
        seen.add(request);
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: request,
            data: request.queryParameters['q'] == 'null' ? null : {},
          ),
        );
      },
    );
    dio.interceptors.add(interceptor);
    addTearDown(() => dio.interceptors.remove(interceptor));
    final repo = SearchRepository();
    expect(await repo.search('null'), isEmpty);
    expect(await repo.search('empty'), isEmpty);
    expect(seen.first.queryParameters, {'q': 'null', 'limit': 20});
  });

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
