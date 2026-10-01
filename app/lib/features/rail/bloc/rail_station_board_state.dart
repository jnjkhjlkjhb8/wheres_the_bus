import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';

/// Every state carries the direction it belongs to, so the segmented control
/// reads its position from the state rather than from a second copy in the
/// view — a request that fails must leave the control where the rider put it.
sealed class RailStationBoardState extends Equatable {
  const RailStationBoardState({required this.direction});

  final RailBoardDirection direction;

  @override
  List<Object?> get props => [direction];
}

final class RailStationBoardLoading extends RailStationBoardState {
  const RailStationBoardLoading({required super.direction});
}

final class RailStationBoardLoaded extends RailStationBoardState {
  const RailStationBoardLoaded({
    required super.direction,
    required this.departures,
    this.delays = const {},
    this.delaysUpdatedAt,
  });

  final List<RailStationDeparture> departures;

  /// Live 誤點 minutes by train number, TRA only. Absent means on time.
  final Map<String, int> delays;

  final DateTime? delaysUpdatedAt;

  RailStationBoardLoaded copyWith({
    Map<String, int>? delays,
    DateTime? delaysUpdatedAt,
  }) => RailStationBoardLoaded(
    direction: direction,
    departures: departures,
    delays: delays ?? this.delays,
    delaysUpdatedAt: delaysUpdatedAt ?? this.delaysUpdatedAt,
  );

  @override
  List<Object?> get props => [
    direction,
    departures,
    delays,
    delaysUpdatedAt,
  ];
}

final class RailStationBoardFailure extends RailStationBoardState {
  const RailStationBoardFailure({
    required super.direction,
    required this.error,
  });

  final AppError error;

  @override
  List<Object?> get props => [direction, error];
}
