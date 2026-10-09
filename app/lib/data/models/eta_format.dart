/// Shared ETA formatting for every transit mode. Two rules the app must never
/// diverge on live here: seconds always ceil to minutes, and one status-code
/// mapping owns the arrival/departure/service-state labels.
library;

import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Approved domain rule: display always rounds seconds UP to minutes (ceil),
/// never round or floor. Non-positive seconds mean "no estimate" -> 0.
int etaCeilMinutes(int seconds) => seconds > 0 ? (seconds / 60).ceil() : 0;

int etaRemainingSeconds({
  required int arrivalUnix,
  required int serverEstimateSeconds,
  required DateTime now,
}) {
  if (arrivalUnix <= 0) return serverEstimateSeconds;
  final seconds = arrivalUnix - now.millisecondsSinceEpoch ~/ 1000;
  return seconds > 0 ? seconds : 0;
}

const int busStopStatusNoReading = 67;

/// Exhaustive interpretation of a bus stop's estimate + TDX stop-status code.
enum BusStopDisplayStatus {
  arriving,
  departingSoon,
  minutes,
  notDeparted,
  trafficControl,
  lastBusPassed,
  notOperating,
  unknown,
}

/// Past this, a status-1 (not-yet-departed) predicted estimate stops reading
/// as a countdown and falls back to its scheduled clock time -- a schedule
/// guess an hour or more out ("200分") is not a claim worth counting down.
const int busStopScheduledCountdownCap = 60 * 60;

/// The one status-code mapping. stopStatus codes are TDX StopStatus values:
/// 0 = normal, 1 = not yet departed, 2 = traffic control, 3 = last bus passed,
/// 4 = not operating today.
BusStopDisplayStatus busStopDisplayStatus({
  required int estimateSeconds,
  required int stopStatus,
}) {
  if (stopStatus == 0 && estimateSeconds == 0) {
    return BusStopDisplayStatus.arriving;
  }
  if (estimateSeconds > 0 && estimateSeconds < 60) {
    return BusStopDisplayStatus.departingSoon;
  }
  if (stopStatus == 1 && estimateSeconds > busStopScheduledCountdownCap) {
    return BusStopDisplayStatus.notDeparted;
  }
  if (estimateSeconds > 0) return BusStopDisplayStatus.minutes;
  return switch (stopStatus) {
    1 => BusStopDisplayStatus.notDeparted,
    2 => BusStopDisplayStatus.trafficControl,
    3 => BusStopDisplayStatus.lastBusPassed,
    4 => BusStopDisplayStatus.notOperating,
    _ => BusStopDisplayStatus.unknown,
  };
}

/// The one display-label function. Returns the user-facing string ('2分',
/// '進站中', a clock time, or a service-state label), or null when nothing is
/// known.
String? busStopDisplayLabel({
  required AppI18n i18n,
  required int estimateSeconds,
  required int stopStatus,
  required String nextBusTime,
}) {
  // A not-yet-departed stop (status 1) is a scheduled departure: show its
  // NextBusTime clock (HH:mm) rather than the countdown derived from it.
  if (stopStatus == 1) {
    final clock = _clockLabel(nextBusTime);
    if (clock != null) return clock;
  }
  // Any positive live estimate shows the countdown; 進站中 is reserved for a
  // live bus at zero.
  if (estimateSeconds > 0) {
    return i18n.etaMinutes(etaCeilMinutes(estimateSeconds));
  }
  if (stopStatus == 0) return i18n.etaArriving;
  return _clockLabel(nextBusTime) ??
      switch (stopStatus) {
        1 => i18n.etaNotDeparted,
        2 => i18n.etaTrafficControl,
        3 => i18n.etaLastBusPassed,
        4 => i18n.etaNotOperating,
        _ => null,
      };
}

bool busStopServiceEnded(int stopStatus) => stopStatus == 3 || stopStatus == 4;

bool busStopLabelIsLive({
  required int estimateSeconds,
  required int stopStatus,
}) {
  // Status 1 is a not-yet-departed stop: its label is the scheduled NextBusTime
  // clock, even when the backend also derived a countdown from it.
  if (stopStatus == 1) return false;
  return estimateSeconds > 0 || stopStatus == 0;
}

String? _clockLabel(String value) {
  if (value.isEmpty) return null;
  final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(value);
  if (match != null) {
    final h = match.group(1)!.padLeft(2, '0');
    return '$h:${match.group(2)!}';
  }
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return _hhmm(parsed.toLocal());
  return null;
}

String _hhmm(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  return '$h:${t.minute.toString().padLeft(2, '0')}';
}
