import 'package:equatable/equatable.dart';

sealed class RailTrainEvent extends Equatable {
  const RailTrainEvent();

  @override
  List<Object?> get props => [];
}

/// Loads (or reloads, on retry) the train's stops and fare.
class RailTrainStarted extends RailTrainEvent {
  const RailTrainStarted();
}

/// Internal: a fresh live TRA 誤點 value (minutes) for this train.
class RailTrainDelayUpdated extends RailTrainEvent {
  const RailTrainDelayUpdated(this.minutes);
  final int minutes;

  @override
  List<Object?> get props => [minutes];
}
