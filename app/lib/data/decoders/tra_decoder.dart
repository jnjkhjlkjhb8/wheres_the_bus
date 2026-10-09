import 'package:wheres_the_bus/data/generated/tra.pb.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/models/rail_timetable_view.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

class TraDecoder {
  const TraDecoder._();
  static const TraDecoder instance = TraDecoder._();

  /// Reshapes one timetable entry into the card-facing view model, preserving
  /// the origin/destination station names and the display travel-time string
  /// that the parsed-minutes [TraTimetableItem] does not carry.
  RailTimetableView decodeTimetableCard(tra_timetable t) => RailTimetableView(
    trainNo: t.trainNo,
    trainType: t.trainTypeName,
    originName: t.startingStationName,
    destinationName: t.endingStationName,
    departureTime: t.startingTime,
    arrivalTime: t.endingTime,
    travelTime: t.travelTime,
  );

  /// One station's next departures, already ordered and windowed by the
  /// router. Each row keeps its own service date, because a board opened near
  /// midnight carries the next day's early trains at the bottom.
  List<RailStationDeparture> decodeStationBoard(tra_station_board board) =>
      board.items
          .map(
            (d) => RailStationDeparture(
              trainNo: d.trainNo,
              trainType: d.trainTypeName,
              destination: d.destinationStationName,
              departureTime: d.departureTime,
              serviceDate: d.trainDate,
              isSuspended: _bit(d.mask, _maskSuspended),
              remark: d.note,
            ),
          )
          .toList();

  /// One fare per 票種 × 車種 combination — see `traFareFor`.
  List<TraFare> decodeFares(tra_fare_items fares) => fares.items
      .map((f) => TraFare(ticketType: f.ticketType, price: f.price))
      .toList();

  /// delay is a map of trainNo to delayMinutes
  Map<String, int> decodeDelayMap(tra_delays delays) => delays.delay;

  List<TraStopTime> decodeStops(tra_stoptimes stoptimes) {
    return stoptimes.items
        .map(
          (s) => TraStopTime(
            stationName: s.stationName,
            arrivalTime: s.arrivalTime,
            departureTime: s.departureTime,
            sequence: s.stopSequence,
          ),
        )
        .toList();
  }

  List<TraTimetableItem> decodeTimetable(tra_timetables timetables) {
    return timetables.items
        .map(
          (t) => TraTimetableItem(
            trainNo: t.trainNo,
            trainType: t.trainTypeName,
            departureTime: t.startingTime,
            arrivalTime: t.endingTime,
            travelMinutes: _parseTravelMinutes(t.travelTime),
            delayMinutes: 0,
            isDisabledFriendly: _bit(t.mask, _maskWheelchair),
            hasDiningCar: _bit(t.mask, _maskDining),
            hasBike: _bit(t.mask, _maskBike),
            hasBreastfeeding: _bit(t.mask, _maskBreastfeeding),
            runsDaily: _bit(t.mask, _maskDaily),
            isAddedService: _bit(t.mask, _maskAddedService),
            isSuspended: _bit(t.mask, _maskSuspended),
            remark: t.note,
          ),
        )
        .toList();
  }

  // Bit positions in tra_timetable.mask, packed by railMask() in
  // services/functions/rail.go. Bit 1 (行李服務) is decoded by neither side —
  // there is no icon for it and nothing in the UI shows it.
  static const _maskWheelchair = 0;
  static const _maskDining = 2;
  static const _maskBike = 3;
  static const _maskBreastfeeding = 4;
  static const _maskDaily = 5;
  static const _maskAddedService = 6;
  static const _maskSuspended = 7;

  static bool _bit(int mask, int position) => mask & (1 << position) != 0;

  int _parseTravelMinutes(String travel) {
    if (travel.contains(':')) {
      final parts = travel.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        return h * 60 + m;
      }
    }
    return int.tryParse(travel.replaceAll('分', '')) ?? 0;
  }
}
