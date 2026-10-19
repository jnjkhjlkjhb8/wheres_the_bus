import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/grpc/grpc_error_interceptor.dart';

import '../../support/helpers/fake_grpc.dart';

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

List<int> _serialize(int value) => [value];
int _deserialize(List<int> values) => values.single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reports a unary failure once without changing the caller result',
    () async {
      expect(FirebaseGate.enabled, isTrue);
      expect(Firebase.apps, isEmpty);
      const channel = MethodChannel('plugins.flutter.io/firebase_crashlytics');
      const pigeon = 'dev.flutter.pigeon.firebase_core_platform_interface';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in [
        channel.name,
        '$pigeon.FirebaseCoreHostApi.initializeCore',
        '$pigeon.FirebaseCoreHostApi.initializeApp',
        '$pigeon.FirebaseCoreHostApi.optionsFromResource',
      ]) {
        expect(messenger.checkMockMessageHandler(name, null), isTrue);
      }
      final calls = <MethodCall>[];
      addTearDown(() {
        try {
          messenger.setMockMethodCallHandler(channel, null);
        } finally {
          TestFirebaseCoreHostApi.setUp(null);
        }
      });
      TestFirebaseCoreHostApi.setUp(_Core());
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'quality-test-key',
          appId: '1:1:android:grpc-error-contract',
          messagingSenderId: '1',
          projectId: 'quality-test-project',
        ),
      );
      expect(Firebase.apps, hasLength(1));

      final method = ClientMethod<int, int>(
        '/contract',
        _serialize,
        _deserialize,
      );
      final interceptor = GrpcErrorInterceptor();
      final success = interceptor.interceptUnary<int, int>(
        method,
        41,
        CallOptions(),
        (_, _, _) => FakeResponseFuture<int>(Future<int>.value(42)),
      );
      expect(await success, 42);
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);

      final completed = Completer<int>();
      final original = FakeResponseFuture<int>(completed.future);
      const failure = GrpcError.unavailable('contract unavailable');
      final response = interceptor.interceptUnary<int, int>(
        method,
        41,
        CallOptions(),
        (_, _, _) => original,
      );
      expect(response, same(original));
      final observed = expectLater(response, throwsA(same(failure)));
      completed.completeError(failure, StackTrace.current);
      await observed;
      await Future<void>.delayed(Duration.zero);

      final reports = calls.where(
        (call) => call.method == 'Crashlytics#recordError',
      );
      expect(reports, hasLength(1));
      final arguments = reports.single.arguments as Map<Object?, Object?>;
      expect(arguments['exception'], failure.toString());
      expect(arguments['fatal'], isFalse);
    },
  );
}
