import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';

String tokenExpiringAt(DateTime time) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
  final payload = base64Url.encode(
    utf8.encode('{"exp":${time.millisecondsSinceEpoch ~/ 1000}}'),
  );
  return '$header.$payload.signature';
}

void main() {
  test('returns cached credentials after the first fetch', () async {
    var calls = 0;
    final connector = CachedPowerSyncConnector(
      fetch: () async {
        calls++;
        return PowerSyncCredentials(
          endpoint: 'https://sync.test',
          token: tokenExpiringAt(DateTime(2100)),
        );
      },
    );

    await connector.fetchCredentials();
    await connector.fetchCredentials();

    expect(calls, 1);
  });

  test('shares a concurrent credential refresh', () async {
    var calls = 0;
    final connector = CachedPowerSyncConnector(
      fetch: () async {
        calls++;
        await Future<void>.delayed(Duration.zero);
        return PowerSyncCredentials(
          endpoint: 'https://sync.test',
          token: tokenExpiringAt(DateTime(2100)),
        );
      },
    );

    await Future.wait([
      connector.fetchCredentials(),
      connector.fetchCredentials(),
    ]);

    expect(calls, 1);
  });

  test('refreshes credentials before the JWT expires', () async {
    var now = DateTime(2026, 7, 10, 12);
    var calls = 0;
    final connector = CachedPowerSyncConnector(
      clock: () => now,
      fetch: () async {
        calls++;
        return PowerSyncCredentials(
          endpoint: 'https://sync.test',
          token: tokenExpiringAt(now.add(const Duration(minutes: 2))),
        );
      },
    );

    await connector.fetchCredentials();
    now = now.add(const Duration(minutes: 2));
    await connector.fetchCredentials();

    expect(calls, 2);
  });
  test('missing or malformed JWT expiry is never cached', () async {
    final malformed = [
      'invalid',
      'a.!.c',
      'a.${base64Url.encode(utf8.encode('[]'))}.c',
      'a.${base64Url.encode(utf8.encode('{"exp":"later"}'))}.c',
    ];
    for (final token in malformed) {
      var requests = 0;
      final connector = CachedPowerSyncConnector(
        fetch: () async {
          requests++;
          return PowerSyncCredentials(
            endpoint: 'https://sync.test',
            token: token,
          );
        },
      );
      await connector.fetchCredentials();
      await connector.fetchCredentials();
      expect(requests, 2, reason: token);
    }
    var missing = 0;
    final connector = CachedPowerSyncConnector(
      fetch: () async {
        missing++;
        return null;
      },
    );
    await connector.fetchCredentials();
    await connector.fetchCredentials();
    expect(missing, 2);
  });
}
