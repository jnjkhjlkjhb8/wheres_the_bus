import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

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
    pluginConstants: {},
  );
}

class _Apps implements TestFirebaseAppHostApi {
  @override
  Future<void> delete(String appName) async {}

  @override
  Future<void> setAutomaticDataCollectionEnabled(
    String appName,
    bool enabled,
  ) async {}

  @override
  Future<void> setAutomaticResourceManagementEnabled(
    String appName,
    bool enabled,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('records only errors the app does not already handle', () {
    final recorded = <Object>[];
    final original = CrashReporter.sink;
    addTearDown(() => CrashReporter.sink = original);
    CrashReporter.sink = (error, _) => recorded.add(error);

    final defect = StateError('defect');
    CrashReporter.record(const SocketException('offline'));
    CrashReporter.record(TimeoutException('slow'));
    CrashReporter.record(const GrpcError.notFound());
    CrashReporter.record(defect, StackTrace.current);

    expect(recorded, [same(defect)]);
  });

  test('disabled reporting stays silent after Firebase initializes', () async {
    expect(FirebaseGate.enabled, isFalse);
    expect(Firebase.apps, isEmpty);
    const appName = 'crash-reporter-disabled-contract';
    const channel = MethodChannel('plugins.flutter.io/firebase_crashlytics');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pigeon = 'dev.flutter.pigeon.firebase_core_platform_interface';
    for (final name in [
      channel.name,
      '$pigeon.FirebaseCoreHostApi.initializeCore',
      '$pigeon.FirebaseCoreHostApi.initializeApp',
      '$pigeon.FirebaseCoreHostApi.optionsFromResource',
      '$pigeon.FirebaseAppHostApi.delete',
      '$pigeon.FirebaseAppHostApi.setAutomaticDataCollectionEnabled',
      '$pigeon.FirebaseAppHostApi.setAutomaticResourceManagementEnabled',
    ]) {
      expect(messenger.checkMockMessageHandler(name, null), isTrue);
    }
    final calls = <MethodCall>[];
    addTearDown(() async {
      try {
        for (final app in Firebase.apps.where((app) => app.name == appName)) {
          await app.delete();
        }
      } finally {
        TestFirebaseAppHostApi.setUp(null);
        TestFirebaseCoreHostApi.setUp(null);
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    TestFirebaseCoreHostApi.setUp(_Core());
    TestFirebaseAppHostApi.setUp(_Apps());
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final app = await Firebase.initializeApp(
      name: appName,
      options: const FirebaseOptions(
        apiKey: 'quality-test-key',
        appId: 'quality-test-app',
        messagingSenderId: 'quality-test-sender',
        projectId: 'quality-test-project',
      ),
    );
    expect(Firebase.apps.map((app) => app.name), contains(appName));
    expect(FirebaseGate.enabled, isFalse);

    expect(
      () => CrashReporter.record(
        StateError('disabled control'),
        StackTrace.current,
      ),
      returnsNormally,
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      calls.where((call) => call.method == 'Crashlytics#recordError'),
      isEmpty,
    );
    await app.delete();
    expect(Firebase.apps, isEmpty);
  });
}
