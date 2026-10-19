import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';

class _Connection implements PowerSyncConnection {
  final statuses = StreamController<SyncStatus>.broadcast();
  final queries = <(String, List<Object?>)>[];
  Completer<void>? initialization;
  Object? initializationError;
  Object? connectionError;
  int initializations = 0;
  int connections = 0;
  int closures = 0;
  PowerSyncBackendConnector? lastConnector;

  @override
  bool connected = false;

  @override
  PowerSyncDatabase get database => throw UnimplementedError();

  @override
  Stream<SyncStatus> get statusStream => statuses.stream;

  @override
  Future<void> initialize() async {
    initializations++;
    await initialization?.future;
    final error = initializationError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }

  @override
  Future<void> connect(PowerSyncBackendConnector connector) async {
    connections++;
    lastConnector = connector;
    final error = connectionError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    connected = true;
  }

  @override
  Future<void> close() async {
    closures++;
    connected = false;
  }

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql,
    List<Object?> parameters,
  ) async {
    queries.add((sql, List<Object?>.of(parameters)));
    return [
      {'name': 'local'},
    ];
  }
}

class _Connector extends PowerSyncBackendConnector {
  PowerSyncCredentials? credentials;
  Error? error;
  int requests = 0;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    requests++;
    final failure = error;
    if (failure != null) throw failure;
    return credentials;
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {}
}

PowerSyncCredentials _credentials(String token) => PowerSyncCredentials(
  endpoint: 'https://sync.test',
  token: token,
);

