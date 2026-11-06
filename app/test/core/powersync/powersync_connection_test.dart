import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';

class _Database implements PowerSyncConnection {
  final statuses = StreamController<SyncStatus>.broadcast();
  int initializations = 0;
  int connections = 0;
  int closures = 0;
  @override
  bool connected = false;

  @override
  DateTime? lastSyncedAt;

  final synced = StreamController<DateTime?>.broadcast();

  @override
  Stream<DateTime?> get lastSyncedStream => synced.stream;
  @override
  Future<void> initialize() async {
    initializations++;
  }

  @override
  Stream<SyncStatus> get statusStream => statuses.stream;
  @override
  Future<void> connect(
    PowerSyncBackendConnector connector, {
    required Map<String, dynamic> params,
  }) async {
    connections++;
    connected = true;
  }

  @override
  Future<void> close() async {
    closures++;
    await statuses.close();
  }

  @override
  PowerSyncDatabase get database => throw UnimplementedError(
    'native database is not part of the fake connection',
  );
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql,
    List<Object?> parameters,
  ) async => [
    {'name': 'local'},
  ];
}

class _Connector extends PowerSyncBackendConnector {
  int requests = 0;
  PowerSyncCredentials? credentials;
  bool fail = false;
  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    requests++;
    if (fail) throw StateError('offline');
    return credentials;
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {}
}

void main() {
  tearDown(AppForeground.reset);
  test(
    'an empty endpoint initializes local storage without connecting',
    () async {
      final database = _Database();
      final connector = _Connector();
      final service = PowerSyncService(
        connectionFactory: () async => database,
        connectorFactory: () => connector,
      );
      await service.init();
      expect(await service.getAll('select name'), [
        {'name': 'local'},
      ]);
      expect(database.initializations, 1);
      expect(connector.requests, 0);
      await service.close();
      expect(database.closures, 1);
    },
  );

  test(
    'valid credentials connect once and foreground avoids an open connection',
    () async {
      final database = _Database();
      final connector = _Connector()
        ..credentials = PowerSyncCredentials(
          endpoint: 'https://sync.test',
          token: 'token',
        );
      final service = PowerSyncService(
        connectionFactory: () async => database,
        connectorFactory: () => connector,
        endpoint: 'https://sync.test',
      );
      await service.init();
      expect(database.connections, 1);
      AppForeground.value.value = false;
      AppForeground.value.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(connector.requests, 1);
      await service.close();
      expect(() => service.db, throwsStateError);
    },
  );

  test(
    'offline credentials keep local storage usable and resume retries',
    () async {
      final database = _Database();
      final connector = _Connector()..fail = true;
      final service = PowerSyncService(
        connectionFactory: () async => database,
        connectorFactory: () => connector,
        endpoint: 'https://sync.test',
      );
      await service.init();
      expect(await service.getAll('select name'), [
        {'name': 'local'},
      ]);
      expect(database.connections, 0);
      connector.fail = false;
      AppForeground.value.value = false;
      AppForeground.value.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(connector.requests, 2);
      expect(database.connections, 0);
      connector.credentials = PowerSyncCredentials(
        endpoint: 'https://sync.test',
        token: 'recovered',
      );
      AppForeground.value.value = false;
      AppForeground.value.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(database.connections, 1);
      await service.close();
    },
  );
}
