/// Rail timetable display derivation.
library;

import 'package:flutter/widgets.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';

/// Scales a fixed column width with the user's text size, so the slots still
/// fit their digits in the app's large-text mode instead of clipping the
/// figures they were sized around.
double scaledWidth(BuildContext context, double base) =>
    MediaQuery.textScalerOf(context).scale(base);

String normalizeStationName(String name) => name.trim().replaceAll('臺', '台');

bool sameStation(String a, String b) =>
    normalizeStationName(a) == normalizeStationName(b);

/// Trims the backend's `HH:mm:ss.ffffff` time strings down to `HH:mm`.
String hhmm(String t) => t.length >= 5 ? t.substring(0, 5) : t;

/// The stop's scheduled arrival (falling back to departure) as a local DateTime
/// on [serviceDate] (`yyyy-MM-dd`), or null when it can't be parsed.
DateTime? stopDateTime(String serviceDate, RailTrainStop stop) {
  final time = stop.arrive.isNotEmpty ? stop.arrive : stop.depart;
  final d = serviceDate.split('-');
  final hm = time.split(':');
  if (d.length != 3 || hm.length < 2) return null;
  final year = int.tryParse(d[0]);
  final month = int.tryParse(d[1]);
  final day = int.tryParse(d[2]);
  final hour = int.tryParse(hm[0]);
  final minute = int.tryParse(hm[1]);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null) {
    return null;
  }
  return DateTime(year, month, day, hour, minute);
}

int? railPositionIndex(
  List<RailTrainStop> stops,
  String serviceDate,
  int delayMinutes,
  DateTime now,
) {
  if (stops.isEmpty) return null;
  final delay = Duration(minutes: delayMinutes);
  var reached = 0;
  for (final stop in stops) {
    final scheduled = stopDateTime(serviceDate, stop);
    if (scheduled == null) return null;
    if (!scheduled.add(delay).isAfter(now)) reached++;
  }
  if (reached == 0 || reached >= stops.length) return null;
  return reached - 1;
}

/// Whole minutes from [from] to [to] along the run, or null when either time
/// can't be parsed or the pair is out of order.
int? elapsedMinutes(String serviceDate, RailTrainStop from, RailTrainStop to) {
  final start = stopDateTime(serviceDate, from);
  final end = stopDateTime(serviceDate, to);
  if (start == null || end == null) return null;
  final minutes = end.difference(start).inMinutes;
  return minutes < 0 ? null : minutes;
}

int dwellMinutes(RailTrainStop stop) {
  if (stop.arrive.isEmpty || stop.depart.isEmpty) return 0;
  final a = stop.arrive.split(':');
  final d = stop.depart.split(':');
  if (a.length < 2 || d.length < 2) return 0;
  final am = (int.tryParse(a[0]) ?? 0) * 60 + (int.tryParse(a[1]) ?? 0);
  final dm = (int.tryParse(d[0]) ?? 0) * 60 + (int.tryParse(d[1]) ?? 0);
  final diff = dm - am;
  return diff > 0 ? diff : 0;
}
