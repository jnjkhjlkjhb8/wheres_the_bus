import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';

/// Seat availability per section: O = available, L = limited, X = sold out.
enum ThsrSeatStatus { available, limited, soldOut, unknown }

class ThsrTimetableItem extends Equatable {
  const ThsrTimetableItem({
    required this.trainNo,
    required this.departureTime,
    required this.arrivalTime,
    required this.travelMinutes,
    required this.delayMinutes,
    required this.remark,
    this.seatStatus = ThsrSeatStatus.unknown,
    this.isOvernight = false,
  });

  final String trainNo;
  final String departureTime;
  final String arrivalTime;
  final int travelMinutes;
  final int delayMinutes;

  final String remark;
  final ThsrSeatStatus seatStatus;

  /// 跨日 — the run crosses midnight, so the arrival falls on the next
  /// calendar day.
  final bool isOvernight;

  @override
  List<Object?> get props => [
    trainNo,
    departureTime,
    arrivalTime,
    travelMinutes,
    delayMinutes,
    remark,
    seatStatus,
    isOvernight,
  ];
}

class ThsrFare extends Equatable {
  const ThsrFare({
    required this.fareClass,
    required this.price,
    this.cabinClass = _standardCabin,
  });

  /// 1 全票, 9 半票. THSR charges 孩童, 敬老 and 愛心 the same 半票, so one class
  /// covers all three concessions.
  final int fareClass;

  /// 1 標準對號, 2 商務, 3 自由座.
  final int cabinClass;
  final int price;

  static const int _standardCabin = 1;

  @override
  List<Object?> get props => [fareClass, cabinClass, price];
}

ResolvedFare? thsrFareFor(List<ThsrFare> fares, FareType type) {
  for (final fareClass in type.thsrFareClasses) {
    for (final fare in fares) {
      if (fare.fareClass == fareClass &&
          fare.cabinClass == ThsrFare._standardCabin &&
          fare.price > 0) {
        return (
          price: fare.price,
          matched: type.matchedWhen(isFullFare: fareClass == 1),
        );
      }
    }
  }
  return null;
}

class ThsrStopTime extends Equatable {
  const ThsrStopTime({
    required this.stationName,
    required this.arrivalTime,
    required this.departureTime,
    required this.sequence,
  });
  final String stationName;
  final String arrivalTime;
  final String departureTime;
  final int sequence;
  @override
  List<Object?> get props => [
    stationName,
    arrivalTime,
    departureTime,
    sequence,
  ];
}
