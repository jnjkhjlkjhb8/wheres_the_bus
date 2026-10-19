import 'dart:async';

import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

enum AlightEvent {
  /// The 提前提醒站 is the next stop. Only exists above 提前站數 0.
  lead,

  /// The 下車站 is the next stop.
  alight,
}

Future<void> fireAlightHaptics(
  String sessionId,
  AlightEvent event, {
  HapticService? haptics,
}) async {
  if (sessionId.isEmpty) return;
  if (!await _markAlightOnce('$sessionId:${event.name}')) return;
  await _pulse(haptics ?? HapticService.instance, event);
}

Future<bool> _markAlightOnce(String key) async {
  if (!HiveStore.settingsReady) return true;
  if (HiveStore.isAlightFired(key)) return false;
  await HiveStore.markAlightFired(key);
  return true;
}

Future<void> _pulse(HapticService haptics, AlightEvent event) async {
  switch (event) {
    case AlightEvent.lead:
      await haptics.shortAlightPulse();
    case AlightEvent.alight:
      // The long buzz owns its timer; callers need not wait for it to finish.
      haptics.longAlightPulse();
  }
}

AlightEvent? alightEventFor({
  required int? previousRemaining,
  required int remaining,
  required int lead,
}) {
  if (previousRemaining == null || previousRemaining <= remaining) return null;
  if (remaining == 1) return AlightEvent.alight;
  return _leadEvent(remaining, lead);
}

AlightEvent? _leadEvent(int remaining, int lead) =>
    lead > 0 && remaining == lead + 1 ? AlightEvent.lead : null;
