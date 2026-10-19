import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/http/http_client.dart' as http;
import 'package:wheres_the_bus/core/http/static_version.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';

class _Router implements HttpClientAdapter {
  Map<String, Object?> body = {};
  bool fail = false;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (fail) throw StateError('offline');
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  late HttpClientAdapter original;
  late _Router router;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('powersync-router-');
    Hive.init(storage.path);
    await Hive.openBox<dynamic>('settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read'
              ? '{"id":"install","secret":"test-secret"}'
              : null,
        );
  });
  setUp(() {
    original = http.HttpClient.instance.dio.httpClientAdapter;
    router = _Router();
    http.HttpClient.instance.dio.httpClientAdapter = router;
  });
  tearDown(() {
    http.HttpClient.instance.dio.httpClientAdapter = original;
  });
  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  test(
    'an unconfigured endpoint remains local without a router request',
    () async {
      expect(
        await CachedPowerSyncConnector().fetchCredentials(),
        isNull,
      );
      expect(router.requests, isEmpty);
    },
  );
  test(
    'router credentials preserve the endpoint and identify the installation',
    () async {
      router.body = {'token': 'router-token'};
      final credentials = await CachedPowerSyncConnector(
        endpoint: 'https://sync.test',
      ).fetchCredentials();
      expect(credentials?.endpoint, 'https://sync.test');
      expect(credentials?.token, 'router-token');
      expect(router.requests.single.path, '/api/token/powersync');
      expect(router.requests.single.headers['X-Install-Id'], 'install');
    },
  );
  test('missing router tokens and network errors leave sync offline', () async {
    expect(
      await CachedPowerSyncConnector(
        endpoint: 'https://sync.test',
      ).fetchCredentials(),
      isNull,
    );
    router.fail = true;
    expect(
      await CachedPowerSyncConnector(
        endpoint: 'https://sync.test',
      ).fetchCredentials(),
      isNull,
    );
  });
  test(
    'static versions accept only nonempty strings and fail offline softly',
    () async {
      for (final value in ['42', '', 42, null]) {
        router.body = {'version': value};
        expect(await fetchStaticVersion(), value == '42' ? '42' : null);
      }
      router.fail = true;
      expect(await fetchStaticVersion(), isNull);
    },
  );
}
