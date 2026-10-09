import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';

class NearbyState extends Equatable {
  const NearbyState({
    this.stations = const [],
    this.loading = true,
    this.error,
  });

  final List<NearStationViewModel> stations;
  final bool loading;
  final AppError? error;

  NearbyState copyWith({
    List<NearStationViewModel>? stations,
    bool? loading,
    AppError? error,
    bool clearError = false,
  }) => NearbyState(
    stations: stations ?? this.stations,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
  );

  @override
  List<Object?> get props => [stations, loading, error];
}