String _expiringToken(DateTime time) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
  final payload = base64Url.encode(
    utf8.encode('{"exp":${time.millisecondsSinceEpoch ~/ 1000}}'),
  );
  return '$header.$payload.signature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    expect(AppForeground.value.value, isTrue);
  });
  tearDown(AppForeground.reset);

  test('query access waits for initialization to finish', () async {
    final connection = _Connection();
    final ready = Completer<void>();
    connection.initialization = ready;
    final service = PowerSyncService(
      connectionFactory: () async => connection,
    );
    final startup = service.init()..ignore();
    try {
      await Future<void>.delayed(Duration.zero);
      expect(() => service.db, throwsStateError);
      await expectLater(service.getAll('select name'), throwsStateError);
      expect(connection.initializations, 1);
      expect(service.init(), same(startup));
      ready.complete();
      await startup;
      expect(await service.getAll('select name where id = ?', [7]), [
        {'name': 'local'},
      ]);
      expect(connection.queries, hasLength(1));
      expect(connection.queries.single.$1, 'select name where id = ?');
      expect(connection.queries.single.$2, [7]);
    } finally {
      if (!ready.isCompleted) ready.complete();
      try {
        await startup;
      } finally {
        try {
          await service.close();
        } finally {
          await connection.statuses.close();
        }
      }
    }
  });

  test(
    'failed initialization preserves the error and permits a fresh retry',
    () async {
      final failure = StateError('storage unavailable');
      final failed = _Connection()..initializationError = failure;
      final recovered = _Connection();
      var factories = 0;
      final service = PowerSyncService(
        connectionFactory: () async => factories++ == 0 ? failed : recovered,
      );
      try {
        await expectLater(service.init(), throwsA(same(failure)));
        expect(() => service.db, throwsStateError);
        await service.init();
        expect(factories, 2);
        expect(recovered.initializations, 1);
        expect(await service.getAll('select name'), [
          {'name': 'local'},
        ]);
      } finally {
        try {
          await service.close();
        } finally {
          await Future.wait([
            failed.statuses.close(),
            recovered.statuses.close(),
          ]);
        }
      }
    },
  );

  test(
    'background transitions do not fetch and each resume retries offline sync',
    () async {
      final connection = _Connection();
      final connector = _Connector();
      final service = PowerSyncService(
        connectionFactory: () async => connection,
        connectorFactory: () => connector,
        endpoint: 'https://sync.test',
      );
      try {
        await service.init();
        expect(connector.requests, 1);
        AppForeground.value.value = false;
        await Future<void>.delayed(Duration.zero);
        expect(connector.requests, 1);
        AppForeground.value.value = true;
        await Future<void>.delayed(Duration.zero);
        expect(connector.requests, 2);
        expect(connection.connections, 0);
        connector.credentials = _credentials('resumed');
        AppForeground.value.value = false;
        AppForeground.value.value = true;
        await Future<void>.delayed(Duration.zero);
        expect(connector.requests, 3);
        expect(connection.connections, 1);
        expect(connection.lastConnector, same(connector));
      } finally {
        try {
          await service.close();
        } finally {
          await connection.statuses.close();
        }
      }
    },
  );

  test(
    'connection failure stays local and a later resume reconnects',
    () async {
      final connection = _Connection()
        ..connectionError = StateError('sync unavailable');
      final connector = _Connector()..credentials = _credentials('retry');
      final service = PowerSyncService(
        connectionFactory: () async => connection,
        connectorFactory: () => connector,
        endpoint: 'https://sync.test',
      );
      final originalPrint = debugPrint;
      final messages = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      try {
        await service.init();
        expect(connection.connected, isFalse);
        expect(await service.getAll('select name'), [
          {'name': 'local'},
        ]);
        expect(
          messages.any(
            (message) =>
                message.contains('[PowerSync]') &&
                message.contains('running offline'),
          ),
          isTrue,
        );
        connection.connectionError = null;
        AppForeground.value.value = false;
        AppForeground.value.value = true;
        await Future<void>.delayed(Duration.zero);
        expect(connection.connected, isTrue);
        expect(connection.connections, 2);
        expect(connector.requests, 2);
      } finally {
        try {
          await service.close();
        } finally {
          debugPrint = originalPrint;
          await connection.statuses.close();
        }
      }
    },
  );

  test(
    'close removes foreground ownership and initialization can reopen storage',
    () async {
      final first = _Connection();
      final second = _Connection();
      final connector = _Connector();
      var factories = 0;
      final service = PowerSyncService(
        connectionFactory: () async => factories++ == 0 ? first : second,
        connectorFactory: () => connector,
        endpoint: 'https://sync.test',
      );
      try {
        await service.init();
        await service.close();
        expect(first.closures, 1);
        expect(() => service.db, throwsStateError);
        AppForeground.value.value = false;
        AppForeground.value.value = true;
        await Future<void>.delayed(Duration.zero);
        expect(connector.requests, 1);
        await service.init();
        expect(factories, 2);
        expect(second.initializations, 1);
        expect(connector.requests, 2);
        AppForeground.value.value = false;
        AppForeground.value.value = true;
        await Future<void>.delayed(Duration.zero);
        expect(connector.requests, 3);
        expect(await service.getAll('select name'), [
          {'name': 'local'},
        ]);
        await service.close();
        await service.close();
        expect(second.closures, 1);
      } finally {
        try {
          await service.close();
        } finally {
          await Future.wait([first.statuses.close(), second.statuses.close()]);
        }
      }
    },
  );

  test(
    'the default database lives in application documents '
    'and exposes transit tables',
    () async {
      final storage = await Directory.systemTemp.createTemp(
        'powersync-service-documents-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      if (!messenger.checkMockMessageHandler(channel.name, null)) {
        await storage.delete(recursive: true);
        fail('The test must own the path-provider channel');
      }
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'getApplicationDocumentsDirectory') {
          return storage.path;
        }
        throw MissingPluginException(call.method);
      });
      final service = PowerSyncService();
      try {
        expect(service.lastSyncedAt, isNull);
        await service.init();
        final database = await service.readyDb;
        expect(database, same(service.db));
        expect(database.connected, isFalse);
        expect(calls, ['getApplicationDocumentsDirectory']);
        expect(File('${storage.path}/bus_local.db').existsSync(), isTrue);
        expect(
          await service.getAll(
            'SELECT from_station_id, to_station_id, system, fare_nt, '
            'half_fare_nt, travel_time_min FROM mrt_journey_matrix',
          ),
          isEmpty,
        );
        expect(
          await service.getAll(
            'SELECT station_id, lineid, destinationstaionid, serviceday, '
            'system, first_train_time, last_train_time FROM mrt_schedule',
          ),
          isEmpty,
        );
        await Future<void>.delayed(Duration.zero);
        expect(service.lastSyncedAt, isNull);
        await service.close();
        expect(service.lastSyncedAt, isNull);
      } finally {
        try {
          await service.close();
        } finally {
          messenger.setMockMethodCallHandler(channel, null);
          await storage.delete(recursive: true);
        }
      }
    },
  );

  test('freshness status ownership starts at init and ends at close', () async {
    final storage = await Directory.systemTemp.createTemp(
      'powersync-status-source-',
    );
    final native = PowerSyncDatabase(
      schema: const Schema([]),
      path: '${storage.path}/local.db',
    );
    final connection = _Connection();
    final service = PowerSyncService(
      connectionFactory: () async => connection,
    );
    try {
      await native.initialize();
      final status = native.currentStatus;
      expect(status.lastSyncedAt, isNull);
      expect(connection.statuses.hasListener, isFalse);
      expect(service.lastSyncedAt, isNull);
      await service.init();
      expect(connection.statuses.hasListener, isTrue);
      connection.statuses.add(status);
      await Future<void>.delayed(Duration.zero);
      expect(service.lastSyncedAt, isNull);
      await service.close();
      expect(connection.statuses.hasListener, isFalse);
      connection.statuses.add(status);
      await Future<void>.delayed(Duration.zero);
      expect(service.lastSyncedAt, isNull);
    } finally {
      try {
        await service.close();
      } finally {
        try {
          await connection.statuses.close();
        } finally {
          try {
            await native.close();
          } finally {
            await storage.delete(recursive: true);
          }
        }
      }
    }
  });

  test('cached credentials refresh exactly one minute before expiry', () async {
    final expiry = DateTime.utc(2026, 10, 11, 12, 3);
    var now = expiry.subtract(const Duration(minutes: 2));
    var requests = 0;
    final connector = CachedPowerSyncConnector(
      clock: () => now,
      fetch: () async {
        requests++;
        return _credentials(_expiringToken(expiry));
      },
    );
    final first = await connector.fetchCredentials();
    expect(first?.token, _expiringToken(expiry));
    now = expiry.subtract(const Duration(minutes: 1, milliseconds: 1));
    expect(await connector.fetchCredentials(), same(first));
    expect(requests, 1);
    now = expiry.subtract(const Duration(minutes: 1));
    expect(await connector.fetchCredentials(), isNot(same(first)));
    expect(requests, 2);
  });

  test(
    'failed concurrent refresh preserves its error and later calls retry',
    () async {
      final release = Completer<PowerSyncCredentials?>();
      final failure = StateError('router unavailable');
      var requests = 0;
      final recovered = _credentials(_expiringToken(DateTime.utc(2100)));
      final connector = CachedPowerSyncConnector(
        fetch: () async {
          requests++;
          if (requests == 1) return release.future;
          return recovered;
        },
      );
      final first = connector.fetchCredentials();
      final second = connector.fetchCredentials();
      final firstCheck = expectLater(first, throwsA(same(failure)));
      final secondCheck = expectLater(second, throwsA(same(failure)));
      final observed = Future.wait<void>([firstCheck, secondCheck])..ignore();
      try {
        expect(requests, 1);
        release.completeError(failure);
        await observed;
        expect(await connector.fetchCredentials(), same(recovered));
        expect(await connector.fetchCredentials(), same(recovered));
        expect(requests, 2);
      } finally {
        if (!release.isCompleted) release.completeError(failure);
        await observed;
      }
    },
  );
}
