part of '../view/bus_route_screen.dart';

const List<FontFeature> _tnum = AppTextStyles.tabularFigures;

typedef _DepartureInfo = ({String time, bool isNext});

// Memoize the timeline-stop derivation per state instance so both eta-scoped
// selectors (timeline + stop list) share one computation instead of rebuilding
// the list once per widget rebuild.
final Expando<List<TimelineStop>> _stopsCache = Expando('busRouteStops');

List<TimelineStop> _stopsFor(AppI18n i18n, BusRouteState s) {
  final cached = _stopsCache[s];
  if (cached != null) return cached;
  final stops = s.direction == 0 ? s.route?.stopsGo : s.route?.stopsReturn;
  final derived = stops == null
      ? const <TimelineStop>[]
      : deriveTimelineStops(
          i18n: i18n,
          stops: stops,
          etaMap: s.etaMap,
          direction: s.direction,
          bufferSequences: s.bufferSequences,
          pricingType: s.fare?.pricingType ?? 0,
        );
  _stopsCache[s] = derived;
  return derived;
}

const int _dtDepartureWindow = 12;

List<_DepartureInfo> _departuresFor(BusRouteState state) {
  final trips =
      state.daily?.tripsForDirection(state.direction) ?? const <BusDailyTrip>[];
  final now = TimeOfDay.now();
  final rows = <String>[];
  for (final trip in trips) {
    if (trip.stopTimes.isEmpty) continue;
    final first = trip.stopTimes.reduce(
      (a, b) => a.stopSequence <= b.stopSequence ? a : b,
    );
    final time = first.departureTime.isNotEmpty
        ? first.departureTime
        : first.arrivalTime;
    if (time.isNotEmpty) rows.add(busClockLabel(time));
  }
  rows.sort();
  final nextIndex = rows.indexWhere((t) => busTimeIsUpcoming(t, now));
  if (nextIndex < 0) {
    // Service is over for the day: nothing to highlight (see _isUpcoming), so
    // the window has no anchor to sit around — show the whole day's schedule.
    return [for (final time in rows) (time: time, isNext: false)];
  }
  // Keep one past departure for context, then fill forward from "next".
  final start = nextIndex > 0 ? nextIndex - 1 : 0;
  final end = start + _dtDepartureWindow < rows.length
      ? start + _dtDepartureWindow
      : rows.length;
  return [
    for (final (i, time) in rows.sublist(start, end).indexed)
      (time: time, isNext: start + i == nextIndex),
  ];
}

/// Headsign for the current direction, shown once above the timetable board.
String _headsignFor(BusRouteState state) => state.currentHeadsign.isNotEmpty
    ? state.currentHeadsign
    : (state.currentStops.isEmpty ? '-' : state.currentStops.last.stopName);

/// Weekly service pattern for the direction on screen.
List<BusServiceEntry> _schedulesFor(BusRouteState state) => state.direction == 0
    ? (state.route?.schedulesGo ?? const [])
    : (state.route?.schedulesReturn ?? const []);

BusDayTimetable _timetableFor(BusRouteState state, int weekday) =>
    busTimetableForDay(
      weekday: weekday,
      schedules: _schedulesFor(state),
      todayTrips:
          state.daily?.tripsForDirection(state.direction) ??
          const <BusDailyTrip>[],
      isToday: weekday == busWeekdayIndex(DateTime.now()),
      now: TimeOfDay.now(),
    );

// Built per call rather than held in a const map: the names follow the
// rider's language.
List<String> _dtWeekdayLabels(AppI18n i18n) => [
  i18n.weekdayMon,
  i18n.weekdayTue,
  i18n.weekdayWed,
  i18n.weekdayThu,
  i18n.weekdayFri,
  i18n.weekdaySat,
  i18n.weekdaySun,
];

String _farePricingTypeLabel(
  AppI18n i18n,
  int type, {
  bool hasFareRange = false,
}) {
  if (hasFareRange) return i18n.busFareByOd;
  return switch (type) {
    0 => i18n.busFareUnknownType,
    1 => i18n.busFareFlat,
    2 => i18n.busFareTwoSection,
    3 => i18n.busFareByDistance,
    _ => i18n.busFareOtherType(type),
  };
}

String _dtCityLabel(AppI18n i18n, String city) =>
    <String, String>{
      'Taipei': i18n.cityTaipei,
      'NewTaipei': i18n.cityNewTaipei,
      'Taoyuan': i18n.cityTaoyuan,
      'Taichung': i18n.cityTaichung,
      'Tainan': i18n.cityTainan,
      'Kaohsiung': i18n.cityKaohsiung,
      'Keelung': i18n.cityKeelung,
      'Hsinchu': i18n.cityHsinchuCity,
      'HsinchuCounty': i18n.cityHsinchuCounty,
      'MiaoliCounty': i18n.cityMiaoli,
      'ChanghuaCounty': i18n.cityChanghua,
      'NantouCounty': i18n.cityNantou,
      'YunlinCounty': i18n.cityYunlin,
      'ChiayiCounty': i18n.cityChiayiCounty,
      'Chiayi': i18n.cityChiayiCity,
      'PingtungCounty': i18n.cityPingtung,
      'YilanCounty': i18n.cityYilan,
      'HualienCounty': i18n.cityHualien,
      'TaitungCounty': i18n.cityTaitung,
      'PenghuCounty': i18n.cityPenghu,
      'KinmenCounty': i18n.cityKinmen,
      'LienchiangCounty': i18n.cityLienchiang,
      'InterCity': i18n.cityInterCity,
      'Miaoli': i18n.cityMiaoli,
      'Changhua': i18n.cityChanghua,
      'Nantou': i18n.cityNantou,
      'Yunlin': i18n.cityYunlin,
      'Pingtung': i18n.cityPingtung,
      'Yilan': i18n.cityYilan,
      'Hualien': i18n.cityHualien,
      'Taitung': i18n.cityTaitung,
      'Penghu': i18n.cityPenghu,
      'Kinmen': i18n.cityKinmen,
      'Lienchiang': i18n.cityLienchiang,
    }[city] ??
    city;
