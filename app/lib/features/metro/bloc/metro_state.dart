import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';

class MetroState extends Equatable {
  const MetroState({
    this.activeStationId,
    this.journeyMatrix,
    this.error,
  });

  final String? activeStationId;
  final Map<String, JourneyInfo>? journeyMatrix;
  final AppError? error;

  MetroState copyWith({
    String? activeStationId,
    bool clearStation = false,
    Map<String, JourneyInfo>? journeyMatrix,
    bool clearMatrix = false,
    AppError? error,
    bool clearError = false,
  }) => MetroState(
    activeStationId: clearStation
        ? null
        : activeStationId ?? this.activeStationId,
    journeyMatrix: clearMatrix ? null : journeyMatrix ?? this.journeyMatrix,
    error: clearError ? null : error ?? this.error,
  );

  @override
  List<Object?> get props => [
    activeStationId,
    journeyMatrix,
    error,
  ];
}
