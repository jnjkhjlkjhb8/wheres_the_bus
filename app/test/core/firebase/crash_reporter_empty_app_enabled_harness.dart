import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('enabled reporting stays silent until an app exists', () async {
    expect(FirebaseGate.enabled, isTrue);
    expect(Firebase.apps, isEmpty);
    const channel = MethodChannel('plugins.flutter.io/firebase_crashlytics');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    expect(messenger.checkMockMessageHandler(channel.name, null), isTrue);
    final calls = <MethodCall>[];
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    expect(
      () => CrashReporter.record(
        StateError('startup control'),
        StackTrace.current,
      ),
      returnsNormally,
    );
    await Future<void>.delayed(Duration.zero);

    expect(Firebase.apps, isEmpty);
    expect(
      calls.where((call) => call.method == 'Crashlytics#recordError'),
      isEmpty,
    );
  });
}
