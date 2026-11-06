import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';

class _Core extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async => [];

  @override
  Future<CoreInitializeResponse> initializeApp(
    String name,
    CoreFirebaseOptions options,
  ) async => CoreInitializeResponse(
    name: name,
    options: options,
    pluginConstants: {
      'plugins.flutter.io/firebase_crashlytics': {
        'isCrashlyticsCollectionEnabled': true,
      },
    },
  );
}

class _Connection implements PowerSyncConnection {
  final statuses = StreamController<SyncStatus>.broadcast();
  Object? error;
  StackTrace? stack;
  int attempts = 0;

  @override
  bool connected = false;

  @override
  DateTime? lastSyncedAt;

  final synced = StreamController<DateTime?>.broadcast();

  @override
  Stream<DateTime?> get lastSyncedStream => synced.stream;

  @override
  PowerSyncDatabase get database => throw UnimplementedError();

  @override
  Stream<SyncStatus> get statusStream => statuses.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> connect(
    PowerSyncBackendConnector connector, {
    required Map<String, dynamic> params,
  }) async {
    attempts++;
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
    connected = true;
  }

  @override
  Future<void> close() async {
    connected = false;
  }

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql,
    List<Object?> parameters,
  ) async => [
    {'name': 'offline row'},
  ];
}

class _Connector extends PowerSyncBackendConnector {
  Object? error;
  StackTrace? stack;
  int requests = 0;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    requests++;
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
    return PowerSyncCredentials(
      endpoint: 'https://sync.test',
      token: 'recovered',
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline startup reports the original sync failure and resume recovers',
    () async {
      expect(FirebaseGate.enabled, isTrue);
      expect(Firebase.apps, isEmpty);
      expect(AppForeground.value.value, isTrue);
      const channel = MethodChannel('plugins.flutter.io/firebase_crashlytics');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const coreChannelPrefix =
          'dev.flutter.pigeon.firebase_core_platform_interface.'
          'FirebaseCoreHostApi.';
      for (final name in [
        channel.name,
        '${coreChannelPrefix}initializeCore',
        '${coreChannelPrefix}initializeApp',
        '${coreChannelPrefix}optionsFromResource',
      ]) {
        expect(messenger.checkMockMessageHandler(name, null), isTrue);
      }
      final calls = <MethodCall>[];
      TestFirebaseCoreHostApi.setUp(_Core());
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      try {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: 'quality-test-key',
            appId: 'quality-test-app',
            messagingSenderId: 'quality-test-sender',
            projectId: 'quality-test-project',
          ),
        );
        expect(Firebase.apps, hasLength(1));
        for (final source in ['credentials', 'connection']) {
          final failure = StateError('$source unavailable');
          final stack = StackTrace.fromString(
            '#0 ${source}Failure (package:bus_test/powersync_error.dart:10:3)',
          );
          final connection = _Connection();
          final connector = _Connector();
          if (source == 'credentials') {
            connector
              ..error = failure
              ..stack = stack;
          } else {
            connection
              ..error = failure
              ..stack = stack;
          }
          final service = PowerSyncService(
            connectionFactory: () async => connection,
            connectorFactory: () => connector,
            endpoint: 'https://sync.test',
          );
          calls.clear();
          try {
            await service.init();
            expect(connection.connected, isFalse);
            expect(await service.getAll('select name'), [
              {'name': 'offline row'},
            ]);
            await Future<void>.delayed(Duration.zero);
            final recorded = calls
                .where((call) => call.method == 'Crashlytics#recordError')
                .toList();
            expect(recorded, hasLength(1));
            final payload = recorded.single.arguments as Map<Object?, Object?>;
            expect(payload['exception'], failure.toString());
            expect(payload['fatal'], isFalse);
            expect(
              payload['stackTraceElements'],
              contains(
                isA<Map<Object?, Object?>>().having(
                  (frame) => frame['method'],
                  'method',
                  '${source}Failure',
                ),
              ),
            );
            connector.error = null;
            connection.error = null;
            AppForeground.value.value = false;
            AppForeground.value.value = true;
            await Future<void>.delayed(Duration.zero);
            expect(connection.connected, isTrue);
            expect(connector.requests, 2);
            expect(connection.attempts, source == 'credentials' ? 1 : 2);
            expect(
              calls.where((call) => call.method == 'Crashlytics#recordError'),
              hasLength(1),
            );
          } finally {
            try {
              await service.close();
            } finally {
              try {
                await connection.statuses.close();
              } finally {
                AppForeground.reset();
              }
            }
          }
        }
      } finally {
        TestFirebaseCoreHostApi.setUp(null);
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
