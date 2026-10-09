import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';

/// Why a CreateTrack call was rejected, mapped to the inline copy the setup
/// sheet shows (never a dialog). InvalidArgument → the train does not reach the
/// chosen alight station; NotFound → the car id resolves to no live trip.
enum MrtTrackCreateError { none, notReachable, notFound, generic }

/// State of the metro alight-reminder feature. At most one session is active
/// (the app shows a single Live Activity), so this is a flat snapshot.
class MrtTrackBlocState extends Equatable {
  const MrtTrackBlocState({
    this.session,
    this.creating = false,
    this.createError = MrtTrackCreateError.none,
    this.boardEtaSeconds,
    this.pickArrival,
    this.pickTargetStationId,
    this.pickLead = 0,
  });

  /// The live session, or null when idle / after a terminal ending.
  final MrtTrackSession? session;

  /// A CreateTrack round-trip is in flight (CTA shows progress, stays off).
  final bool creating;

  /// The last CreateTrack rejection, surfaced inline in the sheet.
  final MrtTrackCreateError createError;

  final int? boardEtaSeconds;

  /// The arrival a 下車站 is currently being chosen for, or null when no
  /// pick is open. Held here rather than on the map screen because the bell
  /// that starts the pick and the map that answers it are different screens.
  final MetroArrival? pickArrival;

  /// The station chosen so far in an open pick, or null before the first tap.
  final String? pickTargetStationId;

  /// 提前站數 for the pick in progress.
  final int pickLead;

  /// Whether a 下車站 is being chosen right now.
  bool get picking => pickArrival != null;

  /// The rider has armed the reminder but the train is not in yet.
  bool get waitingToBoard => (boardEtaSeconds ?? 0) > 0;

  bool get isActive => session != null && !session!.status.isTerminal;

  /// Whether the given arrival tile should render its bell filled: an active
  /// session for the same line, matched by trip id when the arrival carries
  /// one, else by terminal destination.
  bool tracks(MetroArrival arrival) {
    final s = session;
    if (s == null || s.status.isTerminal) return false;
    if (s.line != arrival.line) return false;
    if (s.tripId.isNotEmpty && arrival.trainNumber.isNotEmpty) {
      return s.tripId == arrival.trainNumber;
    }
    return s.targetStationName.isNotEmpty || arrival.destination.isNotEmpty;
  }

  MrtTrackBlocState copyWith({
    MrtTrackSession? session,
    bool clearSession = false,
    bool? creating,
    MrtTrackCreateError? createError,
    int? boardEtaSeconds,
    bool clearBoardEta = false,
    MetroArrival? pickArrival,
    String? pickTargetStationId,
    bool clearPick = false,
    bool clearPickTarget = false,
    int? pickLead,
  }) => MrtTrackBlocState(
    session: clearSession ? null : (session ?? this.session),
    creating: creating ?? this.creating,
    createError: createError ?? this.createError,
    boardEtaSeconds: clearBoardEta
        ? null
        : (boardEtaSeconds ?? this.boardEtaSeconds),
    pickArrival: clearPick ? null : (pickArrival ?? this.pickArrival),
    pickTargetStationId: clearPick || clearPickTarget
        ? null
        : (pickTargetStationId ?? this.pickTargetStationId),
    pickLead: clearPick ? 0 : (pickLead ?? this.pickLead),
  );

  @override
  List<Object?> get props => [
    session,
    creating,
    createError,
    boardEtaSeconds,
    pickArrival,
    pickTargetStationId,
    pickLead,
  ];
}
