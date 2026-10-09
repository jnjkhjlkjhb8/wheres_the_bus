import 'package:equatable/equatable.dart';

enum RailSystem { tra, thsr }

sealed class RailEvent extends Equatable {
  const RailEvent();
  @override
  List<Object?> get props => [];
}

final class RailSystemChanged extends RailEvent {
  const RailSystemChanged(this.system);
  final RailSystem system;
  @override
  List<Object?> get props => [system];
}

final class RailStationSelection extends Equatable {
  const RailStationSelection({required this.name, this.id});

  final String name;
  final String? id;

  @override
  List<Object?> get props => [name, id];
}

final class RailTimetableRequested extends RailEvent {
  const RailTimetableRequested({
    required this.system,
    required this.origin,
    required this.destination,
    required this.date,
    this.cutoffMinutes,
    this.isDeparture = true,
  });
  final RailSystem system;
  final RailStationSelection origin;
  final RailStationSelection destination;
  final String date;
  // Minutes-of-day the user picked. With [isDeparture] it bounds the results:
  // depart at/after it (true) or arrive at/before it (false). null = no bound.
  final int? cutoffMinutes;
  final bool isDeparture;
  @override
  List<Object?> get props => [
    system,
    origin,
    destination,
    date,
    cutoffMinutes,
    isDeparture,
  ];
}

final class RailTrainStopsRequested extends RailEvent {
  const RailTrainStopsRequested({required this.trainNo, required this.date});
  final String trainNo;
  final String date;
  @override
  List<Object?> get props => [trainNo, date];
}

final class RailDelaysUpdated extends RailEvent {
  const RailDelaysUpdated(this.delays);
  final Map<String, int> delays;
  @override
  List<Object?> get props => [delays];
}
