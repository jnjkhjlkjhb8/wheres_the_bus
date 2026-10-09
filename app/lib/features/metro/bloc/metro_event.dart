import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';

sealed class MetroEvent extends Equatable {
  const MetroEvent();
  @override
  List<Object?> get props => [];
}

class MetroStationTapped extends MetroEvent {
  const MetroStationTapped({required this.stationId});
  final String stationId;
  @override
  List<Object?> get props => [stationId];
}

class MetroStationDismissed extends MetroEvent {
  const MetroStationDismissed();
}

class MetroJourneyMatrixLoaded extends MetroEvent {
  const MetroJourneyMatrixLoaded({required this.matrix});
  final Map<String, JourneyInfo> matrix;
  @override
  List<Object?> get props => [matrix];
}
