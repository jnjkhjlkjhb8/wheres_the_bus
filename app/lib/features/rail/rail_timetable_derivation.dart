/// Rail timetable display derivation.
library;

import 'package:flutter/widgets.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';

/// Scales a fixed column width with the system text size, so the slots still
/// fit their digits at a large text size instead of clipping the figures they
/// were sized around.
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
  final date = _dateParts(serviceDate);
  final clock = _clockParts(time);
  if (date == null || clock == null) return null;
  return DateTime(date.year, date.month, date.day, clock.hour, clock.minute);
}

({int year, int month, int day})? _dateParts(String date) {
  final parts = date.split('-');
  if (parts.length != 3) return null;
  return _parsedDate(parts);
}

({int year, int month, int day})? _parsedDate(List<String> parts) {
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return (year: year, month: month, day: day);
}

({int hour, int minute})? _clockParts(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return (hour: hour, minute: minute);
}

int? railPositionIndex(
  List<RailTrainStop> stops,
  String serviceDate,
  int delayMinutes,
  DateTime now,
) {
  if (stops.isEmpty) return null;
  final reached = _reachedStops(stops, serviceDate, delayMinutes, now);
  return _intermediatePosition(reached, stops.length);
}

int? _reachedStops(
  List<RailTrainStop> stops,
  String serviceDate,
  int delayMinutes,
  DateTime now,
) {
  final delay = Duration(minutes: delayMinutes);
  var reached = 0;
  for (final stop in stops) {
    final scheduled = stopDateTime(serviceDate, stop);
    if (scheduled == null) return null;
    if (!scheduled.add(delay).isAfter(now)) reached++;
  }
  return reached;
}

int? _intermediatePosition(int? reached, int stops) {
  if (reached == null) return null;
  return reached > 0 && reached < stops ? reached - 1 : null;
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
  final arrival = _dwellClockMinutes(stop.arrive);
  final departure = _dwellClockMinutes(stop.depart);
  if (arrival == null || departure == null) return 0;
  final difference = departure - arrival;
  return difference > 0 ? difference : 0;
}

int? _dwellClockMinutes(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return null;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}
