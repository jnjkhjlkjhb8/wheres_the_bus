import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

enum BusStopStatus { loading, loaded, empty, error }

class BusStopArrivalItem extends Equatable {
  BusStopArrivalItem(AppI18n i18n, this.source)
    : display = ArrivalDisplay.fromBusStop(i18n, source);

  final BusStopArrival source;
  final ArrivalDisplay display;

  String get stationId => source.stationId;
  String get subRouteUid => source.subRouteUid;
  int get rank => display.rank;

  /// Stable per-arrival identity for list keys: a route (sub-route) at a
  /// member stop. Keeps each row's element paired with the right item across
  /// a re-sort.
  String get itemKey => '$stationId:$subRouteUid';

  @override
  List<Object?> get props => [source];
}

const String kMemberDestinationPrefix = '往';

Map<String, String> memberStopLabels(
  List<BusStationMember> members,
  Map<String, List<BusStopArrivalItem>> byStation,
) {
  if (members.isEmpty) return const {};

  String base(BusStationMember m) {
    final dests = <String>{
      for (final a in byStation[m.stationUid] ?? const <BusStopArrivalItem>[])
        if (a.display.destination.isNotEmpty) a.display.destination,
    };
    if (dests.isNotEmpty) {
      return '$kMemberDestinationPrefix${dests.take(2).join('、')}';
    }
    return m.stationName;
  }

  final bases = {for (final m in members) m.stationUid: base(m)};
  final counts = <String, int>{};
  for (final v in bases.values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  final seen = <String, int>{};
  final labels = <String, String>{};
  for (final m in members) {
    var label = bases[m.stationUid]!;
    if ((counts[label] ?? 0) > 1) {
      final n = (seen[label] ?? 0) + 1;
      seen[label] = n;
      if (n > 1) label = '$label $n';
    }
    labels[m.stationUid] = label;
  }
  return labels;
}

class BusStopState extends Equatable {
  const BusStopState({
    this.status = BusStopStatus.loading,
    this.members = const [],
    this.arrivals = const [],
    this.displays = const [],
    this.arrivalsByStation = const {},
    this.selectedStationUid,
    this.updatedAt,
    this.error,
  });

  final BusStopStatus status;
  final List<BusStationMember> members;
  final List<BusStopArrival> arrivals;

  /// Sorted (soonest first) tile view-models, derived from [arrivals] in the
  /// bloc. Deterministic from [arrivals], so it stays out of [props].
  final List<BusStopArrivalItem> displays;

  /// [displays] grouped by member stop (keyed by arrival stationId, which pairs
  /// with member stationUid). Also derived, also out of [props].
  final Map<String, List<BusStopArrivalItem>> arrivalsByStation;

  /// Selected member stop UID, or null for 全部 (show every member).
  final String? selectedStationUid;
  final DateTime? updatedAt;
  final AppError? error;

  BusStopState copyWith({
    BusStopStatus? status,
    List<BusStationMember>? members,
    List<BusStopArrival>? arrivals,
    List<BusStopArrivalItem>? displays,
    Map<String, List<BusStopArrivalItem>>? arrivalsByStation,
    String? selectedStationUid,
    bool clearSelection = false,
    DateTime? updatedAt,
    AppError? error,
    bool clearError = false,
  }) => BusStopState(
    status: status ?? this.status,
    members: members ?? this.members,
    arrivals: arrivals ?? this.arrivals,
    displays: displays ?? this.displays,
    arrivalsByStation: arrivalsByStation ?? this.arrivalsByStation,
    selectedStationUid: clearSelection
        ? null
        : (selectedStationUid ?? this.selectedStationUid),
    updatedAt: updatedAt ?? this.updatedAt,
    error: clearError ? null : (error ?? this.error),
  );

  // [displays] and [arrivalsByStation] are a deterministic function of
  // [arrivals], so they are omitted here — including them would just re-run the
  // same equality over derived data.
  @override
  List<Object?> get props => [
    status,
    members,
    arrivals,
    selectedStationUid,
    updatedAt,
    error,
  ];
}
