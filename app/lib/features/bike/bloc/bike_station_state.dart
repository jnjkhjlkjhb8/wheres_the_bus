import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';

class BikeStationState extends Equatable {
  const BikeStationState({
    this.name = '',
    this.capacity = 0,
    this.lat = 0,
    this.lon = 0,
    this.available = 0,
    this.returnDocks = 0,
    this.generalBikes = 0,
    this.electricBikes = 0,
    this.loading = true,
    this.hasLiveData = false,
    this.updatedAt,
    this.error,
    this.liveError,
  });

  final String name;
  final int capacity;
  final double lat;
  final double lon;
  final int available;
  final int returnDocks;
  final int generalBikes;
  final int electricBikes;
  final bool loading;

  /// Whether at least one live ETA frame has been received. `available == 0`
  /// is a legitimate reading once this is true; while it's false, the zero
  /// shown is only the field default, not a confirmed empty station (F27).
  final bool hasLiveData;

  /// When the last live availability frame landed. Shown as a clock time, so
  /// counts that stopped updating are visibly stale rather than silently old.
  /// Null until the first frame.
  final DateTime? updatedAt;

  /// Static station-info fetch failure (name/capacity never loaded).
  final String? error;

  final AppError? liveError;

  BikeStationState copyWith({
    String? name,
    int? capacity,
    double? lat,
    double? lon,
    int? available,
    int? returnDocks,
    int? generalBikes,
    int? electricBikes,
    bool? loading,
    bool? hasLiveData,
    DateTime? updatedAt,
    String? error,
    bool clearError = false,
    AppError? liveError,
    bool clearLiveError = false,
  }) => BikeStationState(
    name: name ?? this.name,
    capacity: capacity ?? this.capacity,
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    available: available ?? this.available,
    returnDocks: returnDocks ?? this.returnDocks,
    generalBikes: generalBikes ?? this.generalBikes,
    electricBikes: electricBikes ?? this.electricBikes,
    loading: loading ?? this.loading,
    hasLiveData: hasLiveData ?? this.hasLiveData,
    updatedAt: updatedAt ?? this.updatedAt,
    error: clearError ? null : (error ?? this.error),
    liveError: clearLiveError ? null : (liveError ?? this.liveError),
  );

  @override
  List<Object?> get props => [
    name,
    capacity,
    lat,
    lon,
    available,
    returnDocks,
    generalBikes,
    electricBikes,
    loading,
    hasLiveData,
    updatedAt,
    error,
    liveError,
  ];
}
