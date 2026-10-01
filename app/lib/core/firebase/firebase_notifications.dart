import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:wheres_the_bus/core/firebase/firebase_telemetry.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/firebase_options.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  await FirebaseNotifications.maybeVibrateForAlight(message.data);
  try {
    await FirebaseTelemetry.instance.notificationReceived(
      kind: FirebaseNotifications.kindFrom(message.data),
      foreground: false,
    );
  } on Object catch (_) {}
}

class FirebaseNotifications {
  FirebaseNotifications._();

  static const _alightVibrateType = 'alight_vibrate';

  static String kindFrom(Map<String, dynamic> data) {
    final kind = data['kind']?.toString();
    return kind == null || kind.isEmpty ? 'unknown' : kind;
  }

  static Future<void> maybeVibrateForAlight(Map<String, dynamic> data) async {
    if (data['type']?.toString() != _alightVibrateType) return;
    final trackId = data['track_id']?.toString() ?? '';
    final event = AlightEvent.values
        .where((e) => e.name == data['event']?.toString())
        .firstOrNull;
    if (event == null) return;
    try {
      await fireAlightHaptics(trackId, event);
    } on Object catch (_) {}
  }

  static Future<void> init() async {
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
    FirebaseMessaging.onMessage.listen(_received);
    FirebaseMessaging.onMessageOpenedApp.listen(_opened);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) await _opened(initial);
  }

  static Future<void> _received(RemoteMessage message) async {
    await maybeVibrateForAlight(message.data);
    await FirebaseTelemetry.instance.notificationReceived(
      kind: kindFrom(message.data),
      foreground: true,
    );
  }

  static Future<void> _opened(RemoteMessage message) =>
      FirebaseTelemetry.instance.notificationOpened(
        kind: kindFrom(message.data),
      );
}
