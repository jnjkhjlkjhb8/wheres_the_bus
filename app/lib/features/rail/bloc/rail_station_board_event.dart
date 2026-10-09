import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';

sealed class RailStationBoardEvent extends Equatable {
  const RailStationBoardEvent();
  @override
  List<Object?> get props => [];
}

/// Load (or reload) the board for one direction. The station is fixed for the
/// bloc's lifetime — it is the station the rider tapped — so only the direction
/// travels on the event.
final class RailStationBoardRequested extends RailStationBoardEvent {
  const RailStationBoardRequested(this.direction);

  final RailBoardDirection direction;

  @override
  List<Object?> get props => [direction];
}

/// A frame from the system-wide TRA delay board, keyed by train number.
final class RailStationBoardDelaysUpdated extends RailStationBoardEvent {
  const RailStationBoardDelaysUpdated(this.delays);

  final Map<String, int> delays;

  @override
  List<Object?> get props => [delays];
}
