import 'package:equatable/equatable.dart';

/// How plan results are ordered. Every order ranks the same itineraries, so
/// changing it asks the planner nothing new.
enum PlanSort { fastest, cheapest, fewestTransfers, leastWalking }

class PlanOptions extends Equatable {
  const PlanOptions({
    this.top = 5,
    this.transitModes = const [3, 4, 5, 6, 7, 8, 9],
    this.transferBufferMinutes = 0,
    this.firstMileMode = 0,
    this.firstMileTime = 10,
    this.lastMileMode = 0,
    this.lastMileTime = 10,
    this.maxTransfers,
    this.avoidReservation = false,
    this.carryBike = false,
    this.wheelchair = false,
    this.walkSpeedCmPerSec = 0,
  });

  final int top;
  final List<int> transitModes;

  /// Slack added on top of every transfer walk. Zero leaves the planner's own
  /// walking and same-stop change times, so the transfer wording on each
  /// result is about the connection itself rather than about padding.
  final int transferBufferMinutes;
  final int firstMileMode;
  final int firstMileTime;
  final int lastMileMode;
  final int lastMileTime;

  final int? maxTransfers;

  /// Exclude services that require a seat reservation — TRA's 對號 trains
  /// above all, which are bookable and useless to someone boarding now.
  final bool avoidReservation;

  /// Require every transit leg to accept a bicycle.
  final bool carryBike;

  /// Step-free routing for every walking segment. Set in Settings: needing it
  /// is a fact about the rider, not about one journey.
  final bool wheelchair;

  /// Walking pace in centimetres per second. 0 leaves the planner's own
  /// default (1.4 m/s) alone, which is what "標準" means.
  final int walkSpeedCmPerSec;

  /// [clearMaxTransfers] is how the ceiling is removed: passing
  /// `maxTransfers: null` cannot mean "clear it" and "leave it alone" at the
  /// same time.
  PlanOptions copyWith({
    int? top,
    List<int>? transitModes,
    int? transferBufferMinutes,
    int? firstMileMode,
    int? firstMileTime,
    int? lastMileMode,
    int? lastMileTime,
    int? maxTransfers,
    bool clearMaxTransfers = false,
    bool? avoidReservation,
    bool? carryBike,
    bool? wheelchair,
    int? walkSpeedCmPerSec,
  }) {
    return PlanOptions(
      top: top ?? this.top,
      transitModes: transitModes ?? this.transitModes,
      transferBufferMinutes:
          transferBufferMinutes ?? this.transferBufferMinutes,
      firstMileMode: firstMileMode ?? this.firstMileMode,
      firstMileTime: firstMileTime ?? this.firstMileTime,
      lastMileMode: lastMileMode ?? this.lastMileMode,
      lastMileTime: lastMileTime ?? this.lastMileTime,
      maxTransfers: clearMaxTransfers
          ? null
          : (maxTransfers ?? this.maxTransfers),
      avoidReservation: avoidReservation ?? this.avoidReservation,
      carryBike: carryBike ?? this.carryBike,
      wheelchair: wheelchair ?? this.wheelchair,
      walkSpeedCmPerSec: walkSpeedCmPerSec ?? this.walkSpeedCmPerSec,
    );
  }

  @override
  List<Object?> get props => [
    top,
    transitModes,
    transferBufferMinutes,
    firstMileMode,
    firstMileTime,
    lastMileMode,
    lastMileTime,
    maxTransfers,
    avoidReservation,
    carryBike,
    wheelchair,
    walkSpeedCmPerSec,
  ];
}
