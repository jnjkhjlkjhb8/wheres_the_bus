import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';

enum RailTrainStatus { loading, loaded, empty, error }

/// One stop on a train's timetable, normalized across TRA/THSR.
class RailTrainStop extends Equatable {
  const RailTrainStop({
    required this.name,
    required this.arrive,
    required this.depart,
  });

  final String name;
  final String arrive;
  final String depart;

  @override
  List<Object?> get props => [name, arrive, depart];
}

class RailTrainState extends Equatable {
  const RailTrainState({
    this.status = RailTrainStatus.loading,
    this.stops = const [],
    this.fullFare,
    this.userFare,
    this.error,
    this.liveDelayMinutes,
    this.delayUpdatedAt,
  });

  final RailTrainStatus status;
  final List<RailTrainStop> stops;

  /// Adult (全票) fare in NT$ for the train's own full run (its first stop to
  /// its last), or null when the fare query has no data.
  final RailFareQuote? fullFare;

  final RailFareQuote? userFare;
  final AppError? error;

  /// Live TRA 誤點 minutes for this train, or null before the first delay
  /// frame lands (THSR stays null — no delay feed). The screen falls back to
  /// the snapshot it navigated in with while this is null.
  final int? liveDelayMinutes;

  /// When the last delay frame landed, or null before the first one (and
  /// always, for THSR). The stop times are landed timetable data; the delay
  /// laid over them is the part that ages.
  final DateTime? delayUpdatedAt;

  RailTrainState copyWith({
    RailTrainStatus? status,
    List<RailTrainStop>? stops,
    RailFareQuote? fullFare,
    RailFareQuote? userFare,
    AppError? error,
    int? liveDelayMinutes,
    DateTime? delayUpdatedAt,
  }) => RailTrainState(
    status: status ?? this.status,
    stops: stops ?? this.stops,
    fullFare: fullFare ?? this.fullFare,
    userFare: userFare ?? this.userFare,
    error: error ?? this.error,
    liveDelayMinutes: liveDelayMinutes ?? this.liveDelayMinutes,
    delayUpdatedAt: delayUpdatedAt ?? this.delayUpdatedAt,
  );

  @override
  List<Object?> get props => [
    status,
    stops,
    fullFare,
    userFare,
    error,
    liveDelayMinutes,
    delayUpdatedAt,
  ];
}
