import 'package:wheres_the_bus/data/generated/thsr.pb.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/models/rail_timetable_view.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';

class ThsrDecoder {
  const ThsrDecoder._();
  static const ThsrDecoder instance = ThsrDecoder._();

  /// One station's next departures. The train type is left empty rather than
  /// filled with '高鐵': THSR runs a single class, so a chip repeating the
  /// system on every row of a THSR board would say nothing.
  List<RailStationDeparture> decodeStationBoard(thsr_station_board board) =>
      board.items
          .map(
            (d) => RailStationDeparture(
              trainNo: d.trainNo,
              trainType: '',
              destination: d.destinationStationName,
              departureTime: d.departureTime,
              serviceDate: d.trainDate,
              remark: d.note,
            ),
          )
          .toList();

  /// Reshapes one THSR timetable entry into the card-facing view model. THSR
  /// has a single service class, so the type label is fixed rather than
  /// carried on the wire.
  RailTimetableView decodeTimetableCard(thsa_timetable t) => RailTimetableView(
    trainNo: t.trainNo,
    trainType: '高鐵',
    originName: t.startingStationName,
    destinationName: t.endingStationName,
    departureTime: t.startingTime,
    arrivalTime: t.endingTime,
    travelTime: t.travelTime,
  );

  List<ThsrTimetableItem> decodeTimetable(thsr_timetables timetables) {
    return timetables.items
        .map(
          (t) => ThsrTimetableItem(
            trainNo: t.trainNo,
            departureTime: t.startingTime,
            arrivalTime: t.endingTime,
            travelMinutes: _parseTravelMinutes(t.travelTime),
            delayMinutes: 0,
            remark: t.note,
            isOvernight: t.overnight,
          ),
        )
        .toList();
  }

  /// One fare per fare class × cabin class — see [thsrFareFor].
  List<ThsrFare> decodeFares(thsa_fares fares) => fares.items
      .map(
        (f) => ThsrFare(
          fareClass: f.fareClass,
          cabinClass: f.cabinClas,
          price: f.price,
        ),
      )
      .toList();

  List<ThsrStopTime> decodeStopTimes(thsr_stoptimes stoptimes) {
    return stoptimes.items
        .map(
          (s) => ThsrStopTime(
            stationName: s.stationName,
            arrivalTime: s.arrivalTime,
            departureTime: s.departureTime,
            sequence: s.stopSequence,
          ),
        )
        .toList();
  }

  ThsrSeatStatus decodeSeatStatus(
    thsr_available_seats seats, {
    required String fromStationId,
    required String toStationId,
    bool business = false,
  }) {
    final from = seats.segments.indexWhere(
      (s) => s.originStationId == fromStationId,
    );
    if (from < 0) return ThsrSeatStatus.unknown;
    // The journey ends at the leg that arrives at the alighting station, which
    // covers a terminus and an intermediate stop alike. A station this train
    // never reaches ends nothing, and stays unknown.
    final end =
        seats.segments.indexWhere(
          (s) => s.destinationStationId == toStationId,
          from,
        ) +
        1;
    if (end <= from) return ThsrSeatStatus.unknown;
    // available < limited < soldOut in declaration order, so the worst status
    // over the journey is the highest index; unknown returns before the
    // comparison.
    var worst = ThsrSeatStatus.available;
    for (final segment in seats.segments.sublist(from, end)) {
      final status = _seatStatusOf(
        business ? segment.businessSeatStatus : segment.standardSeatStatus,
      );
      if (status == ThsrSeatStatus.unknown) return ThsrSeatStatus.unknown;
      if (status.index > worst.index) worst = status;
    }
    return worst;
  }

  /// O = 尚有座位, L = 即將售完, X = 已售完. Anything else is a letter this app
  /// does not know, which is not the same as a seat.
  ThsrSeatStatus _seatStatusOf(String code) => switch (code.toUpperCase()) {
    'O' => ThsrSeatStatus.available,
    'L' => ThsrSeatStatus.limited,
    'X' => ThsrSeatStatus.soldOut,
    _ => ThsrSeatStatus.unknown,
  };

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
