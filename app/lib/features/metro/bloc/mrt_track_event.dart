import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';

sealed class MrtTrackEvent extends Equatable {
  const MrtTrackEvent();
  @override
  List<Object?> get props => [];
}

/// Opens pick-mode for [arrival]: the rider is about to choose a 下車站 on the
/// line map. Carries no I/O — the flow only becomes a session at
/// [MrtTrackRequested].
class MrtAlightPickStarted extends MrtTrackEvent {
  const MrtAlightPickStarted(this.arrival);

  final MetroArrival arrival;

  @override
  List<Object?> get props => [arrival];
}

/// Leaves pick-mode with nothing started.
class MrtAlightPickCancelled extends MrtTrackEvent {
  const MrtAlightPickCancelled();
}

/// A station was tapped on the map as the 下車站.
class MrtAlightTargetPicked extends MrtTrackEvent {
  const MrtAlightTargetPicked(this.stationId);

  final String stationId;

  @override
  List<Object?> get props => [stationId];
}

/// 改選: back to the map with the pick still open but no station chosen.
class MrtAlightTargetCleared extends MrtTrackEvent {
  const MrtAlightTargetCleared();
}

/// 提前站數 changed in the confirm bar.
class MrtAlightLeadChanged extends MrtTrackEvent {
  const MrtAlightLeadChanged(this.leadStops);

  final int leadStops;

  @override
  List<Object?> get props => [leadStops];
}

/// Opens a session from the setup sheet's CTA. carId is already derived
/// (from CN1) or typed; the rest come from the tapped arrival + picker.
class MrtTrackRequested extends MrtTrackEvent {
  const MrtTrackRequested({
    required this.carId,
    required this.boardStationId,
    required this.destStationId,
    required this.targetStationId,
    required this.leadStops,
    this.system = 'TRTC',
    this.trainNumber = '',
    this.boardEtaSeconds,
  });

  final String carId;
  final String boardStationId;
  final String destStationId;
  final String targetStationId;
  final int leadStops;

  /// Identity of the boarding-station arrival feed to watch until the train
  /// pulls in. Empty [trainNumber] simply skips the pre-board window: the card
  /// then opens straight into riding, which is what an unpaired train gives us.
  final String system;
  final String trainNumber;

  /// The tapped arrival's own estimate, so the card opens on the reading the
  /// rider was just looking at rather than waiting for the next feed frame.
  final int? boardEtaSeconds;

  @override
  List<Object?> get props => [
    system,
    trainNumber,
    boardEtaSeconds,
    carId,
    boardStationId,
    destStationId,
    targetStationId,
    leadStops,
  ];
}

/// One WatchTrack frame decoded into a session snapshot.
class MrtTrackUpdated extends MrtTrackEvent {
  const MrtTrackUpdated(this.session);
  final MrtTrackSession session;
  @override
  List<Object?> get props => [session];
}

/// The resilient watch stream reported a failure. It keeps reconnecting, so
/// this arms the grace window rather than ending the session.
class MrtTrackWatchFailed extends MrtTrackEvent {
  const MrtTrackWatchFailed();
}

/// The watch stream came back before the grace window ran out.
class MrtTrackWatchRecovered extends MrtTrackEvent {
  const MrtTrackWatchRecovered();
}

/// The grace window ran out with the stream still down — the session is over.
class MrtTrackWatchLost extends MrtTrackEvent {
  const MrtTrackWatchLost();
}

/// Cancels the active session — the bell toggle-off, or the Android
/// notification's 取消追蹤 action. Reversible: the user can rebind after.
class MrtTrackCancelled extends MrtTrackEvent {
  const MrtTrackCancelled();
}

/// Restores a persisted session on startup and re-subscribes its watch.
class MrtTrackRestored extends MrtTrackEvent {
  const MrtTrackRestored();
}

class MrtTrackPushTokenReceived extends MrtTrackEvent {
  const MrtTrackPushTokenReceived(this.token);

  final String token;

  @override
  List<Object?> get props => [token];
}

class MrtBoardEtaTicked extends MrtTrackEvent {
  const MrtBoardEtaTicked(this.seconds);

  final int seconds;

  @override
  List<Object?> get props => [seconds];
}
