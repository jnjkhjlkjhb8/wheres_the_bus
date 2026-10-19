import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/firebase_notifications.dart';
import 'package:wheres_the_bus/firebase_options.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('background delivery initializes the missing Firebase app', () async {
    expect(FirebaseGate.enabled, isFalse);
    expect(Firebase.apps, isEmpty);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pigeon = 'dev.flutter.pigeon.firebase_core_platform_interface';
    for (final name in [
      '$pigeon.FirebaseCoreHostApi.initializeCore',
      '$pigeon.FirebaseCoreHostApi.initializeApp',
      '$pigeon.FirebaseCoreHostApi.optionsFromResource',
    ]) {
      expect(messenger.checkMockMessageHandler(name, null), isTrue);
    }
    final originalPlatform = debugDefaultTargetPlatformOverride;
    addTearDown(() {
      try {
        TestFirebaseCoreHostApi.setUp(null);
      } finally {
        debugDefaultTargetPlatformOverride = originalPlatform;
      }
    });
    TestFirebaseCoreHostApi.setUp(_Core());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await firebaseMessagingBackgroundHandler(
      const RemoteMessage(data: {'kind': 'background_contract'}),
    );

    expect(Firebase.apps.map((app) => app.name), contains('[DEFAULT]'));
    expect(Firebase.app().options.appId, DefaultFirebaseOptions.android.appId);
    expect(
      Firebase.app().options.projectId,
      DefaultFirebaseOptions.android.projectId,
    );
  });
}
