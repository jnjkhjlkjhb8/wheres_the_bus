import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/firebase_telemetry.dart';

void main() {
  test(
    'subscription telemetry records the selected route and toggled value',
    () async {
      final events = <(String, Map<String, Object>?)>[];
      final telemetry = FirebaseTelemetry(
        enabled: true,
        logEvent: (name, parameters) async => events.add((name, parameters)),
      );
      for (final enabled in [false, true]) {
        await telemetry.favoriteRouteChanged(
          routeType: 'bus',
          routeKey: '307',
          enabled: enabled,
        );
        await telemetry.trafficAlertSubscriptionChanged(
          routeType: 'tra',
          routeKey: '408',
          enabled: enabled,
        );
        await telemetry.arrivalReminderChanged(
          routeType: 'metro',
          routeKey: 'BL',
          enabled: enabled,
          leadMinutes: 5,
        );
      }
      expect(events.map((event) => [event.$1, event.$2]).toList(), [
        [
          'favorite_route_changed',
          {'route_type': 'bus', 'route_key': '307', 'enabled': 0},
        ],
        [
          'traffic_alert_subscription_changed',
          {'route_type': 'tra', 'route_key': '408', 'enabled': 0},
        ],
        [
          'arrival_reminder_changed',
          {
            'route_type': 'metro',
            'route_key': 'BL',
            'enabled': 0,
            'lead_minutes': 5,
          },
        ],
        [
          'favorite_route_changed',
          {'route_type': 'bus', 'route_key': '307', 'enabled': 1},
        ],
        [
          'traffic_alert_subscription_changed',
          {'route_type': 'tra', 'route_key': '408', 'enabled': 1},
        ],
        [
          'arrival_reminder_changed',
          {
            'route_type': 'metro',
            'route_key': 'BL',
            'enabled': 1,
            'lead_minutes': 5,
          },
        ],
      ]);
    },
  );
}
