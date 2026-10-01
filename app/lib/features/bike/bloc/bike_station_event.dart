import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';

sealed class BikeStationEvent extends Equatable {
  const BikeStationEvent();
  @override
  List<Object?> get props => [];
}

final class BikeStationStarted extends BikeStationEvent {
  const BikeStationStarted();
}

final class BikeStationEtaUpdated extends BikeStationEvent {
  const BikeStationEtaUpdated({
    required this.available,
    required this.returnDocks,
    required this.generalBikes,
    required this.electricBikes,
  });
  final int available;
  final int returnDocks;
  final int generalBikes;
  final int electricBikes;
  @override
  List<Object?> get props => [
    available,
    returnDocks,
    generalBikes,
    electricBikes,
  ];
}

final class BikeStationEtaFailed extends BikeStationEvent {
  const BikeStationEtaFailed(this.error);

  /// The error itself, not a rendered sentence: the bloc has no `BuildContext`
  /// and so no locale, and resolving the copy here would freeze it in the
  /// language that happened to be active when the stream died.
  final AppError error;
  @override
  List<Object?> get props => [error];
}

/// Emitted when the live availability stream recovers after a prior failure.
final class BikeStationEtaRecovered extends BikeStationEvent {
  const BikeStationEtaRecovered();
}
