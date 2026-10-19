import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

class TestFirebaseCrashRecorder {
  static const _channel = MethodChannel(
    'plugins.flutter.io/firebase_crashlytics',
  );

  final _calls = <MethodCall>[];
  bool _installed = false;

  List<MethodCall> get errors => _calls
      .where((call) => call.method == 'Crashlytics#recordError')
      .toList(growable: false);

  int get errorCount => errors.length;

  Future<void> install() async {
    if (!FirebaseGate.enabled) return;
    TestFirebaseCoreHostApi.setUp(_Core());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          _calls.add(call);
          if (call.method == 'Crashlytics#setCrashlyticsCollectionEnabled') {
            return {'isCrashlyticsCollectionEnabled': true};
          }
          return null;
        });
    _installed = true;
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'quality-test-key',
        appId: 'quality-test-app',
        messagingSenderId: 'quality-test-sender',
        projectId: 'quality-test-project',
      ),
    );
  }

  void clear() => _calls.clear();

  void dispose() {
    if (!_installed) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    TestFirebaseCoreHostApi.setUp(null);
    _installed = false;
  }
}

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
