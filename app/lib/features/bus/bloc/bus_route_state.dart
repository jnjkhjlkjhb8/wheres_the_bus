import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';

class BusRouteState extends Equatable {
  const BusRouteState({
    this.route,
    this.etaMap = const {},
    this.daily,
    this.fare,
    this.bufferSequences = const {},
    this.direction = 0,
    this.reminders = const {},
    this.loading = true,
    this.error,
    this.updatedAt,
  });

  final BusRouteViewModel? route;
  final Map<String, BusStopEtaViewModel> etaMap;
  final BusDailyTimetable? daily;
  final BusFareInfo? fare;
  final Set<int> bufferSequences;
  final int direction;

  final Map<String, String> reminders;
  final bool loading;
  final AppError? error;

  final DateTime? updatedAt;

  List<BusStopModel> get currentStops =>
      direction == 0 ? (route?.stopsGo ?? []) : (route?.stopsReturn ?? []);

  String get currentHeadsign => direction == 0
      ? (route?.headsignGo ?? '')
      : (route?.headsignReturn ?? '');

  BusRouteState copyWith({
    BusRouteViewModel? route,
    Map<String, BusStopEtaViewModel>? etaMap,
    BusDailyTimetable? daily,
    BusFareInfo? fare,
    Set<int>? bufferSequences,
    int? direction,
    Map<String, String>? reminders,
    bool? loading,
    AppError? error,
    bool clearError = false,
    DateTime? updatedAt,
  }) => BusRouteState(
    route: route ?? this.route,
    etaMap: etaMap ?? this.etaMap,
    daily: daily ?? this.daily,
    fare: fare ?? this.fare,
    bufferSequences: bufferSequences ?? this.bufferSequences,
    direction: direction ?? this.direction,
    reminders: reminders ?? this.reminders,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  List<Object?> get props => [
    route,
    etaMap,
    daily,
    fare,
    bufferSequences,
    direction,
    updatedAt,
    reminders,
    loading,
    error,
  ];
}
