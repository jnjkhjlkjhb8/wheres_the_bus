import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/http/http_client.dart' as http;
import 'package:wheres_the_bus/core/http/static_version.dart';

class _StaticVersionAdapter implements HttpClientAdapter {
  String response = '{"version":"42"}';
  int status = 200;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final matchesEndpoint =
        options.method == 'GET' && options.path == '/api/static-version';
    return ResponseBody.fromString(
      matchesEndpoint ? response : '{}',
      matchesEndpoint ? status : 404,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late HttpClientAdapter original;
  late _StaticVersionAdapter adapter;

  setUp(() {
    original = http.HttpClient.instance.dio.httpClientAdapter;
    adapter = _StaticVersionAdapter();
    http.HttpClient.instance.dio.httpClientAdapter = adapter;
  });
  tearDown(() {
    http.HttpClient.instance.dio.httpClientAdapter = original;
    adapter.close();
  });

  test(
    'fetches the cache epoch from the static-version GET endpoint',
    () async {
      for (final version in ['42', '0']) {
        adapter.response = jsonEncode({'version': version});
        expect(await fetchStaticVersion(), version);
      }
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.method, 'GET');
        expect(request.path, '/api/static-version');
      }
    },
  );

  test('a failed HTTP reply returns no cache epoch', () async {
    adapter.status = 503;
    expect(await fetchStaticVersion(), isNull);
    expect(adapter.requests, hasLength(1));
  });

  test('a malformed or absent JSON payload has no cache epoch', () async {
    for (final response in ['{', 'null', '{}', '{"version":[]}']) {
      adapter.response = response;
      expect(await fetchStaticVersion(), isNull, reason: response);
    }
    expect(adapter.requests, hasLength(4));
  });
}
