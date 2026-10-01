import 'package:flutter/material.dart' show TimeOfDay;
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';

/// One departure on the timetable board.
typedef BusTimetableCell = ({String time, bool lowFloor, bool isNext});

/// A headway-operated service window ("06:00–22:00, every 15–20 min"), used by
/// routes that publish no fixed departure times.
typedef BusHeadwayWindow = ({
  String start,
  String end,
  String minMins,
  String maxMins,
});

/// What the board shows for one weekday. Both lists empty means the route does
/// not run that day.
typedef BusDayTimetable = ({
  List<BusTimetableCell> departures,
  List<BusHeadwayWindow> windows,
});

/// Weekday index used throughout the board: 0 = Monday … 6 = Sunday, matching
/// the ServiceDay bitmask the loader packs (`mask2`).
int busWeekdayIndex(DateTime date) => date.weekday - 1;

/// The weekdays the sub-route runs on. Empty when no weekly pattern was
/// published — the caller must then not present any day as "no service", since
/// only today is knowable.
Set<int> busServiceDays(List<BusServiceEntry> schedules) => {
  for (var day = 0; day < 7; day++)
    if (schedules.any((e) => e.runsOn(day))) day,
};

BusDayTimetable busTimetableForDay({
  required int weekday,
  required List<BusServiceEntry> schedules,
  required List<BusDailyTrip> todayTrips,
  required bool isToday,
  required TimeOfDay now,
}) {
  final rows = <(String, bool)>[];
  if (isToday && todayTrips.isNotEmpty) {
    for (final trip in todayTrips) {
      if (trip.stopTimes.isEmpty) continue;
      final origin = trip.stopTimes.reduce(
        (a, b) => a.stopSequence <= b.stopSequence ? a : b,
      );
      final time = origin.departureTime.isNotEmpty
          ? origin.departureTime
          : origin.arrivalTime;
      if (time.isNotEmpty) rows.add((busClockLabel(time), trip.isLowFloor));
    }
  } else {
    for (final entry in schedules) {
      if (!entry.isTimetable ||
          !entry.runsOn(weekday) ||
          entry.departureTime.isEmpty) {
        continue;
      }
      rows.add((busClockLabel(entry.departureTime), entry.isLowFloor));
    }
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  // Only today has a "next" departure; on any other day every row is equally
  // far away, so nothing is highlighted.
  final nextIndex = isToday
      ? rows.indexWhere((r) => busTimeIsUpcoming(r.$1, now))
      : -1;
  return (
    departures: [
      for (final (i, r) in rows.indexed)
        (time: r.$1, lowFloor: r.$2, isNext: i == nextIndex),
    ],
    windows: [
      for (final entry in schedules)
        if (!entry.isTimetable && entry.runsOn(weekday))
          (
            start: busClockLabel(entry.startTime),
            end: busClockLabel(entry.endTime),
            minMins: entry.minHeadwayMins,
            maxMins: entry.maxHeadwayMins,
          ),
    ],
  );
}

/// Trims a TDX clock value ("08:03:00") to its display form ("08:03").
String busClockLabel(String value) =>
    value.length >= 5 ? value.substring(0, 5) : value;

/// Whether [hhmm] has not yet passed. Returns false for unparseable values and
/// once the day's service is over, so nothing is highlighted rather than the
/// first (already departed) trip.
bool busTimeIsUpcoming(String hhmm, TimeOfDay now) {
  final parts = hhmm.split(':');
  if (parts.length < 2) return false;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return false;
  return h > now.hour || (h == now.hour && m >= now.minute);
}
