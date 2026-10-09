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
  final key = '$sessionId:${event.name}';
  if (HiveStore.settingsReady && HiveStore.isAlightFired(key)) return;
  if (HiveStore.settingsReady) await HiveStore.markAlightFired(key);
  final h = haptics ?? HapticService.instance;
  switch (event) {
    case AlightEvent.lead:
      await h.shortAlightPulse();
    case AlightEvent.alight:
      // Fire-and-forget: the long buzz runs on its own timer for 1.6 s and
      // nothing downstream waits on it finishing.
      h.longAlightPulse();
  }
}

AlightEvent? alightEventFor({
  required int? previousRemaining,
  required int remaining,
  required int lead,
}) {
  if (previousRemaining == null || previousRemaining <= remaining) return null;
  if (remaining == 1) return AlightEvent.alight;
  if (lead > 0 && remaining == lead + 1) return AlightEvent.lead;
  return null;
}
