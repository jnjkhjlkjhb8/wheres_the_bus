import 'package:equatable/equatable.dart';

/// Validated bus daily timetable, keyed by direction (0 = go, 1 = return).
/// Mirrors only the fields the route screen reads from the proto.
class BusDailyTimetable extends Equatable {
  const BusDailyTimetable({this.directions = const {}});

  final Map<int, List<BusDailyTrip>> directions;

  List<BusDailyTrip> tripsForDirection(int direction) =>
      directions[direction] ?? const [];

  @override
  List<Object?> get props => [directions];
}

class BusDailyTrip extends Equatable {
  const BusDailyTrip({
    required this.tripId,
    required this.isLowFloor,
    required this.stopTimes,
  });

  final String tripId;
  final bool isLowFloor;
  final List<BusStopTime> stopTimes;

  @override
  List<Object?> get props => [tripId, isLowFloor, stopTimes];
}

class BusStopTime extends Equatable {
  const BusStopTime({
    required this.stopSequence,
    required this.departureTime,
    required this.arrivalTime,
  });

  final int stopSequence;
  final String departureTime;
  final String arrivalTime;

  @override
  List<Object?> get props => [stopSequence, departureTime, arrivalTime];
}

class BusServiceEntry extends Equatable {
  const BusServiceEntry({
    required this.isTimetable,
    required this.serviceDay,
    this.tripId = '',
    this.isLowFloor = false,
    this.departureTime = '',
    this.startTime = '',
    this.endTime = '',
    this.minHeadwayMins = '',
    this.maxHeadwayMins = '',
  });

  final bool isTimetable;

  /// Weekday bitmask, bit 0 = Monday … bit 6 = Sunday (server-side `mask2`).
  final int serviceDay;
  final String tripId;
  final bool isLowFloor;

  /// Origin departure clock time, fixed-timetable entries only.
  final String departureTime;

  /// Window bounds and headway range, headway entries only.
  final String startTime;
  final String endTime;
  final String minHeadwayMins;
  final String maxHeadwayMins;

  /// Whether this entry runs on [weekday], where 0 = Monday … 6 = Sunday.
  bool runsOn(int weekday) => serviceDay & (1 << weekday) != 0;

  @override
  List<Object?> get props => [
    isTimetable,
    serviceDay,
    tripId,
    isLowFloor,
    departureTime,
    startTime,
    endTime,
    minHeadwayMins,
    maxHeadwayMins,
  ];
}

/// Validated fare info. The JSON payloads stay as raw bytes because the UI
/// decodes them lazily (fare_decoder: decodeBufferSequences / decodeFareTable);
/// the seam only guarantees they no longer arrive as a proto type.
class BusFareInfo extends Equatable {
  const BusFareInfo({
    required this.pricingType,
    required this.isFreeBus,
    required this.sectionFaresJson,
    required this.stageFaresJson,
    required this.odFaresJson,
  });

  final int pricingType;
  final bool isFreeBus;
  final List<int> sectionFaresJson;
  final List<int> stageFaresJson;
  final List<int> odFaresJson;

  @override
  List<Object?> get props => [
    pricingType,
    isFreeBus,
    sectionFaresJson,
    stageFaresJson,
    odFaresJson,
  ];
}

/// One operating company for a route (聯營 routes carry several). Fields come
/// straight from TDX Bus/Operator; phone and url may be empty, and the UI hides
/// the matching action when so.
class BusOperatorInfo extends Equatable {
  const BusOperatorInfo({
    required this.name,
    required this.phone,
    required this.url,
  });

  final String name;
  final String phone;
  final String url;

  @override
  List<Object?> get props => [name, phone, url];
}
