import 'package:equatable/equatable.dart';

String mrtLineOfStation(String stationId) =>
    RegExp('^([A-Za-z]+)').firstMatch(stationId)?.group(1) ?? '';

/// The lifecycle status of a metro 追蹤 session, mirroring MrtTrackState.status
/// on the wire. `tracking`/`leadFired` are live; the rest are terminal.
enum MrtTrackStatus {
  tracking,
  leadFired,
  arrived,
  lost,
  stale,
  cancelled;

  static MrtTrackStatus fromWire(String value) => switch (value) {
    'tracking' => MrtTrackStatus.tracking,
    'lead_fired' => MrtTrackStatus.leadFired,
    'arrived' => MrtTrackStatus.arrived,
    'lost' => MrtTrackStatus.lost,
    'stale' => MrtTrackStatus.stale,
    'cancelled' => MrtTrackStatus.cancelled,
    // An unknown status is treated as terminal so a session can never wedge
    // the bell on forever against a state the app does not understand.
    _ => MrtTrackStatus.cancelled,
  };

  /// True once the session has ended (arrived / lost / stale / cancelled) —
  /// the bell clears and the Live Activity stops.
  bool get isTerminal => switch (this) {
    MrtTrackStatus.tracking || MrtTrackStatus.leadFired => false,
    _ => true,
  };
}

class MrtTrackSession extends Equatable {
  const MrtTrackSession({
    required this.trackId,
    required this.tripId,
    required this.carId,
    required this.pathStationIds,
    required this.pathStationNames,
    required this.targetIndex,
    required this.currentIndex,
    required this.remainingStops,
    required this.nextStationId,
    required this.nextStationName,
    required this.progress,
    required this.status,
    required this.leadStops,
    required this.system,
  });

  factory MrtTrackSession.fromJson(Map<String, dynamic> json) =>
      MrtTrackSession(
        trackId: json['trackId'] as String? ?? '',
        tripId: json['tripId'] as String? ?? '',
        carId: json['carId'] as String? ?? '',
        pathStationIds: (json['pathStationIds'] as List? ?? const [])
            .cast<String>(),
        pathStationNames: (json['pathStationNames'] as List? ?? const [])
            .cast<String>(),
        targetIndex: json['targetIndex'] as int? ?? 0,
        currentIndex: json['currentIndex'] as int? ?? 0,
        remainingStops: json['remainingStops'] as int? ?? 0,
        nextStationId: json['nextStationId'] as String? ?? '',
        nextStationName: json['nextStationName'] as String? ?? '',
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        status: MrtTrackStatus.fromWire(json['status'] as String? ?? ''),
        leadStops: json['leadStops'] as int? ?? 1,
        system: json['system'] as String? ?? 'TRTC',
      );

  final String trackId;
  final String tripId;
  final String carId;
  final List<String> pathStationIds;
  final List<String> pathStationNames;
  final int targetIndex;
  final int currentIndex;
  final int remainingStops;
  final String nextStationId;
  final String nextStationName;
  final double progress;
  final MrtTrackStatus status;
  final int leadStops;
  final String system;

  /// Board station code (path origin), used to match the session to a tile.
  String get boardStationId =>
      pathStationIds.isNotEmpty ? pathStationIds.first : '';

  /// Alight (target) station name for the surfaces' 往 {target} copy.
  String get targetStationName =>
      targetIndex >= 0 && targetIndex < pathStationNames.length
      ? pathStationNames[targetIndex]
      : '';

  /// Line letters of the tracked train, from the board station code.
  String get line => mrtLineOfStation(boardStationId);

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'tripId': tripId,
    'carId': carId,
    'pathStationIds': pathStationIds,
    'pathStationNames': pathStationNames,
    'targetIndex': targetIndex,
    'currentIndex': currentIndex,
    'remainingStops': remainingStops,
    'nextStationId': nextStationId,
    'nextStationName': nextStationName,
    'progress': progress,
    'status': status.name,
    'leadStops': leadStops,
    'system': system,
  };

  @override
  List<Object?> get props => [
    trackId,
    tripId,
    carId,
    pathStationIds,
    pathStationNames,
    targetIndex,
    currentIndex,
    remainingStops,
    nextStationId,
    nextStationName,
    progress,
    status,
    leadStops,
    system,
  ];
}
