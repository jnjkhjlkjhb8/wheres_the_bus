import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

typedef FirebaseEventLogger =
    Future<void> Function(
      String name,
      Map<String, Object>? parameters,
    );

class FirebaseTelemetry {
  FirebaseTelemetry({
    this.enabled = FirebaseGate.enabled,
    FirebaseEventLogger? logEvent,
  }) : _logEvent = logEvent ?? _firebaseLogEvent;

  static final instance = FirebaseTelemetry();

  final bool enabled;
  final FirebaseEventLogger _logEvent;

  static Future<void> _firebaseLogEvent(
    String name,
    Map<String, Object>? parameters,
  ) => FirebaseAnalytics.instance.logEvent(
    name: name,
    parameters: parameters,
  );

  Future<void> _log(String name, [Map<String, Object>? parameters]) =>
      enabled ? _logEvent(name, parameters) : Future.value();

  Future<void> routeSearch([Map<String, Object>? parameters]) =>
      _log('route_search', parameters);

  Future<void> favoriteRouteChanged({
    required String routeType,
    required String routeKey,
    required bool enabled,
  }) => _log('favorite_route_changed', {
    'route_type': routeType,
    'route_key': routeKey,
    'enabled': enabled ? 1 : 0,
  });

  Future<void> trafficAlertSubscriptionChanged({
    required String routeType,
    required String routeKey,
    required bool enabled,
  }) => _log('traffic_alert_subscription_changed', {
    'route_type': routeType,
    'route_key': routeKey,
    'enabled': enabled ? 1 : 0,
  });

  Future<void> arrivalReminderChanged({
    required String routeType,
    required String routeKey,
    required bool enabled,
    required int leadMinutes,
  }) => _log('arrival_reminder_changed', {
    'route_type': routeType,
    'route_key': routeKey,
    'enabled': enabled ? 1 : 0,
    'lead_minutes': leadMinutes,
  });

  Future<void> notificationOpened({required String kind}) =>
      _log('notification_opened', {'kind': kind});

  Future<void> notificationReceived({
    required String kind,
    required bool foreground,
  }) => _log('notification_received', {
    'kind': kind,
    'foreground': foreground ? 1 : 0,
  });

  Future<void> notificationPermissionChanged({required bool enabled}) =>
      _log('notification_permission_changed', {'enabled': enabled ? 1 : 0});
}
