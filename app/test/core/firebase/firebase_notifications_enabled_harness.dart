import 'package:firebase_analytics_platform_interface/firebase_analytics_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/firebase_notifications.dart';

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

class _Messaging extends FirebaseMessagingPlatform {
  final presentations = <(bool, bool, bool)>[];

  @override
  FirebaseMessagingPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseMessagingPlatform setInitialValues({bool? isAutoInitEnabled}) => this;

  @override
  Future<void> setForegroundNotificationPresentationOptions({
    required bool alert,
    required bool badge,
    required bool sound,
  }) async {
    presentations.add((alert, badge, sound));
  }

  @override
  Future<RemoteMessage?> getInitialMessage() async =>
      const RemoteMessage(data: {'kind': 'restored_alert'});
}

class _Analytics extends FirebaseAnalyticsPlatform {
  final events = <(String, Map<String, Object?>?)>[];

  @override
  FirebaseAnalyticsPlatform delegateFor({
    required FirebaseApp app,
    Map<String, dynamic>? webOptions,
  }) => this;

  @override
  Future<void> logEvent({
    required String name,
    Map<String, Object?>? parameters,
    AnalyticsCallOptions? callOptions,
  }) async {
    events.add((name, parameters));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'first notification setup handles restored and live deliveries',
    () async {
      expect(FirebaseGate.enabled, isTrue);
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
      final originalMessaging = FirebaseMessagingPlatform.instance;
      final originalAnalytics = FirebaseAnalyticsPlatform.instance;
      final messaging = _Messaging();
      final analytics = _Analytics();
      addTearDown(() {
        try {
          TestFirebaseCoreHostApi.setUp(null);
        } finally {
          try {
            FirebaseMessagingPlatform.instance = originalMessaging;
          } finally {
            FirebaseAnalyticsPlatform.instance = originalAnalytics;
          }
        }
      });
      TestFirebaseCoreHostApi.setUp(_Core());
      FirebaseMessagingPlatform.instance = messaging;
      FirebaseAnalyticsPlatform.instance = analytics;
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'quality-test-key',
          appId: 'quality-test-app',
          messagingSenderId: 'quality-test-sender',
          projectId: 'quality-test-project',
        ),
      );
      expect(Firebase.apps.map((app) => app.name), contains('[DEFAULT]'));

      await FirebaseNotifications.init();
      expect(messaging.presentations, [(true, true, true)]);
      expect(
        analytics.events.map((event) => [event.$1, event.$2]).toList(),
        [
          [
            'notification_opened',
            {'kind': 'restored_alert'},
          ],
        ],
      );

      FirebaseMessagingPlatform.onMessage.add(
        const RemoteMessage(data: {'kind': 'live_alert'}),
      );
      FirebaseMessagingPlatform.onMessageOpenedApp.add(
        const RemoteMessage(data: {'kind': 'tapped_alert'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(analytics.events, hasLength(3));
      expect(
        analytics.events.map((event) => [event.$1, event.$2]).toList(),
        containsAll([
          [
            'notification_opened',
            {'kind': 'restored_alert'},
          ],
          [
            'notification_received',
            {'kind': 'live_alert', 'foreground': 1},
          ],
          [
            'notification_opened',
            {'kind': 'tapped_alert'},
          ],
        ]),
      );
    },
  );
}
